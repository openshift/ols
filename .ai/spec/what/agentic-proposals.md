# Agentic Proposals

Multi-phase AI workflows that diagnose and remediate cluster issues. An alert fires, the system analyzes it, proposes remediation options, and — with human approval — executes and verifies the fix.

## End-to-End Flow

### Phase 1: Trigger

1. The alerts-adapter polls OpenShift AlertManager for firing alerts on a configurable interval.
2. For each firing alert, the adapter computes a fingerprint (8-char prefix) and checks for an existing Proposal CR with a deterministic name derived from the fingerprint.
3. If no matching Proposal exists and the cooldown window has elapsed since the last Proposal for that fingerprint, the adapter creates a new `Proposal` CR in the alert's namespace with the alert metadata and a templated remediation request.
4. The adapter is create-only — it never updates or deletes Proposals after creation.

### Phase 2: Analysis

5. The agentic-operator detects the new Proposal CR and adds a finalizer.
6. The operator checks the cluster-scoped `ApprovalPolicy` (singleton named "cluster") for the analysis approval gate.
7. If approval is required, the operator waits for a `ProposalApproval` CR granting analysis. If automatic, it proceeds immediately.
8. The operator provisions a sandbox pod (bare-pod or sandbox-claim mode) using a derived `SandboxTemplate`.
9. The operator calls `POST /v1/agent/run` on the sandbox with the analysis request, output schema for remediation options, and context (target namespaces).
10. The sandbox executes the request using the configured LLM provider (Claude, Gemini, or OpenAI) and returns structured remediation options (diagnosis, proposed actions, RBAC requirements, verification plan).
11. The operator stores the result in an immutable `AnalysisResult` CR owned by the Proposal.
12. The analysis output includes an `actionRequired` boolean and a top-level `Diagnosis` (summary, confidence, rootCause). When `actionRequired` is false, the `Options` array may be empty (`minItems: 0`); the top-level `Diagnosis` captures the agent's explanation of why no remediation is needed.
13. When the operator stores an `AnalysisResult` with `actionRequired=false`, it sets the `Analyzed` condition to `True` with reason `NoActionRequired`. The Proposal auto-transitions to the `NoActionRequired` terminal phase, bypassing Proposed/Approval/Execution/Verification entirely.

### Phase 3: Approval

14. The agentic-console displays the Proposal in "Proposed" phase with the analysis results.
15. A human reviewer selects a remediation option, sets a max retry count, and creates a `ProposalApproval` CR for execution. **Only cluster-admin users may approve proposals** — see `agentic-security.md` for authorization rules and enforcement.
16. The reviewer can optionally provide revision feedback via `spec.revisionFeedback` on the Proposal. Revision feedback is also supported from the `NoActionRequired` terminal phase — patching `spec.revisionFeedback` resets conditions and re-runs analysis, same as the re-analysis pattern from other phases.

### Phase 4: Execution

17. The operator materializes RBAC (ServiceAccount, Role, RoleBinding) scoped to the approved option's requirements.
18. The operator calls the sandbox with the execution request, passing the approved option and RBAC context.
19. The sandbox agent executes the remediation actions.
20. The operator stores the result in an immutable `ExecutionResult` CR.

### Phase 5: Verification

21. If verification is configured, the operator checks the approval gate for verification.
22. The operator calls the sandbox with a verification request, passing the execution result.
23. If verification fails, the operator retries up to max attempts, including previous attempt results as context.
24. On success, the operator stores the result in a `VerificationResult` CR and the Proposal moves to Completed.
25. On exhausted retries, the Proposal may escalate.

### Phase 6: Escalation

26. If verification fails after all retries, the operator checks the approval gate for escalation.
27. The operator calls the sandbox with an escalation request to generate a human-readable summary.
28. The result is stored in an `EscalationResult` CR and the Proposal moves to Escalated.

### Cleanup

29. On terminal phases (Completed, Failed, Denied, Escalated, NoActionRequired) or Proposal deletion, the operator deletes materialized RBAC, releases sandbox pods/claims, and removes the finalizer.

