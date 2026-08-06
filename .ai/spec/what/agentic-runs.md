# Agentic Runs

Multi-phase AI workflows that diagnose and remediate cluster issues. An alert fires, the system analyzes it, proposes remediation options, and — with human approval — executes and verifies the fix.

## End-to-End Flow

### Phase 1: Trigger

1. The alerts-adapter polls OpenShift AlertManager for firing alerts on a configurable interval.
2. For each firing alert, the adapter computes a fingerprint (8-char prefix) and checks for an existing AgenticRun CR with a deterministic name derived from the fingerprint.
3. If no matching AgenticRun exists and the cooldown window has elapsed since the last AgenticRun for that fingerprint, the adapter creates a new `AgenticRun` CR in the alert's namespace with the alert metadata and a templated remediation request.
4. The adapter is create-only — it never updates or deletes AgenticRuns after creation.

### Phase 2: Analysis

5. The agentic-operator detects the new AgenticRun CR and adds a finalizer.
6. The operator checks the cluster-scoped `ApprovalPolicy` (singleton named "cluster") for the analysis approval gate.
7. If approval is required, the operator waits for an `AgenticRunApproval` CR granting analysis. If automatic, it proceeds immediately.
8. The operator provisions a sandbox pod (bare-pod or sandbox-claim mode) using a derived `SandboxTemplate`.
9. The operator calls `POST /v1/agent/run` on the sandbox with the analysis request, output schema for remediation options, and context (target namespaces).
10. The sandbox executes the request using the configured LLM provider (Claude, Gemini, or OpenAI) and returns structured remediation options. Each option contains a concrete remediation script (ordered bash commands using kubectl/oc) and RBAC requirements derived from those commands. The analysis prompt instructs the agent to inspect cluster state with kubectl/oc before diagnosing, and to derive RBAC by tracing every command in its script.
11. The operator stores the result in an immutable `AnalysisResult` CR owned by the AgenticRun.
12. The analysis output includes an `actionRequired` boolean and a top-level `Diagnosis` (summary, confidence, rootCause). When `actionRequired` is false, the `Options` array may be empty (`minItems: 0`); the top-level `Diagnosis` captures the agent's explanation of why no remediation is needed.
13. When the operator stores an `AnalysisResult` with `actionRequired=false`, it sets the `Analyzed` condition to `True` with reason `NoActionRequired`. The AgenticRun auto-transitions to the `NoActionRequired` terminal phase, bypassing Proposed/Approval/Execution/Verification entirely.

### Phase 3: Approval

14. The agentic-console displays the AgenticRun in "Proposed" phase with the analysis results.
15. A human reviewer selects a remediation option and creates an `AgenticRunApproval` CR for execution. **Only cluster-admin users may approve runs** — see `agentic-security.md` for authorization rules and enforcement.
16. The reviewer can optionally provide revision feedback via `spec.revisionFeedback` on the AgenticRun. Revision feedback is also supported from the `NoActionRequired` terminal phase — patching `spec.revisionFeedback` resets conditions and re-runs analysis, same as the re-analysis pattern from other phases.

### Phase 4: Execution

17. The operator materializes RBAC (ServiceAccount, Role, RoleBinding) scoped to the approved option's requirements.
18. The operator calls the sandbox with the execution request, passing the approved option and RBAC context. The execution prompt instructs the agent to follow the concrete bash script exactly and to dry-run mutation commands with `--dry-run=server` before executing.
19. The sandbox agent executes the remediation actions by running the approved bash commands in order.
20. The operator stores the result in an immutable `ExecutionResult` CR.

### Phase 5: Verification

21. If verification is configured, the operator checks the approval gate for verification.
22. The operator calls the sandbox with a verification request, passing the execution result. The verification prompt instructs the agent to retry convergence-dependent checks (alerts, metrics, pod readiness) with appropriate wait intervals before reporting failure.
23. On success, the operator stores the result in a `VerificationResult` CR and the AgenticRun moves to Completed.
24. On failure, the operator stores the result in a `VerificationResult` CR and moves to the Escalation phase.

### Phase 6: Escalation

25. If verification fails, the operator checks the approval gate for escalation.
26. The operator calls the sandbox with an escalation request to generate a human-readable summary.
27. The result is stored in an `EscalationResult` CR and the AgenticRun moves to Escalated.

### Cleanup

