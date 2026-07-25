#!/usr/bin/env bash
# Polls every service's healthcheck (as reported by `docker compose ps`) until
# all are healthy/running, or a timeout is hit. Used by `make up`.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

TIMEOUT="${WAIT_TIMEOUT:-600}"
INTERVAL=5
ELAPSED=0

echo "Waiting up to ${TIMEOUT}s for all services to become healthy..."

while true; do
  STATUS=$(docker-compose ps --format json 2>/dev/null || docker-compose ps)

  # Count containers that are unhealthy or still starting.
  NOT_READY=$(docker-compose ps --format '{{.Name}} {{.Health}} {{.State}}' 2>/dev/null \
    | awk '{ if ($2 != "" && $2 != "healthy") print; else if ($2 == "" && $3 != "running") print }' | wc -l | tr -d ' ')

  if [ "$NOT_READY" -eq 0 ]; then
    echo "All services are up."
    docker-compose ps
    exit 0
  fi

  if [ "$ELAPSED" -ge "$TIMEOUT" ]; then
    echo "Timed out after ${TIMEOUT}s waiting for services. Current state:"
    docker-compose ps
    exit 1
  fi

  sleep "$INTERVAL"
  ELAPSED=$((ELAPSED + INTERVAL))
  echo "...still waiting (${ELAPSED}s elapsed)"
done