## Integration Contracts

### CRDs — `agentic.openshift.io/v1alpha1`

| CRD | Scope | Owner | Purpose |
|---|---|---|---|
| `Proposal` | Namespace | alerts-adapter (creates), operator (reconciles) | Workflow state machine. Immutable spec, mutable revisionFeedback, status conditions. |
| `ProposalApproval` | Namespace | console (creates) | Approval decisions per stage, option selection, max attempts override. Owned by Proposal. |
| `ApprovalPolicy` | Cluster (singleton "cluster") | admin (creates) | Automatic/Manual gates per stage, max attempts, max concurrent proposals. |
| `Agent` | Cluster | admin (creates) | LLM provider selection and model name. |
| `LLMProvider` | Cluster | admin (creates) | Provider type, credentials secret, URL, region/project. |
| `AnalysisResult` | Namespace | operator (creates) | Immutable analysis output. Owned by Proposal. |
| `ExecutionResult` | Namespace | operator (creates) | Immutable execution output. Owned by Proposal. |
| `VerificationResult` | Namespace | operator (creates) | Immutable verification output. Owned by Proposal. |
| `EscalationResult` | Namespace | operator (creates) | Immutable escalation output. Owned by Proposal. |

### HTTP — Sandbox Run API

| Endpoint | Method | Request | Response |
|---|---|---|---|
| `/v1/agent/run` | POST | `RunRequest`: query, systemPrompt, outputSchema, context, timeout_ms | `RunResponse`: success, summary, plus fields from agent output JSON |

Context envelope varies by phase:
- Analysis: target namespaces
- Execution: approved option (diagnosis, actions, RBAC), target namespaces
- Verification: execution result, previous attempts, attempt metadata
- Escalation: full workflow history

### Shared Data Formats

- **Alert fingerprint**: 8-char prefix for deterministic Proposal naming and deduplication
- **AnalysisResult schema**: includes `actionRequired` (bool) and a top-level `Diagnosis` (summary, confidence, rootCause). When `actionRequired` is false, `Options` may be empty. Each `RemediationOption` contains diagnosis, proposed action, RBAC requirements, verification plan.
- **Phase derivation**: from status.conditions with precedence EmergencyStopped > Escalated > Denied > Verified > Executed > Analyzed (with `NoActionRequired` reason → `NoActionRequired` phase, otherwise → Proposed)
- **LLM config env vars**: `LIGHTSPEED_PROVIDER`, `LIGHTSPEED_MODEL`, `LIGHTSPEED_PROVIDER_URL`, and region/project/api-version variants

## Repo Ownership

| Repo | Owns |
|---|---|
| **lightspeed-agentic-alerts-adapter** | Alert polling, fingerprint-based dedup, cooldown enforcement, Proposal CR creation (create-only) |
| **lightspeed-agentic-operator** | Proposal reconciliation, approval gate enforcement, sandbox provisioning, RBAC materialization, agent HTTP calls, result CR creation, phase derivation, finalizer cleanup |
| **lightspeed-agentic-sandbox** | `/v1/agent/run` endpoint, LLM provider abstraction (Claude/Gemini/OpenAI adapters), structured output handling, tool execution, event logging |
| **lightspeed-agentic-console** | Proposal list/detail UI, phase display (mirrors operator's phase derivation), approval decision UI, option selection, revision feedback, escalation display |

## Planned Changes

| Ticket | Summary |
|---|---|
| OLS-2913 | Populate `status.steps.<step>.conditions` consistently for UI/CLI |
| OLS-2894 | Per-proposal approval overrides and namespace-scoped `ApprovalPolicy` |
| OLS-2957 | Sandbox template management UX and CRD ergonomics |
| OLS-3038 | TLS verification and network policy for agent traffic |
| OLS-3033 | Operator-passed `allowedTools` and `llm` aligned with `ProviderQueryOptions` |
| OLS-3268 | Analysis can signal `actionRequired=false` to auto-complete with `NoActionRequired` phase |
