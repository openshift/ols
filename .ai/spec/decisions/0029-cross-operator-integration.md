# 0029: Cross-Operator Integration

**Status:** Accepted
**Applies to:** lightspeed-operator, lightspeed-agentic-operator

## Context

Two operators share one namespace but reconcile different API groups. The agentic operator had two separate paths that built sandbox pod specifications. The classic operator already owns operand images, shared sandbox configuration, and cross-component connection data.

## Decision

The classic operator deploys agentic operands such as the alerts adapter and agentic console plugin. The agentic operator does not deploy these operands.

Inter-operator communication uses the `lightspeed-agentic-configuration` ConfigMap. The classic operator writes a thin sandbox PodSpec and shared values to this ConfigMap.

The agentic operator reads the ConfigMap and adds values for each run. It uses one overlay path for bare pods and sandbox claims.

The agentic operator starts without the ConfigMap. An individual run fails with a controlled error when the ConfigMap is not available.

## Alternatives Considered

- **Agentic operator deploys its own operands.** Rejected because this choice duplicates image and operand lifecycle management.
- **Duplicate pod-spec construction.** Rejected because the bare-pod and sandbox-claim paths can produce different sandbox configuration.

## Consequences

- The agentic operator has one overlay path.
- The sandbox mode controls delivery after the operator builds the complete PodSpec.
- The classic operator owns the shared handoff values.
- An individual AgenticRun fails when the handoff ConfigMap is not available.
- The old self-contained pod-spec paths are not used.
- Both operators must run before an AgenticRun can start a sandbox.
