---
name: make-jira-from-spec
description: >-
  Create or update Jira Epics and Stories from spec changes.
  Reads spec diffs from the current session or a PR, uses
  brainstorming to design the work breakdown, creates/updates
  issues in Jira, then estimates story points, risk levels,
  and epic sizes. Splits stories that exceed 5 SP. Use when
  the user says "make jira from spec", "make-jira-from-spec",
  "create jira from spec", "update jira from spec", or wants
  to turn spec changes into tracked Jira work.
argument-hint: "[PR-URL... | OLS-XXXX]"
---

# make-jira-from-spec

Turn spec changes into Jira work items. Reads the `.ai/spec/`
changes from the current session or a PR, brainstorms the
decomposition, creates or updates Epics and Stories, then
estimates and risk-assesses every item.

## Defaults

| Setting | Value |
|---------|-------|
| Project key | `OLS` |
| Cloud ID | `redhat.atlassian.net` |
| Content format | `markdown` |
| SP field | `customfield_10028` |
| Risk Score field | `customfield_10976` |
| Epic Size field | `customfield_10795` |
| Max story points | 5 (split if above) |

## Invocation

```
/make-jira-from-spec
/make-jira-from-spec https://github.com/org/repo/pull/123
/make-jira-from-spec https://github.com/org/repo1/pull/10 https://github.com/org/repo2/pull/20
/make-jira-from-spec OLS-1234
```

Arguments (all optional, can be combined):
- **PR URL(s)** — one or more PR URLs to fetch spec diffs from
  (spec changes often span multiple repos)
- **Jira key** — existing Epic or Story to update

## Step 1: Gather Spec Changes

Resolve the spec changes using this priority:

### 1a. PR URL(s) provided

Fetch the diff from each PR with `gh pr diff <URL>`. Filter
to files under `.ai/spec/`. When multiple PR URLs are given,
collect spec diffs from all of them — spec changes often
span multiple repos. Read the full content of each changed
spec file.

**Overlap detection.** If the same spec file appears in
multiple PR diffs, fetch the head revision from each PR
(`gh pr view <URL> --json headRefOid`) and compare the
file at each head. Flag the overlap to the user before
proceeding — do not silently pick one version. Ask which
PR's version to use as the baseline for decomposition.

### 1b. Session context (no PR URLs)

Find spec files changed in the current session across all
repos in the workspace:

```bash
# From the workspace root
for repo in */; do
  git -C "$repo" diff HEAD -- .ai/spec/ 2>/dev/null
done
```

Also check for untracked new spec files:

```bash
for repo in */; do
  git -C "$repo" diff --cached -- .ai/spec/ 2>/dev/null
  git -C "$repo" ls-files --others --exclude-standard .ai/spec/ 2>/dev/null
done
```

### 1c. Neither is clear

Ask the user:

> I couldn't detect spec changes in this session. Can you
> point me to the PR or spec files that changed?

Read the full content of every changed spec file — the diff
alone is not enough context for good decomposition.

## Step 2: Brainstorm Decomposition

Invoke `superpowers:brainstorming` with the spec changes as
context. The brainstorming session should produce:

- What Epics are needed (if the scope warrants them)
- What Stories are needed under each Epic
- Summary and Acceptance Criteria for each item
- Which items map to existing Jira issues (if a parent was
  provided)
- **What e2e / integration test stories are needed** — every
  implementation story MUST have a corresponding test story
  (or test AC within the story itself).

Feed the brainstorming session with:
- The full spec content (not just the diff)
- The diff showing what changed
- The existing Jira parent and its children (if known)
- An explicit prompt: *"For each implementation story,
  identify what e2e or integration tests are needed. Create
  separate test stories when the testing effort is non-trivial
  (new test fixtures, new test scenarios, cross-repo
  validation). Include test criteria in the AC of the
  implementation story when the test is a straightforward
  extension of existing tests."*

**Test coverage gate.** If the brainstorming output includes
implementation stories without test coverage, do NOT proceed
to Step 3. Present the gap to the user and ask whether to
add test stories, add test AC, or explicitly waive testing
for those items.

The brainstorming output is the proposed work breakdown —
it is NOT yet approved for Jira creation.

## Step 3: Resolve Parent

Determine the parent for new Stories based on what the
user provided as the starting context.

**Do NOT create Epics or Stories under Feature Requests.**
A Feature Request is a source of context, not a parent
container. Stories must be under an Epic, never directly
under a Feature or Feature Request.

### 3a. Starting context is an Epic

The Epic itself is the parent for any new Stories. The
Epic's description may also need updating to reflect the
spec changes (handled in Step 6).

### 3b. Starting context is a Feature

The Feature may need its description updated, but Stories
cannot be created directly under a Feature — they need an
Epic parent. Search the Feature's existing children for a
matching Epic:

