# Agentic Token Usage

Cross-repo contract for LLM token usage reported per sandbox invocation and per AgenticRun. Design and rationale: [OLS-3760 design](../../../docs/superpowers/specs/2026-11-16-OLS-3760-token-usage-design.md); decision: [ADR 0049](../decisions/0049-sandbox-token-usage-accounting.md).

## Purpose

Let users estimate the cost of agentic work by hand and understand model context usage (input consumed, tool/skill share, reasoning share, peak single-call context occupancy).

## Behavioral rules

### Unit

1. The reporting unit is **one sandbox invocation**: one sandbox pod run that publishes exactly one Result CR (`AnalysisResult`, `ExecutionResult`, `VerificationResult`, `EscalationResult`). A workflow phase may involve several invocations; each reports separately.
2. `AgenticRun.status.tokenUsage` aggregates the `status.tokenUsage` of every Result CR the operator processes for that run.

### Fields

3. Input/output usage on Result CRs and AgenticRun (`inputTokens`, `outputTokens`) is implemented [OLS-3661]. Both are required whenever `tokenUsage` is present.
4. `inputTokens` is the sum of provider-reported input tokens over all model calls of the invocation, including cached input.
5. `outputTokens` is the sum of provider-reported output tokens over all model calls, including reasoning tokens. Its meaning MUST NOT change to exclude reasoning.
6. [PLANNED: OLS-3760] `reasoningTokens` (optional) is the reasoning portion of `outputTokens`. It MUST be set only when every model call of the invocation that reported usage also reported a reasoning count (an explicit 0 counts as reported); otherwise it MUST be absent. Partial sums MUST NOT be published. When no model call reported usage, it is 0.
7. [PLANNED: OLS-3760] `toolTokens` (optional) is the estimated portion of `inputTokens` contributed by tool results, including skill reads, entering the main agent's context. `skillTokens` (optional) is the portion of `toolTokens` from trusted skill-source reads (sandbox `provider-contract.md` rule 5a). Both are derived from provider-reported input differences between consecutive main-agent calls, never from a local tokenizer, and are always published (0 without tool calls or model calls).
8. [PLANNED: OLS-3760] `peakInputTokens` (optional) is the largest provider-reported input of any single main-agent call in the invocation (observed context occupancy, not the model's configured limit); 0 when there was no main-agent call. Structured-output, classifier and summarization calls MUST NOT contribute to `peakInputTokens`, `toolTokens` or `skillTokens`.
9. [PLANNED: OLS-3760] `model` (optional, Result CRs only) is the observed response model of the invocation. It is absent on `AgenticRun`.
10. [PLANNED: OLS-3760] The sandbox MUST publish values satisfying `reasoningTokens <= outputTokens`, `skillTokens <= toolTokens <= inputTokens` and `peakInputTokens <= inputTokens`, clamping if needed. The CRD MUST NOT enforce these as cross-field validation, so that an anomaly cannot fail the Result CR publish.

### Counting (sandbox)

11. [PLANNED: OLS-3760] Usage MUST include every model call made during the invocation: main-agent turns, the structured-output pass and its retry, tool-result inspection classifier calls, and summarization calls. Each call MUST be counted exactly once.
12. [PLANNED: OLS-3760] Input, output and reasoning counts MUST come only from provider-reported usage; a call's usage MUST NOT be dropped because the response lacks a model name.

### Aggregation (operator)

13. [PLANNED: OLS-3760] `inputTokens` and `outputTokens` are summed (unchanged from OLS-3661). `reasoningTokens`, `toolTokens` and `skillTokens` are summed complete-or-unset: present on the run only if present on every processed Result CR that carries `status.tokenUsage` (Result CRs without `status.tokenUsage` are skipped and do not clear run values). `peakInputTokens` is the maximum, with the same presence rule. `model` is not aggregated.

### Known gaps

14. [PLANNED: OLS-3760] For Anthropic models on Bedrock and Vertex, `reasoningTokens` is absent until upstream fixes are released and adopted ([langchain-aws PR 1497](https://github.com/langchain-ai/langchain-aws/pull/1497), [langchain-google PR 2010](https://github.com/langchain-ai/langchain-google/pull/2010)). No local workaround is applied.

## Repo ownership

| Repo | Responsibility | Child specs |
| --- | --- | --- |
| lightspeed-agentic-sandbox | Counting all model calls, tool/skill derivation, peak input, publishing `status.tokenUsage` | `what/provider-contract.md` (rules 7, 7a, 57), `what/run-api.md` (rule 21 (a₁), (a₂)), `how/provider-architecture.md` |
| lightspeed-agentic-operator | `TokenUsage` CRD type, run-level aggregation | `what/crd-api.md` (rules 6c–6e, 6c.1), `what/sandbox-execution.md` (rules 43.1, 43.2) |

Display is out of scope (lightspeed-agentic-console, OLS-3692 / OLS-3652).

## Integration contract

| Producer → Consumer | Channel | Data |
| --- | --- | --- |
| Sandbox → Operator | Result CR `status.tokenUsage` (status subresource patch) | `inputTokens`, `outputTokens`, optional `reasoningTokens`, `toolTokens`, `skillTokens`, `peakInputTokens`, `model` |
| Operator → users | `AgenticRun.status.tokenUsage` | Aggregates per rule 13 (no `model`) |
