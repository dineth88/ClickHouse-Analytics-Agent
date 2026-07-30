# Runbook

Operational, step-by-step instructions for every phase of ClickHouse-Analytics-Agent, plus a full cold-start-to-live-demo sequence at the end (Phase 6).

---

## Phase 0 — Repo scaffolding + secret hygiene

**Setup:**

```bash
cp .env.example .env
# then edit .env and fill in real values, OR:
make env   # auto-generates random secrets for every local-only service
```

You still have to manually set, in `.env`:
- `GOOGLE_CLOUD_PROJECT`, `GOOGLE_APPLICATION_CREDENTIALS_HOST_PATH` (absolute path to your rotated service-account JSON — never paste the key contents anywhere)

**Verify no secrets are staged before any commit:**

```bash
make check-secrets
```

This runs `scripts/check-secrets.sh`, which greps staged files for known secret filenames (`.env`, `credentials.json`, `auth.json`, `*.pem`, `*.key`) and secret-shaped strings (`PRIVATE KEY`, `service_account`, `AIza...`, Langfuse key prefixes). It exits non-zero — aborting `make push` — if anything is found.

---

## Phase 1 — ClickHouse storage + schema

**Start ClickHouse alone (useful for testing this phase in isolation):**

```bash
docker-compose -f clickhouse/docker-compose.clickhouse.yml --env-file .env up -d
docker-compose -f clickhouse/docker-compose.clickhouse.yml --env-file .env ps   # wait for "healthy"
```

**Open `clickhouse-client` and run a smoke query:**

```bash
docker exec -it $(docker ps -qf name=clickhouse) clickhouse-client \
  --user "${CLICKHOUSE_ANALYTICS_USER:-analytics}" --password
```

Then, inside the client:

```sql
SHOW TABLES FROM stackoverflow;
-- expect: posts, votes, comments, users, badges, postlinks, posthistory,
--         posts_per_minute, votes_per_minute, posts_by_tag_daily,
--         posts_queue, votes_queue, comments_queue (Kafka engine tables, Phase 3)

SELECT count() FROM stackoverflow.posts;  -- 0 until ingestion (Phase 3) runs
```

**Confirm the read-only MCP user was created:**

```sql
SHOW GRANTS FOR mcp_reader;  -- expect: GRANT SELECT ON stackoverflow.* TO mcp_reader
```

If a table is missing, the init scripts in `clickhouse/init/` only run on a **fresh** data volume. To re-run them: `docker-compose -f clickhouse/docker-compose.clickhouse.yml down -v` (drops the volume) then `up -d` again.

---

## Phase 2 — Redpanda buffer

**Start Redpanda alone:**

```bash
docker-compose -f redpanda/docker-compose.redpanda.yml --env-file .env up -d
```

This also runs `redpanda-topics`, a one-shot job that creates `so.posts`, `so.votes`, `so.comments` (3 partitions each) and then exits — that's expected, it isn't meant to stay running.

**List topics:**

```bash
docker exec -it $(docker ps -qf name=^redpanda$) rpk topic list
```

**Tail a topic live** (useful once the replayer, Phase 3, is running):

```bash
docker exec -it $(docker ps -qf name=^redpanda$) rpk topic consume so.posts -n 5
```

**Open the Console UI:** http://localhost:8090 (port from `REDPANDA_CONSOLE_PORT` in `.env`) — browse topics, partitions, and consumer group lag (`clickhouse_posts_consumer`, etc. — these appear once ClickHouse's Kafka engine tables start consuming in Phase 3).

---

## Phase 3 — Ingestion (replayer + Kafka engine + MVs)

**If a ClickHouse restart ever leaves the rollups stuck (raw tables growing, `posts_per_minute`/`votes_per_minute`/`posts_by_tag_minute` not):** this was an early bug — see the "event time vs ingestion time" and Kafka-fan-out notes in `docs/LEARNING.md`. It's fixed in the current schema (rollups chain off the raw tables, not off the Kafka queue directly), so a fresh `make up` won't hit it. If you're troubleshooting an existing deployment, `SELECT count(), max(minute) FROM stackoverflow.posts_per_minute` vs `SELECT count() FROM stackoverflow.posts` will tell you if they've diverged.

**Start a replay** (needs ClickHouse + Redpanda already up — Phases 1-2, or just run `make up` for the whole stack):

```bash
docker-compose -f clickhouse/docker-compose.clickhouse.yml \
               -f redpanda/docker-compose.redpanda.yml \
               -f ingestion/docker-compose.ingestion.yml \
               --env-file .env up -d --build
```

Each of `ingestion-posts` / `ingestion-votes` / `ingestion-comments` reads its yearly parquet file from S3 (only as many row-groups as needed for `MAX_ROWS`), sorts by `CreationDate`, and streams it onto its topic — then exits (`restart: "no"`, this is a one-shot replay, not a long-running daemon). Watch it work:

```bash
docker-compose logs -f ingestion-posts ingestion-votes ingestion-comments
```

**Watch rows arrive in ClickHouse** (run this in a loop while a replay is active):

```bash
watch -n 2 'docker exec $(docker ps -qf name=clickhouse) clickhouse-client \
  --user analytics --password "$CLICKHOUSE_ANALYTICS_PASSWORD" \
  --query "SELECT (SELECT count() FROM stackoverflow.posts) AS posts, (SELECT count() FROM stackoverflow.votes) AS votes, (SELECT count() FROM stackoverflow.comments) AS comments"'
```

**Change year / row cap / speed:** edit `YEAR`, `MAX_ROWS`, `SPEEDUP` in `.env`, then re-run the `ingestion-*` services (`docker-compose ... up -d --build ingestion-posts ingestion-votes ingestion-comments`). Lower `SPEEDUP` to make the replay take longer wall-clock time (closer to real pace); raise it to compress a whole year into a few minutes.