```
searchJiraIssuesUsingJql:
  cloudId: redhat.atlassian.net
  jql: >
    parent = {FEATURE_KEY}
    AND issuetype = Epic
    AND resolution = Unresolved
  fields: ["summary", "status"]
  maxResults: 100
```

- If an existing Epic fits → propose it as the parent
- If no Epic fits → ask the user which Epic to use or
  whether to create a new one

### 3c. Starting context is a Feature Request, or no Jira key provided

Search for existing open Epics by keyword from the Feature
Request summary and the proposed stories. Strip JQL reserved
characters (`-`, `(`, `)`, `[`, `]`, `"`, `'`, `+`, `&`,
`|`, `!`, `{`, `}`) from the search terms before building
the query:

```
searchJiraIssuesUsingJql:
  cloudId: redhat.atlassian.net
  jql: >
    project = OLS
    AND issuetype = Epic
    AND resolution = Unresolved
    AND summary ~ "{escaped keywords}"
  fields: ["summary", "status", "labels"]
  maxResults: 20
```

Run multiple queries if the proposed stories span different
areas — use the most distinctive terms from each story
cluster, not generic words like "OLS" or "support".

**If matching Epics are found**, present them:

```
Found existing Epics that may match:

| # | Key      | Summary                         | Status     |
|---|----------|---------------------------------|------------|
| 1 | OLS-2001 | {summary}                       | Refinement |
| 2 | OLS-2005 | {summary}                       | In Progress|

Options:
  1, 2, ... — use this Epic as the parent
  new      — create a new Epic (will be top-level, no parent)
  key      — enter a different Epic key
```

**If no matching Epics are found**, skip the table:

```
No open Epics match these stories. Options:
  new — create a new Epic (I'll draft summary & scope)
  key — provide an existing Epic key (e.g. OLS-1234)
```

**Wait for user confirmation.** Do NOT proceed without a
confirmed parent Epic.

When the user chooses "new", the Epic is created as a
top-level item (no parent). This is the one exception to
the "parent is required" constraint — Epics from the FR
path are explicitly top-level.

## Step 4: Search Existing Jira Items

Query children of the user-provided parent only:

```
searchJiraIssuesUsingJql:
  cloudId: redhat.atlassian.net
  jql: >
    parent = {PARENT_KEY}
    OR "Epic Link" = {PARENT_KEY}
  fields: ["summary", "description", "status",
           "issuetype", "customfield_10028",
           "customfield_10976"]
  maxResults: 100
```

Match existing items against the proposed work breakdown:
- Items that already cover proposed work → mark for update
- Proposed items with no match → mark for creation
- Existing items not in the proposal → leave untouched

## Step 5: Propose Work Items

Present the full plan to the user:

```
Spec changes: {list of changed spec files}
Parent: {PARENT_KEY} — {parent summary}

## New Items

| # | Type  | Summary                    | AC count | Test |
|---|-------|----------------------------|----------|------|
| 1 | Epic  | {summary}                  | —        | —    |
| 2 | Story | {summary}                  | 4        | AC   |
| 3 | Story | {summary}                  | 3        | #4   |
| 4 | Story | e2e: {test summary}        | 3        | covers #2,#3 |

## Updates to Existing Items

| Key      | Change                              | Test |
|----------|-------------------------------------|------|
| OLS-1234 | Update AC to reflect new constraint | AC   |
| OLS-1235 | Add scope from new spec section     | #4   |

For updates, the Test column reflects whether the *changed
scope* has test coverage, not whether the existing story
has any tests.

**Test column values:**
- `AC` — test criteria are in the story's own acceptance criteria
- `#N` — covered by a dedicated test story (row N)
- `covers #N` — this IS the test story covering row N
- `waived` — user explicitly waived testing at Step 2
- `—` — not applicable (Epics only)
- `NONE` — **gap: no test coverage.** Must be resolved before approval.

If any implementation story shows `NONE`, flag it and
change the approval options:

```
⚠ Test coverage gaps:
  - Story #3 "{summary}" has no test coverage.
    → Add test AC, create a test story, or justify why
      no test is needed.

Options:
  approve-with-gaps — create all items, leaving test gaps
                      (provide justification for each gap)
  revise            — add test coverage first
  stop              — cancel
```

When the user chooses `approve-with-gaps`, ask for a
justification for each gap. Record it in the story's
Testing section as: `Testing waived — {reason}`.

When no stories show `NONE`, use the standard options:

```
Options:
  approve — create/update all items in Jira
  revise  — tell me what to change
  stop    — cancel
```

**Wait for the user.** Do NOT touch Jira without explicit
approval. The `approve` option is only available when all
stories have test coverage. If gaps exist, only
`approve-with-gaps` may proceed.

