# 0047: Shared Policy, Separate Tool-Output Redaction Runtimes

**Status:** Proposed [PLANNED: OLS-3939]; no OLS 2.0 release commitment
**Applies to:** lightspeed-service, lightspeed-console, lightspeed-operator, lightspeed-agentic-operator, lightspeed-agentic-sandbox, lightspeed-agentic-console

## Context

Classic prompt redaction is configurable but has no rules when unconfigured. Classic MCP tool results and Agentic DeepAgents tool results follow different execution paths; the Agentic sandbox does not execute through `lightspeed-service/ols/src/tools/tools.py`. Existing user-facing Classic SSE and native Agentic source traces can expose raw tool results. The OLS-3939 Epic requests shared default-on tool-output protection, but a later Jira comment removes it from the OLS 2.0 requirement and proposes a spike. The [parent policy](../what/tool-output-redaction.md) is a planned full design, not shipped behavior.

## Decision

Use **one normative category/configuration and test contract** with separate implementations in the Classic service and Agentic sandbox. Each compiles the effective named-alternative tool matcher once per policy revision, substitutes once per reply and emits correlated metadata. Keep Classic's existing administrator-defined prompt filters separate; sharing matching code cannot silently change prompt defaults. Deliver sanitized user-facing tool results and explicit per-reply signals, including changing Classic's raw user-facing SSE behavior. Preserve full-fidelity raw source audit/trace evidence under [ADR 0026](0026-audit-logging-design.md); this is not an audit-redaction project.

## Alternatives

- **Shared importable package across both runtimes:** reduces implementation drift but adds a new versioned package and rollout dependency. Reject until conformance testing demonstrates a need.
- **Service-only interception at `tools.py`:** cannot cover Agentic DeepAgents tools. Reject.
- **One shared prompt/tool rule set:** would change the opt-in Classic prompt-filter behavior and risk benign Kubernetes false positives. Reject; tool output is default-on, prompt filters remain administrator-defined.
- **Metadata-only UI warning beside raw content:** leaks the very value being flagged. Reject; user-facing content must be sanitized as well.

## Consequences

- Coordinated operator delivery and the same conformance corpus are necessary to prevent category drift.
- Classic service and console SSE/history contracts must change; Agentic requires a typed per-reply UI handoff rather than guessing from pod logs.
- Admin regex complexity and policy changes need validation, safe failure handling, and performance checks.
- Raw audit/source evidence remains sensitive and governed by its separate retention/access controls. This decision does not claim complete PII/DLP protection or release timing.
