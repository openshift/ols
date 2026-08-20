# OLS Story Point Estimation Rubric

Derived from analysis of 300 completed OLS stories + 429 merged GitHub PRs (project OLS on Jira, Fibonacci scale).
Generated: 2026-06-05, updated with code complexity analysis

This rubric is for use by AI assistants estimating story points on new/unstarted OLS stories.
Story points measure **complexity and effort**, not calendar time.

---

## Scale: Fibonacci — 0.5, 1, 2, 3, 5

The team uses **0.5 through 5**. **0 is retired** — it is no longer used; the smallest value
is 0.5. A story that feels like **8+ should be split**; 8 is not assigned (treat it as a 5,
the team's practical max, or break it up).

> The authoritative correction layer is the **"Calibrated Rules (v11)"** section below (from a
> ~900-story blind calibration + out-of-sample validation). It takes precedence over the
> point-definition prose, the decision tree, and the older bias-corrections wherever they
> conflict.

---

## Point Definitions (from historical data)

### 0 Points — RETIRED (now 0.5)
> **0 is no longer used.** The cases below now map to **0.5** (or 1 for doc-content and
> security-checklist items — see Calibrated Rules). Kept for historical context only.

**Frequency:** ~5% of stories
**Median time to close:** 7 days (mostly review/merge lag)

**Code complexity (from 429 merged PRs):**
- PRs: 1 | Files: ~6 | Code additions: ~13 | Test ratio: 28%
- Typically net-negative lines (more deleted than added)

**Characteristics:**
- Pure removal of dead code, config, or CI jobs with no behavioral change
- Deletion of a feature flag, env var, or provider that is confirmed unused
- No new code written; just deleting lines or toggling settings
- Risk level 1 (automerge / quick glance)
- Single repo, no cross-repo coordination

**Signals in the story:**
- Summary contains "remove", "delete", "clean up"
- Description says "simple config removal" or similar
- CI/build focused (80% of 0-pointers mention CI)
- Usually 0 acceptance criteria that require new behavior

---

### 0.5 Points — Very Small
**Frequency:** ~11% of stories
**Median time to close:** 7 days

**Code complexity:**
- PRs: 1 | Files: 3-5 typical | Code additions: ~7-40 | Test additions: ~0
- Modules: 2 | Repos: 1 | Test ratio: 9% (often no tests needed)
- Note: some 0.5-pointers have high churn from generated/lock file updates — the *authored* code is small

**Characteristics:**
- Small, well-scoped change touching 1 repo
- Remove + replace pattern (delete old, add minimal new)
- Small spike/audit that produces a document, not code
- Straightforward bug fix or config correction
- ~1-3 files changed in the core change
- Acceptance criteria are narrow and specific (2-4 bullets)

**Signals in the story:**
- Clear "What" section listing specific files/functions to change
- Operator or config changes with well-defined scope
- "Spike" or "audit" that is time-boxed and narrow
- Description often mentions specific file paths

**Examples from history:**
- *Remove LIGHTSPEED_MODE from operator-sandbox env var contract and spec* (OLS-3204)
- *Spike: Sandbox failure modes audit for health checks* (OLS-3058)
- *Correct handling of the --hermetic-build command line parameter in RAG build scripts* (OLS-2889)

---

### 1 Point — Small
**Frequency:** ~20% of stories
**Median time to close:** 9 days

**Code complexity:**
- PRs: 1-2 | Files: 2-14 (p25-p75) | Code additions: 6-93 | Test additions: 0-86
- Total churn: 34-520 lines | Modules: 1-4 | Repos: 1 | Test ratio: 29%
- Typical shape: ~36 lines of new code + ~26 lines of tests

**Characteristics:**
- Add a new module/feature with well-defined boundaries (~40-100 lines of new code)
- Single repo change, but touches multiple files (5-10)
- May require new tests but test patterns are established
- Implementation approach is clear — no design decisions needed
- New endpoint, new config option, or new mapping/resolver
- Risk level 2 (requires human review but approach is prescribed)

**Signals in the story:**
- Has "Changes" or "Implementation" section with specific bullets
- Acceptance criteria list 4-6 concrete, testable items
- Description mentions code blocks or specific data structures
- May reference a spec PR that defines the contract
- ~1000-1500 char description with clear structure

**Differentiator from 0.5:** New code is written, not just deletion/config. But the "what" is fully specified — no design ambiguity.

**Examples from history:**
- *Add readiness and liveness probes to sandbox SandboxTemplate in operator* (OLS-3215)
- *Sandbox — add LIGHTSPEED_* env var resolver* (OLS-3203)
- *Operator — replace SDK env vars with LIGHTSPEED_* contract* (OLS-3202)

---

### 2 Points — Medium
**Frequency:** ~33% of stories (most common)
**Median time to close:** 21 days

**Code complexity:**
- PRs: 1-2 | Files: 3-14 (p25-p75) | Code additions: 10-153 | Test additions: 0-260
- Total churn: 67-422 lines | Modules: 1-4 | Repos: 1 | Test ratio: 40%
- Typical shape: ~47 lines of code + ~40 lines of tests — notably test-heavy vs SP 1
- The jump from 1→2 is more about test investment than code volume

**Characteristics:**
- Moderate feature work or refactoring
- May touch multiple files across a module (5-15 files)
- Requires writing new tests (e2e or unit) as part of the work
- Some design decisions needed, but within established patterns
- May involve removing old code AND adding new replacement code
- Could involve documentation alongside code changes
- Spikes/research with broader scope (evaluate multiple options)

**Signals in the story:**
- User story format ("As a... I want... so that...")
- Has a "Description" section explaining context/motivation
- Acceptance criteria with 5-8 items
- 39% mention testing/e2e explicitly
- May reference external tools or frameworks
- Release notes, documentation work

**Differentiator from 1:** More moving parts. The story has a "why" section, not just a "what". Some judgment calls are required during implementation.

**Examples from history:**
- *Remove provider abstraction and native adapters* (OLS-3112) — delete 3 files + refactor routing
- *Create OLS 1.0.13 release notes* (OLS-3110) — requires JQL queries + writing
- *[SPIKE] Propose if we use Native SDK vs common sdk* (OLS-3033) — research + recommendation
- *Add e2e test for agentic-sandbox repo to verify structured output* (OLS-3034)

---

### 3 Points — Large
**Frequency:** ~27% of stories
**Median time to close:** 21 days

**Code complexity:**
- PRs: 1-3 | Files: 5-16 (p25-p75) | Code additions: 68-729 | Test additions: 0-341
- Total churn: 254-1734 lines | Modules: 2-5 | Repos: 1 | Test ratio: 36%
- Typical shape: ~239 lines of code + ~67 lines of tests
- The jump from 2→3 is dramatic: code additions 3-5x larger, modules increase, churn doubles

**Characteristics:**
- Significant new feature or cross-cutting change
- Touches multiple subsystems or requires cross-repo coordination
- E2e test stories that test multi-step workflows (approval → execution → verification)
- UI stories that add new interaction patterns or pages
- CI/infrastructure onboarding across multiple repos
- Operator changes that affect pod lifecycle or CRD schema
- 44% involve UI work; 37% involve operator work
- 41% explicitly mention testing as part of scope

**Signals in the story:**
- Description describes a multi-step workflow or state machine
- Acceptance criteria have 6-10+ items across different concerns
- Multiple PRs expected (15% mention multiple PRs)
- Cross-repo or cross-component coordination needed
- UI + backend changes together
- 67% mention CI/build implications

**Differentiator from 2:** The story spans subsystems or requires understanding a complex workflow. Multiple PRs or repos are involved. The acceptance criteria test an end-to-end flow, not just a unit of functionality.

**Examples from history:**
- *Add e2e test for agentic-operator repo to verify execution approval through verification* (OLS-3037) — multi-step operator workflow
- *Onboard Agentic repos to prow to have merge gates* (OLS-3125) — 3 repos × config
- *[UI] Implement MCP related user messages* (OLS-2662) — new UI message patterns

---

### 5 Points — Very Large
**Frequency:** ~3% of stories
**Median time to close:** 27 days

**Code complexity:**
- PRs: 2-3 | Files: 2-14 (wide range) | Code additions: 3-308 | Modules: 2-4
- Note: SP 5 stories often have *less* raw code than SP 3 — the complexity is architectural,
  not volumetric. The effort is in design, coordination, and getting the abstraction right.

**Characteristics:**
- Major UI feature or architectural change
- 100% of 5-pointers in history are UI/Console stories
- Migration of an entire test framework or toolchain
- New extensibility mechanism or plugin system
- Significant frontend architecture work (new patterns, not just new screens)
- May require external documentation or design docs

**Signals in the story:**
- Description references external design documents
- Multiple draft PRs already in progress
- Console component explicitly tagged
- Scope is "migrate everything" or "build a new system"
- Few acceptance criteria (the scope IS the complexity, not the checklist)

**Differentiator from 3:** The story represents an architectural shift or migration, not just a large feature. It changes HOW things work, not just WHAT exists.

**Examples from history:**
- *[UI] Migrate e2e tests from Cypress to Playwright* (OLS-3197) — framework migration
- *[UI] Tool UI extensibility from external plugins* (OLS-2722) — new extensibility architecture
- *[UI] Implement UI support for MCP execution approval* (OLS-2661) — new approval workflow

---

### 8+ Points — Should Be Split
**Frequency:** 0% in recent history (team doesn't use these)

If a story feels like 8+, it should be broken into multiple stories. Ask: "Can this be delivered in 2-3 independent PRs?" If yes, split it.

---

## Code Complexity Reference

Based on 96 stories matched to 429 merged PRs across 7 openshift/* repos.
Values are p25-p75 (interquartile range) — the middle 50% of stories at each level.

| SP | PRs | Files changed | Code additions | Test additions | Total churn | Modules | Test % |
|----|-----|--------------|----------------|----------------|-------------|---------|--------|
| 0 | 1 | ~6 | ~13 | ~23 | ~53 | ~3 | 28% |
| 0.5 | 1 | 3-5 | 7-40 | 0 | 39-75 | 2 | 9% |
| 1 | 1-2 | 2-14 | 6-93 | 0-86 | 34-520 | 1-4 | 29% |
| 2 | 1-2 | 3-14 | 10-153 | 0-260 | 67-422 | 1-4 | 40% |
| 3 | 1-3 | 5-16 | 68-729 | 0-341 | 254-1734 | 2-5 | 36% |
| 5 | 2-3 | 2-14 | 3-308 | 0-7 | 9-318 | 2-4 | 23% |

**Key insights from code data:**
- **SP 1→2 jump is about tests, not code.** Code additions are similar (36 vs 47 median), but test ratio jumps from 29% to 40%. SP 2 stories require proving correctness.
- **SP 2→3 jump is about code volume.** Code additions go from ~47 to ~239 median (5x). This is where real new functionality lives.
- **SP 5 is NOT bigger code than SP 3.** SP 5 stories often have less raw code — their complexity is architectural (design, coordination, abstraction) rather than volumetric.
- **Modules touched scales with SP.** 1-2 modules for SP 0-1, 2-4 for SP 2-3, 2-5 for SP 3+.
- **Test ratio peaks at SP 2 (40%).** Higher-SP stories have proportionally less test code — they're tested through e2e flows rather than unit tests.

## Estimation Decision Tree

```
1. Is it pure deletion/config with no new behavior?
   → 0.5 points  (0 is retired)

2. Is it a single-file or narrow-scope change with <3 files?
   → 0.5 points

3. Is the implementation fully prescribed (spec exists, files named)?
   AND stays in 1 repo with <10 files?
   → 1 point

4. Does it require design decisions, new tests, or moderate refactoring?
   AND stays primarily in 1 subsystem?
   → 2 points

5. Does it span subsystems, require cross-repo work,
   OR test a multi-step workflow end-to-end?
   → 3 points

6. Is it an architectural change, framework migration,
   OR new extensibility mechanism (especially UI)?
   → 5 points
```

## Calibrated Rules (v11 — from ~900-story blind calibration + out-of-sample validation)

Derived and validated on ~900 completed stories (blind test-and-fix plus two out-of-sample
holdouts). **These take precedence over the point-definition prose, the decision tree, and the
older bias-corrections where they conflict.** Best measured accuracy with these rules plus the
retrieval anchor (see the `estimate-story` skill): ~59% exact / 90% within-1 / MAE 0.52, vs
~40% for the point-definitions alone.

### Boundary leans (apply first)
- **No 0.** Smallest value is 0.5. Anything older guidance called "0" is now 0.5.
- **1 vs 2 — no thumb on the scale.** Decide on normal signals; do NOT round a 1 up to 2
  (1s are already over-called).
- **2 vs 3 — lean UP.** True 3s are routinely under-called as 2. One clear size signal
  (multiple repos; new subsystem/service/CRD/provider; real migration/refactor; 3+ surfaces
  like schema+controller+UI; multi-concern description) → **3**. When torn, choose **3**.
- **3 vs 5 — lean up only gently.** True 5s are rare (~4%). Assign **5 only with TWO OR MORE
  independent strong signals**, or unmistakably architectural/epic-scale work. One signal or a
  mere tie → stay at **3**. (Selectivity beats brute-force rounding.)
- **No 8.** A story that feels like 8 is a 5 or should be split. Never round a large story
  DOWN to 2-3, but do not assign 8.

### Work-type defaults
1. **Administrative / non-technical tickets → 0.5.** Slide decks, JTBD examples, "move this
   Jira to the backlog," peer-review requests, PR-template tweaks. AC bullet count does not
   push these up. *Exception A:* an unfilled template/placeholder story (raw
   "[PERSONA]/[DO A THING]" body, or "TODO: <topic>") → **2**, low-confidence. *Exception B:*
   a numbered security/compliance checklist item ("T1204:", "CT4:", …) → **1**.
2. **Single, isolated code/config edits → 0.5.** One column/field on one table; one boilerplate
   file from a template; a single dependency version bump (unless it names specific new
   capabilities to implement). Reserve **1** for a single-surface change needing design/
   testing/coordination. **Toolchain/runtime upgrades (Go/Node/Python version) → 2** (rebuild +
   compat + CI across the codebase). Routine recurring content-generation (a RAG content image
   per OCP release, a per-version FBC catalog config) → 0.5-1; adding a genuinely NEW doc
   source to a RAG corpus → 2.
2b. **Documentation-authoring/update stories → 1** (not 0.5), even for a trivial edit (broken
   link, one frontmatter field) — ~70% of doc-component tickets land at 1. Pure process tasks
   merely carrying a Documentation label (peer reviews, decks) are rule 1 (0.5). Release notes
   and multi-page/multi-product doc work are 2+.
3. **Removal / subtraction → 0.5-1**, even across several files (delete a provider + its
   registration/tests/docs). Do not apply "multiple surfaces → lean 3/5" to subtractive work.
   Use 2+ only if the removal needs migration/compat work for remaining users or bundles a
   nontrivial replacement.
4. **Compliance/policy-exception and pure verification/confirmation tickets → 0.5** (an
   EC/Conforma exemption entry; "verify X works on new OCP" with no anticipated code change).
   A pure compatibility check is not "investigate and fix" (rule 5).
5. **"Investigate and fix" → scoped fix (2) by default**, even with an unconfirmed cause, when
   scoped to one test/job/suite with a test/CI-side fix. **0.5-1** if a specific (even
   tentative) cause is named or the fix is mechanical; **3** if it needs infra-level changes or
   recurs across multiple suites; **5** if explicitly cross-environment/systemic with no known
   cause.
6. **Release / environment-promotion tickets → 2** (high-variance; a few are really 5 but text
   can't tell — don't chase). "Create release notes for version X" → 2. Promoting an *existing*
   pipeline is this rule; creating a *new* recurring job is rule 8.
7. **A small addition to an existing CI/build pipeline** (one more platform/arch) → 0.5.
8. **Lean 3** for real cross-cutting scope: CRD/API-schema changes touching reconciliation in
   >1 place or propagating status end-to-end (one field read in one path is 2); a new provider
   that *also* removes a retired one; a **new** periodic job/pipeline; a UI↔backend feature
   implementing both sides together (or a backend-only slice that itself adds multiple
   capabilities); one story implementing multiple related API operations; adding a new external
   protocol/spec into an existing system; "single source of truth" consolidation or a
   base-image swap across many Dockerfiles. *Exception:* pure field-naming/type-convention
   standardization with no reconciler change is often just **1** — don't lean 3 on the
   "consolidation" label alone. A long, multi-concern narrative → lean 3 even as one AC bullet.
9. **Lean 5** when: three or more distinct technical surfaces in one deliverable (CRD/schema +
   server logic + a new external library/service), or explicit **total-coverage** framing
   ("extend to *all* pages," "translate *all* strings"). 5/8 stay noisy/low-volume — don't
   over-chase them.
10. **Spikes → 2** by default (they cluster at 2). **0.5** for a single already-scoped
    question/PoC. Comparing multiple options is NOT enough for 3. **3** only if the AC commits
    to a concrete forward deliverable (follow-on stories to file; a CR/config to propose as a
    gate). **5** if it demands quantifiable/benchmarked outcomes or is epic-scale. Judge by
    what the AC commits to producing, not by broad-sounding titles.
11. **Do not let AC-bullet count alone drive the estimate.** Weigh work-type and distinct
    files/layers/decisions first; use AC count only to break a tie between two adjacent
    plausible levels.

### Retrieval anchor & residual hard cases
The `estimate-story` skill retrieves the most similar past stories (with their actual SP)
before finalizing. Weight a near-duplicate (similarity > 0.7) heavily; treat several agreeing
similar neighbors (> 0.4) as a solid anchor; ignore weak/scattered matches. Never let a
small-SP neighbor pull down a story that clearly shows large-scope signals. Actual **5s**
(~21% exact) and **8s** (~0%) remain near the text-only ceiling — rare and textually
indistinguishable from 3s — so do not chase them with aggressive rules.

## Complexity Multipliers

These factors push a story UP by 1 point from the base:

| Factor | Why it adds complexity |
|--------|----------------------|
| Cross-repo changes required | Coordination, multiple PRs, merge ordering |
| New CRD/API schema changes | Backward compatibility, migration, validation |
| Security/RBAC implications | Extra review, compliance checks |
| External dependency changes | Supply chain review, EC exceptions |
| UI + backend changes together | Two tech stacks, two review cycles |
| Operator + sandbox changes together | Two deployment contexts, integration testing |

These factors push a story DOWN by 1 point:

| Factor | Why it reduces complexity |
|--------|-------------------------|
| Established pattern exists (copy/adapt) | No design decisions |
| Spec PR already merged | Implementation is prescribed |
| Removing code without replacement | Fewer things to get wrong |
| Story references specific file paths | Scope is concrete |

## Component-Specific Guidance

| Component | Typical SP Range | Notes |
|-----------|-----------------|-------|
| Console (UI) | 2-5 | UI stories tend to be 3-5; UI-only bugfixes are 1-2 |
| Operator | 1-3 | CRD changes push toward 3; env var/config toward 1 |
| Server/Service | 1-3 | New endpoints are 1-2; refactors are 2-3 |
| RAG | 1-2 | Index/embedding changes are 2; config changes are 1 |
| CI/Build/Release | 0-2 | Pipeline config is 0-1; onboarding new repos is 2-3 |
| Documentation | 1-2 | Release notes are 2; doc corrections are 0.5-1 |
| Spike/Research | 0.5-3 | Narrow audit is 0.5; broad evaluation is 2-3 |
| CVE/Vulnerability Trackers | 0.5-2 | Default **0.5** — most are a dependency bump in one component image (Go module or Python package pin, rebuild, verify). Estimate higher only when the tracker requires code changes beyond a version bump, has no upstream fix yet (requiring workarounds or EC exceptions), or involves cross-component coordination. |

## How to Use This Rubric

When estimating a new story:

1. **Read the summary and description carefully**
2. **Identify the work type** (new feature, removal, refactor, test, spike, UI, operator, etc.)
3. **Count the acceptance criteria** — more criteria generally means more points
4. **Check for cross-cutting concerns** — cross-repo, multi-component, etc.
5. **Apply the decision tree** to get a base estimate
6. **Apply multipliers** up or down
7. **Sanity check against examples** at that point level (internal check only)
8. **Report confidence** — if the story is underspecified, say so and note what would change the estimate
9. **Do NOT list comparable/similar stories** in the output — just the estimate and confidence

### Confidence Levels

- **High confidence:** Story has clear AC, specific file paths, established patterns
- **Medium confidence:** Story has AC but implementation details are ambiguous
- **Low confidence:** Story is vague, no AC, spike-like ("explore", "investigate", "propose")

For low-confidence estimates, provide a range (e.g., "2-3 points depending on whether X requires Y").

### Bias Corrections (from blind testing) — SUPERSEDED

> **Superseded by the "Calibrated Rules (v11)" section above**, which is based on a much larger
> (~900-story) calibration. Where these older 22-story corrections conflict with v11 — notably
> #1 ("vague → bias up") and any 0-point guidance — **follow v11**. Kept here for history.

Blind testing on 22 stories showed 55% exact match, 86% within ±1 SP, but a systematic
underestimation bias of -0.6 SP. Apply these corrections:

1. **Vague descriptions → bias UP, not down.** A sparse description with one-line AC doesn't
   mean small — it means undefined. Undefined work is harder than prescribed work. When in
   doubt between two SP levels on a vague story, pick the higher one.
2. **External system integration → add 1 point.** Stories involving external orgs, external
   repos (not openshift/*), or multi-system coordination (Konflux, dataverse, service-now)
   take more effort than the description suggests.
3. **"Integrate external library" → add 1 point.** Bringing in a new dependency (not just
   using an existing one) involves evaluation, compatibility, supply chain review.
4. **SP 3+ stories are easy to under-call.** The rubric is well-calibrated for 0-2 SP
   (avg error 0.2-0.3) but underestimates at 3+ (avg error 0.8-1.0). When a story
   has 3-pointer signals, consider whether it might actually be a 5.
5. **"Investigate and fix" is never 1 point.** Investigation tasks with vague scope
   ("investigate failures", "find root cause and fix") are 2 minimum, 3 if the scope
   says "across" multiple suites/systems/repos. The investigation itself is the work.
6. **"Setup job/pipeline following existing pattern" is often 2-3, not 1.** Even when
   a pattern exists, adapting it to new data/scale/reporting adds hidden work.

---

## Data Source

- **300 completed stories** from OLS Jira project (Done/Closed status)
- **Story points field:** customfield_10028
- **Distribution across 300 stories:**

| SP | Count | Percentage |
|----|-------|------------|
| 0 | 14 | 4.7% |
| 0.5 | 35 | 11.7% |
| 1 | 85 | 28.3% |
| 2 | 82 | 27.3% |
| 3 | 69 | 23.0% |
| 5 | 13 | 4.3% |
| 8 | 1 | 0.3% |

- **Average SP per story:** 1.8
- **69% of stories are 1 or 2 SP** — the team breaks work into small pieces
- **GitHub PR analysis:** 429 merged PRs across 7 openshift/* repos, matched to 96 stories by OLS-XXXX key in PR title
- **Repos searched:** lightspeed-service, lightspeed-operator, lightspeed-console, lightspeed-rag-content, lightspeed-agentic-operator, lightspeed-agentic-console, lightspeed-agentic-sandbox
- **Code metrics captured per PR:** additions, deletions, files changed, test vs code files, modules (top-level directories), commits
- **Time analysis:** Calendar days from created to resolved (includes review time)