## Step 6: Execute in Jira

Before the first Jira call, resolve the **cloudId** by
calling `getAccessibleAtlassianResources` and picking the
`redhat.atlassian.net` site.

### Label inheritance

If the starting context is a Feature Request or Feature,
fetch its labels:

```
getJiraIssue:
  cloudId: {cloudId}
  issueIdOrKey: "{FR or Feature key}"
  fields: ["labels"]
```

These labels are passed via `additional_fields` on every
`createJiraIssue` call below — both Epics and Stories.

### Creating items

Create Epics first, then implementation Stories, then test
Stories (so test Stories can reference their parent Epic and
the implementation Story keys). After creating each test
story, update the corresponding implementation story's
Testing section with the test story's key (`Covered by
OLS-XXXX`).

```
createJiraIssue:
  cloudId: {cloudId}
  projectKey: OLS
  issueTypeName: {Epic | Story}
  summary: "{summary}"
  description: "{markdown description with AC}"
  contentFormat: "markdown"
  parent: "{parent key}"
  additional_fields:
    labels: ["{inherited labels}"]
```

**MANDATORY** — transition every created item immediately.
This is the most commonly skipped step — treat it as part
of the creation, not a follow-up.

Transition from **New** to **Refinement** (transition ID
`31`):

```
transitionJiraIssue:
  cloudId: {cloudId}
  issueIdOrKey: "{newly created key}"
  transition:
    id: "31"
```

Then **verify** the transition succeeded:

```
getJiraIssue:
  cloudId: {cloudId}
  issueIdOrKey: "{newly created key}"
  fields: ["status"]
```

If the status is still New after the first attempt, retry
the transition once. If it fails again (two attempts total),
report the error to the user — do not silently continue.

This applies to every created Epic and Story. Do not
proceed to the next item until the transition is confirmed
or the error is reported.

### Updating items

Fetch the current description first, then merge changes.
Also add any inherited labels that the item doesn't already
have:

```
editJiraIssue:
  cloudId: {cloudId}
  issueIdOrKey: "{issue key}"
  fields:
    description: "{updated markdown}"
    labels: ["{existing labels}", "{inherited labels}"]
  contentFormat: "markdown"
```

Preserve any content in the existing description that is not
being replaced. Append new AC, update changed sections, do
not remove sections the spec didn't touch.

### Description format

Fill in the Testing section with one or more of these lines
(one per line, combine when a story needs multiple types):
- `e2e: {what e2e test verifies this story}`
- `integration: {what integration test verifies this story}`
- `Covered by OLS-XXXX (dedicated test story)`
- `Covers: OLS-XXXX (this IS the test story for that item)`
- `Unit tests only — no user-facing behavior change`
- `Testing waived — {reason}` (only when user chose approve-with-gaps)

Omit the Testing section only for Epics.

Use markdown with this structure:

```markdown
## User Story

As a {persona}, I want {goal} so that {benefit}.

## Description

{Context, background, technical detail from the spec.}

## Acceptance Criteria

- {AC 1}
- {AC 2}

## Testing

{selected testing line}

## Spec Reference

Source: {repo}/.ai/spec/{path}
```

For Epics, omit the User Story section and use:

```markdown
## Overview

{What this Epic covers and why.}

## Scope

- {Scope item 1}
- {Scope item 2}

## Spec Reference

Source: {repo}/.ai/spec/{path}
```

## Step 7: Estimate and Assess

After all items are created/updated, run the estimation and
risk assessment skills on every item. Pass all keys at once
to each skill.

### Stories

Invoke `/estimate-story` with all story keys:
```
/estimate-story OLS-1001 OLS-1002 OLS-1003
```

Invoke `/estimate-risk` with all story keys:
```
/estimate-risk OLS-1001 OLS-1002 OLS-1003
```

### Epics

Invoke `/estimate-epic` with all epic keys:
```
/estimate-epic OLS-2001
```

## Step 8: Auto-Split Oversized Stories

After estimation, check every story. If any story was
estimated at more than 5 SP:

### 8a. Brainstorm the split

Use `superpowers:brainstorming` to break the oversized story
into smaller stories, each targeting ≤ 3 SP.

**Sibling Epic decision.** Create a new sibling Epic only
when the split produces ≥ 3 stories that share a distinct
concern not covered by the existing parent Epic's scope
(e.g., the parent covers backend API and the split produces
3+ frontend stories). Otherwise, keep all sub-stories under
the original parent — do not create an Epic for fewer than
3 stories or for stories that fit the parent's scope.

### 8b. Present split for approval

```
Story OLS-1002 estimated at 8 SP — splitting:

