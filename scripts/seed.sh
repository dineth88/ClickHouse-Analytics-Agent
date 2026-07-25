#!/usr/bin/env bash
# Loads the users/badges reference tables directly from S3 via ClickHouse's
# own s3() table function — no Python/Kafka involved, since these are static
# dimension tables, not a stream.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
[ -f .env ] && set -a && source .env && set +a

CID=$(docker ps -qf "name=clickhouse" | head -n1)
if [ -z "$CID" ]; then
  echo "seed: no running clickhouse container found — run 'make up' first."
  exit 1
fi

LIMIT="${SEED_MAX_ROWS:-500000}"
BASE="https://datasets-documentation.s3.eu-west-3.amazonaws.com/stackoverflow/parquet"

echo "seed: loading up to ${LIMIT} rows into stackoverflow.users ..."
docker exec "$CID" clickhouse-client \
  --user "${CLICKHOUSE_ANALYTICS_USER:-analytics}" --password "${CLICKHOUSE_ANALYTICS_PASSWORD}" \
  --query "INSERT INTO stackoverflow.users SELECT * FROM s3('${BASE}/users.parquet') LIMIT ${LIMIT}"

echo "seed: loading up to ${LIMIT} rows into stackoverflow.badges ..."
docker exec "$CID" clickhouse-client \
  --user "${CLICKHOUSE_ANALYTICS_USER:-analytics}" --password "${CLICKHOUSE_ANALYTICS_PASSWORD}" \
  --query "INSERT INTO stackoverflow.badges SELECT * FROM s3('${BASE}/badges.parquet') LIMIT ${LIMIT}"

echo "seed: done."
