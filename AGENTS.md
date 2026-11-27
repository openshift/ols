# OpenShift Lightspeed — Workspace Guide for AI

## Project Overview
OpenShift Lightspeed (OLS) is an AI-powered assistant for OpenShift. This workspace contains all repositories that make up the product. Each repo has its own `AGENTS.md` with repo-specific conventions — read it before working in that repo.

## Repositories

| Repo | Purpose |
|---|---|
| `lightspeed-service` | Core backend — FastAPI service, LLM integration, RAG |
| `lightspeed-operator` | Kubernetes operator that deploys and manages the service |
| `lightspeed-console` | OpenShift console plugin (frontend UI) |
| `lightspeed-rag-content` | RAG corpus — OpenShift documentation for retrieval |
| `lightspeed-agentic-operator` | Operator for the agentic (MCP/tool-calling) variant |
| `lightspeed-agentic-console` | Console plugin for the agentic variant |
| `lightspeed-agentic-sandbox` | Sandboxed execution environment for agentic actions |
| `lightspeed-agentic-alerts-adapter` | Adapter bridging OpenShift alerts into the agentic system |
| `lightspeed-hub` | Multicluster hub — manages spoke clusters, coordinates fleet-wide agentic operations |
| `lightspeed-hub-ui` | Console UI for the multicluster hub |
| `lightspeed-otel-collector` | Custom OpenTelemetry collector for OLS observability |
| `lightspeed-team-harness` | Shared AI coding skills for the team |
| `ols-load-generator` | Load testing tool for the OLS service |

## Cross-Repo Conventions

### Jira
- Project key: **OLS** on `redhat.atlassian.net`
- All commit messages and PR titles start with `OLS-XXXX:`

### Git Workflow
All repos use a **fork-based workflow**:
1. Push to your fork, not `origin`
2. PR against `origin/main` from `<your-user>:<branch>`
3. Squash commits before pushing

### Auto-Push Spec PRs

After brainstorming writes and commits a spec change, **auto-push and open a PR** if the diff only touches spec/docs files. The PR is labeled `kind/design` for easy filtering — a human merges it.

**Spec-only pattern:** `.ai/spec/**`, `docs/superpowers/specs/**`. Never include `AGENTS.md`, `CLAUDE.md`, or any other file — changes to agent instructions or non-spec files always require human review.

**Steps** (run automatically after the spec commit, no user prompt needed):

1. Verify every changed file (vs `origin/main`) matches the spec-only pattern. If any file falls outside, skip and tell the user a PR with mixed content needs manual handling.
2. **Pre-push spec review** — review the full diff for:
   - Internal contradictions between sections or spec files
   - Inconsistencies with existing specs (cross-reference `.ai/spec/` files touched vs untouched)
   - Broken or dangling cross-references between spec files
   - Placeholder text (TBD, TODO, FIXME, incomplete sections)
   - Formatting or structural issues
   - Scope creep beyond what was discussed in brainstorming
   - If issues are found: fix them, amend the commit, and re-review
3. Detect the fork remote: get the authenticated GitHub username (`gh api user -q .login`), then find the remote whose push URL contains that username (e.g. `git remote -v | grep push | grep <username>`). Extract `<fork-remote>` name and `<fork-user>` from its URL. If no matching remote is found, stop and tell the user.
4. Create a branch: `spec/<OLS-XXXX>-<topic>` (use `OLS-0000` when there is no Jira ticket)
5. Push: `git push <fork-remote> spec/<branch>`
6. Open the PR with the `kind/design` label:
   ```
   gh pr create --repo openshift/ols --head <fork-user>:<branch> --base main \
     --title "OLS-XXXX: <summary>" --body "Spec-only change, pre-push reviewed." \
     --label kind/design
   ```
7. Tell the user the PR is ready for review and provide the URL.

If any step fails, stop and report the error to the user — do not retry or work around it.

### Per-Repo Context
Each repo's `AGENTS.md` is authoritative for that repo. This file provides the map; the repo-level files provide the territory. Always read the target repo's `AGENTS.md` before making changes there.

## Specs

All specifications live in `.ai/spec/`. Start with `.ai/spec/README.md` for product overview, reading order, and structure guide. Use `.ai/spec/how/repo-map.md` to quickly find which repo and spec file to update for a given concern.
