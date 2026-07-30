# Learning Guide

This document explains **every phase** of ClickHouse-Analytics-Agent, in the order it was built, so a beginner can follow the whole system end to end — what each component is, why it exists, and how it connects to the next one.

---

## Phase 0 — Repo scaffolding + secret hygiene

**Why secrets never go in git.** Git tracks history forever — even if you delete a secret in a later commit, it still lives in the repo's history and anyone with clone access (or a public GitHub page) can dig it out. The fix is to never let the secret enter a commit in the first place.

**What `.gitignore` does.** It tells Git "don't track these paths, even if they exist on disk." We list `.env`, `**/credentials.json`, `**/auth.json`, `*.pem`, `*.key` — the exact files carrying real passwords/keys in this project — while still allowing `.env.example` and `credentials.json.example` (templates with placeholder values) to be committed, so anyone cloning the repo knows *which* variables to fill in without ever seeing a real one.

**The env-var pattern.** Instead of hardcoding secrets into code or config files that get committed, every service reads its credentials from environment variables at container-start time (via Docker Compose's `environment:` blocks, interpolated from a local, git-ignored `.env` file). The `.env.example` file documents every variable's *name* and *shape* without ever holding a real value. `scripts/check-secrets.sh` is a second line of defense: even if `.gitignore` were misconfigured, it scans anything staged for commit and aborts the push if it finds secret-shaped content.

---

## Phase 1 — ClickHouse storage + schema

**Why ClickHouse is columnar.** A traditional row-oriented database stores each row's columns contiguously on disk — great for fetching a single record, wasteful for analytics ("what's the average ViewCount across 10 million posts?") because you still have to read every column of every row even though you only need one. ClickHouse stores each *column* contiguously instead, so a query touching only `ViewCount` and `CreationDate` reads only those two columns off disk — often 10-100x less I/O for the aggregate queries a dashboard or analyst actually runs.

**MergeTree, in plain terms.** MergeTree is ClickHouse's core storage engine family. Data is written in small immutable chunks ("parts"); a background process periodically merges parts together (hence the name) into larger, more efficient parts. This is what makes MergeTree fast for both writes (just append a new part) and reads (fewer, bigger, more compressed parts to scan).

**ORDER BY vs PARTITION BY.** These answer two different questions:
- `ORDER BY` decides how rows are *sorted on disk within a part* — pick columns you'll filter/aggregate by often (e.g. `posts` is ordered by `(PostTypeId, toDate(CreationDate), CreationDate)` because most useful queries filter by post type and a date range). Good ordering lets ClickHouse skip huge swaths of data instead of scanning it.
- `PARTITION BY` decides how data is split into *separate physical directories* (e.g. `posts` partitions `toYear(CreationDate)` — one directory per year). This mostly helps with bulk-dropping old data (`DROP PARTITION`) and letting the query planner skip whole partitions outright.

**What a materialized view does, incrementally.** A normal SQL view is just a saved query — it re-runs against all underlying data every time you `SELECT` from it. A ClickHouse **materialized view** is different: it's a *trigger* that fires on every INSERT into its source table, runs its SELECT against only the newly-inserted rows, and writes the result into a target table. This is why our rollup tables (`posts_per_minute`, etc.) stay cheap to query even as the raw `posts` table grows into the millions — the aggregation work happens once, incrementally, at write time, not repeatedly at read time.

**Table/column comments.** We attach `COMMENT` metadata to every table and several columns (`clickhouse/init/06-table-comments.sql`) explaining what each one means and how tables join together. This isn't just documentation for humans — the agent (Phase 5) reads this same metadata through the MCP server before writing SQL, which measurably reduces hallucinated column names and wrong joins.

**A real bug we hit: `GRANT ALL` isn't actually all.** The read-only `mcp_reader` user (`clickhouse/init/05-create-mcp-reader.sh`) is created by our bootstrap admin user, `analytics` — which the ClickHouse image sets up automatically from `CLICKHOUSE_USER`/`CLICKHOUSE_PASSWORD` with full data privileges. It turns out that "full data privileges" doesn't include the right to create other users: since ClickHouse 22.x, `ACCESS MANAGEMENT` (creating/altering users and roles, granting privileges) is a separate privilege category that a blanket `GRANT ALL` deliberately excludes, for exactly the reason you'd guess — you don't want every app-level admin account able to mint new database users. Without it, `CREATE USER mcp_reader ...` failed with `ACCESS_DENIED`, silently — `mcp_reader` was simply never created, and every MCP query from the agent failed authentication. The fix is the `CLICKHOUSE_ACCESS_MANAGEMENT=1` environment variable on the `clickhouse` service, which the official image's entrypoint uses to additionally grant the bootstrap user that specific privilege. Lesson: "the admin account can do X" is a claim worth actually testing, not assuming from the account being called "admin" — privilege categories in any system with fine-grained access control don't always nest the way their names imply.

---

## Phase 2 — Redpanda buffer

**What a message broker / topic / partition is.** A message broker is a durable, ordered mailbox that sits between producers (things that emit events) and consumers (things that react to them). A **topic** is a named stream (`so.posts`, `so.votes`, `so.comments` here); a **partition** is a topic split into independently-ordered, independently-consumable shards, which is what lets a topic scale past what one machine can read or write.

**Why a buffer decouples producers from ClickHouse.** Without a broker in the middle, the replayer (Phase 3) would have to insert directly into ClickHouse — meaning if ClickHouse is slow, restarting, or temporarily down, the replayer either blocks or loses data. With Redpanda in between, the replayer just appends to a topic (fast, always available) and ClickHouse's Kafka-engine tables consume at their own pace, tracking their own offset. Either side can restart independently without the other losing or duplicating work.

**Why Redpanda instead of Kafka.** Apache Kafka needs a separate coordination service (historically ZooKeeper, now KRaft mode) and a JVM per broker — more moving parts, more memory, more startup time. Redpanda re-implements the Kafka wire protocol as a single, self-contained C++ binary with no JVM and no separate coordination service, so it's Kafka-API-compatible (any Kafka client library works unmodified) while being far lighter to run on a laptop — exactly what this project needs.

---

## Phase 3 — Ingestion (replayer + Kafka engine + MVs)

**The Kafka-engine → MV → MergeTree pattern.** A ClickHouse table with `ENGINE = Kafka` isn't storage at all — it's a *view onto a live topic*. Querying it directly gives you whatever's currently in flight and then it's gone; nothing is persisted. The trick is attaching a **materialized view** to it: each time ClickHouse polls a batch of messages off the topic, it runs the MV's `SELECT` against that batch and writes the result into the MV's target table — `posts_queue` (Kafka engine) → `posts_queue_to_posts_mv` → `posts` (raw MergeTree), with no separate stream-processing framework involved.

**A real bug we hit: don't chain multiple MVs off one Kafka table.** The obvious way to also feed the real-time rollups is to attach two *more* materialized views straight to `posts_queue` (one for `posts_per_minute`, one for `posts_by_tag_minute`), since ClickHouse documents this as supported — one consumed batch, pushed through every attached view. It worked, until the ClickHouse container got restarted (routine maintenance, not a crash): afterward, `posts` kept growing with every new replay, but `posts_per_minute` and `posts_by_tag_minute` silently stopped receiving anything — no error, no warning, just stale rollups next to a growing raw table. The Kafka engine's consumer re-attaches per view on restart, and in practice this doesn't always succeed for every view attached to the same Kafka table. The fix: chain the rollup MVs off the **raw MergeTree table** instead (`FROM stackoverflow.posts`, not `FROM stackoverflow.posts_queue`) — a MergeTree table triggering downstream materialized views on INSERT is the most standard, thoroughly-tested path in ClickHouse, with none of the Kafka-engine's multi-consumer fragility. Two hops (Kafka → raw → rollup) instead of one Kafka table fanning out three ways, but each hop is individually bulletproof. Lesson: "documented as supported" and "reliable across restarts in practice" aren't always the same thing — if a rollup depends on a live stream, check it actually still updates after the thing feeding it restarts, not just right after you first built it.

**Exactly-once caveats.** This pattern is "at-least-once," not exactly-once: if ClickHouse crashes after consuming a batch from Kafka but before fully committing the corresponding INSERT, that batch can be re-delivered and re-inserted on restart, producing duplicate rows. For a real-time analytics dashboard this is a fine trade-off (a dashboard being off by a handful of rows for a few seconds after a crash doesn't matter); it would NOT be fine for, say, a ledger of financial transactions.

**When you'd reach for GlassFlow or Flink instead — and why this project deliberately doesn't.** This native pattern is the right choice when each event maps to a row (or a simple aggregate) independently. You'd add a real stream processor (Flink, or ClickHouse's own GlassFlow) when you need: (1) **true exactly-once** semantics with transactional guarantees across sources, (2) **stateful joins across streams** (e.g. joining `posts` to `votes` *as they both arrive*, not after-the-fact via SQL join on the landed tables), or (3) **complex event-time windowing** with watermarks and late-data handling that goes beyond "aggregate this micro-batch." None of our sample questions need that — every "join" (posts↔votes for controversial posts, posts↔users for top answerers) is answered by a normal SQL join over already-landed MergeTree tables, which ClickHouse is extremely fast at. Adding Flink here would mean running a JobManager, TaskManagers, and checkpointing infrastructure to solve a problem plain SQL already solves — so we don't.

**Event time vs. ingestion time — a subtlety worth calling out.** The replayed rows carry their *original* StackOverflow `CreationDate` (e.g., somewhere in 2020) — that's the historical truth, and it's what the raw `posts`/`votes`/`comments` tables preserve. But "how many posts are we ingesting per minute *right now*" is a question about the live pipeline's current throughput, which has nothing to do with 2020. So the rollup tables (`posts_per_minute`, `votes_per_minute`, `posts_by_tag_minute`) intentionally bucket by `now()` — the wall-clock minute ClickHouse processed the row — not by `CreationDate`. Mixing these up is a common real-world mistake: always ask "is this dashboard/question about when the event *originally happened*, or about when our *pipeline* saw it?"

---

## Phase 4 — Grafana dashboards

**How Grafana talks to ClickHouse.** The official `grafana-clickhouse-datasource` plugin (installed via `GF_INSTALL_PLUGINS` at container start) speaks ClickHouse's HTTP interface (port 8123) directly — Grafana sends a SQL query, ClickHouse returns rows, the plugin maps them onto Grafana's time-series/table data model. The datasource connection itself is provisioned from a YAML file (`grafana/provisioning/datasources/clickhouse.yml`) rather than clicked together in the UI, so the whole stack is reproducible from `git clone` + `make up` with zero manual setup.

**Why dashboards query rollup tables, not raw tables.** `stackoverflow.posts` will hold hundreds of thousands to millions of rows. Recomputing "posts per minute" by scanning and grouping the whole table on every 5-second dashboard refresh would get slower as the table grows, and does needless repeated work. The rollup tables are already aggregated *incrementally* by the materialized views (Phase 3) as data lands, so a dashboard query against them is always just "sum a few dozen small pre-aggregated rows" — fast regardless of how big the raw tables get.

**What auto-refresh does.** Grafana's `refresh: "5s"` setting (set in the dashboard JSON) re-runs every panel's query on that interval, without a manual page reload. Combined with a rolling relative time window (`now-15m` to `now`), this is what makes the dashboard feel "live" — as the replayer produces new rows and ClickHouse's materialized views land them into the rollups, the next 5-second refresh picks them up automatically.

---

## Phase 5 — Agent (LibreChat + ClickHouse MCP + Langfuse + Gemini/Vertex)

**What MCP is, and why it turns the database into an agent-callable tool.** The Model Context Protocol (MCP) is a standard way for an LLM application to discover and call external "tools" — read a file, hit an API, run a query — without every tool needing custom glue code baked into the chat app. The **ClickHouse MCP server** exposes a small set of tools (list tables, describe a table's schema/comments, run a read-only SQL query) over that protocol. LibreChat, configured with the MCP server's URL in `librechat.yaml`, lets Gemini call those tools mid-conversation: the model decides it needs data, calls the "run query" tool with SQL it writes itself, gets real rows back, and incorporates them into its answer. This is what turns a general-purpose chat model into a natural-language interface over a specific database, with no custom text-to-SQL application code required.

**The chat-layer / data-layer / observability-layer split.** Three concerns, three services, cleanly separated:
- **Chat layer (LibreChat):** the UI, conversation history, user accounts, model selection.
- **Data layer (ClickHouse + MCP server):** the actual analytics database and a narrow, read-only, tool-shaped interface onto it.
- **Observability layer (Langfuse):** records every prompt, every tool call, every SQL statement, and every response as a trace, independent of the other two.

Keeping these separate means each can be swapped or scaled independently — e.g., pointing the same LibreChat at a different MCP data source, or shipping traces to a different observability backend, without touching the other layers.

**Why grounding (table comments) reduces hallucination.** An LLM writing SQL against a schema it's never seen has to guess column names, types, and meanings from naming conventions alone — and StackOverflow's schema has real ambiguity (`VoteTypeId` is just an integer; `PostTypeId=1` vs `2` isn't obvious from the column name). The MCP server's schema-inspection tool surfaces the `COMMENT`s we attached in `clickhouse/init/06-table-comments.sql` directly to the model, so it sees "VoteTypeId: ...UpMod=2, DownMod=3..." instead of guessing. This is a cheap, durable way to improve text-to-SQL accuracy: the glossary lives in the database itself, so it's always in sync with the schema and available to any tool that introspects it — not just this one chat app.

**How Vertex service-account auth works.** Vertex AI (unlike the plain Gemini/AI-Studio API) authenticates via a **Google Cloud service account**, not a simple API key. The service account's private key (rotated, referenced only by host path — see Phase 0) is mounted read-only into the LibreChat container; `GOOGLE_SERVICE_KEY_FILE` tells LibreChat where to find it, and `GOOGLE_LOC`/the project id embedded in the key tell it which Vertex region/project to call. Because the credential is a full service-account identity rather than a bearer token, `GOOGLE_KEY` (used for the plain Gemini API) is deliberately left unset — the two auth paths are mutually exclusive, and mixing them up is a common source of "why is it hitting the wrong billing account" confusion.

---

## Phase 6 — Orchestration + live bring-up

**Why `include:` instead of one giant compose file.** Each phase's compose file (`clickhouse/`, `redpanda/`, `ingestion/`, `grafana/`, `agent/*.yml`) is independently runnable and independently readable — you can start just ClickHouse to test Phase 1 in isolation, without every other service's config in view. Docker Compose's `include:` directive (in the root `docker-compose.yml`) merges all of them into a single project at run time, so services still resolve each other by name (e.g. `clickhouse-mcp` can reach `clickhouse:8123`) exactly as if everything had been declared in one file. This is a common pattern for keeping a large multi-service stack navigable without losing the "one command, one project" property.

**What a healthcheck + `depends_on: condition: service_healthy` buys you.** By default, Compose's `depends_on` only waits for a container to *start*, not for the application inside it to be *ready* — a freshly-started ClickHouse container accepts TCP connections before it's actually able to run a query. A `healthcheck` defines a real readiness probe (e.g. hit `/ping`), and `condition: service_healthy` makes a dependent service wait for that probe to pass before it starts. This is why `clickhouse-mcp` doesn't start racing against a ClickHouse that isn't ready yet, and why `ingestion-posts` doesn't start producing into topics before Redpanda's bootstrap job has created them.
