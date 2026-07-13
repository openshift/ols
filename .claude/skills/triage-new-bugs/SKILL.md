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

## Step 4: Classify Each Bug

For each bug, apply the three-criterion test against the spec map:

| Criterion | Classification |
|-----------|---------------|
| Reported behavior contradicts a defined rule in any spec file | **needs-spec-change** |
| Bug describes behavior (expected or actual) not addressed in any spec | **needs-spec-change** |
| Fixing the bug would require changing a cross-repo contract, API shape, or CRD | **needs-spec-change** |
| Description too vague to evaluate any criterion above | **needinfo** |
| None of the above — clear implementation error, spec is correct | **no-spec-change-needed** |

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

## Step 5: Present Report

Show the full analysis before touching Jira:

```
## Bug Triage — New OLS Bugs (N total)

### Needs Spec Change (X bugs)
| Key | Summary | Criterion triggered | Relevant spec |
|-----|---------|--------------------| --------------|
| OLS-1234 | ... | Contradicts rule in ... | repo/.ai/spec/... |

Draft comment for OLS-1234:
> [full draft comment text]

---

### Needinfo (Y bugs)
| Key | Summary | What's missing |
|-----|---------|----------------|
| OLS-1235 | ... | Expected vs actual behavior not described |

Draft comment for OLS-1235:
> [full draft comment text]

---

### No Spec Change Needed (Z bugs)
| Key | Summary | Reason |
|-----|---------|--------|
| OLS-1236 | ... | Implementation error; spec correctly defines behavior |

---
Options:
  approve     — post all draft comments as-is
  revise X    — change the draft comment for OLS-XXXX
  skip X      — drop OLS-XXXX from the posting list
  stop        — cancel without posting anything
```

**Wait for the user.** Do NOT post any comments before explicit approval.

## Step 6: Post Comments

For each approved issue, post using `addCommentToJiraIssue`:

```
cloudId: redhat.atlassian.net
issueIdOrKey: OLS-XXXX
commentBody: [draft comment]
contentFormat: markdown
```

Print a summary of what was posted.

## Constraints

- Human gate is mandatory — there is no force or auto flag
- If no new bugs are found, report that and exit cleanly
- If a repo or spec file is unreadable, warn and continue — do not abort
- Never post comments without explicit user approval
