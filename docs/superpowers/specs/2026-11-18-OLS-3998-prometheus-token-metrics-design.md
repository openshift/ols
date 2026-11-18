# OLS-3998 Prometheus Token Metrics Design

## Intent

Expose agentic token consumption from the lightspeed-agentic-operator metrics endpoint so cluster Prometheus can aggregate usage by namespace, workflow step, model, and token type.

This work builds on:

- lightspeed-agentic-sandbox PR #292, which measures each sandbox invocation and publishes token usage and the observed model on its Result CR; and
- lightspeed-agentic-operator PR #608, which incorporates Result CR usage into `AgenticRun.status.tokenUsage` and reports incomplete telemetry without failing the run.

OLS-3998 adds the remaining Prometheus export layer. It does not introduce another token-counting implementation.

## Goals

- Export reported Result CR token consumption through the existing secured agentic-operator metrics endpoint and ServiceMonitor.
- Preserve namespace, workflow-step, and per-step model attribution.
- Preserve partial telemetry by incrementing each reported token field independently.
- Avoid incrementing metrics when reconciliation sees usage that was already incorporated into the AgenticRun.
- Keep metric labels bounded and suitable for Prometheus aggregation.

## Non-goals

- Configurable namespace budgets or budget windows.
- Budget enforcement.
- Prometheus recording rules, alerting rules, or dashboards.
- Model pricing tables or token-to-currency conversion.
- Durable accounting or transactional exactly-once delivery.
- Sandbox-side Prometheus token counters.
- Per-AgenticRun Prometheus attribution.

Budget configuration and observability content may consume these metrics in follow-up work.

## Constraints

- Token telemetry must never fail, block, or delay an AgenticRun.
- Result CR fields are individually optional. Missing fields remain missing and must not be zero-filled.
- `reasoningTokens` is a subset of `outputTokens`.
- `toolTokens` is an estimated subset of `inputTokens`.
- `peakInputTokens` is context occupancy, not consumable usage.
- The observed model belongs to an individual Result CR/sandbox invocation. Different steps in one AgenticRun may use different models.
- Prometheus counters have normal process lifecycle semantics and may reset when the operator restarts.

## Approaches considered

### One ticket for counters, configurable budgets, and PrometheusRule resources

This most closely matched the original placeholder Jira description, but it coupled stable metric export to unresolved policy decisions: budget windows, reset periods, threshold ownership, configuration location, and enforcement versus alerting. OLS-3998 was narrowed to operator metric export; budget policy is follow-up work.

### Separate metric name for each token type

Examples would include `agenticrun_input_tokens_total` and `agenticrun_output_tokens_total`. This makes each type explicit, but creates multiple collectors and does not reduce time-series count or update volume. Every value has the same unit and attribution dimensions.

### One metric with a bounded token-type label — selected

Use one CounterVec with `token_type` as a bounded dimension. This keeps registration and querying consistent and supports parameterized dashboards and recording rules. Documentation must prevent consumers from adding overlapping token categories together.

## Metric contract

The agentic operator exposes:

```text
agenticrun_token_usage_total{
  namespace="<AgenticRun namespace>",
  step_type="analysis|execution|verification|escalation",
  model="<observed model or unknown>",
  token_type="input|output|reasoning|tool"
}
```

Metric type: Prometheus counter.

Unit: tokens.

Suggested help text:

> Token usage reported by processed agentic workflow steps. Input and output are provider-reported totals; reasoning is a subset of output, and tool is an estimated subset of input. Token types must not be summed together.

### Labels

- `namespace`: namespace of the AgenticRun and Result CR.
- `step_type`: workflow step represented by the Result CR.
- `model`: model observed by the sandbox for this invocation. Use the fixed value `unknown` when usage is reported without a model.
- `token_type`: one of `input`, `output`, `reasoning`, or `tool`.

The metric does not include AgenticRun name or UID. Those values would create an unbounded series per run. `AgenticRun.status.tokenUsage` remains the source of truth for per-run usage.

Arbitrary owner labels are also excluded from this initial contract. Namespace is the supported tenancy and aggregation boundary.

## Emission behavior

The operator updates the counter from an individual Result CR when PR #608's completion path successfully incorporates that Result's usage into its AgenticRun.

For every reported field:

- `inputTokens` increments `token_type="input"`;
- `outputTokens` increments `token_type="output"`;
- `reasoningTokens` increments `token_type="reasoning"`;
- `toolTokens` increments `token_type="tool"`.

An absent field produces no increment. An explicitly reported zero is valid but does not change the counter. `peakInputTokens` produces no consumption counter.

Usage published by a failed step is counted when it is incorporated, even though PR #608 does not assess failed steps for completeness.

A reconciliation that determines the Result was already incorporated into the AgenticRun does not increment the metric again. This is reconciliation retry protection, not a transactional exactly-once guarantee. The design does not promise durable consistency across process crashes, leader changes, or counter resets.

Metric update failures or anomalies are advisory and must not change Result processing, AgenticRun status, phase, or conditions.

## Integration boundaries

| Producer | Consumer | Contract |
| --- | --- | --- |
| Sandbox PR #292 | Result CR | Per-invocation token fields and observed model |
| Operator PR #608 | AgenticRun status | Per-run aggregation and completeness reporting |
| OLS-3998 operator metric | Prometheus | Aggregated counters by namespace, step type, model, and token type |
| Follow-up observability work | Prometheus metrics | Recording rules, alerts, dashboards, budgets, and optional cost calculations |

## Verification

Operator tests should verify:

- each reported token field increments the expected label set;
- optional missing fields do not create increments;
- different steps may increment different model series;
- a missing model uses `model="unknown"`;
- `peakInputTokens` is not exported as consumption;
- reprocessing usage already incorporated into the AgenticRun does not increment counters;
- failed-step usage is counted when incorporated;
- metric behavior does not affect run completion or status publication.
