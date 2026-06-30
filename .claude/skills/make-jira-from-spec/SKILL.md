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
argument-hint: "[PR-URL | OLS-XXXX]"
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
/make-jira-from-spec OLS-1234
```

Arguments (all optional):
- **PR URL** — fetch the spec diff from this pull request
- **Jira key** — existing Epic or Story to update

## Step 1: Gather Spec Changes

Resolve the spec changes using this priority:

### 1a. PR URL provided

Fetch the diff with `gh pr diff <URL>`. Filter to files
under `.ai/spec/` in any repo. Read the full content of each
changed spec file.

### 1b. Session context (no PR URL)

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

Feed the brainstorming session with:
- The full spec content (not just the diff)
- The diff showing what changed
- The existing Jira parent and its children (if known)

The brainstorming output is the proposed work breakdown —
it is NOT yet approved for Jira creation.

## Step 3: Resolve Parent

Determine the parent for new Stories based on what the
user provided as the starting context.

**Do NOT create Epics under Feature Requests.** The skill
only creates Stories (and updates existing Epics/Features).

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

Ask the user:

> What Epic should these stories live under?
> Provide a Jira key (e.g. OLS-1234).

Do NOT create Epics under Feature Requests. Do NOT
proceed without a parent Epic confirmed by the user.

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

| # | Type  | Summary                    | AC count |
|---|-------|----------------------------|----------|
| 1 | Epic  | {summary}                  | —        |
| 2 | Story | {summary}                  | 4        |
| 3 | Story | {summary}                  | 3        |

## Updates to Existing Items

| Key      | Change                              |
|----------|-------------------------------------|
| OLS-1234 | Update AC to reflect new constraint |
| OLS-1235 | Add scope from new spec section     |

Options:
  approve — create/update all items in Jira
  revise  — tell me what to change
  stop    — cancel
```

**Wait for the user.** Do NOT touch Jira without explicit
approval.

## Step 6: Execute in Jira

Before the first Jira call, resolve the **cloudId** by
calling `getAccessibleAtlassianResources` and picking the
`redhat.atlassian.net` site.

### Creating items

Create Epics first, then Stories (so Stories can reference
their parent Epic).

```
createJiraIssue:
  cloudId: {cloudId}
  projectKey: OLS
  issueTypeName: {Epic | Story}
  summary: "{summary}"
  description: "{markdown description with AC}"
  contentFormat: "markdown"
  parent: "{parent key}"
```

### Updating items

Fetch the current description first, then merge changes:

```
editJiraIssue:
  cloudId: {cloudId}
  issueIdOrKey: "{issue key}"
  fields:
    description: "{updated markdown}"
  contentFormat: "markdown"
```

Preserve any content in the existing description that is not
being replaced. Append new AC, update changed sections, do
not remove sections the spec didn't touch.

### Description format

Use markdown with this structure:

```markdown
## User Story

As a {persona}, I want {goal} so that {benefit}.

## Description

{Context, background, technical detail from the spec.}

## Acceptance Criteria

- {AC 1}
- {AC 2}

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

Consider whether the split produces enough scope and
cohesion to warrant a **new sibling Epic**. If the original
parent is already an Epic and the split stories form a
distinct workstream, create a new Epic as a sibling.
Otherwise, keep the smaller stories under the same parent.

### 8b. Present split for approval

```
Story OLS-1002 estimated at 8 SP — splitting:

| # | Summary                    | Parent   |
|---|----------------------------|----------|
| 1 | {sub-story 1}              | OLS-2001 |
| 2 | {sub-story 2}              | OLS-2001 |
| 3 | {sub-story 3}              | OLS-2002 (new Epic) |

Options:
  approve — create the split
  revise  — tell me what to change
```

**Wait for user approval.**

### 8c. Execute the split

1. Create new Epic (if proposed) via `createJiraIssue`
2. Create the smaller stories via `createJiraIssue`
3. Close or update the original oversized story — add a
   comment noting it was split, link to the new stories
4. Re-run `/estimate-story` and `/estimate-risk` on the new
   stories
5. Re-run `/estimate-epic` on all affected Epics

## Step 9: Report

Print a summary table of everything created and updated:

```
## Summary

| Key      | Type  | Summary              | SP | Risk | Status  |
|----------|-------|----------------------|----|------|---------|
| OLS-2001 | Epic  | {summary}            | —  | —    | Created |
| OLS-1001 | Story | {summary}            | 3  | 2    | Created |
| OLS-1002 | Story | {summary}            | 2  | 1    | Created |
| OLS-1234 | Story | {summary}            | 3  | 2    | Updated |

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
  not create orphan stories.
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
