---
name: estimate-risk
description: >
  Assess risk level (1/2/3) for OLS Jira stories using the team's risk rubric.
  Fetches the story, applies the decision tree, sets the Risk Score field, and
  adds the assessment as a comment. Use for on-demand assessment or
  after creating a new story.
argument-hint: "OLS-1234 [OLS-1235 ...]"
---

# Assess Risk Level for OLS Stories

## Overview

Assess the risk level for one or more OLS Jira stories using the team's
risk rubric. After assessing, set the Risk Score field and add a risk
assessment comment.

## Usage

```
/estimate-risk OLS-1234
/estimate-risk OLS-1234 OLS-1235 OLS-1236
```

Also invoked automatically after creating a new OLS story.
Works for Stories, Bugs, Tasks, Weaknesses, and Vulnerabilities.

## Rubric Location

Read the full rubric from the OLS repo root: `risk-level-rubric.md`

You MUST read this file before assessing. It contains:
- Risk level definitions (1, 2, 3) with customer impact and review requirements
- Classification examples by change type
- Decision tree for determining risk level
- Edge cases (cross-repo, CVEs, spikes, feature flags)

## Workflow

### Step 1: Read the rubric

```
Read risk-level-rubric.md
```

### Step 2: Parse story keys from arguments

Extract all `OLS-XXXX` keys from the skill arguments. If no arguments
provided, ask the user for story key(s).

### Step 3: For each story

#### 3a. Fetch the story from Jira

Use `mcp__atlassian__getJiraIssue` with:
- `cloudId`: `redhat.atlassian.net`
- `issueIdOrKey`: the story key
- `fields`: `["summary", "description", "components", "labels", "issuetype", "customfield_10976"]`
- `responseContentFormat`: `markdown`

Extract: summary, description, components, labels, current Risk Score value.

If Risk Score is already set, tell the user the current value and ask
whether to re-assess or skip.

#### 3b. Apply the rubric

Using the rubric you read in Step 1:

1. **Read the summary and description** — identify what kind of change this is
2. **Walk the decision tree:**
   - External contract change? → Risk 3
   - User-visible behavior change? → Risk 3
   - Internal logic change? → Risk 2
   - Mechanical/cosmetic change? → Risk 1
3. **Check classification examples** — match the change type to the table
4. **Check edge cases** — cross-repo, CVE, spike, feature flag
5. **When in doubt, bias UP** — Risk 2 → Risk 3 is safer than the reverse

#### 3c. Set Risk Score on the Jira issue

Use `mcp__atlassian__editJiraIssue` with:
- `cloudId`: `redhat.atlassian.net`
- `issueIdOrKey`: the story key
- `fields`: `{"customfield_10976": <risk_level>}`

Where `<risk_level>` is 1, 2, or 3.

#### 3d. Add risk assessment comment

Use `mcp__plugin_atlassian_atlassian__addCommentToJiraIssue` with:
- `cloudId`: `redhat.atlassian.net`
- `issueIdOrKey`: the story key
- `contentFormat`: `markdown`
- `commentBody`: `**AI Risk Assessment:** Risk {1|2|3} — {one-line impact summary}\nRationale: {why this classification, referencing the rubric}`

Do NOT modify the description field.

### Step 4: Report to user

For each story, report:
- Story key and summary
- Risk level and one-line rationale

## Jira Field Reference

- **Risk Score field**: `customfield_10976` (number, float — set to 1, 2, or 3)
- **Cloud ID**: `redhat.atlassian.net`
- **Project**: `OLS`
- **Scale**: 1 (low), 2 (medium), 3 (high)
