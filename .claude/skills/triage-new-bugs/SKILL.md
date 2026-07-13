---
name: triage-new-bugs
description: >-
  Use when triaging new OLS Jira bugs to determine which ones require a spec
  update, which need more information, and which are pure implementation issues.
  Fetches all New-status bugs, analyzes them against the current .ai/spec/
  landscape, and presents a report with draft comments for human approval.
argument-hint: "[OLS-XXXX]"
---

# Triage New OLS Bugs

Fetch all `New` OLS Jira bugs, analyze each against the current `.ai/spec/`
files, classify each one, and present a report with draft Jira comments for
human approval before posting anything.

## Defaults

| Setting | Value |
|---------|-------|
| Project | `OLS` |
| Cloud ID | `redhat.atlassian.net` |
| Content format | `markdown` |
| JQL | `project = OLS AND issuetype = Bug AND status = New` |

## Single-Bug Test Mode

If an `OLS-XXXX` key is passed as an argument, skip the JQL fetch and analyze
only that bug. Useful for tuning the analysis against a known case.

## Step 1: Sync Repos

Pull all repos in the workspace to ensure the spec is at latest:

```bash
for repo in */; do
  git -C "$repo" pull --ff-only 2>/dev/null || echo "Warning: could not pull $repo"
done
```

Warn if any repo fails; continue with the rest.

## Step 2: Read the Spec Landscape

Read all `.ai/spec/` files across every repo in the workspace. Build an
internal map of:

- What each spec file covers (behaviors, contracts, rules)
- Which repos and components it touches
- Cross-repo integration contracts and API shapes

Do this **once** before analyzing any bugs. Do not re-read spec files per bug.

## Step 3: Fetch New Bugs

Use `searchJiraIssuesUsingJql`:

```
cloudId: redhat.atlassian.net
jql: project = OLS AND issuetype = Bug AND status = New
fields: [summary, description, components, labels]
maxResults: 100
```

## Step 4: Resolve Transition IDs

Before classifying bugs, call `getTransitionsForJiraIssue` on the first bug in
the set (or any `OLS` bug) to resolve the transition IDs for **Backlog** and
**Refinement** in this project. Cache the IDs for use in Step 7.

```
getTransitionsForJiraIssue:
  cloudId: redhat.atlassian.net
  issueIdOrKey: <first bug key>
```

Extract the numeric IDs for transitions named `Backlog` and `Refinement`.

## Step 5: Classify Each Bug

For each bug, apply the three-criterion test against the spec map:

| Criterion | Classification | Jira action |
|-----------|---------------|-------------|
| Reported behavior contradicts a defined rule in any spec file | **needs-spec-change** | Comment + transition to **Backlog** |
| Bug describes behavior (expected or actual) not addressed in any spec | **needs-spec-change** | Comment + transition to **Backlog** |
| Fixing the bug would require changing a cross-repo contract, API shape, or CRD | **needs-spec-change** | Comment + transition to **Backlog** |
| Description too vague to evaluate any criterion above | **needinfo** | Comment only — stays in **New** |
| None of the above — clear implementation error, spec is correct | **no-spec-change-needed** | Transition to **Refinement** (no comment) |

For bugs with **no description**, classify automatically as **needinfo**.

Draft a comment for every **needs-spec-change** and **needinfo** bug.

### Comment Templates

**needs-spec-change:**
> AI triage: This bug appears to require a spec update. [State which criterion
> applies and what the conflict or gap is.] The relevant spec is
> `[repo]/.ai/spec/[file]`. Flagging for spec review before implementation
> begins.

**needinfo:**
> AI triage: This bug report lacks sufficient detail to determine whether a
> spec change is needed. Missing: [list specific gaps, e.g. expected vs actual
> behavior, reproduction steps, affected version, component]. Please add this
> information so the bug can be properly triaged.

## Step 6: Present Report

Show the full analysis before touching Jira:

```
## Bug Triage — New OLS Bugs (N total)

### Needs Spec Change (X bugs) → Backlog
| Key | Summary | Criterion triggered | Relevant spec |
|-----|---------|--------------------| --------------|
| OLS-1234 | ... | Contradicts rule in ... | repo/.ai/spec/... |

Draft comment for OLS-1234:
> [full draft comment text]

---

### Needinfo (Y bugs) → stays New
| Key | Summary | What's missing |
|-----|---------|----------------|
| OLS-1235 | ... | Expected vs actual behavior not described |

Draft comment for OLS-1235:
> [full draft comment text]

---

### No Spec Change Needed (Z bugs) → Refinement
| Key | Summary | Reason |
|-----|---------|--------|
| OLS-1236 | ... | Implementation error; spec correctly defines behavior |

---
Options:
  approve     — apply all actions (comments + transitions) as shown
  revise X    — change the draft comment for OLS-XXXX
  skip X      — drop OLS-XXXX from all actions
  stop        — cancel without touching Jira
```

**Wait for the user.** Do NOT touch Jira before explicit approval.

## Step 7: Apply Actions

For each approved issue, execute in order: comment first (if applicable), then transition.

### needs-spec-change

Post comment via `addCommentToJiraIssue`, then transition to Backlog:

```
addCommentToJiraIssue:
  cloudId: redhat.atlassian.net
  issueIdOrKey: OLS-XXXX
  commentBody: [draft comment]
  contentFormat: markdown

transitionJiraIssue:
  cloudId: redhat.atlassian.net
  issueIdOrKey: OLS-XXXX
  transition:
    id: "<Backlog transition ID from Step 4>"
```

### needinfo

Post comment only — do NOT transition:

```
addCommentToJiraIssue:
  cloudId: redhat.atlassian.net
  issueIdOrKey: OLS-XXXX
  commentBody: [draft comment]
  contentFormat: markdown
```

### no-spec-change-needed

Transition to Refinement only — do NOT post a comment:

```
transitionJiraIssue:
  cloudId: redhat.atlassian.net
  issueIdOrKey: OLS-XXXX
  transition:
    id: "<Refinement transition ID from Step 4>"
```

Print a summary table of all actions taken:

```
| Key | Classification | Comment posted | Transitioned to |
|-----|---------------|----------------|-----------------|
| OLS-1234 | needs-spec-change | yes | Backlog |
| OLS-1235 | needinfo | yes | (none) |
| OLS-1236 | no-spec-change-needed | no | Refinement |
```

## Constraints

- Human gate is mandatory — there is no force or auto flag
- If no new bugs are found, report that and exit cleanly
- If a repo or spec file is unreadable, warn and continue — do not abort
- Never post comments without explicit user approval
