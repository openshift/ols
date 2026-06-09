# OpenShift Lightspeed Workspace

Cross-repo workspace for OpenShift Lightspeed — shared specs, routing, and AI conventions.

## Repositories

| Repo | Purpose |
|---|---|
| [lightspeed-service](https://github.com/openshift/lightspeed-service) | Core backend — FastAPI service, LLM integration, RAG |
| [lightspeed-operator](https://github.com/openshift/lightspeed-operator) | Kubernetes operator that deploys and manages the service |
| [lightspeed-console](https://github.com/openshift/lightspeed-console) | OpenShift console plugin (frontend UI) |
| [lightspeed-rag-content](https://github.com/openshift/lightspeed-rag-content) | RAG corpus — OpenShift documentation for retrieval |
| [lightspeed-agentic-operator](https://github.com/openshift/lightspeed-agentic-operator) | Operator for the agentic (MCP/tool-calling) variant |
| [lightspeed-agentic-console](https://github.com/openshift/lightspeed-agentic-console) | Console plugin for the agentic variant |
| [lightspeed-agentic-sandbox](https://github.com/openshift/lightspeed-agentic-sandbox) | Sandboxed execution environment for agentic actions |
| [lightspeed-agentic-alerts-adapter](https://github.com/openshift/lightspeed-agentic-alerts-adapter) | Adapter bridging OpenShift alerts into the agentic system |
| [lightspeed-team-harness](https://github.com/openshift/lightspeed-team-harness) | Shared AI coding skills for the team |
| [ols-load-generator](https://github.com/openshift/ols-load-generator) | Load testing tool for the OLS service |

## Setup

Clone all repos into this directory:

```bash
for repo in lightspeed-service lightspeed-operator lightspeed-console lightspeed-rag-content \
  lightspeed-agentic-operator lightspeed-agentic-console lightspeed-agentic-sandbox \
  lightspeed-agentic-alerts-adapter lightspeed-team-harness ols-load-generator; do
  git clone git@github.com:openshift/$repo.git
done
```

Pull all repos:

```bash
for d in */; do [ -d "$d/.git" ] && echo "=== $d ===" && git -C "$d" pull --ff-only; done
```

## Specs

Cross-repo specifications live in `.ai/spec/`. Start with [`.ai/spec/README.md`](.ai/spec/README.md) for the product overview and reading guide. Use [`.ai/spec/how/repo-map.md`](.ai/spec/how/repo-map.md) to find which repo and spec file to update for a given concern.

## Conventions

- **Jira**: Project key `OLS` on `redhat.atlassian.net`
- **Commits**: All messages and PR titles start with `OLS-XXXX`
- **Git workflow**: Fork-based — push to your fork, PR against `origin/main`, squash before pushing
- **Per-repo guides**: Each repo has an `AGENTS.md` with repo-specific conventions
