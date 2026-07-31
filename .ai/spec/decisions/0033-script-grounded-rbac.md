# 0033: Script-Grounded RBAC

**Status:** Accepted
**Applies to:** lightspeed-agentic-sandbox, lightspeed-agentic-operator

## Context

Abstract RBAC prediction is unreliable — the analysis LLM misses implicit sub-resources, intermediate reads, wait/status commands, and other operations its scripts will actually perform. Analysis and execution run as separate LLM sessions, so there is inherent divergence risk. Concrete scripts make RBAC derivation traceable and verifiable.

## Decision

The analysis agent produces concrete remediation scripts (ordered bash commands) and RBAC requirements are derived from those scripts, rather than abstractly predicting RBAC from a vague action description. Execution dry-runs mutations before applying.

## Alternatives Considered

- **Abstract action descriptions with independent RBAC prediction** — rejected because it causes 403 failures when execution discovers it needs permissions the analysis did not predict
- **Admin-specified RBAC per alert type** — rejected because it does not scale to novel alert types
- **Fixed RBAC for all runs** — rejected because it violates the least-privilege principle

## Consequences

- RBAC is verifiable against actual commands
- Reduced 403 failures during execution
- Dry-run catches errors before real mutations
- Scripts serve as human-readable documentation of what will happen