28. On terminal phases (Completed, Failed, Denied, Escalated, NoActionRequired) or AgenticRun deletion, the operator deletes materialized RBAC, releases sandbox pods/claims, and removes the finalizer.

## Integration Contracts

### CRDs — `agentic.openshift.io/v1alpha1`

| CRD | Scope | Owner | Purpose |
|---|---|---|---|
| `AgenticRun` | Namespace | alerts-adapter (creates), operator (reconciles) | Workflow state machine. Immutable spec, mutable revisionFeedback, status conditions. |
| `AgenticRunApproval` | Namespace | console (creates) | Approval decisions per stage, option selection. Owned by AgenticRun. |
| `ApprovalPolicy` | Cluster (singleton "cluster") | admin (creates) | Automatic/Manual gates per stage, max concurrent runs. |
| `Agent` | Cluster | admin (creates) | LLM provider selection and model name. |
| `LLMProvider` | Cluster | admin (creates) | Provider type, credentials secret, URL, region/project. |
| `AnalysisResult` | Namespace | operator (creates) | Immutable analysis output. Owned by AgenticRun. |
| `ExecutionResult` | Namespace | operator (creates) | Immutable execution output. Owned by AgenticRun. |
| `VerificationResult` | Namespace | operator (creates) | Immutable verification output. Owned by AgenticRun. |
| `EscalationResult` | Namespace | operator (creates) | Immutable escalation output. Owned by AgenticRun. |

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

- **Alert fingerprint**: 8-char prefix for deterministic AgenticRun naming and deduplication
- **AnalysisResult schema**: includes `actionRequired` (bool) and a top-level `Diagnosis` (summary, confidence, rootCause). When `actionRequired` is false, `Options` may be empty. Each `RemediationOption` contains diagnosis, remediation plan (`plan` field), RBAC requirements, verification plan. The `RemediationPlan` struct holds description, actions, risk, and reversibility. Each action includes `command` (exact bash command, required, 1-4096 chars), `type` (phase category: pre-check, mutation, wait, post-check), and `description`. RBAC requirements are derived from the script commands, with `get`/`list`/`watch` as minimum read verbs for every resource.
- **Phase derivation**: from status.conditions with precedence EmergencyStopped > Escalated > Denied > Verified > Executed > Analyzed (with `NoActionRequired` reason → `NoActionRequired` phase, otherwise → Proposed)
- **LLM config env vars**: `LIGHTSPEED_PROVIDER`, `LIGHTSPEED_MODEL`, `LIGHTSPEED_PROVIDER_URL`, and region/project/api-version variants

## Repo Ownership

| Repo | Owns |
|---|---|
| **lightspeed-agentic-alerts-adapter** | Alert polling, fingerprint-based dedup, cooldown enforcement, AgenticRun CR creation (create-only) |
| **lightspeed-agentic-operator** | AgenticRun reconciliation, approval gate enforcement, sandbox provisioning, RBAC materialization, agent HTTP calls, result CR creation, phase derivation, finalizer cleanup |
| **lightspeed-agentic-sandbox** | `/v1/agent/run` endpoint, LLM provider abstraction (Claude/Gemini/OpenAI adapters), structured output handling, tool execution, event logging |
| **lightspeed-agentic-console** | AgenticRun list/detail UI, phase display (mirrors operator's phase derivation), approval decision UI, option selection, revision feedback, escalation display |

## Planned Changes

| Ticket | Summary |
|---|---|
| OLS-2913 | Populate `status.steps.<step>.conditions` consistently for UI/CLI |
| OLS-2894 | Per-run approval overrides and namespace-scoped `ApprovalPolicy` |
| OLS-2957 | Sandbox template management UX and CRD ergonomics |
| OLS-3038 | TLS verification and network policy for agent traffic |
| OLS-3033 | Operator-passed `allowedTools` and `llm` aligned with `ProviderQueryOptions` |
| OLS-3268 | Analysis can signal `actionRequired=false` to auto-complete with `NoActionRequired` phase |
| OLS-3295 | Rename `Proposal` → `AgenticRun`, `ProposalApproval` → `AgenticRunApproval`, `ProposalResult` → `RemediationPlan` across CRDs, API, CLI, console, and docs |
| OLS-3441 | Script-grounded RBAC: analysis produces concrete bash scripts and derives RBAC from commands; execution dry-runs mutations before applying |
