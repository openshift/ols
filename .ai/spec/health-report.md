# Spec health report

Last evaluated: 2026-07-22
Trigger: session start — staleness check
Layout: software (.ai/spec/)

## Status: All Issues Fixed ✓

### Fixed Issues

**1. Broken cross-references** ✓
- Removed references to non-existent specs `what/collector.md` and `what/postgres-exporter.md` from `what/templog.md` lines 222–223
- These specs were never created; templog feature is fully self-contained

**2. Stale repository name** ✓
- Updated all 5 references from `lightspeed-otel-postgres-collector` → `lightspeed-otel-collector` in `what/templog.md`
- Updated repo-map.md cross-repo feature reference for templog

**3. OLS-3236 PLANNED markers** ✓
- Removed all 11 occurrences of `[PLANNED: OLS-3236]` from `what/deployment-lifecycle.md`
- Feature is implemented and merged (commit d686d00, 2026-07-09)
- Spec now reflects current behavior without markers

**4. OLS-3442 PLANNED marker** ✓
- Removed `[PLANNED: OLS-3442 — revisit cache schema...]` from `what/query-pipeline.md` line 30
- Feature is completed (commit 06c18d7, 2026-07-15)
- Cache behavior spec now current

## Verification

✓ No incomplete sections (no TODO, TBD, FIXME)
✓ No dangling feature references
✓ No stale PLANNED markers
✓ All cross-repo features have specs
✓ Repo-map is complete and accurate
✓ Git workflow and Jira constraints enforced at constraint level

## Result

Spec structure is now healthy. All references are current and all completed work has been unmarked as PLANNED.
