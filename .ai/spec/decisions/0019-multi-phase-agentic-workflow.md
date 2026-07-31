# 0019: Multi-Phase Agentic Workflow

**Status:** Accepted
**Applies to:** lightspeed-agentic-operator, lightspeed-agentic-sandbox, lightspeed-agentic-console, lightspeed-agentic-alerts-adapter

## Context

AI-driven cluster operations are safety-critical — a wrong remediation can cause outages. The system needs separation between "understanding the problem" (analysis), "deciding to act" (approval), "taking action" (execution), and "confirming it worked" (verification). Human approval is mandatory between analysis and execution.

## Decision

Agentic workflows follow a six-phase lifecycle: Trigger, Analysis, Approval, Execution, Verification, and Escalation. Each phase has defined trust levels, RBAC requirements, and failure modes. Analysis can short-circuit to a NoActionRequired terminal phase when no remediation is needed.

## Alternatives Considered

- **Two-phase analyze-then-execute** — rejected because there is no verification of results and no safety gate between analysis and execution
- **Three-phase without escalation** — rejected because failed verifications need an escalation path for problems beyond AI capability
- **Fully autonomous execution** — rejected because unacceptable risk for cluster-modifying operations

## Consequences

- Clear safety boundaries between phases with human-in-the-loop at the approval gate
- Verification catches failed remediations before they are considered complete
- Escalation provides a path for problems beyond AI capability
- Each phase has independent observability via per-phase OTel traces
