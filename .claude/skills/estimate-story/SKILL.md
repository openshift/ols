---
name: estimate-story
description: >
  Estimate story points for OLS Jira stories using the calibrated rubric
  derived from 300 completed stories. Fetches the story, applies the decision
  tree, sets the SP field, and appends the estimate to the description.
  Use for on-demand estimation or after creating a new story.
argument-hint: "OLS-1234 [OLS-1235 ...]"
---

# Estimate Story Points for OLS Stories

## Overview

Estimate story points for one or more OLS Jira stories using the team's
calibrated rubric. After estimating, set the story points field and append
an estimation note to the description.

## Usage

```
/estimate-story OLS-1234
/estimate-story OLS-1234 OLS-1235 OLS-1236
```

Also invoked automatically after creating a new OLS story.
Works for Stories, Bugs, Tasks, Weaknesses, and Vulnerabilities.

## Rubric Location

Read the full rubric from: `/mnt/host-workspace/ols/story-point-rubric.md`

You MUST read this file before estimating. It contains:
- Point definitions (0, 0.5, 1, 2, 3, 5) with characteristics and code complexity data
- Decision tree for base estimate
- Bias corrections from blind testing
- Complexity multipliers (up/down factors)
- Component-specific guidance

## Workflow

### Step 1: Read the rubric

```
Read /mnt/host-workspace/ols/story-point-rubric.md
```

### Step 2: Parse story keys from arguments

Extract all `OLS-XXXX` keys from the skill arguments. If no arguments
provided, ask the user for story key(s).

### Step 3: For each story

#### 3a. Fetch the story from Jira

Use `mcp__plugin_atlassian_atlassian__getJiraIssue` with:
- `cloudId`: `redhat.atlassian.net`
- `issueIdOrKey`: the story key
- `responseContentFormat`: `markdown`

Extract: summary, description, components, labels, current story points value.

If story points are already set, tell the user and ask whether to re-estimate
or skip.

Note: The rubric was built from Stories but applies to all issue types that
use story points. For Weaknesses and Vulnerabilities, treat them like Bugs —
the complexity is in the investigation + fix, not the issue type label.

#### 3b. Apply the rubric

Using the rubric you read in Step 1:

1. **Identify work type** — new feature, removal, refactor, test, spike, UI, operator, doc, CI, etc.
2. **Count acceptance criteria** — more criteria generally means more points
3. **Check for cross-cutting concerns** — cross-repo, multi-component, external systems
4. **Apply the decision tree** to get a base estimate
5. **Apply bias corrections**:
   - Vague/sparse descriptions → bias UP, not down
   - External system integration → add 1 point
   - "Integrate external library" → add 1 point
   - "Investigate and fix" tasks → 2 minimum, 3 if "across" anything
   - "Setup job following existing pattern" → often 2-3, not 1
6. **Apply complexity multipliers** (up/down factors from rubric)
7. **Determine confidence level**:
   - **High**: clear AC, specific file paths, established patterns
   - **Medium**: has AC but implementation details are ambiguous
   - **Low**: vague, no AC, spike-like scope

#### 3c. Set story points on the Jira issue

Use `mcp__plugin_atlassian_atlassian__editJiraIssue` with:
- `cloudId`: `redhat.atlassian.net`
- `issueIdOrKey`: the story key
- `fields`: `{"customfield_10028": <estimated_points>}`

#### 3d. Append estimation note to description

Use `mcp__plugin_atlassian_atlassian__editJiraIssue` to update the description.
Fetch the current description first, then append at the bottom:

```
---
**AI Estimate:** X SP (confidence: high/medium/low)
```

Use `contentFormat: "markdown"` for the edit.

If the description already has an `**AI Estimate:**` line, replace it rather
than adding a duplicate.

### Step 4: Report to user

For each story, report:
- Story key and summary
- Estimated SP and confidence level

Do NOT list comparable stories from history.

For low-confidence estimates, provide a range and note what would change
the estimate.

## Jira Field Reference

- **Story Points field**: `customfield_10028` (number, float)
- **Cloud ID**: `redhat.atlassian.net`
- **Project**: `OLS`
- **Fibonacci scale**: 0, 0.5, 1, 2, 3, 5 (8+ means split the story)
