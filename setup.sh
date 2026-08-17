#!/usr/bin/env bash
set -euo pipefail

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
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<EOF
Usage: $(basename "$0") [command]

Commands:
  clone          Clone all repos from openshift/ org (default)
  clone-fork     Clone from your fork and add openshift/ as upstream
  pull           Pull --ff-only on all cloned repos
  status         Show git status for all cloned repos
  help           Show this help

Options (for clone-fork):
  GITHUB_USER    Set via env var or pass as: clone-fork <user>

Examples:
  ./setup.sh                          # Clone all repos from openshift/
  ./setup.sh clone-fork myuser        # Clone from your fork, add upstream
  GITHUB_USER=myuser ./setup.sh clone-fork
  ./setup.sh pull                     # Fast-forward pull all repos
  ./setup.sh status                   # Quick status check across all repos
EOF
}

clone() {
  echo "Cloning repos from ${ORG}/..."
  for repo in "${REPOS[@]}"; do
    if [ -d "${SCRIPT_DIR}/${repo}" ]; then
      echo "  ✓ ${repo} (already exists, skipping)"
    else
      echo "  ⏳ ${repo}"
      git clone --quiet "git@github.com:${ORG}/${repo}.git" "${SCRIPT_DIR}/${repo}"
      echo "  ✓ ${repo}"
    fi
  done
  echo "Done. ${#REPOS[@]} repos ready."
}

clone_fork() {
  local user="${1:-${GITHUB_USER:-}}"
  if [ -z "${user}" ]; then
    echo "Error: GitHub username required."
    echo "  Usage: $(basename "$0") clone-fork <user>"
    echo "  Or:    GITHUB_USER=<user> $(basename "$0") clone-fork"
    exit 1
  fi

  echo "Cloning repos from ${user}/ (upstream: ${ORG}/)..."
  for repo in "${REPOS[@]}"; do
    if [ -d "${SCRIPT_DIR}/${repo}" ]; then
      echo "  ✓ ${repo} (already exists, skipping)"
    else
      echo "  ⏳ ${repo}"
      git clone --quiet "git@github.com:${user}/${repo}.git" "${SCRIPT_DIR}/${repo}"
      git -C "${SCRIPT_DIR}/${repo}" remote add upstream "git@github.com:${ORG}/${repo}.git"
      git -C "${SCRIPT_DIR}/${repo}" fetch --quiet upstream
      echo "  ✓ ${repo} (origin=${user}, upstream=${ORG})"
    fi
  done
  echo "Done. ${#REPOS[@]} repos ready."
}

pull() {
  echo "Pulling all repos..."
  local ok=0 fail=0 skip=0
  for repo in "${REPOS[@]}"; do
    if [ ! -d "${SCRIPT_DIR}/${repo}/.git" ]; then
      skip=$((skip + 1))
      continue
    fi
    if git -C "${SCRIPT_DIR}/${repo}" pull --ff-only --quiet 2>/dev/null; then
      ok=$((ok + 1))
    else
      echo "  ✗ ${repo} (ff-only failed — local changes or diverged)"
      fail=$((fail + 1))
    fi
  done
  echo "Done. ${ok} updated, ${fail} failed, ${skip} not cloned."
}

status() {
  for repo in "${REPOS[@]}"; do
    if [ ! -d "${SCRIPT_DIR}/${repo}/.git" ]; then
      printf "  %-40s %s\n" "${repo}" "(not cloned)"
      continue
    fi
    local branch dirty ahead behind
    branch=$(git -C "${SCRIPT_DIR}/${repo}" branch --show-current 2>/dev/null || echo "detached")
    dirty=$(git -C "${SCRIPT_DIR}/${repo}" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
    ahead=$(git -C "${SCRIPT_DIR}/${repo}" rev-list --count '@{u}..HEAD' 2>/dev/null || echo "?")
    behind=$(git -C "${SCRIPT_DIR}/${repo}" rev-list --count 'HEAD..@{u}' 2>/dev/null || echo "?")

    local info="${branch}"
    [ "${dirty}" != "0" ] && info="${info}, ${dirty} dirty"
    [ "${ahead}" != "0" ] && [ "${ahead}" != "?" ] && info="${info}, ${ahead} ahead"
    [ "${behind}" != "0" ] && [ "${behind}" != "?" ] && info="${info}, ${behind} behind"
    printf "  %-40s %s\n" "${repo}" "${info}"
  done
}

cmd="${1:-clone}"
case "${cmd}" in
  clone)      clone ;;
  clone-fork) clone_fork "${2:-}" ;;
  pull)       pull ;;
  status)     status ;;
  help|-h|--help) usage ;;
  *)
    echo "Unknown command: ${cmd}"
    usage
    exit 1
    ;;
esac
