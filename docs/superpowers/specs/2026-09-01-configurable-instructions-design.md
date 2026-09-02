# OLS-3491: Configurable System Instructions — Redesign

**Jira:** [OLS-3491](https://redhat.atlassian.net/browse/OLS-3491)  
**Date:** 2026-09-01  
**Status:** Redesign (supersedes prior OLS-3491 spec annotations)

## Problem

The agentic sandbox has no configurable instructions mechanism. Step instructions are either empty or hardcoded as Go templates in the operator. There is no way to provide different instructions for different use cases (alerts remediation, security audit, Jira triage) without operator redeployment.

The prior OLS-3491 design placed instructions on `OLSConfig.spec.agenticOLS.instructions` (classic operator CRD) with a 3-layer precedence chain (AgenticRun override > cluster config > built-in), create-time materialization via defaulting webhook, and handoff ConfigMap instruction keys. This was overly complex and introduced unnecessary cross-operator coupling — the classic operator does not execute instructions and just forwarded them.

## Solution: Instructions on Agent CR

Move per-step instructions to the `Agent` CR. The Agent already carries per-step timeouts and compute configuration (model, provider). Adding per-step instructions makes the Agent a complete "how to run this step" definition — compute + behavior.

### Agent CR Extension

```yaml
apiVersion: agentic.openshift.io/v1alpha1
kind: Agent
metadata:
  name: alerts-smart
spec:
  llmProvider:
    name: anthropic
  model: claude-4-sonnet
  timeouts:
    analysisSeconds: 600
    executionSeconds: 600
  instructions:
    analysis: |
      You are an analysis agent. Diagnose the problem...
    execution: |
      You are an execution agent. Execute the approved remediation...
    verification: |
      You are a verification agent. Verify that the issue is resolved...
    escalation: |
      Review the failed step results, diagnose why remediation did not succeed...
```

New `spec.instructions` struct on the Agent CR with optional per-step string fields:

| Field | Type | Required | MaxLength | Description |
|---|---|---|---|---|
| `spec.instructions` | `*AgentInstructions` | No | — | Per-step system instructions. When omitted, all steps use built-in defaults. |
| `spec.instructions.analysis` | `string` | No | 32768 | Analysis step system prompt. Replaces built-in when non-empty. |
| `spec.instructions.execution` | `string` | No | 32768 | Execution step system prompt. Replaces built-in when non-empty. |
| `spec.instructions.verification` | `string` | No | 32768 | Verification step system prompt. Replaces built-in when non-empty. |
| `spec.instructions.escalation` | `string` | No | 32768 | Escalation step system prompt. Replaces built-in when non-empty. |

### Precedence

Two layers: **Agent `spec.instructions.<step>`** (when non-empty) > **product built-in** (Go template).

### How It Works

1. AgenticRun step references an Agent: `spec.analysis.agent: "alerts-smart"`.
2. Operator resolves the Agent CR and reads `spec.instructions.<step>`.
3. If the Agent has instructions for that step, use them. If not (or Agent has no `instructions`), render the product built-in Go template.
4. Write the resolved instructions to the input ConfigMap `system-prompt` key.
5. Sandbox reads `/input/system-prompt` and uses it — unchanged.

### Backward Compatibility

- Existing agents (`default`, `smart`, `fast`) have no `instructions` field → built-in defaults. Zero behavioral change.
- Workflow-specific agents (`alerts-smart`, `security-audit-smart`) combine compute config + instructions for their domain.
- Adapters select the appropriate Agent when creating an AgenticRun.

### What's Removed (vs. prior OLS-3491 design)

| Removed | Why |
|---|---|
| `OLSConfig.spec.agenticOLS.instructions` | Classic operator overreach — instructions are an agentic concern |
| `AgenticRunStep.instructions` | Unnecessary — adapter picks the right Agent instead |
| Handoff ConfigMap `instructions-*` keys | No cross-operator instruction handoff needed |
| Create-time materialization / defaulting webhook | No per-run instruction state to freeze |
| 3-layer precedence chain | Simplified to 2 layers: Agent > built-in |

### Sandbox Impact

**None.** The sandbox is a pure executor. It reads `/input/system-prompt` and runs. It doesn't care where the instructions came from. The `[PLANNED: OLS-3491]` annotations in sandbox specs are removed — they were misplaced.

## Size Considerations

Current built-in templates range from 0.7 KB (escalation) to 6.4 KB (analysis). Custom instructions for a specific workflow are expected to be 2-10 KB per step. Four steps at 32 KB max each = 128 KB worst case, well within etcd's 1.5 MiB object limit.

## Changes by Repository

| Repository | Change |
|---|---|
| `lightspeed-agentic-operator` | Add `spec.instructions` to Agent CRD. Resolve instructions from Agent at sandbox setup time. Remove `AgenticRunStep.instructions` field and materialization. |
| `lightspeed-operator` | Remove `AgenticStepInstructions` from `spec.agenticOLS`. Remove `instructions-*` keys from handoff ConfigMap. |
| `lightspeed-agentic-sandbox` | No changes. Remove misplaced OLS-3491 annotations from specs. |

## Risk Assessment

**Risk Level 2 (Medium)** — CRD field additions on Agent (additive, non-breaking). Removes unused planned fields from AgenticRun and OLSConfig (no shipped implementation to deprecate).
