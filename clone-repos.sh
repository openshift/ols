#!/usr/bin/env bash
# Clone or update all OLS sub-repos, for sandbox triage or local checkouts.
#
# Repos that do not exist are shallow-cloned. Repos that already exist are
# updated to the latest origin/main with a fast-forward only — local commits,
# branches, and uncommitted changes are never discarded. If main is checked
# out it is fast-forwarded in place; otherwise only the local main ref moves
# and the current checkout is left alone. Repos whose main has diverged, or
# whose local changes conflict with the update, are reported and left as-is.
#
# Transport / authentication (first match wins):
#   1. OLS_CLONE_PROTOCOL env var: "token", "ssh", or "https"
#   2. GitHub token found (GITHUB_TOKEN env var or CREDS_FILE) -> HTTPS + token
#   3. An SSH key that authenticates to github.com               -> SSH
#   4. Fallback                                                   -> plain HTTPS,
#      where git's credential helpers supply auth if needed (public
#      repos clone anonymously)
#
# Token source priority:
#   1. GITHUB_TOKEN env var
#   2. File at CREDS_FILE (default: /etc/secrets/clone-credentials/token)
#
# Usage: clone-repos.sh [target-dir]
#   target-dir  Directory to clone/update repos in (default: current directory)
#
# OLS_REPOS may override the repo list (space-separated repo names), e.g. for
# testing. The script exits non-zero if any clone or update fails.
set -euo pipefail

ORG="openshift"
CREDS_FILE="${CREDS_FILE:-/etc/secrets/clone-credentials/token}"
GITHUB_TOKEN="${GITHUB_TOKEN:-}"
TARGET_DIR="${1:-$(pwd)}"
mkdir -p "${TARGET_DIR}"

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
if [ -n "${OLS_REPOS:-}" ]; then
  # shellcheck disable=SC2206  # intentional word splitting of a name list
  REPOS=(${OLS_REPOS})
fi

# Never hang waiting for an interactive credential prompt; fail fast instead.
export GIT_TERMINAL_PROMPT=0

if [ -z "${GITHUB_TOKEN}" ] && [ -f "${CREDS_FILE}" ]; then
  GITHUB_TOKEN="$(cat "${CREDS_FILE}")"
fi

# True if an SSH key/agent authenticates to github.com without any prompt.
ssh_to_github_works() {
  command -v ssh >/dev/null 2>&1 || return 1
  local probe
  probe="$(ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new \
    -T git@github.com 2>&1 || true)"
  # ssh exits 1 even on success ("GitHub does not provide shell access"),
  # so inspect the message instead of the exit code.
  grep -q "successfully authenticated" <<<"${probe}"
}

# Pick a transport: an explicit OLS_CLONE_PROTOCOL always wins; otherwise use
# a token if one is available, SSH if it authenticates, else plain HTTPS.
PROTOCOL="${OLS_CLONE_PROTOCOL:-auto}"
if [ "${PROTOCOL}" = "auto" ]; then
  if [ -n "${GITHUB_TOKEN}" ]; then
    PROTOCOL="token"
  elif ssh_to_github_works; then
    PROTOCOL="ssh"
  else
    PROTOCOL="https"
  fi
fi

case "${PROTOCOL}" in
  token)
    if [ -z "${GITHUB_TOKEN}" ]; then
      echo "Error: OLS_CLONE_PROTOCOL=token but no GitHub token found." >&2
      echo "  Set GITHUB_TOKEN or ensure ${CREDS_FILE} exists." >&2
      exit 1
    fi
    # GIT_ASKPASS lets git fetch the password via a helper script rather than
    # prompting interactively (which would hang in a pod) or embedding the token
    # in the URL (where it would be visible in `ps` output and git's reflog).
    _ASKPASS=$(mktemp)
    printf '#!/bin/sh\necho "%s"\n' "${GITHUB_TOKEN}" > "${_ASKPASS}"
    chmod +x "${_ASKPASS}"
    export GIT_ASKPASS="${_ASKPASS}"
    trap 'rm -f "${_ASKPASS}"' EXIT
    ;;
  ssh)
    # BatchMode disables password prompts; accept-new trusts github.com's host
    # key on first contact but still fails loudly if that key ever changes.
    export GIT_SSH_COMMAND="ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new"
    ;;
  https)
    # Plain HTTPS: git's credential helpers (if configured) supply auth;
    # public repos need none.
    ;;
  *)
    echo "Error: OLS_CLONE_PROTOCOL must be \"token\", \"ssh\", or \"https\" (got \"${PROTOCOL}\")." >&2
    exit 1
    ;;
