# Unified Execution Core

[PLANNED: OLS-4671] Cross-repo contract for running Classic chat and Agentic batch on one shared DeepAgents execution core with separate entry points. Design and rationale: [OLS-4671 design](../../../docs/superpowers/specs/2026-11-23-OLS-4671-unified-execution-core-design.md); decision: [ADR 0052](../decisions/0052-shared-deepagents-execution-core.md).

Nothing in this file is implemented. Every rule is [PLANNED: OLS-4671] unless marked otherwise.

## Purpose

Classic chat (lightspeed-service) runs a custom tool-calling loop. Agentic batch (lightspeed-agentic-sandbox) runs DeepAgents. Capabilities and fixes are designed, implemented and validated twice. This contract moves agent execution into one library used by both entry points and removes the Classic loop once parity is established. The chat API and experience are preserved except for the changes listed under [Intentional chat behavior changes](#intentional-chat-behavior-changes).

## Behavioral rules

### Architecture

1. Agent execution for chat and batch MUST use one Python library, `lightspeed-agent-core` (the "core"), maintained in its own repository. After cutover, no other agent loop remains in lightspeed-service or lightspeed-agentic-sandbox.
2. The core MUST NOT depend on lightspeed-service or lightspeed-agentic-sandbox and MUST NOT contain HTTP, SSE, ConfigMap, Result CR, quota, or conversation-storage logic. Both entry points depend on the core.
3. The core owns: DeepAgents agent construction and loop; provider/model routing and credential handling; the MCP client; tool-result inspection; tool-output wrapping and redaction; context management configuration (rules 15–17); the approval middleware (rules 27–28); the turn-limit middleware (rules 29–33); tool retries (rule 24); accepting a conversation thread and a caller-supplied checkpointer (rule 18a); calling a caller-supplied quota gate (rule 35a); normalized events; token usage accounting; OTel GenAI tracing; reasoning configuration; structured output.
4. lightspeed-service (chat entry point) keeps: the REST/SSE API, authentication, conversation IDs, query and attachment redaction, quota, the conversation endpoints and conversation record (rule 18b), transcript and feedback collection, BYOK RAG retrieval, hybrid-RAG skill matching, hybrid-RAG tool filtering, chat prompt composition, the pending-decision store and the decision endpoint, and mapping core events to SSE.
5. lightspeed-agentic-sandbox (batch entry point) keeps: `/input/` handling, readiness checks, batch lifecycle and deadlines, MCP tool admission (`mcp-tool-rbac.md`), Result CR publishing, and termination-log handling.
6. **Implementation-source rule.** Where chat and batch both had an implementation of the same concern before this change, the core MUST use the sandbox implementation. Where only one entry point had an implementation, that capability stays with that entry point: in the core as an opt-in capability, or in the entry point itself.
7. Every core capability that an entry point did not use before this change MUST be opt-in and disabled by default. Batch MUST NOT enable the approval middleware, the turn-limit middleware, or tool retries.

### Distribution

8. The core MUST NOT require publication to PyPI or any other package index. Each release is a Git tag with a built sdist attached to the GitHub release.
9. Consumers MUST pin the core as a pip HTTPS direct-URL requirement to that sdist with exactly one `--hash=sha256:` option, in their Hermeto-prefetched hashed requirements files. Git URL and wheel URL requirements MUST NOT be used (Hermeto cannot hash-check git requirements; wheel-URL support in the deployed Hermeto version is unverified).
10. Consumers MUST add the core's build backend and its build requirements to `.konflux/requirements-build.txt`, and their requirement generators MUST emit the direct-URL line. `pyproject.toml` (`[tool.uv.sources]`) MUST pin the same release so `uv.lock` and the Konflux inputs agree.
11. Version bumps MUST be automated (a custom Renovate rule on the GitHub releases datasource or a bump job in the core repository). Reserving the `lightspeed-agent-core` name on PyPI is optional and does not change rule 8.

### Provider routing

12. The core MUST provide one model router covering every route supported by either entry point before this change (including WatsonX, RHEL AI/vLLM and other OpenAI-compatible endpoints for chat). The service maps `olsconfig.yaml` providers to routes; the sandbox maps its environment variables to routes. Neither external configuration surface changes.
13. Provider integrations MUST be optional extras of the core. Each image installs only the extras for the routes it supports. Selecting a route whose extra is not installed MUST fail at startup with a clear error. The core MUST NOT depend on torch, FAISS, embedding models, or other retrieval dependencies.

### Agent profiles

14. **Chat profile.**
    - Tools: exactly the MCP tools the service resolves and filters for the request, plus `search_openshift_documentation` when OKP/Solr is configured, plus the DeepAgents file tools needed to read evicted results (rule 15).
    - Backend: an in-memory DeepAgents `StateBackend` scoped to the request. `execute`, `write_file` and `edit_file` MUST be excluded. Chat MUST have no shell or host filesystem access.
    - Disabled: DeepAgents subagents (`task`) and the DeepAgents skills middleware. Skills still come from service skill matching, injected into the system prompt as today.
    - Prompt: the system prompt is the one the service composes, passed through unchanged. Prior conversation messages come from the conversation's checkpoint (rule 18a). The only additions allowed are the prompt sections required by the enabled built-in tools.

    **Batch profile.** The sandbox's DeepAgents configuration is unchanged: native tools, skills, subagents, shell backend, admitted MCP tools, and structured output.

### Context management

15. Context management MUST be delegated to DeepAgents' built-in middleware in both profiles. Large tool results are evicted by `FilesystemMiddleware`: the model receives a preview and pages through the rest with the DeepAgents file tools. Conversation growth, within a run and across the turns of a chat conversation, is handled by `SummarizationMiddleware`, including its reactive fallback on `ContextOverflowError`. Neither the core nor the service may implement token budget partitioning, tool-output truncation, offload storage, or history compression of its own.
16. Eviction and summarization thresholds MUST be the DeepAgents defaults (default eviction limit; `compute_summarization_defaults` from the model profile), as the sandbox uses today. When a model has no LangChain profile, the entry point MUST supply its context window so the defaults can be computed. Chat uses the existing `context_window_size` configuration. No new customer-facing settings are added.
17. In chat, the start and end of a DeepAgents summarization MUST be emitted as the existing `history_compression_start` / `history_compression_end` SSE events.
18. **Service removals at cutover:**
    - token-budget truncation of RAG chunks (top-k, score cutoff, multi-index merge and URL deduplication remain)
    - history truncation and history compression
    - prompt-budget validation before the provider call
    - the tool budget, per-round cap and tiered truncation
    - `offloaded_content.py`

    The service passes the retrieved RAG context and matched skill content to the core. For configuration compatibility, `ols_config.history_compression_enabled`, `ols_config.tool_round_cap_fraction`, `ols_config.offload_storage_path` and `llm_providers[].models[].parameters.tool_budget_ratio` stay accepted and validated, have no effect, and log a one-time deprecation warning when set.
18a. **Conversation state (chat only).** Cross-turn conversation history is required for chat and not for batch. Each chat `conversation_id` MUST be a DeepAgents thread with a LangGraph checkpointer, so prior messages and summarization state (including the summary DeepAgents produced) persist across turns and compaction is not repeated on every turn. Chat uses a Postgres checkpointer in the existing OLS database when `conversation_cache` is PostgreSQL, and an in-memory checkpointer when it is memory. Batch MUST NOT use a checkpointer.
18b. **Conversation record.** The conversation endpoints (`GET`/`PUT`/`DELETE /v1/conversations...`), user isolation and capacity eviction keep their contracts. Each completed turn is still recorded as today (query and plain-string response, including reasoning). How the conversation endpoints are sourced (the checkpoint alone, or the existing cache kept as a projection) is open decision OD-1.
18c. **Checkpoint retention.** A conversation's checkpoint thread MUST be deleted when the conversation is deleted or evicted. Only the latest checkpoint per thread is retained, and a checkpoint is written when a run completes, not after every graph step, so memory and storage stay bounded (the in-memory checkpointer otherwise keeps every step).
18d. **Interrupted runs.** A run that ends without completing (client disconnect, error, inspection failure, quota error) MUST NOT write a checkpoint. The conversation stays at its last completed turn.
18e. **Data at rest.** Checkpoints contain tool calls and (redacted, inspection-passed) tool results, which today's conversation cache does not store. A security and data-retention review of checkpoint contents MUST be recorded before cutover.
19. **Context overflow.** The core MUST raise one error type, `ContextWindowExceeded`, when the provider rejects input for exceeding the context window. This covers LangChain `ContextOverflowError` plus a core classifier for routes whose integrations do not raise it (at least RHEL AI/vLLM and other OpenAI-compatible endpoints, WatsonX, and Vertex Model Garden). The classifier prefers structured error codes and uses documented provider message patterns only where no code exists. Classified errors MUST be raised as `ContextOverflowError` subclasses inside the run, so DeepAgents' reactive compaction fallback applies on every route; `ContextWindowExceeded` is raised to the entry point only when that fallback cannot recover. Chat MUST map `ContextWindowExceeded` to today's "Prompt is too long" response (HTTP 413 for `/v1/query`, SSE `error` for streaming, same body). Batch keeps its existing agent-failure handling.
19a. **No local prompt fitting.** Input that summarization cannot shrink (system prompt, RAG context, skill content, attachments, the current query) is not trimmed or rejected locally, and RAG chunks are no longer trimmed to a token budget. If it does not fit, the request reaches the provider and fails with rule 19's response. This is an accepted behavior change; the parity gate measures its overflow rate and evaluation impact (rule 39).

### Safety

20. Tool-result inspection MUST use the sandbox implementation in both profiles. Each model-visible result or error is inspected as DeepAgents produces it, including summarization input and reads or searches of evicted results, as in the sandbox DeepAgents rules of `tool-result-inspection.md`. A failed inspection stops the whole run. Chat emits the fixed inspection-failure message in an SSE `error` event and ends the stream (HTTP 500 for `/v1/query`). Batch writes the termination log and publishes no Result CR. The Classic all-or-nothing concurrent-round rule is superseded.
21. Inspection MUST complete before a result is evicted to the backend, so rejected content never enters the backend.
22. Rejected content MUST NOT enter model context, normalized result events, SSE, conversation history, transcripts, or Result CRs. Audit evidence follows the sandbox rule in both profiles: a successfully completed native tool span keeps its raw (redaction-sanitized) result even if inspection later rejects it. Applying this to chat requires sign-off from the compliance and data-collection owner before cutover.
23. Tool-output wrapping and redaction, the Azure classifier input-filter exception (`tool-result-inspection.md` rule 44a), classifier diagnostics, and inspection span status semantics MUST use the sandbox implementation in both profiles. `inspection.runtime` is `deepagents` for both. Classifier tokens continue to be charged to the initiating user's quota in chat and not in batch.

### Tool execution

24. **Tool retries** (chat only): the core provides opt-in retries with chat's current policy: 2 retries for transient failures, exponential backoff from a 0.2-second base (1.0 second for rate-limit errors), immediate failure for non-transient errors, and final error messages truncated to 220 characters. Batch does not enable it.
25. **Run timeout:** both profiles MUST use the sandbox cooperative agent-timeout implementation. Batch passes `LIGHTSPEED_AGENT_TIMEOUT_SECONDS` as today. Chat passes the existing `TOOL_CALL_ROUND_TIMEOUT` (300 seconds) multiplied by the effective turn limit, restarted on each Continue. The clock MUST pause while awaiting an approval or continuation decision.
26. Concurrent execution of tool calls requested in one model turn follows DeepAgents' default behavior in both profiles.

### Approval

27. Chat tool approval MUST be a custom core middleware (`ApprovalMiddleware`), not LangGraph human-in-the-loop interrupts. The conversation checkpointer (rule 18a) MUST NOT be used to suspend or resume a run. Before each tool call it evaluates the configured strategy (`never`, `always`, `tool_annotations` with the existing `readOnlyHint` rule). When approval is needed, it awaits a decision from an approver supplied by the service, inside that tool call. Approval executes the tool. Rejection or timeout returns today's non-retryable error to the model, unwrapped.
28. The service approver keeps the existing approval contract unchanged: the `approval_required` event, `POST /v1/tool-approvals/decision`, 404/409 semantics, the `tools_approval.approval_timeout` default of 600 seconds, and pending-state cleanup. Batch installs no approval middleware.

### Turn limit and continuation

29. **Batch** keeps the sandbox implementation: `LIGHTSPEED_AGENT_MAX_TURNS` maps to LangGraph `recursion_limit`, and exceeding it is an agent failure.
30. **Chat** MUST count turns as model calls with a core `TurnLimitMiddleware`, against the effective limit resolved as today (service `agent-modes.md` rule 12: ASK 5, TROUBLESHOOTING 35, raised by `ols_config.max_iterations`). Chat's `recursion_limit` is the DeepAgents default (9,999) and serves only as a hard ceiling.
31. When the limit is reached and the model is still requesting tools, the middleware MUST pause before the next model call and await a continuation decision from the service. The service emits `continuation_required` and resolves the decision through `POST /v1/tool-approvals/decision` using `continuation_id`. The wait is bounded by `tools_approval.approval_timeout` (the same setting as approval; no new configuration). On expiry the run takes the Stop path (rule 33).
31a. **Pauses are single-stream.** Approval and continuation waits exist only inside the live request. They MUST NOT survive a client disconnect or a pod restart and cannot be resumed later; a disconnect cancels the request and releases all run state (rule 18d). Durable pause and resume is out of scope.
31b. **Non-streaming requests.** `/v1/query` cannot prompt the user. At the turn limit it MUST take the Stop path immediately without emitting `continuation_required` or waiting.
32. **Continue** resets the turn count and grants another block of turns equal to the effective limit, in the same stream and with the same context.
33. **Stop** MUST make exactly one more model call with tool calling disabled and an instruction to answer the original question from the information gathered so far and to state what is incomplete. Tools stay bound, and calling is disabled with the existing per-provider mechanisms (service `agent-modes.md` rule 13: provider `tool_choice="none"`, Anthropic `{"type": "none"}`, Vertex Gemini tool-free synthesis request). If the provider still returns tool calls, they MUST be ignored and the stream ends with a fixed turn-limit message. The response streams as normal `token`/`reasoning` events followed by `end`. The previous automatic final no-tool iteration at the limit is superseded by this flow.

### Events, usage and telemetry

34. The core emits normalized events. The service maps them to the existing SSE contract without changing event names, payloads, or ordering rules. The only addition is `continuation_required` (rule 31). The sandbox maps them to its existing normalized events and Result data.
35. Token usage accounting MUST use the sandbox implementation (`token-usage.md`). Chat deducts quota from the core's usage for every model call of the request: agent turns, the Stop final answer, summarization, and inspection classifier calls.
35a. **Quota enforcement (chat).** Chat keeps the existing soft-cap model (service `quota.md` rules 3–4e). The core MUST call a quota gate supplied by the service before every model call (agent turns, summarization, inspection classifier calls, the Stop final answer), and the service debits after each call rather than once per request. When the gate reports exhausted quota, the run stops with the existing quota error. Continue grants turns, not quota; when quota is exhausted the Stop final answer is skipped and the quota error is returned. Strict pre-reservation is out of scope.
36. OTel GenAI tracing and reasoning configuration MUST use the sandbox implementations. Chat exports spans only when OTLP export is configured for the service. Chat's `reasoning_config` maps onto the core's reasoning configuration. Chat keeps storing streamed reasoning in the plain-string response (`query-pipeline.md` Stage 8). Service Prometheus metrics stay in the service.

### Rollout and cutover

37. Work proceeds in this order, each step independently releasable:
    1. Create the core by moving the sandbox's agent code and tests.
    2. Switch the sandbox to the core as a pure refactor. Batch behavior and contracts are unchanged, and the existing sandbox offline and live suites pass unchanged.
    3. Add the chat-only capabilities to the core: approval, turn limit, retries, chat-only providers, the overflow classifier, and the chat profile.
    4. Cut over the service in one release: Stage 7 calls the core, and the code in rule 18 plus the Classic tool-calling loop are deleted. There is no feature flag or dual path.
38. lightspeed-console MUST ship the continuation prompt (Continue / Stop) in the same release as rule 37 step 4.
39. **Parity gate:** step 4 MUST NOT merge until all of the following pass:
    - SSE, request and REST contract tests show no change other than rule 34's addition and the `continuation_id` decision input.
    - The service e2e suite passes, and the evaluation suite score drops by no more than 5% (relative) on every supported provider route. A route without credentials or with skipped tests is unverified, not passed.
    - Approval tests cover every strategy, including reject and timeout.
    - Continuation tests cover Continue, Stop with final answer, Stop fallback, timeout, `/v1/query` automatic Stop, and disconnect.
    - Conversation tests cover multi-turn summarization persisted in the checkpoint (no repeated compaction), retention on delete and eviction (rule 18c), interrupted runs (rule 18d), and changing provider or model mid-conversation (OD-2).
    - Overflow rate and evaluation results are reported per route, including at least one small-context model (rule 19a).
    - Quota tests cover the gate before every model call and exhaustion mid-run and at Stop (rule 35a).
    - `ContextWindowExceeded` mapping is verified for every route.
    - Chat-profile inspection, wrapping and redaction tests pass, including evicted and summarized content.
    - Quota tests show usage includes classifier and summarization tokens.
    - Rules 41–42 are met.
    - Rule 22 sign-off and the rule 18e review are recorded.
    - Open decisions OD-1 and OD-2 are resolved.
    - The data-collection compatibility review is recorded if chat telemetry shape changes.
40. Rollback is to the previous service release, or independently to the previous sandbox release.

### Images

41. There MUST be two images: lightspeed-service (chat) and lightspeed-agentic-sandbox (batch). Each includes the core with only its own provider extras. The core has no image.
42. Before rule 37 step 2, a baseline MUST be recorded per supported architecture for:
    - compressed and uncompressed image size
    - sandbox pod start-to-Ready time and time to first model call
    - service startup, time-to-first-token, and end-to-end latency on the evaluation suite
    - chat per-request and steady-state memory

    Cutover limits:
    - sandbox image growth ≤ 5% and start-to-Ready growth ≤ 10%
    - service image growth ≤ 10%
    - chat p50/p95 time-to-first-token and end-to-end latency regression ≤ 10% on the same provider and model
    - chat steady-state memory regression ≤ 15%

    Exceeding a limit blocks cutover until it is mitigated or the limit is formally revised.

## Intentional chat behavior changes

These are the only chat behavior changes. Batch behavior does not change.

1. DeepAgents eviction and summarization replace the tool budget, tiered truncation, service offload, and history compression (rules 15–18). Conversation state is kept in a DeepAgents checkpoint per conversation, including tool calls and results (rules 18a–18e).
2. Context overflow is detected after provider rejection, with the same response body, and RAG chunks are no longer trimmed to a budget (rules 19, 19a).
3. Inspection checks each result individually instead of the whole concurrent round (rule 20).
4. Rejected results may remain in native tool span audit evidence (rule 22).
5. Sandbox-implemented diagnostics, the Azure classifier exception, span semantics, the run timeout, and usage accounting apply (rules 23, 25, 35).
6. At the turn limit the user is asked whether to continue, bounded by the approval timeout; `/v1/query` stops automatically (rules 30–33, 31a, 31b).
7. Quota is checked before every model call and debited per call (rule 35a).

## Open decisions

These block cutover (rule 39) and are recorded here for review.

- **OD-1: conversation endpoint source.** (a) The existing conversation cache stays as a projection written after each completed turn and serves the conversation endpoints, while the checkpoint is the source of model context. The API and cache code stay unchanged, and existing stored conversations remain readable; a conversation without a checkpoint is seeded from its cached history on its next turn. (b) The checkpoint is the single store, and the conversation endpoints read from it. This means one store, but the endpoints, eviction and existing data need migrating. Recommended: (a).
- **OD-2: changing provider or model mid-conversation.** Checkpointed messages can carry provider-specific content (tool-use blocks, reasoning signatures) that another provider rejects; today's plain-string history avoids this. (a) Start a new checkpoint thread seeded from the conversation's plain-string history when the effective provider or model changes. (b) Normalize checkpointed messages before each run. Recommended: (a), which depends on OD-1 (a).

## Integration contracts

| Producer → Consumer | Channel | Contract |
| --- | --- | --- |
| Core → service, sandbox | Python API | Agent construction from a profile (route, tools, backend, middleware options, limits, context window, optional approver and continuation decider); async run yielding normalized events; `ContextWindowExceeded` error type |
| Core repo → consumers | GitHub release sdist | HTTPS direct-URL requirement with one `--hash=sha256:`; optional provider extras |
| Service → console | SSE | New `continuation_required` event: `continuation_id`, `turns_used`, `turn_limit`. All existing events unchanged. |
| Console → service | `POST /v1/tool-approvals/decision` | Accepts exactly one of `approval_id` or `continuation_id`. For `continuation_id`, `approved: true` is Continue and `false` is Stop. 404 when no pending entry exists, 409 when already resolved. |
| Service → OLS PostgreSQL | LangGraph Postgres checkpointer | Checkpoint tables in the existing OLS database for chat conversation state (rule 18a); no change to operator-managed PostgreSQL deployment |
| Core → service | Quota gate callback | Called before every model call; reports whether the subject has available quota (rule 35a) |

## Repo ownership

| Repo | Responsibility |
| --- | --- |
| lightspeed-agent-core (new) | Core capabilities in rules 3, 12–17, 18a (thread and checkpointer input), 19–27, 30–36; distribution (rules 8, 11); core CI and Konflux |
| lightspeed-service | Chat entry point (rule 4), removals (rule 18), conversation checkpointer and record (rules 18a–18e), quota gate (rule 35a), SSE mapping, approver and continuation decider, decision endpoint extension, cutover |
| lightspeed-agentic-sandbox | Batch entry point (rule 5); moving agent code to the core; consuming the core (rule 37 step 2) |
| lightspeed-console | Continuation prompt (rule 38) |
| lightspeed-operator, lightspeed-agentic-operator | No change |

Child specs: service `what/execution-core.md` (consumer rules) with `[PLANNED: OLS-4671]` markers in `what/query-processing.md`, `what/agent-modes.md`, `what/tools.md`, `what/conversation-history.md`, `what/api.md`, `what/config.md`, `what/tool-output-redaction.md` and `how/`; sandbox `what/provider-contract.md` rules 68–74, `what/system-overview.md`, `how/`, and decision `0004-consume-shared-agent-core.md`. The core repository's own specs are planned in [the core spec plan](../../../docs/superpowers/specs/2026-11-23-OLS-4671-agent-core-spec-plan.md) and are written when the repository is created.
