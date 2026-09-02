# Architectural Decision Records

This directory holds lightweight decision records for the OLS workspace, numbered chronologically by when each decision was made.

Each file follows the naming convention `NNNN-slug.md` (e.g., `0001-langchain-llm-abstraction.md`).

## Index

### Project Founding (2023-10)
| # | Decision | Repos |
|---|---|---|
| [0001](0001-langchain-llm-abstraction.md) | LangChain as unified LLM interface | service |
| [0002](0002-fastapi-single-worker.md) | FastAPI with single Uvicorn worker | service |
| [0003](0003-rag-over-fine-tuning.md) | RAG over fine-tuning for knowledge grounding | service, rag-content |

### Core Platform (2024-01 — 2024-08)
| # | Decision | Repos |
|---|---|---|
| [0004](0004-operator-deployment-model.md) | Singleton CR, operator deploys all components | operator |
| [0005](0005-plugin-proxy-api-calls.md) | All API calls through console plugin proxy | console, agentic-console |
| [0006](0006-security-baseline.md) | File-path credentials, TLS 1.2+, FIPS-ready | service, operator, collector |
| [0007](0007-prebuilt-faiss-read-only.md) | Pre-built FAISS indexes, read-only at runtime | rag-content, service |
| [0008](0008-embedding-model-in-image.md) | Embedding model shipped in container image | rag-content, service |
| [0009](0009-postgresql-for-persistence.md) | PostgreSQL for cache, quota, and templog | service, operator, collector |
| [0010](0010-konflux-hermetic-builds.md) | Hermetic builds with Konflux CI | all |
| [0011](0011-multi-provider-llm-abstraction.md) | 8+ providers with self-registration | service, operator |
| [0012](0012-disconnected-operation.md) | Air-gapped deployment support | all |

### Classic OLS Maturity (2025-04 — 2026-03)
| # | Decision | Repos |
|---|---|---|
| [0013](0013-mcp-for-tool-integration.md) | MCP for external tool integration | service, operator, sandbox |
| [0014](0014-sse-streaming-first.md) | SSE streaming as primary API | service, console |
| [0015](0015-token-budget-partitioning.md) | Context window partitioning with charge order | service |
| [0016](0016-mcp-app-iframe-sandboxing.md) | Sandboxed iframe with JSON-RPC 2.0 | console, service |
| [0017](0017-skills-progressive-disclosure.md) | Three-level skill loading | service |
| [0018](0018-ask-vs-troubleshooting-modes.md) | ASK vs TROUBLESHOOTING query modes | service, console |

### Agentic Launch (2026-04 — 2026-05)
| # | Decision | Repos |
|---|---|---|
| [0019](0019-multi-phase-agentic-workflow.md) | Six-phase lifecycle with approval gate | agentic-operator, sandbox, agentic-console, alerts-adapter |
| [0020](0020-agentic-state-model.md) | Condition-derived phase + immutable result CRs | agentic-operator, agentic-console |
| [0021](0021-approval-gate-design.md) | Dual approval model with RBAC enforcement | agentic-operator, agentic-console |
| [0022](0022-sandbox-isolation.md) | Ephemeral pods with per-run ServiceAccount | agentic-operator, sandbox |
| [0023](0023-alerts-adapter-design.md) | Polling, stateless, create-only adapter | alerts-adapter |

### Recent Design (2026-06 — 2026-08)
| # | Decision | Repos |
|---|---|---|
| [0024](0024-three-layer-product-architecture.md) | Classic / Agentic / Multicluster layer split | all |
| [0025](0025-dual-rag-architecture.md) | OKP (Solr) + BYOK (FAISS) dual systems | service, rag-content, operator |
| [0026](0026-audit-logging-design.md) | Full-fidelity OTel audit with EU AI Act compliance | service, sandbox, agentic-operator, collector |
| [0027](0027-bedrock-single-provider.md) | Single Bedrock provider with model-prefix routing | service, operator |
| [0028](0028-multicluster-architecture.md) | Hub as router + per-spoke CRs | hub, hub-ui |
| [0029](0029-cross-operator-integration.md) | ConfigMap-based inter-operator handoff | operator, agentic-operator |
| [0030](0030-observability-architecture.md) | Custom OTel Collector with per-phase traces | collector, agentic-operator, sandbox |
| [0031](0031-config-driven-reasoning.md) | Config-driven reasoning via freeform map | service, operator |
| [0032](0032-dynamic-product-filtering.md) | LLM-driven product selection for doc search | service, operator |
| [0033](0033-script-grounded-rbac.md) | RBAC derived from concrete remediation scripts | sandbox, agentic-operator |
| [0034](0034-hybrid-rag-tool-selection.md) | Dense + sparse retrieval for tool/skill filtering | service |
| [0035](0035-remove-claude-sdk.md) | Remove proprietary binary from sandbox | sandbox |
| [0036](0036-rhokp-standalone-deployment.md) | Standalone HTTPS, not sidecar | operator, service |
### Version Gating (2026-08)
| # | Decision | Repos |
|---|---|---|
| [0037](0037-agentic-version-gating.md) | Agentic layer gated to OCP ≥ 5.0 via two version-split bundles | operator, agentic-operator |

### MCP Tool RBAC (2026-08)
| # | Decision | Repos |
|---|---|---|
| [0038](0038-mcp-tool-rbac-resolution.md) | RBAC for MCP tool calls: server-published `_meta` contract → oc-IR fallback → fail-closed, with a hard deny ceiling | agentic-operator, agentic-sandbox, operator (ocp-mcp) |

### Timeout Enforcement (2026-08)
| # | Decision | Repos |
|---|---|---|
| [0039](0039-layered-agent-timeouts.md) | One agent budget with cooperative and hard sandbox enforcement | agentic-operator, sandbox |

### Agentic Run Termination (2026-09)
| # | Decision | Repos |
|---|---|---|
| [0040](0040-agentic-run-termination.md) | Unified hard-stop contract for per-run cancellation and global suspension | agentic-operator, agentic-console |

### Sandbox Credentials (2026-09)
| # | Decision | Repos |
|---|---|---|
| [0041](0041-sandbox-sdk-delegated-tokens.md) | SDK-delegated short-lived tokens; Azure Entra ID via built-in `AsyncAzureOpenAI`, Bedrock STS assume-role via botocore | agentic-sandbox, agentic-operator |
