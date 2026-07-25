#!/bin/bash
# CREATE USER isn't valid in a plain .sql initdb file when the value needs to
# come from an env var, so this runs as a shell init script instead (the
# ClickHouse image executes both *.sql and *.sh under docker-entrypoint-initdb.d).
set -e

clickhouse-client --query "
CREATE USER IF NOT EXISTS ${CLICKHOUSE_MCP_READER_USER} IDENTIFIED WITH sha256_password BY '${CLICKHOUSE_MCP_READER_PASSWORD}';
"
clickhouse-client --query "
GRANT SELECT ON stackoverflow.* TO ${CLICKHOUSE_MCP_READER_USER};
"
