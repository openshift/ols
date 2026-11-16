# OLS-3760: Sandbox-Invocation Token Usage Design

**Status:** Proposed; not implemented.
**Source:** [OLS-3760](https://redhat.atlassian.net/browse/OLS-3760). Consumers: OLS-3692 (UI analysis token count) and OLS-3652 (tokens consumed column); both are out of scope here.
**Normative contract:** [`what/token-usage.md`](../../../.ai/spec/what/token-usage.md). **Decision:** [ADR 0049](../../../.ai/spec/decisions/0049-sandbox-token-usage-accounting.md).

## Intent

Give users enough token data to (a) estimate the cost of agentic work by hand and (b) understand how the model's context is used: how much input the agent consumed, how much of it came from tool results and skills, how much output was reasoning, and how close a single call came to the model's context window.

## Current state (the ticket text predates this)

- Since OLS-3066 the sandbox publishes the Result CR itself (`oc create` + status patch). There is no HTTP `RunResponse` and no `sandbox_agent.go` response path; the ticket's steps 2 and 4 do not apply as written.
- OLS-3661 already shipped input/output usage end to end: the sandbox writes `status.tokenUsage {inputTokens, outputTokens}` (`publish_results/status.py`), the operator defines `TokenUsage` on all four Result kinds and sums it into `AgenticRun.status.tokenUsage` (`aggregateTokenUsage`). Child specs still mark this `[PLANNED: OLS-3661]`; those markers are stale.
- Gaps: the DeepAgents provider's `ResultEvent` carries no reasoning count; its totals come from summing stream chunks plus the structured-output `raw` messages and exclude classifier and summarization calls; no model, tool, skill or peak-context data is published.

## Unit

The unit is **one sandbox invocation**: one sandbox pod run, which publishes exactly one Result CR. A workflow phase may involve several invocations (re-analysis, revisions); each has its own Result CR. `AgenticRun.status.tokenUsage` aggregates over every Result CR the operator processes for the run.

## Goals

- Per invocation: summed input, output and reasoning tokens over **every** model call (main agent turns, structured-output pass and its retry, tool-result inspection classifier, summarization); observed model; estimated tool-result and skill-read tokens; peak single-call input.
- Per run: sums of the per-invocation counts and the maximum peak.
- Provider-reported numbers only for input/output/reasoning; no local tokenizer anywhere.
- Backward compatible: existing `inputTokens`/`outputTokens` keep their meaning; new fields are optional.

## Non-goals

- Console/UI changes (OLS-3692, OLS-3652).
- Cost computation, pricing tables, cache-token fields (OLS-3544), OTel metric changes (OLS-3541).
- Per-purpose breakdown (agent vs classifier vs structured output) in the CRD; per-call detail stays in existing OTel `chat` spans.
- Token counts for tool schemas, the skill catalog in the system prompt, or tool-call arguments (constant per call or inseparable without tokenizing).
- Local workarounds for the Anthropic Bedrock/Vertex reasoning gap (see Known gaps).
- Classic OLS (lightspeed-service).

## Anti-goals

- Silently changing what `outputTokens` means.
- Partial values that look complete (for example reasoning from the classifier only).
- Validation that can reject a Result CR publish because of a token anomaly.

## Field semantics

`TokenUsage` (existing struct, extended):

| Field | Type | Meaning |
| --- | --- | --- |
| `inputTokens` | int64, required when struct present | Sum of provider-reported input tokens over all model calls. Includes cached input (billed at a lower rate, so cost estimates are an upper bound until OLS-3544). |
| `outputTokens` | int64, required when struct present | Sum of provider-reported output tokens. Includes reasoning (billed total). |
| `reasoningTokens` | int64, optional | Of which reasoning. Set only when every model call that reported usage also reported a reasoning count (zero is a reported value); otherwise unset ("not reported"). |
| `toolTokens` | int64, optional | Estimated tokens of tool results (including skill reads) that entered the main agent's context. A portion of `inputTokens`. |
| `skillTokens` | int64, optional | Of which trusted skill reads. A portion of `toolTokens`. |
| `peakInputTokens` | int64, optional | Largest provider-reported input of any single main-agent call: observed context occupancy, not the model's configured limit. |
| `model` | string, optional, Result CR only | Observed response model of the invocation. |

Visible output = `outputTokens - reasoningTokens` (consumer arithmetic; not stored).

## Approaches

1. **Selected: LangChain `UsageMetadataCallbackHandler` (thin subclass) plus tool-token derivation in the existing `GenerationCallback`.** One handler per invocation receives `on_llm_end` from every model call; upstream code already sums nested usage details (reasoning, `flex_`/`priority_` keys), is lock-protected for parallel classifier calls and keys totals per model. The subclass adds per-call completeness tracking (needed for the reasoning rule) and a model-name fallback (the upstream handler silently drops usage when `response_metadata["model_name"]` is absent). Tool tokens come from consecutive main-agent calls, which `GenerationCallback` already observes. Picked by the user.
2. **Own accumulator inside `GenerationCallback`.** Same result with more custom code; usage rules (count everything) would conflict with the span filters (skip classifier, `nostream`, summarization) in the same class.
3. **Extend today's scattered summing** (stream loop, structured-output `raw`, add classifier `raw`). Three code paths, already missing classifier, reasoning and summarization. Rejected.

## Design

### Sandbox (lightspeed-agentic-sandbox)

1. **Usage handler.** Create one `InvocationUsageHandler(UsageMetadataCallbackHandler)` per `DeepAgentsProvider.query()`. Attach it to the agent stream config callbacks and to the structured-output `ainvoke` callbacks. The classifier calls (`LangChainClassifierClient`, invoked inside tool execution) inherit callbacks from the parent run; this MUST be verified by a test on the real DeepAgents tool path; if not inherited, pass the handler explicitly in the classifier's `ainvoke` config. Summarization calls inherit the same way.
2. **Subclass behavior.** In `on_llm_end`: if `response_metadata["model_name"]` is missing, use the route's configured model as the key before delegating; count calls with usage and calls whose `output_token_details` contains a key ending in `reasoning`.
3. **Totals.** After the run (and structured-output pass), sum the handler's per-model entries: `input_tokens`, `output_tokens`, and reasoning = sum of `output_token_details` values whose key ends in `reasoning` (`reasoning`, `flex_reasoning`, `priority_reasoning`). Reasoning is published only if the completeness counts match.
4. **Model.** One model per invocation is expected (classifier and structured-output models are built from the same route parameters). If one key: that model. If several: the main agent's observed model, with a warning log. This is a known constraint: a separately configured classifier model would require per-model reporting.
5. **Tool and skill tokens.** In `GenerationCallback`, for main-agent calls only (`lc_agent_name == main_name`, not `nostream`, not summarization, and not structured-output calls, which MUST carry an explicit tag such as `structured_output` so they are excluded even when `main_name` is unset), keep the previous call's message list (`on_chat_model_start`) and usage (`on_llm_end`). For call N+1:
   - Valid pair only if call N's messages are a prefix of call N+1's and the appended messages are exactly call N's `AIMessage` followed by one or more `ToolMessage`s. Otherwise (summarization rewrite, injected middleware messages) skip the pair.
   - `delta = input(N+1) - input(N) - visible_output(N)`, where `visible_output(N) = output(N) - reasoning(N)` when reasoning was reported, else `output(N)`. Clamp at 0 and at `input(N+1)`.
   - Add `delta` to `toolTokens`. Split the skill share by character length: `delta * len(skill ToolMessage contents) / len(all ToolMessage contents)`, where a skill ToolMessage is one accepted as a trusted skill-source read (provider-contract rule 5a provenance: call ID, native `read_file`, canonical path under `/skills/`).
   - `toolTokens` and `skillTokens` are always published when the agent ran (0 without tool calls). Skipped pairs make them a slight undercount.
   - Measured accuracy (live, one run per route, single tool call): estimate vs provider-only ground truth within +2.2% (Anthropic Sonnet 4.6, Bedrock and Vertex), +0.8% (Opus 5.5), -0.2% (Gemini 2.5 Pro), +3.5% (OpenAI gpt-5-mini). Residual = message framing plus previous-turn reasoning that providers echo back.
6. **Peak input.** In the same callback, track the maximum `input_tokens` of main-agent calls.
7. **Remove** the stream-loop token summing and the structured-output `raw` summing (`_usage_from_message`) so nothing is counted twice.
8. **Publish.** `ResultEvent` / `AgentResult` carry all fields; `reasoning_tokens`, `tool_tokens`, `skill_tokens`, `peak_input_tokens` become optional (`None` = unset). `build_status` writes `status.tokenUsage` with `inputTokens`/`outputTokens` as today, adds optional fields only when set, and clamps so that `reasoningTokens <= outputTokens`, `skillTokens <= toolTokens <= inputTokens`, `peakInputTokens <= inputTokens`. When no model call reported usage (including failure paths that publish zero input/output), publish `reasoningTokens`, `toolTokens`, `skillTokens` and `peakInputTokens` as 0 (completeness holds trivially), so one failed invocation does not unset the run-level values.
9. **Dependency floor.** Raise `langchain-anthropic>=1.6.0` (first release reporting reasoning, langchain#39590); the lock already pins 1.7.5.

### Operator (lightspeed-agentic-operator)

1. **CRD.** Extend `TokenUsage` with optional `reasoningTokens`, `toolTokens`, `skillTokens`, `peakInputTokens` (`*int64`, `Minimum=0`) and optional `model` (string, bounded length; Result CRs only). No cross-field CEL rules: an anomaly must not make the sandbox's publish fail (the sandbox clamps instead). `IsZero` keeps keying on input/output.
2. **Aggregation** (`aggregateTokenUsage`, one call per processed Result CR, same status patch as today):
   - `inputTokens`, `outputTokens`: sum (unchanged).
   - `reasoningTokens`, `toolTokens`, `skillTokens`: complete-or-unset. On the first contribution copy the Result's value (possibly nil). On later contributions: if the run value is nil, keep nil; if the Result value is nil, set the run value to nil; otherwise add.
   - `peakInputTokens`: maximum, same nil handling.
   - `model`: not aggregated; absent on `AgenticRun`.
   - A Result CR without `status.tokenUsage` is skipped (as today) and does not clear run values.
3. **Compatibility.** Result CRs from an older sandbox lack the new fields, so run-level optional fields become unset; older CRDs prune unknown fields from a newer sandbox.

### Known gaps

- **Anthropic on Bedrock and Vertex: reasoning unset for now.** Both platforms send `thinking_tokens`, but `langchain-aws` drops it on streaming (main agent) and `langchain-google-vertexai` drops it on both paths. Under the completeness rule `reasoningTokens` is unset on these routes. Decided: accept this; no local hooks. It appears after upstream fixes are released and dependencies are bumped: [langchain-aws#1496](https://github.com/langchain-ai/langchain-aws/issues/1496) / [PR #1497](https://github.com/langchain-ai/langchain-aws/pull/1497); [langchain-google#1928](https://github.com/langchain-ai/langchain-google/issues/1928) / [PR #2010](https://github.com/langchain-ai/langchain-google/pull/2010).
- Older models with thinking off (for example Claude Sonnet 4.6) omit the reasoning field: `reasoningTokens` unset, not 0.
- OpenAI `service_tier` flex/priority: reasoning arrives as `flex_reasoning` / `priority_reasoning` (handled by the suffix rule; priority not verified live).
- Not verified live: direct Anthropic, Azure, third-party OpenAI-compatible servers, Gemini 2.5 Flash.
- Existing behavior, unchanged here: some `run_agent_query()` failure paths (for example after a timeout) report zero usage even when model calls were made, so cost is undercounted for failed invocations. Fixing this is a separate follow-up.

## Verification

- Offline sandbox tests: handler counts main, structured-output (both attempts), classifier and summarization calls exactly once; missing `model_name` fallback; completeness rule (all/none/partial reasoning); suffix keys; tool/skill derivation for valid, skipped (summarization, injected message) and parallel pairs; clamping; failure paths.
- Classifier inheritance on the real DeepAgents tool path (blocks merge if it fails; fix by explicit callback).
- Offline operator tests: aggregation rules for each field including nil transitions and peak maximum; CRD schema accepts and prunes as described.
- Live acceptance per verified route (Bedrock, Vertex Anthropic, Vertex Gemini, OpenAI): `oc get analysisresult <name> -o yaml` shows `status.tokenUsage` with input/output, model, tool/skill/peak fields; reasoning present on Gemini and OpenAI, unset on Bedrock/Vertex Anthropic until the upstream fixes land.

## Child spec updates

Written alongside this design in the child repositories (spec-only PRs there):

| Repo | Spec | Change |
| --- | --- | --- |
| lightspeed-agentic-sandbox | `what/provider-contract.md` rules 7, 7a (new), 57; Planned Changes | Result event optional fields; invocation usage accounting (coverage, model fallback, reasoning completeness, tool/skill derivation, peak input) |
| lightspeed-agentic-sandbox | `what/run-api.md` rule 21 (a₂) (new); Planned Changes | Publish the extended `tokenUsage`; omission of unset fields; clamps; zeros when no call reported usage |
| lightspeed-agentic-sandbox | `how/provider-architecture.md` Implementation Notes | Where the handler is attached, what is removed, which types carry the fields, dependency floor |
| lightspeed-agentic-operator | `what/crd-api.md` rules 6c–6e, 6c.1 (new); field lists; Planned Changes | New optional fields; `model` on Result CRs only; no cross-field validation; OLS-3661 marked done (implemented by OLS-3993/OLS-3995) |
| lightspeed-agentic-operator | `what/sandbox-execution.md` rules 43.1, 43.2 (new); Planned Changes | Complete-or-unset and maximum aggregation; OLS-3661 marked done |

## Left to the builder

- Exact Go field ordering, kubebuilder markers and the `model` length bound.
- Where the handler is constructed and passed (constructor argument vs per-query attribute).
- Log message wording and whether to expose the skipped-pair count in debug logs.
