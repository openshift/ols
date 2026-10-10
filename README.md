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
| [lightspeed-hub](https://github.com/openshift/lightspeed-hub) | Multicluster hub — manages spoke clusters, coordinates fleet-wide agentic operations |
| [lightspeed-hub-ui](https://github.com/openshift/lightspeed-hub-ui) | Console UI for the multicluster hub |
| [lightspeed-otel-collector](https://github.com/openshift/lightspeed-otel-collector) | Custom OpenTelemetry collector for OLS observability |
| [lightspeed-team-harness](https://github.com/openshift/lightspeed-team-harness) | Shared AI coding skills for the team |
| [ols-load-generator](https://github.com/openshift/ols-load-generator) | Load testing tool for the OLS service |

## Setup

Clone all repos into this directory:

```bash
./setup.sh clone
```

To clone from your GitHub forks and configure upstream remotes, use either form:

```bash
./setup.sh clone-fork <github-user>
# or
GITHUB_USER=<github-user> ./setup.sh clone-fork
```

Pull all repos:

```bash
./setup.sh pull
```

Run `./setup.sh help` for the complete command list and examples.

## Specs

Cross-repo specifications live in `.ai/spec/`. Start with [`.ai/spec/README.md`](.ai/spec/README.md) for the product overview and reading guide. Use [`.ai/spec/how/repo-map.md`](.ai/spec/how/repo-map.md) to find which repo and spec file to update for a given concern.

## Conventions

- **Jira**: Project key `OLS` on `redhat.atlassian.net`
- **Commits**: All messages and PR titles start with `OLS-XXXX`
- **Git workflow**: Fork-based — push to your fork, PR against `origin/main`, squash before pushing
- **Per-repo guides**: Each repo has an `AGENTS.md` with repo-specific conventions
