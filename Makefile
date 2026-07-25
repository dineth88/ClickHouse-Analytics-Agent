.PHONY: up down logs ingest seed env check-secrets push ps

COMPOSE := docker-compose --env-file .env

up:
	$(COMPOSE) up -d --build
	bash scripts/wait-for-healthy.sh

down:
	$(COMPOSE) down

ps:
	$(COMPOSE) ps

logs:
	$(COMPOSE) logs -f

# Re-run the (one-shot) replayer services.
ingest:
	$(COMPOSE) up -d --build --force-recreate ingestion-posts ingestion-votes ingestion-comments

# Bulk-load users/badges reference tables straight from S3 via ClickHouse's s3().
seed:
	bash scripts/seed.sh

# Generate a .env with random secrets for every local-only service.
env:
	bash scripts/generate-env.sh

check-secrets:
	bash scripts/check-secrets.sh

# Guarded push: aborts if check-secrets finds anything staged.
push: check-secrets
	git push origin main
