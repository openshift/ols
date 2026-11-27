# OLS-4671: Spec Plan for the New `lightspeed-agent-core` Component

**Status:** Planning document. The repository does not exist yet and MUST NOT be created as part of this spec work. `lightspeed-agent-core` is a placeholder name.
**Source:** [OLS-4671](https://redhat.atlassian.net/browse/OLS-4671).
**Normative contract:** [`what/unified-execution-core.md`](../../../.ai/spec/what/unified-execution-core.md). **Decision:** [ADR 0052](../../../.ai/spec/decisions/0052-shared-deepagents-execution-core.md). **Design:** [OLS-4671 design](2026-11-23-OLS-4671-unified-execution-core-design.md).

## Purpose

This document plans the repository-level specification set (`.ai/spec/`) that the core repository will carry once it is created. It decides which files exist, what each file covers, where its content comes from (moved from lightspeed-agentic-sandbox or derived from lightspeed-service), and which parent rules each file implements. The specs themselves are written as the first commit of the repository (rollout step 1, contract rule 37).

## Timing and ownership

| Event | Spec action |
| --- | --- |
| Now (OLS-4671 spec PRs) | Parent contract, ADR 0052, this plan; sandbox and service child specs carry `[PLANNED: OLS-4671]` markers |
| Repository creation (org admin, Konflux onboarding, OWNERS) | First commit adds `AGENTS.md` (human-reviewed) and the `.ai/spec/` tree below, with every rule marked `[PLANNED: OLS-4671]` |
| Rollout step 1 (code moved from sandbox) | Remove markers for moved behavior. Sandbox `provider-contract.md` rules that moved are replaced by references to core specs |
| Rollout steps 2–3 | Core specs gain the chat-only capabilities. Markers are removed per implemented capability |
| Rollout step 4 (service cutover) | Remaining markers removed. Parent `unified-execution-core.md` markers removed |

The repository's owners and the Konflux component name are decided at creation; the specs do not depend on them.

## Conventions to follow

The core specs follow the existing child-spec layout and conventions (sandbox and service `.ai/spec/README.md`):

- `what/` contains behavioral, implementation-agnostic rules numbered sequentially per file. `how/` contains codebase navigation. `decisions/` contains repository-level ADRs.
- Unimplemented rules carry `[PLANNED: OLS-XXXX]`.
- Each `what/` file has Behavioral Rules, Configuration Surface (where applicable), Constraints, Verification, and Planned Changes sections. Verification links to the tests that exercise the rules.
- The parent contract stays authoritative for cross-repo integration. Core specs are authoritative for core-internal behavior and MUST NOT redefine shared policy owned by parent specs (`tool-result-inspection.md`, `tool-output-redaction*.md`, `token-usage.md`, `agentic-data-collection.md`).

## Planned file set

```
.ai/spec/
  README.md
  what/
    system-overview.md
    agent-api.md
    profiles.md
    provider-routing.md
    context-management.md
    safety.md
    middleware.md
    events-usage-telemetry.md
    distribution.md
  how/
    project-structure.md
    architecture.md
  decisions/
    README.md
    0001-core-boundary.md
    0002-distribution-without-index.md
```

### `README.md`

Index, structure, audience, quick-start table, and conventions, following the sandbox README. States the placeholder-name caveat until the final name is chosen.

### `what/system-overview.md`

- **Scope:** role of the core, its two consumers, dependency direction, no-HTTP/SSE/ConfigMap/CR rule, component inventory, and integration boundaries.
- **Sources:** parent contract rules 1–7. Sandbox `what/system-overview.md` rules 3–4 and 7–8 (the harness, model routing, and model-resolution parts).
- **Must state:** the implementation-source rule (parent rule 6), and that capabilities an entry point did not use before are opt-in and default-off (parent rule 7).

### `what/agent-api.md`

- **Scope:** the public Python API. It covers:
  - agent construction from a profile: route, tools, backend, middleware options, limits, context window, optional approver, continuation decider and quota gate
  - optional conversation thread and caller-supplied checkpointer (chat only; parent rule 18a)
  - async run returning normalized events
  - the error types (`ContextWindowExceeded`, inspection failure, timeout, limit exceeded)
  - cancellation semantics, and the guarantee that cancellation releases all run state
- **Sources:** sandbox `what/provider-contract.md` (the `AgentProvider` boundary, `ProviderQueryOptions`, event model, rules 1–12), adapted from batch-only to a two-consumer API. The parent integration contract table.
- **Must state:** API stability and versioning rules (semantic versioning; breaking changes require a major version and coordinated consumer bumps).

### `what/profiles.md`

- **Scope:** chat and batch profile definitions.
  - Chat: request-scoped in-memory backend; `execute`/`write_file`/`edit_file` excluded; no subagents; no skills middleware; prompt passthrough.
  - Batch: native tools, skills, subagents, shell backend, structured output.
  - How each consumer selects a profile, and the rule that the chat profile can never get shell or host filesystem access.
- **Sources:** parent rule 14. Sandbox `decisions/0002-sdk-native-skills-route.md` (batch skills route).

### `what/provider-routing.md`

- **Scope:**
  - the model router covering the union of chat and batch routes
  - provider extras, with a clear error at startup when an extra is missing
  - model resolution precedence
  - credential handling (SDK-delegated tokens)
  - TLS and CA handling
  - reasoning configuration mapping
  - context-window input
- **Sources:**
  - parent rules 12–13 and 16
  - sandbox `what/configuration.md` (rules on provider selection, model resolution, credentials, including 3a, 9a and 9b), `what/provider-contract.md` (native integrations, Azure/Bedrock credential modes), and `how/provider-architecture.md`
  - service `what/llm-providers.md` for chat-only routes (WatsonX, RHEL AI/vLLM, other OpenAI-compatible endpoints)
  - parent ADR 0041
- **Note:** consumer-specific configuration mapping (environment variables for batch, `olsconfig.yaml` for chat) stays in consumer specs. This file defines only the route model the consumers map onto.

### `what/context-management.md`

- **Scope:**
  - delegation to DeepAgents `FilesystemMiddleware` eviction and `SummarizationMiddleware` with DeepAgents default thresholds, the sandbox's safety-wrapped summarizer, and a supplied context window for models without a profile
  - cross-turn persistence through the caller's checkpointer: latest checkpoint only, written at run completion, nothing written for interrupted runs
  - no custom budgeting, truncation or local prompt fitting
  - the overflow classifier for vLLM/OpenAI-compatible, WatsonX, and Vertex Model Garden (structured codes preferred), raising `ContextOverflowError` subclasses so DeepAgents' fallback applies, and `ContextWindowExceeded` when it cannot recover
  - the summarization start and end events
- **Sources:** parent rules 15–19a. The design doc's context-management section and provider overflow table. Sandbox `inspection/summarization.py` behavior.
- **Must state:** batch keeps today's eviction and summarization configuration (sandbox rule 72). Any new default applies only where a profile opts in.

### `what/safety.md`

- **Scope:** the local interception points for inspection (each result as produced, before eviction, summarization input, evicted-result reads and searches), the wrapper, redaction, the audit-evidence boundary, and the whole-run stop on rejection.
- **Sources:** sandbox `what/provider-contract.md` (Tool-Result Prompt-Injection Inspection, SAFE-02 sections, rule 60), sandbox `what/tool-output-redaction.md`, sandbox `decisions/0001-tool-output-boundary.md`. Parent rules 20–23.
- **Constraint:** this file defines only local mechanics. Classifier semantics, retries, chunking, failure policy, and data restrictions stay owned by parent `tool-result-inspection.md` and the redaction specs.

### `what/middleware.md`

- **Scope:**
  - `ApprovalMiddleware`: per-call strategy evaluation, the in-process approver await, and reject/timeout results; no LangGraph interrupts or checkpointer.
  - `TurnLimitMiddleware`: model-call counting, the continuation await bounded by the caller's timeout (expiry takes the Stop path), Continue resets the count, Stop makes a final call with tools disabled using per-provider mechanisms and falls back to a fixed message, immediate Stop when no decider is interactive (`/v1/query`), and the recursion ceiling.
  - The quota gate: invoked before every model call, including summarization, classifier and the Stop answer.
  - Tool retries: policy and transient-error classes.
  - The cooperative run timeout, with the clock paused during decisions.
  - All chat-only middleware is opt-in, and the batch profile never installs it.
- **Sources:** parent rules 24–33 and 35a. Service `what/tools.md` rules 11–13 and 27–31, service `what/agent-modes.md` rules 12–13, service `what/execution-core.md` rules 13–21. Sandbox `run_agent.py` timeout behavior (sandbox `what/run-api.md`).

### `what/events-usage-telemetry.md`

- **Scope:**
  - the normalized event model and ordering guarantees
  - token usage accounting across all model calls
  - OTel GenAI spans and attributes
  - content-capture gates
  - the native-span evidence boundary
- **Sources:** sandbox `what/provider-contract.md` (event model, rules 7, 7a, 57, 62), sandbox `what/audit-logging.md`, sandbox `what/data-collection.md`, parent `token-usage.md`, parent `agentic-data-collection.md`, parent rules 34–36.
- **Must state:** consumer-specific projections (SSE mapping, Result CR status, quota) are consumer-owned. Telemetry shape changes require the parent data-collection compatibility review.

### `what/distribution.md`

- **Scope:**
  - the release process: a tag plus an sdist attached to the GitHub release
  - semantic versioning
  - the consumer pin form (HTTPS direct URL with exactly one `--hash`; no git or wheel URLs)
  - build-backend requirements for consumers
  - provider-extras catalogue
  - the dependency rules: no torch/FAISS/embeddings; lazy provider imports
  - the bump-automation contract
  - optional PyPI name reservation
- **Sources:** parent rules 8–13. The design doc's distribution section (Hermeto findings). Sandbox `how/project-structure.md` (extras pattern, lazy imports).

### `how/project-structure.md` and `how/architecture.md`

Package layout, entry points (library only), extras, module responsibilities, middleware ordering in the DeepAgents stack, and the data flow from profile to agent to events. Sources: sandbox `how/project-structure.md` and `how/provider-architecture.md`. Both are written after the code move, from the actual layout. The first commit carries placeholders that list only the planned module groups.

### `decisions/`

- `0001-core-boundary.md`: why the core has no transport or storage knowledge, the implementation-source rule, and default-off capabilities. It references parent ADR 0052 and does not repeat its alternatives.
- `0002-distribution-without-index.md`: the sdist direct-URL choice, why git and wheel URLs are excluded, and why there is no PyPI publication. It references parent ADR 0052.
- Sandbox decisions 0001 (SAFE-02 boundary), 0002 (skills route), and 0003 (single harness) stay in the sandbox repository as history. The core cites them rather than copying them.

## Rule migration from the sandbox

When the code moves (rollout step 1), sandbox spec content is handled as follows:

| Sandbox spec content | Destination |
| --- | --- |
| `provider-contract.md` boundary, events, structured output, model identity (rules 1–12) | Core `what/agent-api.md`. The sandbox keeps only batch-specific option mapping |
| `provider-contract.md` "Tool-Result Prompt-Injection Inspection" and "Tool-Output Content Boundary (SAFE-02)" sections, rule 60 | Core `what/safety.md`. The sandbox keeps the termination-log and Result-suppression rules |
| `provider-contract.md` DeepAgents consolidation (rules 50–67) and verification matrix | Core `what/provider-routing.md` and `what/agent-api.md`. Live batch acceptance evidence stays sandbox-owned |
| `configuration.md` provider selection, model resolution, credentials | Core `what/provider-routing.md`. Environment variable names and their mapping stay in the sandbox |
| `audit-logging.md`, `data-collection.md` span and attribute rules | Core `what/events-usage-telemetry.md`. The sandbox keeps the export and activation wiring |
| `run-api.md`, `health-probes.md`, `e2e-testing.md`, `tool-output-redaction.md` (batch opt-out wiring) | Stay in the sandbox |
| `provider-contract.md` rules 68–74 (OLS-4671) | Stay in the sandbox as the consumption contract |

The service needs no migration: chat-only behavior in the core (approval, turn limit, retries) is specified fresh in core `what/middleware.md`. Service specs keep the consumer-side rules in `what/execution-core.md`.

## Verification expectations

Every core `what/` file MUST have a Verification section once code exists. The planned test areas follow the parent parity gate (rule 39):

- API contract tests
- profile isolation (chat has no shell or filesystem write)
- routing per extra
- overflow normalization for each route
- safety interception points
- each middleware's paths (approve, reject, timeout, Continue, Stop, fallback, disconnect)
- event ordering
- usage completeness

Live provider acceptance stays with the consumers: the sandbox for batch, the service for chat.

## Open items for repository creation

1. Final repository and package name (placeholder `lightspeed-agent-core`).
2. GitHub organization location and OWNERS.
3. Konflux application and component naming, and whether the core builds only an sdist or also a test image.
4. Whether the PyPI name is reserved defensively.
