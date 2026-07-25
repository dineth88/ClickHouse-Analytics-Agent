-- Real-time rollup tables. Grafana (Phase 4) and the agent (Phase 5) query
-- these instead of the raw MergeTree tables, so dashboards/answers stay fast
-- and cheap no matter how large `posts`/`votes` grow.
--
-- IMPORTANT: these bucket by INGESTION time (`now()` at the moment ClickHouse
-- processes the row), not by the row's original historical `CreationDate`.
-- The replayed StackOverflow data is all timestamped in the source year
-- (e.g. 2020) — a rollup keyed on CreationDate would never fall inside a
-- Grafana "last 15 minutes" window relative to today. Ingestion-time keying
-- is also what "how many posts are we ingesting per minute right now?" and
-- "trending tags in the last N minutes" actually mean: a question about the
-- live stream's current rate, not about StackOverflow's history. Historical,
-- event-time questions (e.g. "posts per day in 2020") query the raw
-- `posts`/`votes`/`comments` tables and their real CreationDate directly.

-- Posts landing per minute, split by PostTypeId so a query can show either
-- total posts/min (sum over post_type_id) or a questions-vs-answers ratio
-- (filter PostTypeId IN (1,2)).
CREATE TABLE IF NOT EXISTS stackoverflow.posts_per_minute
(
    `minute` DateTime,
    `PostTypeId` UInt8,
    `cnt` UInt64
)
ENGINE = SummingMergeTree(cnt)
PARTITION BY toYYYYMMDD(minute)
ORDER BY (minute, PostTypeId);

-- Votes landing per minute, split by VoteTypeId (2 = UpMod, 3 = DownMod, etc).
CREATE TABLE IF NOT EXISTS stackoverflow.votes_per_minute
(
    `minute` DateTime,
    `VoteTypeId` UInt8,
    `cnt` UInt64
)
ENGINE = SummingMergeTree(cnt)
PARTITION BY toYYYYMMDD(minute)
ORDER BY (minute, VoteTypeId);

-- Per-tag, per-minute counts (ingestion time), for "top tags" / "trending
-- tags in the last N minutes" panels and questions. Populated by splitting
-- the pipe-delimited Tags string on insert (see 04-kafka-engine-and-mvs.sql).
CREATE TABLE IF NOT EXISTS stackoverflow.posts_by_tag_minute
(
    `minute` DateTime,
    `tag` String,
    `cnt` UInt64
)
ENGINE = SummingMergeTree(cnt)
PARTITION BY toYYYYMMDD(minute)
ORDER BY (minute, tag);
