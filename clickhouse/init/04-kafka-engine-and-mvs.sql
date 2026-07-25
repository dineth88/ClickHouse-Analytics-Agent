-- The whole ingestion pipeline, natively in ClickHouse: no Flink, no GlassFlow.
--
-- Pattern per topic: one Kafka-engine table (a "window" onto the topic, not
-- storage) + one-or-more materialized views that SELECT from it. ClickHouse
-- pushes every consumed batch through all attached materialized views in a
-- single pass, so one Kafka table can fan out into the raw MergeTree table
-- AND the real-time rollups below, with no duplicate consumption.

-- ============================= posts =============================

CREATE TABLE IF NOT EXISTS stackoverflow.posts_queue
(
    `Id` Int32,
    `PostTypeId` Enum8('Question' = 1, 'Answer' = 2, 'Wiki' = 3, 'TagWikiExcerpt' = 4, 'TagWiki' = 5, 'ModeratorNomination' = 6, 'WikiPlaceholder' = 7, 'PrivilegeWiki' = 8),
    `AcceptedAnswerId` UInt32,
    `CreationDate` DateTime64(3, 'UTC'),
    `Score` Int32,
    `ViewCount` UInt32,
    `Body` String,
    `OwnerUserId` Int32,
    `OwnerDisplayName` String,
    `LastEditorUserId` Int32,
    `LastEditorDisplayName` String,
    `LastEditDate` DateTime64(3, 'UTC'),
    `LastActivityDate` DateTime64(3, 'UTC'),
    `Title` String,
    `Tags` String,
    `AnswerCount` UInt16,
    `CommentCount` UInt8,
    `FavoriteCount` UInt8,
    `ContentLicense` LowCardinality(String),
    `ParentId` String,
    `CommunityOwnedDate` DateTime64(3, 'UTC'),
    `ClosedDate` DateTime64(3, 'UTC')
)
ENGINE = Kafka
SETTINGS
    kafka_broker_list = 'redpanda:9092',
    kafka_topic_list = 'so.posts',
    kafka_group_name = 'clickhouse_posts_consumer',
    kafka_format = 'JSONEachRow',
    kafka_num_consumers = 1,
    kafka_skip_broken_messages = 1000,
    date_time_input_format = 'best_effort';

CREATE MATERIALIZED VIEW IF NOT EXISTS stackoverflow.posts_queue_to_posts_mv
    TO stackoverflow.posts AS
SELECT * FROM stackoverflow.posts_queue;

CREATE MATERIALIZED VIEW IF NOT EXISTS stackoverflow.posts_queue_to_per_minute_mv
    TO stackoverflow.posts_per_minute AS
SELECT
    toStartOfMinute(now()) AS minute,
    PostTypeId,
    count() AS cnt
FROM stackoverflow.posts_queue
GROUP BY minute, PostTypeId;

CREATE MATERIALIZED VIEW IF NOT EXISTS stackoverflow.posts_queue_to_tags_mv
    TO stackoverflow.posts_by_tag_minute AS
SELECT
    toStartOfMinute(now()) AS minute,
    tag,
    count() AS cnt
FROM stackoverflow.posts_queue
ARRAY JOIN splitByChar('|', Tags) AS tag
WHERE tag != ''
GROUP BY minute, tag;

-- ============================= votes =============================

CREATE TABLE IF NOT EXISTS stackoverflow.votes_queue
(
    `Id` UInt32,
    `PostId` Int32,
    `VoteTypeId` UInt8,
    `CreationDate` DateTime64(3, 'UTC'),
    `UserId` Int32,
    `BountyAmount` UInt8
)
ENGINE = Kafka
SETTINGS
    kafka_broker_list = 'redpanda:9092',
    kafka_topic_list = 'so.votes',
    kafka_group_name = 'clickhouse_votes_consumer',
    kafka_format = 'JSONEachRow',
    kafka_num_consumers = 1,
    kafka_skip_broken_messages = 1000,
    date_time_input_format = 'best_effort';

CREATE MATERIALIZED VIEW IF NOT EXISTS stackoverflow.votes_queue_to_votes_mv
    TO stackoverflow.votes AS
SELECT * FROM stackoverflow.votes_queue;

CREATE MATERIALIZED VIEW IF NOT EXISTS stackoverflow.votes_queue_to_per_minute_mv
    TO stackoverflow.votes_per_minute AS
SELECT
    toStartOfMinute(now()) AS minute,
    VoteTypeId,
    count() AS cnt
FROM stackoverflow.votes_queue
GROUP BY minute, VoteTypeId;

-- ============================ comments ============================

CREATE TABLE IF NOT EXISTS stackoverflow.comments_queue
(
    `Id` UInt32,
    `PostId` UInt32,
    `Score` UInt16,
    `Text` String,
    `CreationDate` DateTime64(3, 'UTC'),
    `UserId` Int32,
    `UserDisplayName` LowCardinality(String)
)
ENGINE = Kafka
SETTINGS
    kafka_broker_list = 'redpanda:9092',
    kafka_topic_list = 'so.comments',
    kafka_group_name = 'clickhouse_comments_consumer',
    kafka_format = 'JSONEachRow',
    kafka_num_consumers = 1,
    kafka_skip_broken_messages = 1000,
    date_time_input_format = 'best_effort';

CREATE MATERIALIZED VIEW IF NOT EXISTS stackoverflow.comments_queue_to_comments_mv
    TO stackoverflow.comments AS
SELECT * FROM stackoverflow.comments_queue;
