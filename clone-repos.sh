#!/usr/bin/env bash
# Clone all OLS sub-repos for sandbox triage.
#
# Token source priority:
#   1. GITHUB_TOKEN env var
#   2. File at CREDS_FILE (default: /etc/secrets/clone-credentials/token)
#
# Usage: clone-repos.sh [target-dir]
#   target-dir  Directory to clone repos into (default: current directory)
#
# Idempotent — repos that already exist are skipped.
set -euo pipefail

CREDS_FILE="${CREDS_FILE:-/etc/secrets/clone-credentials/token}"
GITHUB_TOKEN="${GITHUB_TOKEN:-}"

if [ -z "${GITHUB_TOKEN}" ] && [ -f "${CREDS_FILE}" ]; then
  GITHUB_TOKEN="$(cat "${CREDS_FILE}")"
fi

if [ -z "${GITHUB_TOKEN}" ]; then
  echo "Error: GitHub token not found." >&2
  echo "  Set GITHUB_TOKEN env var or ensure ${CREDS_FILE} exists." >&2
  exit 1
fi

REPOS=(
  lightspeed-service
  lightspeed-operator
  lightspeed-console
  lightspeed-rag-content
  lightspeed-agentic-operator
  lightspeed-agentic-console
  lightspeed-agentic-sandbox
  lightspeed-agentic-alerts-adapter
  lightspeed-hub
  lightspeed-hub-ui
  lightspeed-otel-collector
  lightspeed-team-harness
  ols-load-generator
)

ORG="openshift"
TARGET_DIR="${1:-$(pwd)}"

# GIT_ASKPASS lets git fetch the password via a helper script rather than
# prompting interactively (which would hang in a pod) or embedding the token
# in the URL (where it would be visible in `ps` output and git's reflog).
_ASKPASS=$(mktemp)
printf '#!/bin/sh\necho "%s"\n' "${GITHUB_TOKEN}" > "${_ASKPASS}"
chmod +x "${_ASKPASS}"
export GIT_ASKPASS="${_ASKPASS}"
trap 'rm -f "${_ASKPASS}"' EXIT

echo "Cloning OLS repos into ${TARGET_DIR}..."
ok=0
skip=0
for repo in "${REPOS[@]}"; do
  dest="${TARGET_DIR}/${repo}"
  if [ -d "${dest}/.git" ]; then
    echo "  ✓ ${repo} (already exists, skipping)"
    skip=$((skip + 1))
  else
    echo "  ⏳ ${repo}"
    git clone --quiet --depth=1 "https://oauth2@github.com/${ORG}/${repo}.git" "${dest}"
    echo "  ✓ ${repo}"
    ok=$((ok + 1))
  fi
done
echo "Done. ${ok} cloned, ${skip} skipped."
