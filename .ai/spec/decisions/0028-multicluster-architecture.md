# 0028: Multicluster Architecture

**Status:** Accepted
**Applies to:** lightspeed-hub, lightspeed-hub-ui

## Context

Multicluster operations need a central control plane for fleet-wide agentic operations. Spoke clusters may be edge devices with limited resources, ruling out per-spoke agent deployments as the default. Different user populations (Red Hat SREs, customers with MCE, customers with manual credential management) need different credential sources.

## Decision

The multicluster hub is a thin routing and credential management layer in front of the existing agentic stack, not a reimplementation of the agentic engine. Each spoke cluster gets its own `SpokeCluster` CR (not entries in a centralized list). Credential management uses a pluggable interface with three implementations: SecretCredentialSource (stored K8s Secrets), BackplaneCredentialSource (Red Hat SREs), and MCECredentialSource (MCE cluster-proxy). Zero spoke footprint for the default path. ACM is not required; MCE is acceptable but not required.

## Alternatives Considered

- **Reimplemented agentic engine on hub** — rejected because of duplication; the existing engine already handles "what to do"
- **Centralized spoke list** — rejected because one broken spoke affects all others, with no per-spoke status/conditions or independent reconciliation
- **ACM as hard dependency** — rejected because not all customers run ACM
- **Single credential source** — rejected because different user populations need different mechanisms

## Consequences

- Hub adds "which cluster" dimension; existing engine handles "what to do"
- Per-spoke CRs enable independent reconciliation, per-spoke status, owner references for auto-GC, and per-spoke RBAC
- Zero spoke footprint keeps edge deployment simple
- Pluggable credentials accommodate all user segments
