---
name: estimate-story
description: >
  Estimate story points for OLS Jira stories using the calibrated rubric
  derived from 300 completed stories. Fetches the story, applies the decision
  tree, sets the SP field, and adds the estimate as a comment.
  Use for on-demand estimation or after creating a new story.
argument-hint: "OLS-1234 [OLS-1235 ...]"
---

# Estimate Story Points for OLS Stories

## Overview

Estimate story points for one or more OLS Jira stories using the team's
calibrated rubric. After estimating, set the story points field and add
an estimation comment.

## Usage

```
/estimate-story OLS-1234
/estimate-story OLS-1234 OLS-1235 OLS-1236
```

Also invoked automatically after creating a new OLS story.
Works for Stories, Bugs, Tasks, Weaknesses, and Vulnerabilities.

## Rubric Location

Read the full rubric from: `story-point-rubric.md` (in the workspace root), **and the
calibration overrides** from `.claude/skills/estimate-story/story-point-rubric-overrides.md`
(these take precedence on conflict — no 0; no 1→2 push; lean 2→3; 5 only with 2+ strong
signals; no 8).

You MUST read this file before estimating. It contains:
- Point definitions (0, 0.5, 1, 2, 3, 5) with characteristics and code complexity data
- Decision tree for base estimate
- Bias corrections from blind testing
- Complexity multipliers (up/down factors)
- Component-specific guidance

## Workflow

### Step 1: Read the rubric and overrides

```
Read story-point-rubric.md
Read .claude/skills/estimate-story/story-point-rubric-overrides.md
```

The overrides file is the calibrated (v11) correction layer and **takes precedence** over
the base rubric where they conflict.

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

#### 3a-bis. Retrieve similar past stories (RAG)

Pull the 5 most similar *completed, human-pointed* stories (with their actual story points)
from the historical corpus:

```
python3 .claude/skills/estimate-story/retrieve_neighbors.py --summary "<summary>" --description "<description>"
```

This prints a JSON list of `{key, summary, sp, sim}` (sim = 0-1 text similarity) and adds no
LLM tokens beyond that small list. Use it as an anchor in 3b:
- Near-duplicate (`sim` > 0.7) → strong evidence the SP matches; weight heavily.
- Genuinely similar neighbors (`sim` > 0.4) that agree → a solid anchor.
- Weak / scattered neighbors (low `sim`) → ignore; rely on the rubric + overrides.
- Never let a small-SP neighbor drag down a story that clearly shows large-scope signals
  (overrides C/D).

#### 3b. Apply the rubric

Using the rubric, the overrides, and the retrieved neighbors:

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

Do NOT update the description field. Only set the story points field.

#### 3d. Add estimation comment

Use `mcp__plugin_atlassian_atlassian__addCommentToJiraIssue` with:
- `cloudId`: `redhat.atlassian.net`
- `issueIdOrKey`: the story key
- `contentFormat`: `markdown`
- `commentBody`: `**AI Estimate:** X SP (confidence: high/medium/low)`

### Step 4: Report to user

For each story, report:
- Story key and summary
- Estimated SP and confidence level

Do NOT list comparable stories from history.

For low-confidence estimates, provide a range and note what would change
the estimate.

## Retrieval Corpus & Refresh Policy

The corpus is `.claude/skills/estimate-story/story-corpus.jsonl` (one row per completed,
human-pointed story: key, summary, description, components, labels, sp). Retrieval is TF-IDF
cosine in `retrieve_neighbors.py` — deterministic, no external services, regenerated from the
corpus on each run (no index to maintain).

**Refresh monthly / per-release, with one hard rule:**
- **Only add HUMAN-estimated stories.** Anything estimated by this skill (i.e. resolved after
  the AI-estimation cutoff, ~2026-05 — the end of the calibration window) must NOT be added:
  feeding the skill's own estimates back into the corpus creates a feedback loop that
  amplifies error.
- You MAY extend the corpus with OLDER human-estimated stories (before 2025-04) — more
  human-pointed data improves retrieval quality.
- Query shape: `project = OLS AND issuetype = Story AND "Story Points" is not EMPTY AND
  resolved <= "<AI cutoff>"`; fields key/summary/description/components/labels + Story Points.
  Sanitize descriptions (drop any line mentioning an AI estimate / confidence) before writing.

## Jira Field Reference

- **Story Points field**: `customfield_10028` (number, float)
- **Cloud ID**: `redhat.atlassian.net`
- **Project**: `OLS`
- **Fibonacci scale**: 0, 0.5, 1, 2, 3, 5 (8+ means split the story)
