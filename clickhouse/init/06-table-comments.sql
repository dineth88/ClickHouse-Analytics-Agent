-- Business glossary for the agent (Phase 5): table/column comments materially
-- improve text-to-SQL accuracy because the LLM sees them via
-- `SELECT ... FROM system.columns` / `DESCRIBE TABLE` through the MCP server.

ALTER TABLE stackoverflow.posts MODIFY COMMENT
    'One row per StackOverflow post (question or answer). PostTypeId=1 is a Question, PostTypeId=2 is an Answer. Tags is a pipe-delimited string like "python|pandas|dataframe" on Questions only (empty on Answers) — split with splitByChar(''|'', Tags). ParentId links an Answer to its Question''s Id.';

ALTER TABLE stackoverflow.posts COMMENT COLUMN PostTypeId 'Question=1, Answer=2, Wiki=3, TagWikiExcerpt=4, TagWiki=5, ModeratorNomination=6, WikiPlaceholder=7, PrivilegeWiki=8';
ALTER TABLE stackoverflow.posts COMMENT COLUMN Tags 'Pipe-delimited tag list on Questions, e.g. "python|pandas". Split with splitByChar(''|'', Tags). Empty on Answers.';
ALTER TABLE stackoverflow.posts COMMENT COLUMN ViewCount 'Number of times this post has been viewed.';
ALTER TABLE stackoverflow.posts COMMENT COLUMN Score 'Net score (upvotes minus downvotes) as of the dataset snapshot.';
ALTER TABLE stackoverflow.posts COMMENT COLUMN AnswerCount 'Number of answers this Question has received (0 on Answers).';
ALTER TABLE stackoverflow.posts COMMENT COLUMN OwnerUserId 'Id of the user who authored this post; join to stackoverflow.users.Id.';

ALTER TABLE stackoverflow.votes MODIFY COMMENT
    'One row per vote cast on a post. Join PostId to stackoverflow.posts.Id. VoteTypeId=2 is an upvote ("UpMod"), VoteTypeId=3 is a downvote ("DownMod") — a post''s "controversy" can be measured by comparing counts of each per PostId.';

ALTER TABLE stackoverflow.votes COMMENT COLUMN VoteTypeId 'AcceptedByOriginator=1, UpMod=2, DownMod=3, Offensive=4, Favorite=5, Close=6, Reopen=7, BountyStart=8, BountyClose=9, Deletion=10, Undeletion=11, Spam=12, ModeratorReview=15, ApproveEditSuggestion=16.';

ALTER TABLE stackoverflow.comments MODIFY COMMENT
    'One row per comment left on a post. Join PostId to stackoverflow.posts.Id.';

ALTER TABLE stackoverflow.posts_per_minute MODIFY COMMENT
    'Real-time rollup keyed by INGESTION time (minute = when ClickHouse processed the row, not the historical CreationDate): count of posts landing per minute, split by PostTypeId (1=Question, 2=Answer). Use this — not stackoverflow.posts — to answer "how many posts per minute right now" or "questions vs answers ratio right now" questions, since it is populated incrementally as the live stream ingests. For historical/date-range questions (e.g. "posts per day in 2020"), query stackoverflow.posts.CreationDate directly instead.';

ALTER TABLE stackoverflow.votes_per_minute MODIFY COMMENT
    'Real-time rollup keyed by INGESTION time: count of votes landing per minute, split by VoteTypeId. Use this for "votes per minute right now" questions.';

ALTER TABLE stackoverflow.posts_by_tag_minute MODIFY COMMENT
    'Real-time rollup keyed by INGESTION time: count of Questions per tag per minute, one row per (minute, tag) pair (a post with N tags contributes to N rows). Use this for "trending tags in the last N minutes" questions — filter minute >= now() - INTERVAL N MINUTE and sum(cnt) grouped by tag. For overall historical "most popular tags" (not time-windowed), split stackoverflow.posts.Tags directly instead, since this rollup only covers data ingested since the stream started.';