| # | Summary                    | Parent              | Test |
|---|----------------------------|---------------------|------|
| 1 | {sub-story 1}              | OLS-2001            | AC   |
| 2 | {sub-story 2}              | OLS-2001            | #3   |
| 3 | e2e: {test summary}        | OLS-2002 (new Epic) | covers #2 |
```

Apply the same test coverage gating as Step 5: if any
sub-story shows `NONE`, only offer `approve-with-gaps`.

```
Options:
  approve — create the split (only when all sub-stories have test coverage)
  approve-with-gaps — create the split, leaving test gaps
  revise  — tell me what to change
```

**Wait for user approval.**

### 8c. Execute the split

Follow the same creation procedure as Step 6:

1. Create new Epic (if proposed) via `createJiraIssue` —
   include inherited labels via `additional_fields`
2. Create the smaller stories via `createJiraIssue` —
   include inherited labels via `additional_fields`
3. Transition every newly created item to **Refinement**
   (transition ID `31`), then verify the status. If still
   New after the first attempt, retry once. If it fails
   again (two attempts total), report the error and
   continue.
4. Close or update the original oversized story — add a
   comment noting it was split, link to the new stories
5. Re-run `/estimate-story` and `/estimate-risk` on the new
   stories
6. Re-run `/estimate-epic` on all affected Epics

## Step 9: Report

### Feature Request summary comment

If the starting context was a Feature Request, post a
summary comment on it listing all final work items (after
any splits in Step 8). Use bare issue keys for Jira
auto-linking — do not wrap them in brackets:

```
addCommentToJiraIssue:
  cloudId: {cloudId}
  issueIdOrKey: "{FR key}"
  commentBody: |
    Work items created from this Feature Request:

    Source: {spec file path(s)}

    Epics:
    - OLS-2001 — {epic summary}

    Stories:
    - OLS-1001 — {story summary} (under OLS-2001)
    - OLS-1002 — {story summary} (under OLS-2001)

    Created by make-jira-from-spec.
  contentFormat: "markdown"
```

### Summary table

Print a summary table of everything created and updated:

```
## Summary

| Key      | Type  | Summary              | SP | Risk | Test | Status  |
|----------|-------|----------------------|----|------|------|---------|
| OLS-2001 | Epic  | {summary}            | —  | —    | —    | Created |
| OLS-1001 | Story | {summary}            | 3  | 2    | AC   | Created |
| OLS-1002 | Story | {summary}            | 2  | 1    | #1003| Created |
| OLS-1003 | Story | e2e: {test summary}  | 2  | 1    | covers #1002 | Created |
| OLS-1234 | Story | {summary}            | 3  | 2    | AC   | Updated |

Epics sized: OLS-2001 → S (15 SP)

Spec sources:
- lightspeed-service/.ai/spec/what/query-pipeline.md
- lightspeed-operator/.ai/spec/what/deployment.md
```

## Constraints

- **Human gates are mandatory** — never create or update
  Jira issues without explicit user approval (Step 5, Step
  8b).
- **Parent is required** — always ask if not provided. Do
  not create orphan stories. Exception: Epics created from
  the Feature Request path are top-level (no parent).
- **Scoped search only** — when searching for existing
  items, only look at children of the user-provided parent.
  Do not search the entire project.
- **Preserve existing content** — when updating an issue,
  merge changes into the existing description. Do not
  overwrite sections the spec didn't touch.
- **Max 5 SP per story** — any story estimated above 5 SP
  must be split. This is not optional.
- **Spec reference required** — every created item must
  include a Spec Reference section linking back to the
  source spec file.
- **No invented requirements** — only create work items for
  scope that exists in the spec. Do not expand scope.
- **Use markdown contentFormat** — all Jira descriptions use
  `contentFormat: "markdown"`. The Jira MCP server converts
  to ADF automatically.
- **Label inheritance** — when the starting context is a
  Feature Request or Feature, copy its labels to every
  created and updated item (Steps 6 and 8c).
- **Transition verification** — after transitioning any item
  to Refinement, verify the status. Retry once if it fails.
  Report the error after two attempts total.
- **FR summary comment in Step 9** — the comment on the
  Feature Request is posted in Step 9, after all items
  (including splits) are final. Use bare issue keys for
  Jira auto-linking.
- **JQL escaping** — strip reserved characters (`-`, `(`,
  `)`, `[`, `]`, `"`, `'`, `+`, `&`, `|`, `!`, `{`, `}`)
  from search terms before building JQL queries.
- **Test coverage required** — every implementation story
  must have test coverage: either test criteria in its own
  AC, a dedicated test story, or an explicit user waiver
  via `approve-with-gaps` (with recorded justification).
  Flag gaps in Step 5 and Step 8b. The `approve` option is
  only available when all stories have coverage.
