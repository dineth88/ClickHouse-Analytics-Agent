#!/usr/bin/env bash
# Aborts (non-zero exit) if anything staged for commit looks like a secret.
# Wired as a pre-push guard and invoked by `make push`.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

STAGED_FILES=$(git diff --cached --name-only --diff-filter=ACM || true)

if [ -z "$STAGED_FILES" ]; then
  echo "check-secrets: nothing staged, nothing to check."
  exit 0
fi

FAIL=0

# 1. Known secret filenames should never be staged (allow the .example templates).
for f in $STAGED_FILES; do
  case "$f" in
    *.example) continue ;;
  esac
  case "$f" in
    .env|.env.*|*/credentials.json|credentials.json|*/auth.json|auth.json|*.pem|*.key|*.p12)
      echo "check-secrets: FORBIDDEN FILE STAGED: $f"
      FAIL=1
      ;;
  esac
done

# 2. Grep staged content for secret-shaped strings.
PATTERNS='PRIVATE KEY|"type": *"service_account"|service_account|AIza[0-9A-Za-z_-]{35}|sk-lf-[a-f0-9]+|pk-lf-[a-f0-9]+'

for f in $STAGED_FILES; do
  case "$f" in
    *.example) continue ;;
    *.md) continue ;;                    # docs legitimately name these patterns in prose
    scripts/check-secrets.sh) continue ;; # this file defines the patterns themselves
  esac
  if git diff --cached -- "$f" | grep -Ev '^(---|\+\+\+)' | grep -E "$PATTERNS" -q 2>/dev/null; then
    echo "check-secrets: possible secret content staged in: $f"
    FAIL=1
  fi
done

if [ "$FAIL" -ne 0 ]; then
  echo ""
  echo "check-secrets: ABORTING — remove the above before committing/pushing."
  exit 1
fi

echo "check-secrets: OK — no secrets detected in staged changes."
