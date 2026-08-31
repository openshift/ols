# System Overview

OpenShift Lightspeed (OLS) is an AI-powered assistant for OpenShift clusters. It answers user questions about OpenShift/Kubernetes using LLM backends augmented with retrieval from product documentation (RAG), and can execute agentic workflows to diagnose and remediate cluster issues.

## Product Layers

### Classic OLS

The core Q&A assistant. A user asks a question in the console, the service processes it through RAG retrieval and LLM generation (with optional tool calling), and streams back an answer.

1. **lightspeed-service** (Python/FastAPI) — Backend. Owns the query pipeline, LLM provider abstraction, OKP-based knowledge retrieval (via Solr hybrid search), BYOK FAISS retrieval, conversation caching, quota management, MCP tool integration, and skill execution. Spec: `lightspeed-service/.ai/spec/README.md`
2. **lightspeed-operator** (Go/kubebuilder) — Kubernetes operator. Reconciles the `OLSConfig` CR to deploy and manage the service, console plugin, PostgreSQL, and all supporting resources. Spec: `lightspeed-operator/.ai/spec/README.md`
3. **lightspeed-console** (TypeScript/React) — OpenShift console plugin. Floating chat UI for the assistant, handles streaming responses, context attachment (YAML/logs), conversation history, and tool result visualization. Guide: `lightspeed-console/AGENTS.md`
4. **lightspeed-rag-content** (Python) — BYOK tooling. Provides the BYOK tool image for customers to build FAISS vector indexes from their own Markdown documentation. The main RAG content image (OCP product docs FAISS indexes) is deprecated — OCP docs are now served by OKP via the RHOKP sidecar. Spec: `lightspeed-rag-content/.ai/spec/README.md`

### Agentic OLS

Autonomous cluster operations. Alerts or user requests trigger multi-phase AI workflows (analysis → approval → execution → verification) that can take actions on the cluster through sandboxed agents.

The entire agentic layer is installed only on OCP ≥ 5.0. On OCP 4.x, OLS runs classic-only with no agentic components, CRDs, or RBAC present. See constraint 10 in `constraints.md` and decision `decisions/0037-agentic-version-gating.md`.

5. **lightspeed-agentic-operator** (Go/kubebuilder) — Orchestrates `AgenticRun` CRs through multi-phase workflows, manages sandbox pods, enforces approval policies, materializes RBAC for execution. Spec: `lightspeed-agentic-operator/.ai/spec/README.md`
6. **lightspeed-agentic-console** (TypeScript/React) — Console plugin providing the AI Hub UI for viewing, approving, and monitoring agentic runs. Configuration for approval policies, LLM providers, and agent tiers. Spec: `lightspeed-agentic-console/.ai/spec/README.md`
7. **lightspeed-agentic-sandbox** (Python/FastAPI) — Containerized agent runtime. Wraps multiple LLM provider SDKs (Claude, Gemini, OpenAI) behind a unified `/v1/agent/run` HTTP endpoint with structured output and tool execution. Spec: `lightspeed-agentic-sandbox/.ai/spec/README.md`
8. **lightspeed-agentic-alerts-adapter** (Go) — Stateless bridge. Polls AlertManager for firing alerts, creates `AgenticRun` CRs with deduplication and cooldown logic. Guide: `lightspeed-agentic-alerts-adapter/AGENTS.md`

### Multicluster OLS

The hub layer for fleet-scale operations. A central hub cluster manages spoke clusters, aggregating alerts and proposals across the fleet, and providing a single pane of glass for multicluster AI-assisted operations.

9. **lightspeed-hub** (Go/kubebuilder) — Hub operator. Manages `SpokeCluster` CRs, brokers credentials to spoke clusters (secret, MCE), orchestrates standalone adapters on the hub, and coordinates fleet-wide agentic operations. Spec: `lightspeed-hub/.ai/spec/README.md`
10. **lightspeed-hub-ui** (TypeScript/React) — Console plugin for the hub. Single control plane for fleet-wide AgenticRun visibility, spoke management, and approval. Spec: `lightspeed-hub-ui/.ai/spec/README.md`
11. **lightspeed-otel-collector** (Go) — Custom OpenTelemetry collector. Collects and forwards observability data (metrics, traces, logs) across the OLS fleet. Spec: `lightspeed-otel-collector/.ai/spec/README.md`

### Tooling

12. **lightspeed-team-harness** — Shared AI coding skills and conventions for the team (dependency updates, CI failure investigation, PR workflows, CVE resolution). Also hosts the event adapter prototype (polls Jira for new bugs, creates AgenticRun CRs for automated triage). Guide: `lightspeed-team-harness/AGENTS.md`; event adapter spec: `lightspeed-team-harness/.ai/spec/what/event-adapter.md`
13. **ols-load-generator** (Go) — Load testing tool. Measures OLS performance under concurrent query load, scrapes cluster Prometheus metrics. Guide: `ols-load-generator/README.md`

## Cross-Repo Features

These features span multiple repos and have dedicated spec files describing the end-to-end behavior:

| Feature | Spec File | Repos Involved |
|---|---|---|
| Agentic run lifecycle | `what/agentic-runs.md` | alerts-adapter, agentic-operator, agentic-sandbox, agentic-console |
| RAG pipeline | `what/rag-pipeline.md` | rag-content, service, operator |
| Deployment lifecycle | `what/deployment-lifecycle.md` | operator, service, console |
| Query pipeline | `what/query-pipeline.md` | console, service, operator, rag-content |
| Compliance audit logging | `what/audit-logging.md` | agentic-operator, agentic-sandbox, service, operator, agentic-console |
| Temporary audit log storage | `what/templog.md` | otel-collector, operator, agentic-operator, agentic-sandbox |
| Agentic security model | `what/agentic-security.md` | agentic-operator, agentic-console |
| MCP tool RBAC resolution | `what/mcp-tool-rbac.md` | agentic-operator, agentic-sandbox, operator (ocp-mcp) |
| Multicluster operations | `what/multicluster-ops.md` | hub, hub-ui, agentic-operator, alerts-adapter |
| Multicluster testing | `what/multicluster-testing.md` | hub, agentic-operator, alerts-adapter, hub-ui |

## Planned Changes

| Ticket | Summary |
|---|---|
| OLS-2743 | Rebranding to "Red Hat OpenShift Intelligent Assistant" |
| OLS-3473 | Remove Claude SDK and binaries from agentic-sandbox. Reroute Vertex/Anthropic and Bedrock paths to alternative agentic SDKs. |
| OLS-3899 | Gate the agentic layer to OCP ≥ 5.0 via two version-split OLM bundles (v1 classic / v2 full) under one package. See decision 0037. |
