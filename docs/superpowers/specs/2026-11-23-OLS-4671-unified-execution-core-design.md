# OLS-4671: Unified Execution Core for Classic Chat and Agentic Batch — Design

**Status:** Proposed; not implemented.
**Source:** [OLS-4671](https://redhat.atlassian.net/browse/OLS-4671) (parent OCPSTRAT-3911).
**Normative contract:** [`what/unified-execution-core.md`](../../../.ai/spec/what/unified-execution-core.md). **Decision:** [ADR 0052](../../../.ai/spec/decisions/0052-shared-deepagents-execution-core.md).
**Core spec plan:** [lightspeed-agent-core spec plan](2026-11-23-OLS-4671-agent-core-spec-plan.md).

## Intent

Classic chat and Agentic batch provide overlapping execution capabilities through different orchestration: a custom loop in lightspeed-service and DeepAgents in lightspeed-agentic-sandbox. This design moves both onto one DeepAgents execution core with separate entry points. It preserves the chat API and removes the Classic loop once parity is established.

## Guiding principles

1. **Freeze external contracts.** The chat REST/SSE API, request format, `olsconfig.yaml`/OLSConfig, CRDs, batch `/input/` and Result CR, and operator↔sandbox environment variables do not change. Additive exception: continuation (below).
2. **Sandbox implementation wins.** If chat and batch both implemented a concern, the core uses the sandbox code. Capabilities only one side had stay with that side.
3. **Delegate to DeepAgents.** Prefer DeepAgents/LangChain built-in middleware over custom code. Write custom middleware only where nothing suitable exists (inspection, wrapping, redaction, approval, turn-limit continuation).

## Architecture

```
lightspeed-service (chat)            lightspeed-agentic-sandbox (batch)
  API, auth, quota, history,           /input/, readiness, deadlines,
  RAG/skills/tool filtering,           MCP admission, Result CR
  SSE mapping, decision endpoint
            \                                /
             \                              /
              lightspeed-agent-core (library)
  DeepAgents agent, model router, MCP client, inspection, wrapping,
  redaction, context-management config, Approval/TurnLimit middleware,
  tool retries, normalized events, usage, tracing, reasoning, structured output
```

Two images. Each image installs the core with only the provider extras it needs.

### Why a library and not a second entrypoint in the sandbox image

| | Shared library (chosen) | Chat entrypoint in sandbox image |
|---|---|---|
| Parity | Strong, given the version pin | Strongest |
| Image-size risk | Lands on service image extras | Every batch pod pulls retrieval stack; affects 5-minute startup deadline |
| Operator/topology | No change | New long-running Deployment, NetworkPolicy, TLS, OLSConfig mapping |
| New capability work | Service adopts DeepAgents | Sandbox becomes a multi-user HTTP/SSE server |
| Security separation | Preserved (chat has no shell) | Shared image carries `oc`/shell tooling to chat |
| Rollout | Incremental | New component |

## Core distribution

- New repository `lightspeed-agent-core`. Tagged releases attach a built sdist.
- Consumers pin the sdist as a pip HTTPS direct-URL requirement with exactly one `--hash=sha256:`. This is the form Hermeto documents for external dependencies (`docs/pip.md`, "https urls"). `inject-files` rewrites it to a local `file://` path for the offline build.
- **Git URLs are excluded.** Hermeto documents that git requirements are incompatible with pip hash checking. A requirements file cannot mix hashed HTTPS dependencies with git dependencies, and our files are fully hashed.
- **Wheel URLs are excluded.** Current upstream Hermeto code recognizes `.whl` URLs, but the docs only show source archives, and the Hermeto version in the Konflux prefetch task is unverified.
- Because it is an sdist, pip builds it inside the hermetic build. The core's build backend goes into each consumer's `requirements-build.txt`. The generators (sandbox `scripts/konflux_resolve.py`, service equivalent) emit the URL line.
- **PyPI publication is not required.**
  - CVE scanning gains nothing, because the vulnerable surface is the core's transitive dependencies, which consumers lock and hash either way.
  - Renovate's built-in PyPI support is the only real benefit. A custom regex manager on the GitHub releases datasource, or a bump job, covers it.
  - Defensively reserving the PyPI name is optional (hash pinning already blocks dependency confusion).
- Verification: a throwaway sandbox build against a tagged core sdist precedes rule 37 step 2.

## Execution behavior

### Implementation sources

| Concern | Before | Core uses |
|---|---|---|
| Agent harness | Both | Sandbox DeepAgents adapter |
| Provider routing / credentials | Both | Sandbox model router, plus chat-only routes (WatsonX, etc.) as extras |
| MCP client | Both | Sandbox |
| Inspection, wrapping, redaction | Both | Sandbox |
| Summarization (with `tool_data` handling) | Both (chat history compression) | Sandbox / DeepAgents |
| Large-output offload | Both (`offloaded_content.py`, DeepAgents eviction) | DeepAgents eviction |
| Reasoning config, usage, tracing | Both | Sandbox |
| Iteration limit | Both | Batch: sandbox `recursion_limit`. Chat: continuation middleware (new requirement) |
| Run timeout | Both | Sandbox cooperative timeout |
| Approval | Chat only | Core opt-in `ApprovalMiddleware` |
| Tool retries | Chat only | Core opt-in |
| Tool filtering, skill matching, BYOK RAG | Chat only | Stay in service |
| MCP admission, structured output, native skills, shell backend | Batch only | Stay batch-only |

### Context management (delegated)

DeepAgents 0.7.22 built-ins:

- **`FilesystemMiddleware`** (required, cannot be excluded). Evicts tool results over a token threshold (default 20,000) to `/large_tool_results/<id>`. The model gets a head+tail preview and pages with `read_file`/`grep`. Chat uses an in-memory `StateBackend`, so nothing touches disk; `execute`, `write_file` and `edit_file` are excluded.
- **`SummarizationMiddleware`**. Summarizes at a fraction of the context window from the model profile. Also handles a reactive tail-clip and offload on `ContextOverflowError`.

The sandbox already uses exactly this: default eviction, `compute_summarization_defaults(model)` for trigger/keep/argument truncation, and a `ToolDataSummarizationMiddleware` subclass that changes only the summary prompt and serialization for safety (tool-data trust instruction, visible `<tool_data>` tags, `lc_source=summarization` tagging). It has no context management of its own. The core adopts it unchanged for both profiles.

**Trigger.** No trigger other than "the next call would not fit" is needed. DeepAgents' default threshold provides the headroom for the response and token-estimate error, so no custom tuning is added.

**Cross-turn history (chat only).** DeepAgents supports multi-turn agents natively: a LangGraph checkpointer keyed by thread keeps messages and the `SummarizationEvent` across turns, so compaction happens once and persists. Each chat `conversation_id` becomes a thread (Postgres checkpointer with a PostgreSQL conversation cache, in-memory otherwise). Alternatives considered:

| Option | Outcome |
|---|---|
| Pass the service's stored raw history each turn, without saving the summary | Rejected: long conversations are re-summarized on every turn (extra LLM call, latency, drifting summaries) |
| Write DeepAgents' summary back into the service cache | Rejected: re-implements compaction persistence the checkpointer already provides, and depends on private DeepAgents state |
| Native checkpointer per conversation (chosen) | DeepAgents owns context and compaction across turns. Costs: conversation storage and endpoints must map onto checkpoints (OD-1), a data-at-rest review because checkpoints include tool calls and results, and provider switching mid-conversation (OD-2) |

The earlier ~53 MB checkpoint figure (Approval section) came from `InMemorySaver` retaining every graph step. The contract bounds this: only the latest checkpoint per thread is kept, written at run completion, and deleted with the conversation.

**Provider-native compaction** (Anthropic `compact_20260112` beta, OpenAI Responses compaction; both exposed through `context_management` in langchain-anthropic and langchain-openai) is not used now. It covers only some routes, bypasses the safety-wrapped summarizer, produces opaque provider-specific blocks that cannot be stored as readable history, and is beta.

Consequences:

- The service's Stage 3–4 budget truncation, history truncation and compression, prompt-budget check, tool budget and offload are deleted.
- Input that summarization cannot shrink (system prompt, RAG, skill, attachments, query) is no longer trimmed or rejected locally; RAG chunks are no longer trimmed to a budget. Oversized input fails at the provider. This is accepted in favor of full delegation; the parity gate measures overflow rate and evaluation impact, including a small-context model.
- The epic's "category-based token budgeting" is realized by DeepAgents' default thresholds. The Jira epic text should be updated to match.

### Context overflow normalization

The service's pre-flight `PromptTooLongError` is what makes today's chat overflow message uniform. Without it, providers differ:

| Integration (route) | Raises `ContextOverflowError` |
|---|---|
| `langchain-openai` (OpenAI, Azure OpenAI) | Yes (`context_length_exceeded`, `Input tokens exceed the configured limit`, `exceeds the context window`) |
| `langchain-openai` for vLLM / RHEL AI / OpenAI-compatible | Likely not (vLLM message `This model's maximum context length is …`) |
| `langchain-anthropic` | Yes (`prompt is too long`) |
| `langchain-aws` `ChatBedrockConverse` | Yes |
| `langchain-google-genai` (incl. Vertex Gemini) | Yes |
| `langchain-google-vertexai` (Model Garden) | Not found |
| `langchain-ibm` (WatsonX) | Not found |

The core classifies the gaps (upstreaming fixes preferred) and raises them as `ContextOverflowError` subclasses inside the run, so DeepAgents' reactive fallback works on every route. Only when that fallback cannot recover does the entry point see `ContextWindowExceeded`; chat maps it to today's "Prompt is too long" body. Proactive summarization needs the context window, so entry points supply it for models without a LangChain profile.

### Approval

Custom `ApprovalMiddleware` (`awrap_tool_call`) evaluates `never` / `always` / `tool_annotations` per call and awaits the service approver in-process.

LangGraph `HumanInTheLoopMiddleware` was evaluated:

- It adds no dependencies (already in `langchain`/`langgraph-checkpoint`), and its `when` predicate can express our gating.
- Its required checkpointer measured as follows in a throwaway benchmark (fake model, ~10k-token tool output per round). These figures reflect `InMemorySaver` retaining every step; a Postgres checkpointer keeps state in the database:

| Rounds | Checkpointer | Time | Retained memory |
|---|---|---|---|
| 5 | no / yes | 80 / 106 ms | ~0 / 1.5 MB |
| 35 | no / yes | 494 / 858 ms | ~0 / 52.6 MB |

- It interrupts once per model turn, blocking sibling calls until every approval resolves, and requires interrupt/resume stream stitching. These, not memory, are the deciding reasons. The conversation checkpointer (Context management) is never used to suspend runs.

### Turn limit and continuation

DeepAgents has no turn limit of its own; `create_deep_agent` sets `recursion_limit` 9,999. Probe results with a model that never finishes:

- `recursion_limit` raises `GraphRecursionError`: no reply, and state is lost without a checkpointer. Steps are graph steps, not turns.
- LangChain `ModelCallLimitMiddleware(exit_behavior="end")` appends the fixed `AIMessage("Model call limits exceeded: run limit (3/3)")`. That is not a model-written answer.

Chat therefore uses a core `TurnLimitMiddleware` that counts model calls against the existing effective limit:

- At the limit it emits `continuation_required` and awaits the user, bounded by `tools_approval.approval_timeout` (expiry takes the Stop path). Approval and continuation waits are single-stream: a disconnect or pod restart cancels them, and they cannot be resumed later. `/v1/query` cannot prompt and takes the Stop path immediately.
- **Continue** grants another block of turns.
- **Stop** makes one final model call with tool calling disabled, using the existing per-provider mechanics (`tool_choice="none"`, Anthropic `{"type": "none"}`, Vertex Gemini tool-free synthesis). The instruction is to answer from the evidence gathered so far. If tool calls still come back, they are ignored and the stream ends with a fixed message.
- The decision reuses `POST /v1/tool-approvals/decision` with `continuation_id`.
- Batch keeps `recursion_limit` → failure.

### Quota

Today's quota is a soft cap (service `quota.md`): positive balance checked before every LLM call, debit afterwards. The core calls a service-supplied quota gate before every model call (agent turns, summarization, classifier, Stop answer); the service debits per call. Exhaustion mid-run stops with the existing quota error. Continue grants turns, not quota; with quota exhausted, the Stop answer is skipped.

### Safety

- The sandbox inspection implementation applies to both profiles: each result is inspected, and any failure stops the run. Inspection precedes eviction and covers summarization input and evicted-result reads.
- Audit evidence follows the sandbox rule (A2): raw successful native tool spans are retained even if rejected. This needs compliance sign-off for chat.
- Chat SSE, history and transcripts still never contain rejected content.

## Rollout

1. Create the core by moving the sandbox's agent code and tests. Set up CI, Konflux, sdist releases and bump automation.
2. Switch the sandbox to the core (pure refactor; existing suites must pass unchanged).
3. Add chat-only capabilities and the chat profile to the core.
4. Hard cutover of the service in one release, with the console continuation prompt in the same release. There is no flag.

The parity gate and the full list of intentional chat behavior changes are normative in the contract (rules 39 and "Intentional chat behavior changes").

## Image size

Two images. Measured compressed amd64 sizes via `skopeo inspect`:

| Image | Compressed |
|---|---|
| Sandbox, released (`registry.redhat.io/.../lightspeed-agentic-sandbox-rhel9`, 2026-11-10) | ~904 MB |
| Sandbox, Konflux latest (2026-11-23) | ~904 MB |
| Service, released (`registry.redhat.io/.../lightspeed-service-api-rhel9`, 2026-11-11) | ~2,071 MB |
| Service, upstream `quay.io/openshift-lightspeed/lightspeed-service-api:latest` | ~1,042 MB (difference from released not yet explained) |

Dependency overlap (from `uv.lock`): `langgraph` is already in both. `deepagents` is sandbox-only, so the service gains it (small, pure Python). torch, FAISS, sentence-transformers, `ibm-watsonx-ai` and pandas are service-only and stay out of the sandbox via extras and rule 13.

Estimates: sandbox about 904 MB (<1% change); service about 2.07 GB (<1% change). Cutover limits and the measurement baseline are normative in contract rule 42.

## Out of scope

- Converging chat skill matching onto DeepAgents native skills.
- Moving chat data collection to trace-based collection.
- Durable pause and resume of approval or continuation waits (the checkpointer is not used for it).
- Provider-native compaction endpoints.
- Operator, CRD, or `olsconfig.yaml` changes.
- Proxy idle-timeout behavior for long approval or continuation waits (worth checking during implementation; it affects today's approval wait equally).
