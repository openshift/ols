# Agentic Runs

Multi-phase AI workflows that diagnose and remediate cluster issues. An alert fires, the system analyzes it, proposes remediation options, and — with human approval — executes and verifies the fix.

## End-to-End Flow

### Phase 1: Trigger

An external event source creates an `AgenticRun` CR to initiate a workflow. Any authorized adapter, controller, CLI, or API client can create AgenticRuns — the operator reconciles them regardless of origin. Adapters are create-only — they never update or delete AgenticRuns after creation.

**Example — alerts-adapter (AlertManager events):**

1. The alerts-adapter polls OpenShift AlertManager for firing alerts on a configurable interval.
2. For each firing alert, the adapter computes a fingerprint (8-char prefix) and checks for an existing AgenticRun CR with a deterministic name derived from the fingerprint.
3. If no matching AgenticRun exists and the cooldown window has elapsed since the last AgenticRun for that fingerprint, the adapter creates a new `AgenticRun` CR in the alert's namespace with the alert metadata and a templated remediation request.

**Example — event-adapter (team-harness prototype; Jira + GitHub domains):**

4. The event adapter uses one image with a separate Deployment + ConfigMap per domain (`source: jira` or `source: github`). See `lightspeed-team-harness/.ai/spec/what/event-adapter.md`.
5. The Jira domain polls for issues in New and creates batch triage AgenticRuns (analysis + human-approved execution).
6. The GitHub PR-review domain polls allowlisted repos and creates one AgenticRun per `repo + pull + headSha` after CI is terminal (all checks except Tide).

**Analysis-only writeback:** Some domains (e.g. GitHub PR review) perform external side effects during analysis (such as posting a Pull Request Review with event `COMMENT`) and return `actionRequired=false`, so the run terminates in `NoActionRequired` without an execution phase. This intentionally bypasses the propose → approve → execute gate for that domain and must be documented on the adapter; it does not change the CRD.

### Phase 2: Analysis

5. The agentic-operator detects the new AgenticRun CR and adds a finalizer.
6. The operator checks the cluster-scoped `ApprovalPolicy` (singleton named "cluster") for the analysis approval gate.
7. If approval is required, the operator waits for an `AgenticRunApproval` CR granting analysis. If automatic, it proceeds immediately.
8. The operator creates an input ConfigMap with the analysis **query** (request input), **system instructions**, output schema, context, and a pre-filled Result CR template. It then provisions a sandbox pod (bare-pod or sandbox-claim mode) with the ConfigMap mounted at `/input/`. [OLS-3066] [PLANNED: OLS-3491] System instructions are resolved from the step's `Agent` CR (`Agent.spec.instructions.analysis` when non-empty, else product built-in) and passed on the system channel via the `system-prompt` ConfigMap key; `query` carries `spec.request` only (plus existing revision suffix). See agentic-operator `what/crd-api.md` and `what/sandbox-execution.md`.
9. The sandbox pod runs the agent autonomously (batch execution — no HTTP). The agent executes using the configured LLM provider (Anthropic, Gemini, or OpenAI) and produces structured remediation options. Each option contains a concrete remediation script (ordered bash commands using kubectl/oc) and RBAC requirements derived from those commands. Analysis **instructions** require inspecting cluster state before diagnosing and deriving RBAC by tracing every command in the script. [OLS-3066]
10. The sandbox creates the `AnalysisResult` CR via `oc create` + `oc patch --subresource=status`, merging the agent output into the operator-provided template. The operator watches for this CR via `Owns()` and is automatically enqueued when it appears. [OLS-3066]
11. The operator reads the `AnalysisResult` CR and updates the AgenticRun conditions accordingly.
12. The analysis output includes an `actionRequired` boolean and a top-level `Diagnosis` (summary, rootCause). When `actionRequired` is false, the `Options` array may be empty (`minItems: 0`); the top-level `Diagnosis` captures the agent's explanation of why no remediation is needed.
13. When the operator stores an `AnalysisResult` with `actionRequired=false`, it sets the `Analyzed` condition to `True` with reason `NoActionRequired`. The AgenticRun auto-transitions to the `NoActionRequired` terminal phase, bypassing Proposed/Approval/Execution/Verification entirely.

### Phase 3: Approval

14. The agentic-console displays the AgenticRun in "Proposed" phase with the analysis results.
15. A human reviewer selects a remediation option and creates an `AgenticRunApproval` CR for execution. **Only cluster-admin users may approve runs** — see `agentic-security.md` for authorization rules and enforcement.
16. The reviewer can optionally provide revision feedback via `spec.revisionFeedback` on the AgenticRun. Revision feedback is also supported from the `NoActionRequired` terminal phase — patching `spec.revisionFeedback` resets conditions and re-runs analysis, same as the re-analysis pattern from other phases.

### Phase 4: Execution

