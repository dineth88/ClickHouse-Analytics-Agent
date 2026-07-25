# Sample Questions

Ask these in LibreChat (select the **Google** endpoint, `gemini-2.5-flash` or `gemini-2.5-pro`, with the `ClickHouse-StackOverflow` MCP tool enabled). The agent should answer in plain language, show the SQL it ran, and return a small table where useful. Every interaction should appear as a trace in Langfuse (http://localhost:3002).

Reference SQL below is for you to sanity-check the agent's answer — the agent may phrase its own query slightly differently and still be correct.

---

### 1. "What are the 10 most popular tags on Stack Overflow?"

Expected shape: a ranked list of (tag, count) pairs.

```sql
SELECT tag, count() AS cnt
FROM stackoverflow.posts
ARRAY JOIN splitByChar('|', Tags) AS tag
WHERE tag != ''
GROUP BY tag
ORDER BY cnt DESC
LIMIT 10;
```

### 2. "Who are the top 5 users by number of answers?"

Expected shape: a ranked list of (user, answer count). Requires `make seed` to have loaded `stackoverflow.users` for a display name; otherwise falls back to `OwnerUserId`.

```sql
SELECT u.DisplayName, count() AS answers
FROM stackoverflow.posts AS p
JOIN stackoverflow.users AS u ON p.OwnerUserId = u.Id
WHERE p.PostTypeId = 'Answer'
GROUP BY u.DisplayName
ORDER BY answers DESC
LIMIT 5;
```

### 3. "Which ClickHouse-related posts have the most views?"

Expected shape: a ranked list of (title, view count).

```sql
SELECT Id, Title, ViewCount
FROM stackoverflow.posts
WHERE Title ILIKE '%ClickHouse%'
ORDER BY ViewCount DESC
LIMIT 10;
```

### 4. "Show me the most controversial posts."

Expected shape: posts with both a high upvote AND high downvote count (as opposed to just a high total).

```sql
SELECT
    PostId,
    countIf(VoteTypeId = 2) AS upvotes,
    countIf(VoteTypeId = 3) AS downvotes
FROM stackoverflow.votes
WHERE VoteTypeId IN (2, 3)
GROUP BY PostId
HAVING upvotes > 0 AND downvotes > 0
ORDER BY least(upvotes, downvotes) DESC, (upvotes + downvotes) DESC
LIMIT 10;
```

### 5. "How many questions were posted per day in 2020?"

Expected shape: a time series of (day, question count).

```sql
SELECT toDate(CreationDate) AS day, count() AS questions
FROM stackoverflow.posts
WHERE PostTypeId = 'Question' AND toYear(CreationDate) = 2020
GROUP BY day
ORDER BY day;
```

### 6. "What's the ratio of answers to questions over time?"

Expected shape: a time series of (month, answers, questions, ratio).

```sql
SELECT
    toStartOfMonth(CreationDate) AS month,
    countIf(PostTypeId = 'Answer') AS answers,
    countIf(PostTypeId = 'Question') AS questions,
    answers / questions AS ratio
FROM stackoverflow.posts
GROUP BY month
ORDER BY month;
```

### 7. "How many posts are we ingesting per minute right now?"

Expected shape: a recent time series from the **live rollup**, not the raw table — this only returns data while (or shortly after) a replay has been running (see Phase 3/4 in `docs/LEARNING.md` on event-time vs. ingestion-time).

```sql
SELECT minute, sum(cnt) AS posts_per_minute
FROM stackoverflow.posts_per_minute
WHERE minute >= now() - INTERVAL 15 MINUTE
GROUP BY minute
ORDER BY minute;
```

### 8. "Which tags are trending in the last N minutes of the stream?"

Expected shape: a ranked list of (tag, count) restricted to a recent ingestion-time window.

```sql
SELECT tag, sum(cnt) AS cnt
FROM stackoverflow.posts_by_tag_minute
WHERE minute >= now() - INTERVAL 10 MINUTE
GROUP BY tag
ORDER BY cnt DESC
LIMIT 10;
```
