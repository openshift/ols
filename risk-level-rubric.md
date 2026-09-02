# Risk Level Rubric

## Risk Levels

| Level | Customer Impact | Review Requirements | Automation |
|-------|----------------|---------------------|------------|
| Risk 0 | No customer-visible change | No human involvement at any step | Agent runs the change end to end and merges, preapproved task types only |
| Risk 1 | Very little impact if change goes wrong | No human code review required, spot-check optional | Fully automated implementation |
| Risk 2 | Medium impact if change causes problems | 1 human reviewer required | Automated implementation with human review gate |
| Risk 3 | Major impact — risk of losing customers if a bug is introduced | 2+ human reviewers required | Human-driven implementation |

Risk 0 differs from Risk 1 in who is in the loop, not in how the code
gets written. Both are automated. A Risk 1 change lands in a PR that a
human may spot-check before it merges; a Risk 0 change merges without
anyone waiting on it. That only works for task types the team has
preapproved in advance, and only while the circuit breakers below stay
quiet.

## Preapproved Task Types (Risk 0)

A change qualifies for Risk 0 only if its type appears on this list.
The list is the team's decision, reviewed as it grows:

- Dependency version bump, no breaking API changes
- CVE fix where the version bump is the only change

### Circuit Breakers

Autonomous merge stops and escalates to a human when any of these fire:

- CI fails. A failed build is evidence the change is not Risk 0.
- The agent is unsure. Confidence governs whether the agent acts; risk
  level governs who reviews the result. An unsure agent escalates even
  at Risk 0.
- The change touches auth, RBAC, credential handling, or cluster state,
  regardless of what the task type says.
- More than three autonomous merges land in 24 hours. Rate is evidence
  something upstream is wrong.

## Classification Examples

| Change Type | Risk Level |
|-------------|------------|
| Dependency version bump | 0 |
| CVE fix, version bump only | 0 |
| Doc/comment updates, test-only changes | 1 |
| Localization/translation updates | 1 |
| Metadata-only changes (CSV version, labels) | 1 |
| Internal refactor with no API or behavior change | 2 |
| New component or adapter (non-critical path) | 2 |
| Pipeline or calculation logic changes | 2 |
| API contract changes (endpoints, schemas, CRDs — spec fields) | 3 |
| Additive CRD status/condition changes (no spec field changes) | 2 |
| Authentication/authorization/RBAC changes | 3 |
| User-facing UI flow changes | 3 |
| Data export schema or credential handling changes | 3 |
| Changes that mutate cluster state | 3 |

## Decision Tree

1. **Does the change touch an external contract?** (API endpoints, CRD spec fields, auth/RBAC, data export formats, credential handling)
   - Yes → **Risk 3**
   - Exception: additive CRD status/condition changes (no spec field changes) → **Risk 2** — status subresources are operator-managed, not user-facing input

2. **Does the change affect user-visible behavior?** (UI flows, user-facing error messages, cluster state mutations)
   - Yes → **Risk 3**

3. **Does the change alter internal logic?** (refactors, new non-critical-path components, pipeline/calculation changes)
   - Yes → **Risk 2**

4. **Is the change mechanical or cosmetic?** (dep bumps, doc/comment edits, test-only, metadata, localization)
   - Yes, and the task type is preapproved → **Risk 0**
   - Yes, otherwise → **Risk 1**

5. **When in doubt**, bias UP — a Risk 2 that should have been Risk 3 causes more damage than a Risk 3 that could have been Risk 2.

## Edge Cases

- **Cross-repo changes:** If the change spans multiple repos, treat each repo's portion independently but note the cross-repo dependency — this often pushes toward Risk 3.
- **CVE fixes:** Dep bumps for CVEs are Risk 0 if the bump is the only change. If a code fix accompanies the bump, the change is no longer a preapproved task type: assess the code fix separately and classify it on its own.
- **Spikes / investigations:** Risk 1 — no production code changes result from the spike itself.
- **Feature flags:** Adding a new feature behind a flag is Risk 2 (the flag mechanism itself). Removing a flag to expose a feature is Risk 3 (user-visible behavior change).