17. The operator materializes RBAC (ServiceAccount, Role, RoleBinding) scoped to the approved option's requirements. When a remediation step is an MCP tool call rather than an `oc`/`kubectl` command, its RBAC is resolved via the `_meta` contract → oc-IR fallback → fail-closed order in `mcp-tool-rbac.md` (OLS-3680), with a hard deny ceiling applied before materialization.
18. The operator creates an input ConfigMap with the execution **query** (approved option JSON) and **system instructions**, then provisions a sandbox pod. [OLS-3066] [PLANNED: OLS-3491] Execution instructions (follow script exactly; dry-run mutations) are resolved from the execution step's Agent CR and passed on the system channel.
19. The sandbox agent executes the remediation actions by running the approved bash commands in order.
20. The sandbox creates the `ExecutionResult` CR via `oc`, and the operator processes it upon watch notification. [OLS-3066]

### Phase 5: Verification

21. If verification is configured, the operator checks the approval gate for verification.
22. The operator calls the sandbox with a verification **query** (option + execution output) and verification **system instructions** resolved from the verification step's Agent CR [PLANNED: OLS-3491]. The verification instructions require retrying convergence-dependent checks (alerts, metrics, pod readiness) with appropriate wait intervals before reporting failure.
23. On success, the operator stores the result in a `VerificationResult` CR and the AgenticRun moves to Completed.
24. On failure, the operator stores the result in a `VerificationResult` CR and moves to the Escalation phase.

### Phase 6: Escalation

25. If verification fails, the operator checks the approval gate for escalation.
26. The operator calls the sandbox with an escalation **query** payload and escalation **system instructions** resolved from the escalation step's Agent CR (`Agent.spec.instructions.escalation` when non-empty, else built-in). [PLANNED: OLS-3491]
27. The result is stored in an `EscalationResult` CR and the AgenticRun moves to Escalated.

### Cleanup

28. On terminal phases (Completed, Failed, Denied, Escalated, NoActionRequired) or AgenticRun deletion, the operator deletes materialized RBAC, releases sandbox pods/claims, and removes the finalizer.

## Integration Contracts

### CRDs — `agentic.openshift.io/v1alpha1`

| CRD | Scope | Owner | Purpose |
|---|---|---|---|
| `AgenticRun` | Namespace | external adapters/clients (creates), operator (reconciles) | Workflow state machine. Immutable spec, mutable revisionFeedback, status conditions. |
| `AgenticRunApproval` | Namespace | console (creates) | Approval decisions per stage, option selection, max attempts override. Owned by AgenticRun. |
| `ApprovalPolicy` | Cluster (singleton "cluster") | admin (creates) | Automatic/Manual gates per stage, max attempts, max concurrent runs. |
| `Agent` | Cluster | admin (creates) | LLM provider, model, per-step agent execution budgets, and maximum agent turns. |
| `LLMProvider` | Cluster | admin (creates) | Provider type, credentials secret, URL, region/project. |
| `AnalysisResult` | Namespace | sandbox (creates via `oc`), operator (reads) [OLS-3066] | Immutable analysis output. Owned by AgenticRun. |
| `ExecutionResult` | Namespace | sandbox (creates via `oc`), operator (reads) [OLS-3066] | Immutable execution output. Owned by AgenticRun. |
| `VerificationResult` | Namespace | sandbox (creates via `oc`), operator (reads) [OLS-3066] | Immutable verification output. Owned by AgenticRun. |
| `EscalationResult` | Namespace | sandbox (creates via `oc`), operator (reads) [OLS-3066] | Immutable escalation output. Owned by AgenticRun. |

### [OLS-3066] Batch Sandbox I/O (replaces HTTP)

The operator and sandbox communicate via Kubernetes objects, not HTTP:

| Direction | Mechanism | Content |
|---|---|---|
| Operator → Sandbox (input) | ConfigMap volume mount at `/input/` | `query` (rendered prompt), `output-schema` (JSON schema), `context` (targetNamespaces, previousAttempts, approvedOption, executionResult), `result-template` (pre-filled Result CR) |
| Sandbox → Operator (output) | Result CR created via `oc create` + `oc patch --subresource=status` | Same Result CR status fields as before (options, diagnosis, actionsTaken, checks, conditions, failureReason) |
| Sandbox → Operator (errors) | `/dev/termination-log` (sandbox failures) or Result CR with `failureReason` (agent failures) | Error message string |

Context envelope in the `context` ConfigMap key varies by phase:
- Analysis: target namespaces
- Execution: approved option (diagnosis, actions, RBAC), target namespaces
- Verification: execution result, previous attempts, attempt metadata
- Escalation: full workflow history

### [PLANNED: OLS-3743] Layered Step Timeouts

Each workflow step has one administrator-configured agent execution budget on the selected `Agent`, enforced by two layers. The sandbox applies the effective budget cooperatively to the complete agent invocation and reports `AgentTimeout` through the Result CR. The operator applies a five-minute sandbox startup deadline and a hard running deadline equal to the agent budget plus one minute. Operator enforcement cleans up a sandbox that cannot cancel or publish a result. This replaces OLS-3066's original single ten-minute deadline measured from Pod creation.

