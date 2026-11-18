# Agentic Token Usage

Cross-repository contract for LLM token usage measured per sandbox invocation, aggregated per AgenticRun, and exported by the agentic operator for Prometheus. Design and rationale: [OLS-3760 design](../../../docs/superpowers/specs/2026-11-16-OLS-3760-token-usage-design.md), [OLS-3998 metrics design](../../../docs/superpowers/specs/2026-11-18-OLS-3998-prometheus-token-metrics-design.md); accounting decision: [ADR 0049](../decisions/0049-sandbox-token-usage-accounting.md).

## Purpose

Let users inspect per-invocation and per-run token usage, estimate model cost externally, understand context occupancy, and aggregate consumption by namespace, workflow step, model, and token type through Prometheus.

## Behavioral rules

### Reporting unit

1. One sandbox invocation publishes at most one Result CR: `AnalysisResult`, `ExecutionResult`, `VerificationResult`, or `EscalationResult`. A workflow may contain several invocations and each reports independently.
2. `AgenticRun.status.tokenUsage` aggregates usage from every Result CR the operator incorporates for that run.
3. [PLANNED: OLS-3998] Prometheus consumption counters are updated from individual Result CR usage when the operator incorporates that Result into its AgenticRun. The Result CR preserves the per-step model needed for metric attribution; model is not a run-level property.

### Result and AgenticRun fields

4. `TokenUsage` may contain `inputTokens`, `outputTokens`, `reasoningTokens`, `toolTokens`, `peakInputTokens`, and `model`. No individual field is CRD-required. A present `tokenUsage` object requires at least one property; a token anomaly must never cause the API server to reject the Result CR's complete status publication.
5. Presence is field-specific. Absent means "not reported"; explicit `0` means "reported, with no tokens". Unknown values MUST NOT be zero-filled.
6. `inputTokens` is the sum of provider-reported input tokens over all model calls in the invocation, including cached input.
7. `outputTokens` is the sum of provider-reported output tokens over all model calls, including reasoning. Its meaning MUST NOT change to exclude reasoning.
8. `reasoningTokens` is the reasoning portion of `outputTokens`. It is published only when every model call that reported usage also reported reasoning details; otherwise it is absent. Partial reasoning sums MUST NOT be published.
9. `toolTokens` is an estimate of the portion of main-agent input contributed by tool results. Skill content is read through tools and is included in `toolTokens`; there is no separate `skillTokens` field. It is derived from provider-reported usage differences, never a local tokenizer. Missing reasoning needed by the derivation, a negative delta, or another unreliable attribution makes the invocation field absent rather than clamped or partially published.
10. `peakInputTokens` is the largest provider-reported input of a single main-agent call. It measures observed context occupancy, not consumption or the model's configured context limit. Classifier, shaping, and summarization calls do not contribute to it.
11. `model` is the model observed for the invocation. It is Result-CR-only and is never aggregated onto `AgenticRun.status.tokenUsage`. Different steps of one AgenticRun may report different models.
12. Cross-field validation is not enforced by the CRD. Token telemetry MUST NOT fail, block, or delay the Result CR, workflow step, or AgenticRun.

### Sandbox counting [OLS-4921; PR #292]

13. Usage includes every model call made during the invocation: main-agent turns, structured-output shaping and retry, tool-result inspection classifier calls, and summarization calls. Each callback run is counted once, including usage received through error callbacks.
14. Usage comes only from provider-reported metadata. Missing response-model metadata does not discard a call's usage; the configured route model may be used as the model fallback.
15. Every failure or timeout path that publishes a Result CR publishes usage observed before the failure. When no model usage was observed, `status.tokenUsage` is absent. A failure path that intentionally publishes no Result CR reports no CR usage.
16. Anthropic models on Bedrock and Vertex may omit `reasoningTokens` until their upstream integrations expose reasoning details. No local tokenization workaround is applied.

### Operator aggregation and completeness [OLS-4920; PR #608]

