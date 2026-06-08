# OpenShift Lightspeed — Specifications

Cross-repo specifications for the OpenShift Lightspeed product. This spec layer sits above the individual repo specs and covers product-wide context: what the system is, how features flow across repos, and where to find everything.

Each child repo has its own `.ai/spec/` (or `AGENTS.md`) with repo-specific behavioral rules and implementation details. This parent spec does not duplicate that content — it provides the map between repos and the end-to-end view of cross-repo features.

## Structure

| Layer | Path | Purpose |
|---|---|---|
| **what/** | `.ai/spec/what/` | Product-level behavioral rules. Cross-repo feature flows, integration contracts, repo ownership. |
| **how/** | `.ai/spec/how/` | Routing index. Concern → repo → spec file lookup table. |

## Scope

Covers the full OLS product across all 10 repositories in this workspace. Out of scope: internal repo implementation details (covered by each repo's own `.ai/spec/`).

## Audience

AI agents. Content is optimized for precision and machine consumption.

## Quick Start

| Task | Start here |
|---|---|
| Understand the full product | `what/system-overview.md` |
| Find which repo owns a concern | `how/repo-map.md` |
| Understand the agentic proposal flow | `what/agentic-proposals.md` |
| Understand how RAG indexes are built and consumed | `what/rag-pipeline.md` |
| Understand how the operator deploys everything | `what/deployment-lifecycle.md` |
| Understand how a user query is processed | `what/query-pipeline.md` |
| Understand the agentic security model | `what/agentic-security.md` |
| Check cross-repo rules | `constraints.md` |

## Conventions

- **Rule numbering:** behavioral rules are numbered sequentially within each what/ file.
- **Planned changes:** unimplemented behavior is marked with `[PLANNED]` or `[PLANNED: TICKET-XXXX]` inline next to the rule it affects.
- **Authority:** what/ specs are authoritative for behavior. how/ specs are authoritative for implementation. When they conflict, what/ wins.
- **Child spec authority:** for repo-internal behavior, the child repo's `.ai/spec/` is authoritative. This parent spec is authoritative for cross-repo integration contracts and product-level behavior.

## Updating this spec

- **Adding a cross-repo feature:** create `what/<feature>.md` with end-to-end flow, integration contracts, and repo ownership table. Add entries to `how/repo-map.md`. Add to the quick-start table above.
- **Adding a single-repo concern:** do not add it here. Add it to the child repo's `.ai/spec/`. Update `how/repo-map.md` if the concern isn't listed yet.
- **After implementation:** remove `[PLANNED]` markers from implemented rules. Update integration contracts if APIs/CRDs changed.
- **When to create a new cross-repo what/ file:** when a feature has its own lifecycle, touches 2+ repos, and has integration contracts (CRDs, APIs, shared data) between them.
