# 0024: Three-Layer Product Architecture

**Status:** Accepted
**Applies to:** all repos

## Context

OpenShift Lightspeed serves three distinct value propositions — Q&A assistance, autonomous cluster operations, and fleet management — each with different maturity levels and risk profiles. Agentic operations take real cluster actions requiring approval gates, while classic Q&A is read-only. Multicluster management introduces its own CRDs, UI, and deployment topology. Bundling these into a single product would force a single safety model and release cadence on fundamentally different capabilities.

## Decision

The product is split into three layers: Classic OLS (Q&A assistant), Agentic OLS (autonomous cluster operations), and Multicluster OLS (fleet management). Each layer has its own operator, console plugin, and backend as separate component sets.

## Alternatives Considered

- **Single unified product** — rejected because different risk profiles need different safety models; agentic actions require approval gates that would add unnecessary complexity to the read-only Q&A path.
- **Two layers with multicluster as a feature of agentic** — rejected because fleet management has distinct CRDs, UI, and deployment topology that don't fit within the agentic operator's scope.

## Consequences

- Independent release cadence per layer allows each to mature at its own pace
- Clear safety boundaries: agentic has approval gates, classic doesn't need them
- Multicluster can develop without blocking classic or agentic GA
- Requires cross-layer integration testing to ensure layers compose correctly
