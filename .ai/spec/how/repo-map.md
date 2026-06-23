# Repo Map

Lookup table: concern → repo(s) → spec file(s). Use this to find where to go when updating specs or implementing a feature.

## Classic OLS — Service

| Concern | Repo | Spec Files |
|---|---|---|
| Query processing & prompt composition | lightspeed-service | `what/query-processing.md`, `how/query-pipeline.md` |
| LLM provider support (OpenAI, Azure, WatsonX, RHEL AI) | lightspeed-service | `what/llm-providers.md`, `how/llm-providers.md` |
| MCP tool integration & tool calling loop | lightspeed-service | `what/tools.md`, `how/tools.md` |
| MCP apps (UI resources, tool proxy) | lightspeed-service | `what/mcp-apps.md` |
| RAG retrieval at query time | lightspeed-service | `what/rag.md` |
| OKP retrieval (Solr hybrid search) | lightspeed-service | `what/rag.md` |
| Conversation history & caching | lightspeed-service | `what/conversation-history.md`, `how/cache.md` |
| Authentication & authorization | lightspeed-service | `what/auth.md` |
| Quota management | lightspeed-service | `what/quota.md` |
| Skills (hybrid RAG matching) | lightspeed-service | `what/skills.md` |
| Agent modes (ask, troubleshooting) | lightspeed-service | `what/agent-modes.md` |
| Prompt templates | lightspeed-service | `what/prompts.md` |
| REST API endpoints | lightspeed-service | `what/api.md` |
| Observability (metrics, logging) | lightspeed-service | `what/observability.md` |
| Security (TLS, redaction, input validation) | lightspeed-service | `what/security.md` |
| Configuration model | lightspeed-service | `what/config.md`, `how/config.md` |

## Classic OLS — Operator

| Concern | Repo | Spec Files |
|---|---|---|
| OLSConfig CRD & API | lightspeed-operator | `what/crd-api.md` |
| Reconciliation loop | lightspeed-operator | `what/reconciliation.md`, `how/reconciliation.md` |
| App server deployment | lightspeed-operator | `what/app-server.md` |
| Console plugin deployment | lightspeed-operator | `what/console-ui.md` |
| PostgreSQL deployment | lightspeed-operator | `what/postgres.md` |
| TLS configuration | lightspeed-operator | `what/tls.md` |
| Resource lifecycle & cleanup | lightspeed-operator | `what/resource-lifecycle.md` |
| OLM bundle composition | lightspeed-operator | `what/bundle-composition.md` |
| Agentic alerts adapter deployment | lightspeed-operator | [PLANNED: OLS-3236] `what/reconciliation.md` |
| Agentic console plugin deployment | lightspeed-operator | [PLANNED: OLS-3236] `what/reconciliation.md` |
| Observability (ServiceMonitor, PrometheusRule) | lightspeed-operator | `what/observability.md` |
| Security (RBAC, NetworkPolicy) | lightspeed-operator | `what/security.md` |
| Config generation (olsconfig.yaml) | lightspeed-operator | `how/config-generation.md` |
| Deployment generation | lightspeed-operator | `how/deployment-generation.md` |

## Classic OLS — Console

| Concern | Repo | Spec Files |
|---|---|---|
| Chat UI & streaming | lightspeed-console | `AGENTS.md` (no `.ai/spec/` yet) |
| Context attachment (YAML, logs) | lightspeed-console | `AGENTS.md` |
| Conversation history UI | lightspeed-console | `AGENTS.md` |
| Tool result visualization | lightspeed-console | `AGENTS.md` |

## Classic OLS — RAG Content

| Concern | Repo | Spec Files |
|---|---|---|
| Content sources (BYOK customer Markdown) | lightspeed-rag-content | `what/content-sources.md` |
| Embedding pipeline (chunking, vectorization — BYOK only) | lightspeed-rag-content | `what/embedding-pipeline.md`, `how/plaintext-pipeline.md`, `how/html-pipeline.md` |
| BYOK (customer custom content) | lightspeed-rag-content | `what/byok.md` |
| Container image build (main image deprecated, BYOK tool image only) | lightspeed-rag-content | `what/container-build.md`, `how/container-build.md` |
| LSC library (shared utilities — BYOK scope) | lightspeed-rag-content | `how/lsc-library.md` |

