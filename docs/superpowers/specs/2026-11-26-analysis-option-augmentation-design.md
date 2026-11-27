# Analysis Option Augmentation Framework

**Jira**: OLS-4941 — Post-mutation read commands fail for resources outside the operator's reader RBAC
**Date**: 2026-11-26

## Problem

The analysis prompt template tells the agent that the execution and verification environments have read access to all resources. This is only true for resources covered by the pre-existing reader ClusterRoleBindings mirrored onto the per-step service account (`rbac.go: discoverReaderBindings`). Resources without a matching role binding for the lightspeed-operator service account — for example `clusterextensions.olm.operatorframework.io` — are not covered by the auto-generated read RBAC in the AnalysisResult. Post-mutation read commands in remediation plans (`oc wait`, `oc get`) then fail with 403 at execution or verification time.

Today there is no place to fix this: the AnalysisResult is created and completed by the sandbox, treated as immutable by the operator, and consumers (approval UI, RBAC materialization) read it as-published.

## Root Cause

Read access at execution time depends on cluster state (which reader ClusterRoleBindings exist) that the analysis agent cannot know and the sandbox does not check. The gap between what the prompt promises the agent and what the operator actually grants is invisible until a plan command fails mid-execution.

## Solution: Operator-Side Pre-Approval Augmentation

A general framework in the operator that applies registered **augmentations** to remediation options on an AnalysisResult after the sandbox publishes it and before the run is marked `Analyzed`. Each augmentation pairs predicates (prerequisites evaluated per option) with an idempotent transform.

The first augmentation closes the clusterextensions gap: any option whose remediation plan runs a read command (`get`/`wait`/`describe`) against `clusterextensions.olm.operatorframework.io` gains a cluster-scoped read RBAC rule for that resource, if not already present.

Design constraints, in order:

1. **Approval visibility** — the approval UI, audit events, and RBAC materialization only ever see augmented options. There is no window where a user approves a plan whose RBAC differs from what execution receives.
2. **Auditability** — applied augmentations are recorded on the AnalysisResult itself.
3. **Bounded failure** — transient augmentation failures retry via reconcile; permanent failures fail the analysis step promptly with a diagnosable reason.
4. **No state-machine change** — run phases, `DerivePhase`, console conditions, and termination handling are untouched.

## Changes

### 1. Augmentation Framework

**File**: `lightspeed-agentic-operator/controller/agenticrun/augment_option.go`

```go
// optionPredicate is a prerequisite for applying an optionTransform.
type optionPredicate func(*agenticv1alpha1.RemediationOption) bool

// optionTransform mutates an option and reports whether anything changed.
// Transforms must be idempotent.
type optionTransform func(*agenticv1alpha1.RemediationOption) (bool, error)

// optionAugmentation groups an optionTransform with its prerequisites.
type optionAugmentation struct {
    name       string            // stable identifier, recorded on the CR
    predicates []optionPredicate // ALL must match
    transform  optionTransform
}

var preApprovalAugmentations = []optionAugmentation{...}
```

**Engine** (`AgenticRunReconciler.augmentOptions`):

- Re-reads the AnalysisResult through the uncached `APIReader` (the sandbox created the CR moments ago; the cached client may lag).
- For each option, checks every augmentation's predicates; on a full match, applies the transform to that option.
- Patches status with `MergeFromWithOptimisticLock`; on conflict, re-reads and re-applies (safe because transforms are idempotent), up to 5 attempts.
- Sets the `Augmented` condition (see §3) **in the same status patch** as the option mutations, so the record can never diverge from the mutation.
- Returns without patching when no transform changed anything.

**Extensibility**: built-in Go steps. New augmentations are added by appending to `preApprovalAugmentations` in a PR; no configuration surface, no CRD changes for the framework itself.

### 2. Hook Point

**File**: `lightspeed-agentic-operator/controller/agenticrun/pod_handler.go` (`completeStep`, analysis branch)

Ordering within the analysis branch:

1. `validateResultCR` requires `Completed=True` (existing, unchanged).
2. If `ActionRequired=True`: run `augmentOptions(ctx, ar, preApprovalAugmentations)`.
   - **Transient failure** (conflict retry exhausted, API errors): return the error, leave the step in progress — standard reconcile backoff retries.
   - **Permanent failure** (e.g. option at the 50-rule CRD max on `RBACResult` lists): patch `Analyzed=False` with new reason `ReasonAnalysisAugmentationFailed` and a message naming the augmentation and option; the run proceeds to `Failed` through the normal path. No synthesized result CR.
3. `patchStepResult` sets `Analyzed=True` only after successful augmentation.

`ActionRequired=False` runs bypass augmentation entirely (no options to modify) and keep the existing `NoActionRequired` behavior.

