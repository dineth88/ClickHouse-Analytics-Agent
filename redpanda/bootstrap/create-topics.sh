#!/bin/sh
set -e

for topic in so.posts so.votes so.comments; do
  if rpk topic list --brokers redpanda:9092 | grep -q "^${topic}\b"; then
    echo "topic ${topic} already exists, skipping"
  else
    rpk topic create "${topic}" --brokers redpanda:9092 --partitions 3 --replicas 1
  fi
done

echo "--- topics ---"
rpk topic list --brokers redpanda:9092
