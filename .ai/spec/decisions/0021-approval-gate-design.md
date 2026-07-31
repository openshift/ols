# 0021: Approval Gate Design

**Status:** Accepted
**Applies to:** lightspeed-agentic-operator, lightspeed-agentic-console

## Context

AI-proposed cluster remediations can be destructive. The approval gate is the primary safety mechanism. Identity must be API-server-verified to prevent spoofing. A binary cluster-admin gate is chosen for simplicity in the first release — restricting approvers to cluster-admin prevents privilege escalation since an agent requesting cluster-admin-level RBAC via approval would represent the worst-case escalation path.

## Decision

Agentic run approval uses a dual model: `ApprovalPolicy` (cluster-scoped singleton) defines default Automatic/Manual gates per phase, while `AgenticRunApproval` (per-run CR) carries individual user decisions. Only `system:cluster-admins` may approve, enforced by Kubernetes RBAC on the `agentic-run-approver` ClusterRole. A mutating admission webhook injects the authenticated user identity from the API server's admission review into the approval CR, not from client-submitted fields.

## Alternatives Considered

- **Namespace-scoped approval delegation** — rejected for first release; planned but deferred
- **ValidatingAdmissionWebhook with SubjectAccessReview** — rejected because Kubernetes RBAC is simpler and more standard
- **Console-submitted identity** — rejected because it can be spoofed; admission review userInfo is authoritative
- **Role-based tiered approval** — rejected because of added complexity without first-release need

## Consequences

- Separation of cluster-wide policy from per-run user decisions
- A step is approved if policy says Automatic OR approval has a non-denied entry
- Webhook is fail-closed (API server rejects PATCH if webhook unavailable), which is correct for the compliance-critical path
- Approval identity in the audit trail is API-server-verified
- Future work can add namespace-scoped delegation
