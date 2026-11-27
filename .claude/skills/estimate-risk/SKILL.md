---
name: estimate-risk
description: >
  Assess risk level (0/1/2/3) for OLS Jira stories using the team's risk rubric.
  Fetches the story, applies the decision tree, sets the Effort field, and
  adds the assessment as a comment unless --no-comment is passed. Use for
  on-demand assessment or after creating a new story.
argument-hint: "[--no-comment] OLS-1234 [OLS-1235 ...]"
disable-model-invocation: true
---

# Assess Risk Level for OLS Stories

## Overview

Assess the risk level for one or more OLS Jira stories using the team's
risk rubric. After assessing, set the Effort field and add a risk
assessment comment.

## Usage

```
/estimate-risk OLS-1234
/estimate-risk OLS-1234 OLS-1235 OLS-1236
/estimate-risk --no-comment OLS-1234 OLS-1235 OLS-1236
```

`--no-comment` sets the Effort field but skips the assessment comment.
Use it for bulk runs, where one comment per issue would flood watchers
with notifications. The rationale is then reported only in the chat
summary, so prefer the default for one-off assessments — the comment is
the only durable record of *why* a level was chosen.

Also invoked automatically after creating a new OLS story.
Works for Stories, Bugs, Tasks, Weaknesses, and Vulnerabilities.

## Rubric Location

Read the full rubric from the OLS repo root: `risk-level-rubric.md`

You MUST read this file before assessing. It contains:
- Risk level definitions (0, 1, 2, 3) with customer impact and review requirements
- Classification examples by change type
- Decision tree for determining risk level
- Preapproved task types and circuit breakers for Risk 0
- Edge cases (cross-repo, CVEs, spikes, feature flags)

## Workflow

### Step 1: Read the rubric

```
Read risk-level-rubric.md
```

### Step 2: Parse arguments

Extract all `OLS-XXXX` keys from the skill arguments. If no keys are
provided, ask the user for story key(s).

Check for the `--no-comment` flag anywhere in the arguments. When
present, skip step 3d for every story in the run. The flag is not a
story key — do not treat it as one.

### Step 3: For each story

#### 3a. Fetch the story from Jira

Use `mcp__atlassian__getJiraIssue` with:
- `cloudId`: `redhat.atlassian.net`
- `issueIdOrKey`: the story key
- `fields`: `["summary", "description", "components", "labels", "issuetype", "customfield_10637"]`
- `responseContentFormat`: `markdown`

Extract: summary, description, components, labels, current Effort value.

If Effort is already set, tell the user the current value and ask
whether to re-assess or skip.

#### 3b. Apply the rubric

Using the rubric you read in Step 1:

1. **Read the summary and description** — identify what kind of change this is
2. **Walk the decision tree:**
   - External contract change? → Risk 3
   - User-visible behavior change? → Risk 3
   - Internal logic change? → Risk 2
   - Mechanical/cosmetic change, preapproved task type? → Risk 0
   - Mechanical/cosmetic change otherwise? → Risk 1
3. **Check classification examples** — match the change type to the table
4. **Check edge cases** — cross-repo, CVE, spike, feature flag
5. **Before assigning Risk 0**, confirm the task type is on the preapproved list and that the change does not touch auth, RBAC, credential handling, or cluster state — that exclusion makes it Risk 3 regardless of task type
6. **When in doubt, bias UP** — Risk 2 → Risk 3 is safer than the reverse

#### 3c. Set Effort on the Jira issue

Use `mcp__atlassian__editJiraIssue` with:
- `cloudId`: `redhat.atlassian.net`
- `issueIdOrKey`: the story key
- `fields`: `{"customfield_10637": <risk_level>}`

Where `<risk_level>` is 0, 1, 2, or 3.

Do NOT write to the Risk Score field (`customfield_10976`). It is
maintained by a ScriptRunner job that reverts any value written to it
within seconds, so writing there has no effect.

#### 3d. Add risk assessment comment

Skip this step entirely when `--no-comment` was passed.

Use `mcp__plugin_atlassian_atlassian__addCommentToJiraIssue` with:
- `cloudId`: `redhat.atlassian.net`
- `issueIdOrKey`: the story key
- `contentFormat`: `markdown`
- `commentBody`: `**AI Risk Assessment:** Risk {0|1|2|3} — {one-line impact summary}\nRationale: {why this classification, referencing the rubric}`

Do NOT modify the description field.

### Step 4: Report to user

For each story, report:
- Story key and summary
- Risk level and one-line rationale

Under `--no-comment` this report is the only record of the rationale,
so always include it, and state in the summary that comments were
skipped.

## Jira Field Reference

- **Effort field**: `customfield_10637` (number — set to 0, 1, 2, or 3).
  This is where the risk level is stored.
- **Risk Score field**: `customfield_10976` — read-only in practice.
  ScriptRunner recomputes it on every issue update and discards anything
  written to it. Do not use it.
- **Cloud ID**: `redhat.atlassian.net`
- **Project**: `OLS`
- **Scale**: 0 (autonomous, preapproved types only), 1 (low), 2 (medium), 3 (high)
