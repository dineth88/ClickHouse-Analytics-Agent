#!/usr/bin/env bash
# Generates a .env with cryptographically random secrets for every
# local-only service. You still must fill in GOOGLE_CLOUD_PROJECT and
# GOOGLE_APPLICATION_CREDENTIALS_HOST_PATH by hand afterward.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

if [ -f .env ]; then
  echo "generate-env: .env already exists — refusing to overwrite it. Delete it first if you really want to regenerate."
  exit 1
fi

rand32() { openssl rand -base64 32 | tr -d '/+=' | cut -c1-32; }

cp .env.example .env

set_kv() {
  local key="$1" val="$2"
  # Escape & and / for sed's replacement side.
  local esc_val
  esc_val=$(printf '%s' "$val" | sed -e 's/[\/&]/\\&/g')
  if grep -q "^${key}=" .env; then
    sed -i.bak "s/^${key}=.*/${key}=${esc_val}/" .env && rm -f .env.bak
  else
    echo "${key}=${val}" >> .env
  fi
}

set_kv CLICKHOUSE_ANALYTICS_PASSWORD "$(rand32)"
set_kv CLICKHOUSE_MCP_READER_PASSWORD "$(rand32)"
set_kv GRAFANA_ADMIN_PASSWORD "$(rand32)"
set_kv CLICKHOUSE_MCP_AUTH_TOKEN "$(openssl rand -hex 32)"
set_kv ADMIN_PANEL_SESSION_SECRET "$(openssl rand -hex 32)"
set_kv MEILI_MASTER_KEY "$(openssl rand -hex 32)"
set_kv VECTORDB_PASSWORD "$(rand32)"
set_kv JWT_SECRET "$(rand32)"
set_kv JWT_REFRESH_SECRET "$(rand32)"
set_kv CREDS_KEY "$(openssl rand -hex 32)"
set_kv CREDS_IV "$(openssl rand -hex 16)"
set_kv LIBRECHAT_USER_PASSWORD "$(openssl rand -base64 16 | tr -d '/+=' | cut -c1-16)"
set_kv POSTGRES_PASSWORD "$(rand32)"
set_kv LANGFUSE_CLICKHOUSE_PASSWORD "$(rand32)"
set_kv ENCRYPTION_KEY "$(openssl rand -hex 32)"
set_kv NEXTAUTH_SECRET "$(rand32)"
set_kv SALT "$(openssl rand -hex 16)"
set_kv REDIS_AUTH "$(rand32)"
set_kv MINIO_ROOT_PASSWORD "$(rand32)"
set_kv LANGFUSE_INIT_PROJECT_PUBLIC_KEY "pk-lf-$(openssl rand -hex 16)"
set_kv LANGFUSE_INIT_PROJECT_SECRET_KEY "sk-lf-$(openssl rand -hex 16)"
set_kv LANGFUSE_PUBLIC_KEY "$(grep '^LANGFUSE_INIT_PROJECT_PUBLIC_KEY=' .env | cut -d= -f2)"
set_kv LANGFUSE_SECRET_KEY "$(grep '^LANGFUSE_INIT_PROJECT_SECRET_KEY=' .env | cut -d= -f2)"
set_kv LANGFUSE_INIT_USER_PASSWORD "$(openssl rand -base64 16 | tr -d '/+=' | cut -c1-16)"

echo "generate-env: wrote .env with random secrets."
echo ""
echo "STILL REQUIRED — edit .env by hand:"
echo "  GOOGLE_CLOUD_PROJECT=<your GCP project id>"
echo "  GOOGLE_APPLICATION_CREDENTIALS_HOST_PATH=<absolute path to your rotated service-account JSON>"