17. For each incorporated Result CR, every reported `inputTokens`, `outputTokens`, `reasoningTokens`, and `toolTokens` value is added to the corresponding run field. `peakInputTokens` takes the maximum. An omitted field adds nothing and never clears a value reported by an earlier step. A field remains absent until some incorporated Result reports it.
18. A Result CR without `status.tokenUsage` contributes nothing. Explicit zeros are reported values and aggregate normally. `model` is not aggregated.
19. Run-level values are partial sums of what was reported; their presence does not assert completeness. Per-Result values remain the source of truth for step attribution.
20. For succeeded steps the operator records advisory `TokenUsageReported` completeness status. `inputTokens`, `outputTokens`, and `peakInputTokens` are required in practice; `reasoningTokens` and `toolTokens` are optional. Missing fields increment `agenticrun_token_usage_missing_total{field}`. Missing telemetry produces warning-oriented logs but no Kubernetes Warning Event and MUST NOT change phase or outcome.
21. Failed steps are not assessed for completeness because failure before a model call is valid. Any usage they do report is still aggregated.
22. Reconciliation of a Result already incorporated into the AgenticRun does not aggregate it again.

### Prometheus consumption export [PLANNED: OLS-3998]

23. The lightspeed-agentic-operator exposes one counter on its existing secured metrics endpoint:

```text
agenticrun_token_usage_total{
  namespace="<AgenticRun namespace>",
  step_type="analysis|execution|verification|escalation",
  model="<observed model or unknown>",
  token_type="input|output|reasoning|tool"
}
```

24. The counter is updated from an individual Result CR when that Result's usage is incorporated into its AgenticRun. Each reported field increments independently: `inputTokens` maps to `input`, `outputTokens` to `output`, `reasoningTokens` to `reasoning`, and `toolTokens` to `tool`. An absent field produces no increment; an explicit zero is valid but does not change the counter.
25. The `model` label uses the Result CR's observed model. When usage is reported without a model, the fixed value is `unknown`. AgenticRun name, UID, arbitrary owner values, and Result name MUST NOT be labels because they create unbounded per-run series.
26. `peakInputTokens` MUST NOT be exported by this consumption counter because it is a maximum/context-occupancy measurement, not consumed tokens.
27. `reasoning` is a subset of `output`, and `tool` is an estimated subset of `input`. Consumers MUST NOT sum all `token_type` values together.
28. A reconciliation that sees usage already incorporated into the AgenticRun does not intentionally increment the counter again. This is retry protection, not a transactional or durable exactly-once guarantee. Counters follow normal Prometheus process lifecycle and may reset when the operator restarts.
29. Metric handling is advisory. It MUST NOT change Result processing, AgenticRun status, conditions, phase, or outcome.
30. OLS-3998 does not define sandbox Prometheus counters, configurable budgets, budget windows, enforcement, recording rules, alerts, dashboards, pricing tables, or token-to-currency conversion. Those are separate observability work that may consume this metric.

## Repository ownership

| Repository | Responsibility | Child specifications |
| --- | --- | --- |
| lightspeed-agentic-sandbox | Count all model calls, estimate tool usage, track peak input and observed model, publish Result CR usage | `what/provider-contract.md`, `what/run-api.md`, `how/provider-architecture.md` |
| lightspeed-agentic-operator | Define the shared CRD shape, aggregate run usage, report completeness, and expose the planned OLS-3998 Prometheus counter | `what/crd-api.md`, `what/sandbox-execution.md`, `what/system-overview.md` |
| ols observability follow-up | Define budgets, recording/alerting rules, dashboards, and optional cost conversion | Not part of OLS-3998 |

Display in lightspeed-agentic-console remains out of scope here.

## Integration contract

| Producer → consumer | Channel | Data |
| --- | --- | --- |
| Sandbox → operator | Result CR `status.tokenUsage` | Individually optional token fields plus per-invocation `model` |
| Operator → users | `AgenticRun.status.tokenUsage` | Partial run-level sums and maximum peak input; no model |
| Operator → Prometheus [PLANNED: OLS-3998] | `agenticrun_token_usage_total` | Consumption by namespace, step type, model, and token type |
| Prometheus → follow-up observability content | Queries/rules | Budgets, alerts, dashboards, and cost attribution outside OLS-3998 |