**Error taxonomy**: a small interface (e.g. `Permanent() bool`) distinguishes permanent transform failures from transient engine failures. `augmentOptions` wraps errors with the augmentation name and AnalysisResult name.

### 3. Auditability: the `Augmented` Condition

When at least one augmentation changes an option, the same status patch sets a condition on the AnalysisResult:

- `Type: "Augmented"`, `Status: "True"`, `Reason: "OptionsAugmented"`
- `Message`: comma-separated list of applied augmentation names (e.g. `clusterextensions-read-rbac`)

No condition is set when no predicate matched. The condition uses the existing `metav1.Condition` list in status — no CRD schema change. Combined with each injected RBAC rule's `Justification` field, an auditor can reconstruct what the agent proposed versus what the operator added.

### 4. First Augmentation: clusterextensions Read RBAC

**Registration** in `preApprovalAugmentations`:

```go
{
    name:       "clusterextensions-read-rbac",
    predicates: []optionPredicate{readsClusterExtensions},
    transform:  appendClusterRBACRule(clusterExtensionsReadRule),
}
```

**Predicate** (`readsClusterExtensions`): for each action in `option.RemediationPlan.Actions`, split `Command` on `|`, `&`, `;`, and newlines (piped/chained commands are evaluated separately), then require both:

- a read command: `(oc|kubectl) (get|wait|describe)` with quote-aware token boundaries (so wrapped commands like `bash -c "oc get …"` match)
- a clusterextensions reference: `clusterextension`/`clusterextensions`, optionally fully qualified as `.olm.operatorframework.io`, bounded by token boundaries

**Transform** (`appendClusterRBACRule`): appends to `option.RBAC.ClusterScoped`:

```go
RBACRule{
    APIGroups:     []string{"olm.operatorframework.io"},
    Resources:     []string{"clusterextensions"},
    Verbs:         []string{"get", "list", "watch"},
    Justification: "Option includes commands reading OLM ClusterExtensions; grants the read access its actions require",
}
```

No-op if an identical rule already exists; permanent error if the option is at the 50-rule CRD maximum.

**Matching philosophy**: command matching is heuristic, so the predicate is tuned to over-match. A false positive (e.g. `echo "oc get clusterextensions"` matching) grants read-only access to one cluster-scoped resource on a plan the user already sees and approves — bounded and visible in the plan's RBAC display. A false negative leaves the original failure mode: post-mutation read commands failing at execution. Under-matching is the bug being fixed; over-matching is an accepted, documented trade-off.

### 5. Spec Updates

- **`.ai/spec/what/agentic-runs.md`**: relax the AnalysisResult description from "Immutable analysis output" to "Immutable analysis output, except recorded operator augmentations." Add a flow rule between the current rules for reading the AnalysisResult and setting `Analyzed`: the operator applies pre-approval augmentations after validating `Completed=True` and before setting `Analyzed`; applications are recorded on the CR via the `Augmented` condition.
- **`lightspeed-agentic-operator/.ai/spec/what/crd-api.md`** (AnalysisResult status contract): document the `Augmented` condition and augmentation semantics.
- **`lightspeed-agentic-operator/.ai/spec/what/run-lifecycle.md`**: document the `ReasonAnalysisAugmentationFailed` failure reason.

## Testing

- **Predicate table tests**: bare/fully-qualified/wrapped reads, pipelines, semicolon chains, `wait`/`describe`, singular/plural forms, flags-before-resource, and negatives (other resources, patch-only, grep adjacent to a read of another resource, adjacent-token non-matches like `clusterextensions.txt`).
- **Engine tests** (fake client): augmentation applies only to matching options; idempotent re-run is a no-op; identical pre-existing rule is a no-op; conflict exhaustion is transient; 50-rule limit is permanent and leaves options unchanged.
- **Recording tests**: `Augmented` condition set atomically with the mutation, naming the augmentation; absent when nothing matched; stable across re-runs.
- **Integration** (`completeStep`): successful augmentation precedes `Analyzed=True`; permanent failure sets `Analyzed=False` with `ReasonAnalysisAugmentationFailed`; `ActionRequired=False` bypasses augmentation.
- **Invariant test**: after `completeStep` succeeds, the stored AnalysisResult options include the injected rule — what approval and RBAC materialization read is augmented.

## Out of Scope

- Fixing read access for other uncovered resources (each becomes a new registered augmentation).
- Configurable or user-declared augmentation rules.
- Augmentations at any other lifecycle point (e.g. post-approval); the `preApprovalAugmentations` name leaves room for future registries without designing them now.
- Changes to the sandbox's publishing/sanitization pipeline.
