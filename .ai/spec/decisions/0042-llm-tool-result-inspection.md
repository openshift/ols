# 0042: LLM-Based Tool-Result Inspection

**Status:** Accepted
**Applies to:** lightspeed-service, lightspeed-operator, lightspeed-agentic-operator, lightspeed-agentic-sandbox
**Tracking:** OLS-3928

## Context

Tool results contain untrusted data. A result can contain instructions that try to change model behavior before the next model call.

Classic OLS has one centralized tool loop. Agentic OLS has separate SDK paths with different tool execution models.

OLS needs one inspection policy for Classic OLS and the DeepAgents path. The policy must not require another model deployment.

## Decision

OLS will inspect model-visible tool results and errors with a separate LLM classifier call.

The classifier will use the active provider, model, endpoint, and credentials. It will receive no tools, conversation history, RAG content, attachments, or skills.

The classifier will return a strict result with a boolean and one controlled category. OLS will not request or accept free-form reasoning.

OLS will inspect long results in sequential chunks with a 256-token overlap. Every chunk must pass before OLS sends any result content to the main model.

A detection or an exhausted classifier failure will terminate the complete chat request or AgenticRun. OLS will not return partial results or rejected content.

The Classic centralized tool loop will apply this policy to all result and error content. DeepAgents middleware will apply the same policy in the agentic sandbox.

Gemini ADK and OpenAI Agents will remain unguarded. OLS will document this limit without a runtime warning.

Tool calls will not receive active prompt-injection inspection. Existing schema, authorization, approval, RBAC, network, and sandbox controls will remain active.

One cluster-administrator value will control both guarded paths:

```yaml
spec:
  ols:
    guardrails:
      toolResultInspection:
        enabled: true
```

The value will default to `true`. Main-model tool-safety instructions will remain active when an administrator disables inspection.

## Alternatives Considered

### Deterministic prompt-injection rule engine

Rejected. Natural-language signature rules require a maintained corpus and can cause false positives on logs and security documentation.

OLS will keep structural checks for size, encoding, serialization, and schemas. These checks do not decide prompt-injection intent.

### NeMo Guardrails

Rejected. The selected scope needs one classifier call at an existing tool boundary. OLS already owns interception, retries, failure propagation, and telemetry.

### Local Prompt Guard classifier

Rejected. A local model adds model artifacts, inference dependencies, resource requirements, and license review. The selected design reuses the configured model.

### Classifier inspection of tool calls

Rejected. The selected scope inspects results and errors only. Tool calls continue through existing validation and authorization controls.

### Truncate long results before safety inspection

Rejected as an inspection strategy. An injection can exist outside the inspected prefix.

Existing model-visible output limits still apply before inspection. OLS inspects all content that can enter model context.

## Consequences

- The classifier remains non-deterministic, even with temperature zero.
- Classifier quality varies by configured provider and model.
- Each tool result adds classifier latency and token cost.
- Long results can require many classifier calls because the design has no explicit chunk-count limit.
- Classic classifier tokens count against the initiating user quota.
- A classifier outage can terminate otherwise valid requests because the policy fails closed.
- Result inspection occurs after tool execution and cannot reverse tool side effects.
- Tool calls have no active prompt-injection classifier.
- OLS adds no guardrail framework, deterministic rule engine, or local model dependency.
- OpenTelemetry spans and controlled logs report inspection outcomes. The feature adds no Prometheus metrics.

The complete behavioral contract is in `../what/tool-result-inspection.md`.