**Re-running a replay:** because the Kafka-engine consumer groups (`clickhouse_posts_consumer`, etc.) track their own offsets, re-running the same replayer container will NOT re-insert already-consumed messages as long as the topic/offsets are unchanged — but running the replayer *again* produces a fresh batch of messages (new offsets) that WILL be consumed and inserted again, so re-running the same replay will double-count rows in the raw tables. For a clean re-demo, tear down and recreate the volumes (`docker-compose down -v`) or point at a different `YEAR`.

---

## Phase 4 — Grafana dashboards

**Start Grafana alone** (needs ClickHouse up):

```bash
docker-compose -f clickhouse/docker-compose.clickhouse.yml \
               -f grafana/docker-compose.grafana.yml \
               --env-file .env up -d
```

**Default login:** `${GRAFANA_ADMIN_USER}` / `${GRAFANA_ADMIN_PASSWORD}` from `.env` (default username `admin`).

**Where dashboards live:** http://localhost:3000 → the "StackOverflow Real-Time Analytics" dashboard is provisioned automatically from `grafana/provisioning/dashboards/realtime-analytics.json` — no manual clicking needed. The ClickHouse datasource is likewise auto-provisioned from `grafana/provisioning/datasources/clickhouse.yml`, connecting as the read-only `mcp_reader` user.

**Verify live updates:** start a replay (Phase 3), then open the dashboard — it auto-refreshes every 5s over a rolling "last 15 minutes" window. Panels are keyed by ClickHouse **ingestion** time, not the historical StackOverflow date, so they only show data from the point a replay started; watch "Posts / min" and "Running Total Posts" climb while `ingestion-posts` is running.

---

## Phase 5 — Agent (LibreChat + ClickHouse MCP + Langfuse + Gemini/Vertex)

**Prerequisites in `.env`:**
- `GOOGLE_CLOUD_PROJECT` — your GCP project id
- `GOOGLE_CLOUD_LOCATION` — Vertex region (default `us-central1`)
- `GOOGLE_APPLICATION_CREDENTIALS_HOST_PATH` — absolute path to your **already-rotated** service-account JSON (Vertex AI API must be enabled on that project). Never paste its contents into any file in this repo.

**Start the agent layer** (needs the analytics ClickHouse up):

```bash
docker-compose -f clickhouse/docker-compose.clickhouse.yml \
               -f agent/docker-compose.langfuse.yml \
               -f agent/docker-compose.mcp.yml \
               -f agent/docker-compose.librechat.yml \
               -f agent/docker-compose.admin-panel.yml \
               --env-file .env up -d
```

This is a lot of containers (Postgres, Redis, MinIO, Langfuse's own ClickHouse, LibreChat's Mongo/Meilisearch/pgvector/RAG API) — give it a few minutes, especially Langfuse-web's first boot (it runs DB migrations).

**Open LibreChat:** http://localhost:3080 (log in with `LIBRECHAT_USER_EMAIL` / `LIBRECHAT_USER_PASSWORD` from `.env` — created automatically by `librechat-user-init`).

**Select the Gemini model:** in the endpoint picker, choose **Google** → `gemini-2.5-flash` (or `gemini-2.5-pro` for harder text-to-SQL). Under the message composer, enable the `ClickHouse-StackOverflow` MCP tool (Interface → MCP Servers, or the tools icon in a new chat) so the model can query the database.

**Ask a sample question** (see `docs/SAMPLE_QUESTIONS.md`), e.g. "What are the 10 most popular tags on Stack Overflow?" — the agent should call the MCP tool, run a real SQL query against `stackoverflow`, and answer with the SQL it used.

**View traces in Langfuse:** http://localhost:3002 (port from `LANGFUSE_PORT`), log in with `LANGFUSE_INIT_USER_EMAIL` / `LANGFUSE_INIT_USER_PASSWORD`. Every LibreChat prompt → tool call → SQL → response should appear as a trace.

**Admin panel** (optional, manage LibreChat users/config): http://localhost:3081.

---

## Phase 6 — Orchestration + live bring-up

**Cold start, from a fresh clone:**

```bash
cp .env.example .env
make env                          # fills in random secrets for local-only services
# then edit .env by hand:
#   GOOGLE_CLOUD_PROJECT=<your GCP project id>
#   GOOGLE_APPLICATION_CREDENTIALS_HOST_PATH=<absolute path to your rotated service-account JSON>

make check-secrets                 # confirm nothing secret is staged, if you're about to commit
make up                             # builds the ingestion image, pulls everything else, starts all services
```

`make up` runs `docker-compose --env-file .env up -d --build` across every included compose file, then `scripts/wait-for-healthy.sh`, which polls until every service reports healthy (or times out after `WAIT_TIMEOUT` seconds, default 600).

**Verify each endpoint:**

| Service | URL / command |
|---|---|
| ClickHouse | `curl http://localhost:8123/ping` → `Ok.` |
| Redpanda Console | http://localhost:8090 |
| Grafana | http://localhost:3000 |
| LibreChat | http://localhost:3080 |
| Langfuse | http://localhost:3002 |
| Admin Panel | http://localhost:3081 |

**If a service fails to become healthy:** `docker-compose logs <service>` first. Langfuse-web in particular can take several minutes on first boot (it runs Prisma migrations) — its healthcheck has a 300s grace period before it's even considered for a failure.

**Teardown:**

```bash
make down          # stops and removes containers, keeps volumes (data survives)
docker-compose --env-file .env down -v   # also wipes all volumes — full reset
```
