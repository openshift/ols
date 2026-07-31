# 0020: Agentic State Model

**Status:** Accepted
**Applies to:** lightspeed-agentic-operator, lightspeed-agentic-console

## Context

Storing phase as a separate status field creates drift risk — the phase label could disagree with the actual condition state. Result CRs (AnalysisResult, ExecutionResult, VerificationResult, EscalationResult) are the audit trail for each phase; immutability prevents tampering after the fact.

## Decision

AgenticRun phase is derived from `status.conditions` via a pure function `DerivePhase()`, never stored as a separate field. Result CRs are immutable once created and use OwnerReference for garbage collection.

## Alternatives Considered

- **Stored phase field** — rejected because of drift risk between phase and conditions, requiring coordination to keep in sync
- **Mutable result CRs with versioning** — rejected because it complicates the audit trail and makes it harder to prove results were not altered post-hoc
- **Results stored as AgenticRun status fields** — rejected because it bloats the main CR and makes lifecycle management harder

## Consequences

- Phase is always consistent with condition state; any consumer can recompute phase without the operator
- Console and operator use identical derivation logic via shared `DerivePhase` function
- Result CRs use OwnerReference for automatic garbage collection
- Immutable results provide a tamper-evident audit trail
