# 0052: Shared DeepAgents Execution Core for Chat and Batch

**Status:** Proposed [PLANNED: OLS-4671]
**Applies to:** lightspeed-service, lightspeed-agentic-sandbox, lightspeed-console, new lightspeed-agent-core

## Context

Classic chat uses a custom tool-calling loop in lightspeed-service. Agentic batch uses DeepAgents in lightspeed-agentic-sandbox (sandbox ADR 0003). Both loops implement the same concerns: provider routing, MCP, inspection, wrapping, redaction, context control, usage, and tracing. As a result, fixes and features are built and validated twice. OLS-4671 asks for one DeepAgents execution core with separate entry points, preserving the chat API. Contract: [`what/unified-execution-core.md`](../what/unified-execution-core.md).

## Decision

- **Shared library, separate entry points.** A new `lightspeed-agent-core` repository provides the core as a Python library. Chat runs it in-process in lightspeed-service; batch runs it in the sandbox. There are two images. Retrieval (BYOK RAG, skill matching, tool filtering) stays in the service.
- **Distribution without a package index.** Releases attach an sdist to a GitHub release. Consumers pin it as a Hermeto-compatible HTTPS direct-URL requirement with one `--hash`. Provider integrations are optional extras.
- **Sandbox implementation wins.** Where both entry points implemented a concern, the core uses the sandbox implementation. Capabilities only one side had stay with that side and are opt-in.
- **Delegate context management to DeepAgents.** Built-in eviction and summarization with DeepAgents defaults replace chat's token budget, truncation, offload, history compression and local prompt fitting. Context-overflow errors are normalized into one core error type and fed to DeepAgents' reactive fallback on every route.
- **Native conversation state for chat.** Each chat conversation is a DeepAgents thread with a LangGraph checkpointer (Postgres or in-memory, matching the conversation cache), so summaries persist across turns. Batch has no cross-run history and no checkpointer.
- **Custom approval and turn-limit middleware.** Both await a decision in-process. There are no LangGraph interrupts, and the checkpointer is never used to suspend runs. When chat reaches its turn limit, it asks the user whether to continue. Stop yields one final answer with tools disabled. Both waits are bounded by `tools_approval.approval_timeout` and exist only within the live request.
- **Quota stays a soft cap.** A service-supplied gate runs before every model call; Continue grants turns, not quota.
- **Hard cutover** after a parity gate, preceded by a pure-refactor migration of the sandbox onto the core.

## Alternatives Considered

- **Chat entrypoint inside the sandbox image (one image)** — rejected. It adds retrieval dependencies and an HTTP server to every batch pod. It requires new operator topology, and it mixes a multi-user chat server with per-run shell tooling.
- **Per-turn delegation from the service to sandbox pods** — rejected because of startup latency on every chat turn.
- **Core inside the sandbox repo** — rejected in favor of neutral ownership and an independent release.
- **Pinned git dependency or git submodule** — rejected. Hermeto cannot hash-check git requirements alongside our hashed requirement files, and submodules weaken update automation.
- **Publishing to PyPI** — not required. It offers no CVE benefit, because transitive dependencies are locked by consumers either way. Its only benefit is simpler Renovate support, at the cost of public publication process.
- **LangGraph human-in-the-loop for approval** — rejected. It batches approvals per model turn (one slow approval blocks sibling calls) and needs interrupt/resume stream stitching. A throwaway benchmark showed an `InMemorySaver` retaining every step (about 53 MB for a 35-round request); that figure reflects in-memory retention of all steps, not a Postgres checkpointer. Its `when` predicate could express our gating rules, so capability was not the deciding factor.
- **Service-owned history passed in each turn** — rejected. Without persisted summarization state, long conversations are re-summarized on every turn. Writing DeepAgents' summary back into the service cache was also rejected as re-implementing compaction persistence that the checkpointer already provides.
- **Provider-native compaction (Anthropic `compact_20260112`, OpenAI Responses compaction)** — not used now. It covers only some routes, bypasses the safety-wrapped summarizer, produces opaque provider-specific blocks, and is beta. A possible later optimization.
- **Keeping chat's custom budget and truncation** — rejected in favor of DeepAgents built-ins (no context management of our own).
- **A dual path behind a feature flag** — rejected in favor of a hard cutover gated on parity.

## Consequences

- One implementation and one test suite for agent behavior. The Classic loop, budget code, history compression, and the service offload are deleted.
- Chat conversation state is persisted as checkpoints that include tool calls and results; a security and data-retention review is required, and conversation endpoint sourcing and provider switching are open decisions in the contract.
- Oversized input that summarization cannot shrink now fails at the provider instead of being trimmed locally; RAG chunks are no longer trimmed to a budget.
- ADR 0015's in-run partitioning is superseded for chat. The epic's "category-based token budgeting" becomes DeepAgents threshold configuration derived from the context window.
- Some chat behavior changes, as enumerated in the contract. The audit-evidence change needs compliance sign-off.
- Context overflow is detected after the provider rejects the request. Routes whose LangChain integrations do not raise `ContextOverflowError` need a core classifier.
- A new repository needs its own CI, Konflux pipeline, release workflow, and bump automation.
- The console gains a continuation prompt, and the decision endpoint accepts `continuation_id`.
- The image-size risk mainly moves to provider extras. Estimates are roughly unchanged for both images (sandbox about 904 MB, service about 2.07 GB compressed, released amd64), subject to the measured cutover limits.
