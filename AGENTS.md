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
- All commit messages and PR titles start with `OLS-XXXX`

### Git Workflow
All repos use a **fork-based workflow**:
1. Push to your fork, not `origin`
2. PR against `origin/main` from `<your-user>:<branch>`
3. Squash commits before pushing

### Per-Repo Context
Each repo's `AGENTS.md` is authoritative for that repo. This file provides the map; the repo-level files provide the territory. Always read the target repo's `AGENTS.md` before making changes there.

## Specs

All specifications live in `.ai/spec/`. Start with `.ai/spec/README.md` for product overview, reading order, and structure guide. Use `.ai/spec/how/repo-map.md` to quickly find which repo and spec file to update for a given concern.
