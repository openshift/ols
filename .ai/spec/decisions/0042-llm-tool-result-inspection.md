# 0042: LLM-Based Tool-Result Inspection

**Status:** Accepted
**Applies to:** lightspeed-service, lightspeed-operator, lightspeed-agentic-operator, lightspeed-agentic-sandbox
**Tracking:** OLS-3928

## Context

Tool results contain untrusted data. A result can contain instructions that try to change model behavior before the next model call.

Classic OLS has one centralized tool loop. At the original decision, Agentic OLS had separate SDK harnesses with different tool execution models. OLS-4434 consolidates implemented sandbox routes on DeepAgents; provider-specific model and credential integrations remain separate.

OLS needs one inspection policy for Classic OLS and the DeepAgents path. The policy must not require another model deployment.

## Decision

OLS will inspect model-visible tool results and errors with a separate LLM classifier call.

The classifier will use the active provider, model, endpoint, and credentials. It will receive no tools, conversation history, RAG content, attachments, or skills.

The classifier will return a strict, singular, unambiguous result with a boolean and one controlled category. OLS will not request or accept free-form reasoning. Incomplete or contradictory replies, duplicate JSON keys, multiple decisions, and disagreement between exposed raw and parsed decisions are classifier failures; provider transport mechanics remain repository-owned.

For the DeepAgents sandbox's isolated Azure classifier only, a native OpenAI SDK `BadRequestError` with HTTP 400 and structured `content_filter` code (including normalized `prompt_attack_filtered`) is conservatively treated as malicious with category `unknown`, immediately without retry. This is an unsafe-content policy decision, not a completed model reply or proof of a specific injection category. Other errors, output filtering/refusals, non-Azure classifiers, main-agent calls, and shaping retain their existing behavior. The exception does not change Classic OLS. The exact scope and data restrictions are normative in `../what/tool-result-inspection.md` rule 44a.

OLS will inspect long results in sequential chunks with a 256-token overlap. Every chunk must pass before OLS sends any result content to the main model.

A detection or an exhausted classifier failure will terminate the complete chat request or AgenticRun. OLS will not return partial results or rejected content.
For the sandbox only, fail-closed inspection governs model delivery and application result events, not native telemetry retention: a successfully completed tool span records its raw callback result before inspection, and content-enabled compliance copies may retain it even when rejected. Disabling compliance content capture filters the six standard content fields from those copies only; it does not change source spans or the existing trace endpoint. A valid benign or malicious inspection outcome is `UNSET`; `classifier_error`, including cancellation, is `ERROR` with controlled failure metadata. A fail-closed abort marks the `invoke_agent` span `ERROR` with controlled metadata and no terminal output; sandbox inspector, classifier, and developer logs remain payload-free. A successfully completed native tool span remains `UNSET` and retains its raw result despite later rejection, classifier failure, or sibling failure; a native tool failure is `ERROR` without a success result, and interruption marks only unfinished operations `ERROR`. A normally produced, post-shaped `AgentResult.output`, including domain `success=false`, is recorded exactly; actual pre-terminal failures have no terminal output. These sandbox rules do not change Classic SSE, history, transcript, or audit restrictions.


The Classic centralized tool loop will apply this policy to all result and error content. DeepAgents middleware will apply the same policy in the agentic sandbox.

The original Gemini ADK/OpenAI Agents inspection exemption is historical. Anthropic, Vertex/Google, native/custom OpenAI, and Azure API-key/Entra routes now use shared DeepAgents inspection and tool-output boundaries; both legacy runtime adapters are removed. Vertex/OpenAI is unsupported and out of scope, not a deferred migration target. [Agentic runs](../what/agentic-runs.md#vertexopenai-support-exclusion) requires removal from both sandbox and agentic-operator support surfaces; this decision does not claim that removal is implemented or permit an unguarded fallback. Declared dependency cleanup, live route acceptance, and telemetry compatibility review remain separate work; this decision does not assert completed provider parity.

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
- OpenTelemetry spans and controlled logs report inspection outcomes. Sandbox diagnostics include fixed response-issue codes, the reserved output-token limit, and payload-free warnings for rejected classifier replies even when retries later succeed. They do not change retry/deadline policy or add Prometheus metrics.
- The sandbox Azure input-filter exception can conservatively reject unsafe content without a completed classifier decision; it does not identify a specific injection subtype.

The complete behavioral contract is in `../what/tool-result-inspection.md`.
