#!/usr/bin/env python3
"""Replays a StackOverflow parquet table onto a Redpanda topic, in
CreationDate order, at an accelerated-but-throttled rate.

Reads only as many row groups as needed to satisfy MAX_ROWS (via pyarrow's
lazy batch iterator over S3), so it never downloads the full multi-GB yearly
file just to demo a few hundred thousand rows.

Env vars:
  TABLE        posts | votes | comments | all (comma-separated also allowed)
  YEAR         which yearly parquet file to read (default 2020)
  MAX_ROWS     row cap PER TABLE (default 200000)
  SPEEDUP      wall-clock compression factor (default 20000)
  TOPIC_PREFIX Redpanda topic prefix (default "so")
  BROKER       Kafka bootstrap servers (default "redpanda:9092")
"""
import io
import json
import math
import os
import sys
import threading
import time
from datetime import datetime, timezone

import pandas as pd
import pyarrow.fs as pafs
import pyarrow.parquet as pq
from confluent_kafka import Producer

S3_BUCKET = "datasets-documentation"
S3_REGION = "eu-west-3"
S3_PREFIX = "stackoverflow/parquet"
EPOCH_STR = "1970-01-01 00:00:00.000"
MAX_SLEEP_PER_ROW_SECONDS = 2.0
BATCH_SIZE = 50_000

# column -> default value used when the source parquet has a null/NaN.
DEFAULTS = {
    "posts": {
        "AcceptedAnswerId": 0, "Score": 0, "ViewCount": 0, "Body": "",
        "OwnerUserId": 0, "OwnerDisplayName": "", "LastEditorUserId": 0,
        "LastEditorDisplayName": "", "LastEditDate": None, "LastActivityDate": None,
        "Title": "", "Tags": "", "AnswerCount": 0, "CommentCount": 0,
        "FavoriteCount": 0, "ContentLicense": "", "ParentId": "",
        "CommunityOwnedDate": None, "ClosedDate": None,
    },
    "votes": {"UserId": 0, "BountyAmount": 0},
    "comments": {"Score": 0, "Text": "", "UserId": 0, "UserDisplayName": ""},
}

DATETIME_COLUMNS = {
    "posts": ["CreationDate", "LastEditDate", "LastActivityDate", "CommunityOwnedDate", "ClosedDate"],
    "votes": ["CreationDate"],
    "comments": ["CreationDate"],
}


def log(msg):
    print(f"[replayer] {msg}", flush=True)


def s3_parquet_path(table: str, year: int) -> str:
    return f"{S3_BUCKET}/{S3_PREFIX}/{table}/{year}.parquet"


def load_subset(table: str, year: int, max_rows: int) -> pd.DataFrame:
    """Reads just enough row groups from the S3 parquet file to gather
    max_rows, then returns them sorted by CreationDate."""
    path = s3_parquet_path(table, year)
    log(f"opening s3://{path} (reading up to {max_rows} rows, anonymous access)")
    fs = pafs.S3FileSystem(anonymous=True, region=S3_REGION)
    with fs.open_input_file(path) as f:
        pf = pq.ParquetFile(f)
        batches = []
        collected = 0
        for batch in pf.iter_batches(batch_size=BATCH_SIZE):
            batches.append(batch)
            collected += batch.num_rows
            if collected >= max_rows:
                break
        if not batches:
            raise RuntimeError(f"no data read from {path}")
        import pyarrow as pa  # local import: only needed here
        arrow_table = pa.Table.from_batches(batches)
    df = arrow_table.to_pandas()
    if len(df) > max_rows:
        df = df.iloc[:max_rows].copy()
    for col in DATETIME_COLUMNS.get(table, []):
        if col in df.columns:
            df[col] = pd.to_datetime(df[col], errors="coerce", utc=True)
    df = df.sort_values("CreationDate").reset_index(drop=True)
    log(f"loaded {len(df)} rows for {table}, spanning {df['CreationDate'].min()} .. {df['CreationDate'].max()}")
    return df


def fmt_datetime(value) -> str:
    if value is None or pd.isna(value):
        return EPOCH_STR
    if isinstance(value, pd.Timestamp):
        value = value.to_pydatetime()
    return value.strftime("%Y-%m-%d %H:%M:%S.") + f"{int(value.microsecond / 1000):03d}"


def row_to_json(table: str, row: dict) -> str:
    defaults = DEFAULTS.get(table, {})
    out = {}
    for key, value in row.items():
        if key in DATETIME_COLUMNS.get(table, []):
            out[key] = fmt_datetime(value)
            continue
        # StackOverflow's parquet stores string columns as Arrow `binary`;
        # to_pandas() surfaces these as Python `bytes`, not `str`. Without
        # this, json.dumps falls back to repr() and every text field ends up
        # literally containing "b'...'" in ClickHouse.
        if isinstance(value, bytes):
            value = value.decode("utf-8", errors="replace")
        if value is None or (isinstance(value, float) and math.isnan(value)):
            value = defaults.get(key, 0 if not isinstance(defaults.get(key), str) else "")
        # numpy scalar types aren't JSON-serializable directly
        if hasattr(value, "item"):
            value = value.item()
        out[key] = value
    return json.dumps(out, default=str)


def replay_table(table: str, year: int, max_rows: int, speedup: float, topic_prefix: str, broker: str):
    df = load_subset(table, year, max_rows)
    producer = Producer({"bootstrap.servers": broker})
    topic = f"{topic_prefix}.{table}"

    prev_ts = None
    emitted = 0
    for row in df.to_dict(orient="records"):
        ts = row["CreationDate"]
        if prev_ts is not None and pd.notna(ts) and pd.notna(prev_ts):
            gap_seconds = (ts - prev_ts).total_seconds()
            sleep_for = min(max(gap_seconds, 0) / speedup, MAX_SLEEP_PER_ROW_SECONDS)
            if sleep_for > 0:
                time.sleep(sleep_for)
        prev_ts = ts

        payload = row_to_json(table, row)
        producer.produce(topic, value=payload.encode("utf-8"))
        producer.poll(0)
        emitted += 1
        if emitted % 5000 == 0:
            log(f"{table}: emitted {emitted}/{len(df)} rows to {topic}")

    producer.flush(30)
    log(f"{table}: done, emitted {emitted} rows to {topic}")


def main():
    tables_env = os.environ.get("TABLE", "posts").strip().lower()
    tables = ["posts", "votes", "comments"] if tables_env == "all" else [t.strip() for t in tables_env.split(",")]
    year = int(os.environ.get("YEAR", "2020"))
    max_rows = int(os.environ.get("MAX_ROWS", "200000"))
    speedup = float(os.environ.get("SPEEDUP", "20000"))
    topic_prefix = os.environ.get("TOPIC_PREFIX", "so")
    broker = os.environ.get("BROKER", "redpanda:9092")

    log(f"tables={tables} year={year} max_rows={max_rows} speedup={speedup} broker={broker}")

    if len(tables) == 1:
        replay_table(tables[0], year, max_rows, speedup, topic_prefix, broker)
        return

    threads = [
        threading.Thread(target=replay_table, args=(t, year, max_rows, speedup, topic_prefix, broker), name=t)
        for t in tables
    ]
    for t in threads:
        t.start()
    for t in threads:
        t.join()


if __name__ == "__main__":
    main()
