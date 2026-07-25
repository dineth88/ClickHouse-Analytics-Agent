#!/bin/sh
# Runs once (restart: "no") after LibreChat is healthy: creates the initial
# admin user via LibreChat's own CLI, then promotes it to ADMIN in Mongo.
# Adapted from github.com/ClickHouse/agentic-data-stack's scripts/init-librechat-user.sh.
set -e

echo "=================================================="
echo "LibreChat User Initialization"
echo "=================================================="

LIBRECHAT_USER_EMAIL=${LIBRECHAT_USER_EMAIL:-admin@example.com}
LIBRECHAT_USER_PASSWORD=${LIBRECHAT_USER_PASSWORD:-changeme}
LIBRECHAT_USER_NAME=${LIBRECHAT_USER_NAME:-Admin}
USERNAME=$(echo "${LIBRECHAT_USER_EMAIL}" | cut -d'@' -f1)

echo "Target user: ${LIBRECHAT_USER_EMAIL}"

LIBRECHAT_CONTAINER=$(docker ps --filter "name=librechat" --filter "status=running" --format "{{.Names}}" | grep -E "librechat-[0-9]+$" | head -n1)
MONGODB_CONTAINER=$(docker ps --filter "name=mongodb" --filter "status=running" --format "{{.Names}}" | grep -E "mongodb-[0-9]+$" | head -n1)

if [ -z "$LIBRECHAT_CONTAINER" ]; then
    echo "Error: could not find running LibreChat container"
    exit 1
fi
if [ -z "$MONGODB_CONTAINER" ]; then
    echo "Error: could not find running MongoDB container"
    exit 1
fi

sleep 3

USER_EXISTS=$(docker exec "${MONGODB_CONTAINER}" mongosh LibreChat --quiet --eval "
db.users.countDocuments({ email: '${LIBRECHAT_USER_EMAIL}' })
" 2>/dev/null | tail -n 1 | tr -d '[:space:]' || echo "0")

if ! echo "$USER_EXISTS" | grep -Eq '^[0-9]+$'; then
    USER_EXISTS="0"
fi

if [ "$USER_EXISTS" -gt 0 ]; then
    echo "User ${LIBRECHAT_USER_EMAIL} already exists, skipping creation."
    exit 0
fi

echo "Creating user with LibreChat CLI..."
echo "Y" | docker exec -i "${LIBRECHAT_CONTAINER}" npm run create-user \
  "${LIBRECHAT_USER_EMAIL}" \
  "${LIBRECHAT_USER_NAME}" \
  "${USERNAME}" \
  "${LIBRECHAT_USER_PASSWORD}"

echo "Setting user as admin..."
docker exec "${MONGODB_CONTAINER}" mongosh LibreChat --quiet --eval "
db.users.updateOne(
  { email: '${LIBRECHAT_USER_EMAIL}' },
  { \$set: { role: 'ADMIN' } }
)
" > /dev/null 2>&1

echo "Done. LibreChat ready at http://localhost:${LIBRECHAT_PORT:-3080}"