Timeout fields and defaults are: analysis 600 seconds, execution 600 seconds, verification 1800 seconds, and escalation 600 seconds. The operator resolves omitted fields and sends `LIGHTSPEED_AGENT_TIMEOUT_SECONDS`; the sandbox does not own separate defaults. `chatSeconds` is removed because providers have no consistent per-turn timeout.

`Agent.spec.maxTurns` remains independent from wall-clock timeout. The operator defaults it to 200 and sends `LIGHTSPEED_AGENT_MAX_TURNS`; the sandbox maps it to each provider SDK's iteration limit. Timeout failures never retry automatically. See `decisions/0039-layered-agent-timeouts.md` for deadline clocks, status reasons, cleanup, and alternatives.

### Shared Data Formats

- **Alert fingerprint**: 8-char prefix for deterministic AgenticRun naming and deduplication
- **AnalysisResult schema**: includes `actionRequired` (bool) and a top-level `Diagnosis` (summary, rootCause). When `actionRequired` is false, `Options` may be empty. Each `RemediationOption` contains diagnosis, remediation plan (`plan` field), RBAC requirements, verification plan. The `RemediationPlan` struct holds description, actions, and reversibility. Each action includes `command` (exact bash command, required, 1-4096 chars), `type` (phase category: pre-check, mutation, wait, post-check), and `description`. RBAC requirements are derived from the script commands, with `get`/`list`/`watch` as minimum read verbs for every resource.
- **Phase derivation**: from status.conditions with precedence EmergencyStopped > Escalated > Denied > Verified > Executed > Analyzed (with `NoActionRequired` reason → `NoActionRequired` phase, otherwise → Proposed)
- **LLM config env vars**: `LIGHTSPEED_PROVIDER`, `LIGHTSPEED_MODEL`, `LIGHTSPEED_PROVIDER_URL`, and region/project/api-version variants
- **Agent execution limits** [PLANNED: OLS-3743]: `LIGHTSPEED_AGENT_TIMEOUT_SECONDS` and `LIGHTSPEED_AGENT_MAX_TURNS`, always resolved and set by the agentic operator

## Repo Ownership

| Repo | Owns |
|---|---|
| **lightspeed-agentic-alerts-adapter** | Alert polling, fingerprint-based dedup, cooldown enforcement, AgenticRun CR creation (create-only) |
| **lightspeed-agentic-operator** | AgenticRun reconciliation, approval gate enforcement, sandbox provisioning (ConfigMap input + pod creation), RBAC materialization, Result CR processing (reads CRs created by sandbox), phase derivation, finalizer cleanup [OLS-3066] |
| **lightspeed-agentic-sandbox** | Batch agent execution (reads `/input/`, runs LLM, creates Result CR via `oc`), LLM provider abstraction (DeepAgents/Anthropic, Gemini, OpenAI adapters), structured output handling, tool execution, event logging [OLS-3066] |
| **lightspeed-agentic-console** | AgenticRun list/detail UI, phase display (mirrors operator's phase derivation), approval decision UI, option selection, revision feedback, escalation display |

## Planned Changes

| Ticket | Summary |
|---|---|
| OLS-3066 | Decouple reconcile latency: batch sandbox model, ConfigMap input, Result CR output via `oc`, watch-driven async, per-step timeout, ≤30s reconcile SLO. Subsumes OLS-2913 step-conditions. |
| OLS-3743 | Wire Agent execution budgets and maximum turns into the batch sandbox; enforce layered agent and sandbox lifecycle deadlines. |
| OLS-2894 | Per-run approval overrides and namespace-scoped `ApprovalPolicy` |
| OLS-2957 | Sandbox template management UX and CRD ergonomics |
| ~~OLS-3038~~ | ~~TLS verification and network policy for agent traffic~~ No longer applicable — sandbox pods have no HTTP server (OLS-3066) |
| OLS-3033 | Operator-passed `allowedTools` and `llm` aligned with `ProviderQueryOptions` |
| ~~OLS-3268~~ | ~~Analysis can signal `actionRequired=false` to auto-complete with `NoActionRequired` phase~~ [DONE: OLS-3268] |
| ~~OLS-3295~~ | ~~Rename `Proposal` → `AgenticRun`, `ProposalApproval` → `AgenticRunApproval`, `ProposalResult` → `RemediationPlan` across CRDs, API, CLI, console, and docs~~ [DONE: OLS-3295] |
| OLS-3441 | Script-grounded RBAC: analysis produces concrete bash scripts and derives RBAC from commands; execution dry-runs mutations before applying |
| OLS-3680 | MCP tool RBAC resolution: derive execution RBAC for MCP tool-call steps via server-published `_meta` (operator-managed servers) → oc-IR fallback → fail-closed, with a hard deny ceiling. See `mcp-tool-rbac.md`. |
| OLS-3657 | Event adapter: Jira-triggered AgenticRuns for automated bug triage (prototype in lightspeed-team-harness) |
