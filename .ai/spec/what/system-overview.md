# System Overview

OpenShift Lightspeed (OLS) is an AI-powered assistant for OpenShift clusters. It answers user questions about OpenShift/Kubernetes using LLM backends augmented with retrieval from product documentation (RAG), and can execute agentic workflows to diagnose and remediate cluster issues.

## Product Layers

### Classic OLS

The core Q&A assistant. A user asks a question in the console, the service processes it through RAG retrieval and LLM generation (with optional tool calling), and streams back an answer.

1. **lightspeed-service** (Python/FastAPI) — Backend. Owns the query pipeline, LLM provider abstraction, RAG retrieval, conversation caching, quota management, MCP tool integration, and skill execution. Spec: `lightspeed-service/.ai/spec/README.md`
2. **lightspeed-operator** (Go/kubebuilder) — Kubernetes operator. Reconciles the `OLSConfig` CR to deploy and manage the service, console plugin, PostgreSQL, and all supporting resources. Spec: `lightspeed-operator/.ai/spec/README.md`
3. **lightspeed-console** (TypeScript/React) — OpenShift console plugin. Floating chat UI for the assistant, handles streaming responses, context attachment (YAML/logs), conversation history, and tool result visualization. Guide: `lightspeed-console/AGENTS.md`
4. **lightspeed-rag-content** (Python) — Offline pipeline. Builds FAISS vector indexes from OpenShift documentation and customer content (BYOK), packages them as OCI container images consumed at runtime by the service. Spec: `lightspeed-rag-content/.ai/spec/README.md`

### Agentic OLS

Autonomous cluster operations. Alerts or user requests trigger multi-phase AI workflows (analysis → approval → execution → verification) that can take actions on the cluster through sandboxed agents.

5. **lightspeed-agentic-operator** (Go/kubebuilder) — Orchestrates `Proposal` CRs through multi-phase workflows, manages sandbox pods, enforces approval policies, materializes RBAC for execution. Spec: `lightspeed-agentic-operator/.ai/spec/README.md`
6. **lightspeed-agentic-console** (TypeScript/React) — Console plugin providing the AI Hub UI for viewing, approving, and monitoring proposals. Configuration for approval policies, LLM providers, and agent tiers. Spec: `lightspeed-agentic-console/.ai/spec/README.md`
7. **lightspeed-agentic-sandbox** (Python/FastAPI) — Containerized agent runtime. Wraps multiple LLM provider SDKs (Claude, Gemini, OpenAI) behind a unified `/v1/agent/run` HTTP endpoint with structured output and tool execution. Spec: `lightspeed-agentic-sandbox/.ai/spec/README.md`
8. **lightspeed-agentic-alerts-adapter** (Go) — Stateless bridge. Polls AlertManager for firing alerts, creates `Proposal` CRs with deduplication and cooldown logic. Guide: `lightspeed-agentic-alerts-adapter/AGENTS.md`

### Tooling

9. **lightspeed-team-harness** — Shared AI coding skills and conventions for the team (dependency updates, CI failure investigation, PR workflows, CVE resolution). Guide: `lightspeed-team-harness/AGENTS.md`
10. **ols-load-generator** (Go) — Load testing tool. Measures OLS performance under concurrent query load, scrapes cluster Prometheus metrics. Guide: `ols-load-generator/README.md`

## Cross-Repo Features

These features span multiple repos and have dedicated spec files describing the end-to-end behavior:

| Feature | Spec File | Repos Involved |
|---|---|---|
| Agentic proposal lifecycle | `what/agentic-proposals.md` | alerts-adapter, agentic-operator, agentic-sandbox, agentic-console |
| RAG pipeline | `what/rag-pipeline.md` | rag-content, service, operator |
| Deployment lifecycle | `what/deployment-lifecycle.md` | operator, service, console |
| Query pipeline | `what/query-pipeline.md` | console, service, operator, rag-content |

## Planned Changes

| Ticket | Summary |
|---|---|
| OLS-2743 | Rebranding to "Red Hat OpenShift Intelligent Assistant" |
