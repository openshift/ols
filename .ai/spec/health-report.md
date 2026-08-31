# Spec health report

Last evaluated: 2026-08-31
Trigger: staleness-check (after `git pull` — new repos landed)
Layout: software (.ai/spec/)

## Stale
- **README.md:17** — "11 repositories currently cloned in this workspace (lightspeed-hub and lightspeed-hub-ui are not yet available)." Both repos are now present and each has its own `.ai/spec/`. Count is now 13 cloned repos.
- **what/system-overview.md:32** — `lightspeed-hub-ui [PLANNED]` with "Guide: `lightspeed-hub-ui/AGENTS.md`". hub-ui now exists with `.ai/spec/` (`what/system-overview.md`, `what/fleet-dashboard.md`, `what/spoke-management.md`). No longer PLANNED; should point at `.ai/spec/README.md`.
- **how/repo-map.md:123-126** — Multicluster Hub UI rows all carry `[PLANNED]` markers pointing at files that now exist in `lightspeed-hub-ui/.ai/spec/what/` (`system-overview.md`, `fleet-dashboard.md`, `spoke-management.md`). Markers are stale.

## Missing
- **what/system-overview.md:44-53** — Cross-Repo Features table omits two cross-repo specs that exist in `what/` and are already listed in `how/repo-map.md`:
  - `what/mcp-tool-rbac.md` (OLS-3680, added a251b02)
  - `what/multicluster-testing.md`

## Structural concerns
- none. `constraints.md` at spec root is an intentional, README-documented convention for this cross-repo workspace (not the single-repo init layout) — left as-is.

## Findability issues
- none. Decisions index (`decisions/README.md`) is current through `0038-mcp-tool-rbac-resolution.md`. `how/repo-map.md` Cross-Repo Features table is complete.

## No issues
- Checked: all 11 `what/` files, `how/repo-map.md`, `README.md`, `constraints.md`, `decisions/README.md` (38 ADRs, all present).
- Sibling repo references in `how/repo-map.md` verified against the 13 repos now cloned under `ols/`. hub section (106-117) already accurate; hub-ui section was the stale one.
- `[PLANNED: TICKET]` markers scanned — none reference completed tickets (OLS-3236, OLS-3491, OLS-3697, OLS-2682, OLS-3697 still open).
