# 0048: Name-Based Exceptions to Remote Baseline Reader Validation

**Status:** Accepted for planned implementation
**Applies to:** lightspeed-hub, lightspeed-agentic-operator (remote runs only)
**Tracking:** OLS-4685, under OLS-4632
**Amends:** [ADR 0045](0045-multicluster-agent-baseline-rbac.md)

## Context

An OLS-4685 smoke test on OpenShift 5.0.0-rc.7 found that both default roles fail strict reader validation: `cluster-reader` includes RBAC reads and non-reader verbs; `cluster-monitoring-view` includes create/update. The administrator chose exact-name exceptions rather than removing validation for all roles.

## Decision

Retain strict reader validation, except that ClusterRoles named exactly `cluster-reader` or `cluster-monitoring-view` bypass permission-content validation in hub provisioning and remote phase setup. Match case-sensitive role names, not binding names or configuration origin. The exceptions remain valid after administrator edits, replacement, or aggregation changes. Custom fleet defaults, copied policies under other names, and near-match names are not exempt.

Still enforce role existence/accessibility, API authorization and bind checks, ownership/collision protections, and cleanup. Do not widen standing credentials. Local single-cluster validation is unchanged. The [canonical contract](../what/multicluster-agent-rbac.md), especially rule 16a, defines the full behavior and test requirements.

## Consequences

Administrators own review of the two exempt roles. Their current permissions apply in every remote phase, potentially granting writes or Secret/RBAC access independently of execution approval. Approved execution RBAC generation is unchanged. Non-exempt validation remains preflight, not continuous revocation of existing grants.

This is a planned spec change, not an implementation claim. OLS-4685 retains hub unit/controller scope; real cross-cluster acceptance remains separate. Jira wording requiring all roles, including defaults, to pass validation needs alignment with these two exceptions.