## Agentic OLS — Operator

| Concern | Repo | Spec Files |
|---|---|---|
| Proposal lifecycle (analysis → execution → verification) | lightspeed-agentic-operator | `what/proposal-lifecycle.md` |
| Approval gates & policies | lightspeed-agentic-operator | `what/approval.md` |
| Agentic CRD API (Proposal, Agent, LLMProvider) | lightspeed-agentic-operator | `what/crd-api.md` |
| Sandbox provisioning & execution | lightspeed-agentic-operator | `what/sandbox-execution.md` |
| Reconciler implementation | lightspeed-agentic-operator | `how/reconciler.md` |
| CLI (olsctl) | lightspeed-agentic-operator | `how/cli.md` |

## Agentic OLS — Console

| Concern | Repo | Spec Files |
|---|---|---|
| Proposal list/detail UI | lightspeed-agentic-console | `what/proposal-lifecycle.md` |
| Dynamic configuration components | lightspeed-agentic-console | `what/dynamic-components.md` |
| Configuration UI (approval policies, providers, agents) | lightspeed-agentic-console | `what/configuration.md` |
| Console plugin system integration | lightspeed-agentic-console | `how/console-plugin-system.md` |
| K8s data fetching layer | lightspeed-agentic-console | `how/k8s-data-layer.md` |

## Agentic OLS — Sandbox

| Concern | Repo | Spec Files |
|---|---|---|
| Agent run API (`/v1/agent/run`) | lightspeed-agentic-sandbox | `what/run-api.md` |
| LLM provider contract (Claude, Gemini, OpenAI) | lightspeed-agentic-sandbox | `what/provider-contract.md` |
| Configuration (env vars, provider selection) | lightspeed-agentic-sandbox | `what/configuration.md` |
| Health probes | lightspeed-agentic-sandbox | `what/health-probes.md` |
| Provider architecture (adapters) | lightspeed-agentic-sandbox | `how/provider-architecture.md` |

## Agentic OLS — Alerts Adapter

| Concern | Repo | Spec Files |
|---|---|---|
| Alert polling & deduplication | lightspeed-agentic-alerts-adapter | `AGENTS.md` (no `.ai/spec/` yet) |
| Proposal CR creation | lightspeed-agentic-alerts-adapter | `AGENTS.md` |
| Cooldown logic | lightspeed-agentic-alerts-adapter | `AGENTS.md` |

## Tooling

| Concern | Repo | Spec Files |
|---|---|---|
| Shared AI coding skills | lightspeed-team-harness | `AGENTS.md` (no `.ai/spec/` yet) |
| Load testing & metrics | ols-load-generator | `README.md` (no `.ai/spec/` yet) |

## Cross-Repo Features

These features span multiple repos. See the parent `what/` files for end-to-end behavior:

| Feature | Parent Spec | Repos |
|---|---|---|
| Agentic proposal lifecycle | `what/agentic-proposals.md` | alerts-adapter, agentic-operator, agentic-sandbox, agentic-console |
| Agentic security (approval auth, SA isolation) | `what/agentic-security.md` | agentic-operator, agentic-console |
| RAG pipeline (OKP + BYOK) | `what/rag-pipeline.md` | rag-content, service, operator |
| Deployment lifecycle | `what/deployment-lifecycle.md` | operator, service, console, alerts-adapter [PLANNED: OLS-3236], agentic-console [PLANNED: OLS-3236] |
| Query pipeline | `what/query-pipeline.md` | console, service, operator, rag-content |
| Compliance audit logging | `what/audit-logging.md` | agentic-operator, agentic-sandbox, service, operator, agentic-console |