esac

clone_url() { # $1 = repo name
  case "${PROTOCOL}" in
    token) echo "https://oauth2@github.com/${ORG}/${1}.git" ;;
    ssh)   echo "git@github.com:${ORG}/${1}.git" ;;
    https) echo "https://github.com/${ORG}/${1}.git" ;;
  esac
}

# Fast-forward an existing repo to the latest origin/main without disturbing
# local work. Sets OUTCOME to "updated", "uptodate", or "failed".
update_repo() { # $1 = dest, $2 = repo
  local dest="$1" repo="$2" branch label before after ahead note=""
  branch="$(git -C "${dest}" rev-parse --abbrev-ref HEAD 2>/dev/null || echo HEAD)"
  label="${branch}"
  [ "${branch}" = "HEAD" ] && label="detached HEAD"

  if [ "${branch}" = "main" ]; then
    before="$(git -C "${dest}" rev-parse --short HEAD)"
    if ! git -C "${dest}" fetch --quiet origin main; then
      echo "  ⚠ ${repo} — fetch failed; left untouched"
      OUTCOME="failed"
      return 0
    fi
    if ! git -C "${dest}" merge --ff-only --quiet FETCH_HEAD; then
      echo "  ⚠ ${repo} — cannot fast-forward main (diverged or conflicting local changes); left untouched"
      OUTCOME="failed"
      return 0
    fi
    after="$(git -C "${dest}" rev-parse --short HEAD)"
    ahead="$(git -C "${dest}" rev-list --count FETCH_HEAD..HEAD)"
    [ "${ahead}" -gt 0 ] && note=" (${ahead} local commit(s) ahead of origin)"
  else
    # Not on main: fast-forward only the local main ref, keep the checkout.
    before="$(git -C "${dest}" rev-parse --short refs/heads/main 2>/dev/null || echo "(absent)")"
    if ! git -C "${dest}" fetch --quiet origin main:main; then
      if git -C "${dest}" fetch --quiet origin main; then
        echo "  ⚠ ${repo} — local main diverged from origin/main; left on ${label}"
      else
        echo "  ⚠ ${repo} — fetch failed; left on ${label}"
      fi
      OUTCOME="failed"
      return 0
    fi
    after="$(git -C "${dest}" rev-parse --short main)"
  fi

  if [ "${before}" = "${after}" ]; then
    echo "  ✓ ${repo} — already up to date (${after})${note}"
    OUTCOME="uptodate"
  else
    echo "  ✓ ${repo} — updated ${before} → ${after}"
    OUTCOME="updated"
  fi
  [ "${branch}" != "main" ] && echo "    (checkout left on ${label}; only the main ref was moved)"
  return 0
}

echo "Syncing OLS repos in ${TARGET_DIR} (transport: ${PROTOCOL})..."
cloned=0 updated=0 uptodate=0 failed=0
for repo in "${REPOS[@]}"; do
  dest="${TARGET_DIR}/${repo}"
  if [ -d "${dest}/.git" ]; then
    update_repo "${dest}" "${repo}"
    case "${OUTCOME}" in
      updated)  updated=$((updated + 1)) ;;
      uptodate) uptodate=$((uptodate + 1)) ;;
      *)        failed=$((failed + 1)) ;;
    esac
  elif [ -e "${dest}" ]; then
    echo "  ⚠ ${repo} — ${dest} exists but is not a git repository; skipping"
    failed=$((failed + 1))
  else
    echo "  ⏳ ${repo}"
    if git clone --quiet --depth=1 "$(clone_url "${repo}")" "${dest}"; then
      echo "  ✓ ${repo} — cloned via ${PROTOCOL}"
      cloned=$((cloned + 1))
    else
      echo "  ✗ ${repo} — clone failed via ${PROTOCOL}"
      failed=$((failed + 1))
    fi
  fi
done

echo "Done: ${cloned} cloned, ${updated} updated, ${uptodate} already up to date, ${failed} failed."
[ "${failed}" -eq 0 ]
