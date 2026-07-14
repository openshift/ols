---
name: triage-new-bugs
description: >
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
only that bug. The human approval gate still applies — do not post anything
without explicit approval.

## Step 1: Sync Repos

Pull all repos in the workspace to ensure the spec is at latest. Only attempt
pull on directories that are git repos:

```bash
for repo in */; do
  if git -C "$repo" rev-parse --git-dir > /dev/null 2>&1; then
    result=$(git -C "$repo" pull --ff-only 2>&1)
    if [ $? -ne 0 ]; then
      echo "Warning: could not pull $repo — $result"
    else
      echo "OK: $repo"
    fi
  fi
done
```

Surface all warnings to the user. Continue even if some repos fail to pull,
but note which repos may have stale spec content.

## Step 2: Read the Spec Map

Do NOT read all spec files upfront — that would exceed usable context.

Instead, read only the spec index files to build a map of what each spec covers:

```bash
find . -path "*/.ai/spec/how/repo-map.md" -o \
       -path "*/.ai/spec/README.md" | sort
```

Read all discovered index files. This gives you a map of:
- Which spec files exist per repo
- What each spec file covers (from repo-map entries)
- Which repos and components own which concerns

Hold this map in context. You will read individual spec files on demand in
Step 5, not upfront.

## Step 3: Fetch New Bugs

Use `searchJiraIssuesUsingJql`:

```
cloudId: redhat.atlassian.net
jql: project = OLS AND issuetype = Bug AND status = New
fields: [summary, description, components, labels]
maxResults: 100
```

**Cap:** This fetches at most 100 bugs. If the result count equals 100, warn
the user that there may be more bugs not included in this run.

### Idempotency check

Before analyzing, filter out any bugs that are already triaged. Skip a bug if:
- It already has an `AI triage:` comment (check via `getJiraIssue` with
  `fields: ["comment"]` for any bug where labels suggest prior triage), OR
- It already has a `needs-spec-change` label

Report skipped bugs to the user.

## Step 4: Resolve Transition IDs

Call `getTransitionsForJiraIssue` on any one bug to resolve the transition IDs
for `Backlog` and `Refinement` in this project. Cache the IDs for Step 8.

If either transition name is not found, warn the user and skip transitions
for that classification — do not abort the run.

## Step 5: Classify Each Bug

For each bug, apply this sequence:

### 5a. Identify relevant spec files

From your spec map, determine which spec files are relevant to this bug based
on its summary, description, and components. Read only those files.

If the bug's area is unclear from the map, read the most likely candidate spec
file and check.

### 5b. Apply the three-criterion test

| Criterion | Classification | Jira action |
|-----------|---------------|-------------|
| Reported behavior contradicts a **defined rule** in a spec file | **needs-spec-change** | Comment + labels + transition to **Backlog** |
| Bug describes behavior that **should be specced** (architectural, cross-component, or contract-level) but is absent from all spec files | **needs-spec-change** | Comment + labels + transition to **Backlog** |
| Fix would require changing a **cross-repo contract, API shape, or CRD** defined in spec | **needs-spec-change** | Comment + labels + transition to **Backlog** |
| Description too vague to evaluate any criterion | **needinfo** | Comment only — stays in **New** |
| None of the above | **no-spec-change-needed** | Brief comment + transition to **Refinement** |

**Important — criterion 2 scope:** "Should be specced" means architectural
behavior, integration contracts between repos, or observable product behavior.
It does NOT apply to every unspecced implementation detail. If the behavior
is internal to a single component and the fix is a localized code change with
no broader behavioral implications, criterion 2 does not apply. When in doubt
between criterion 2 and `no-spec-change-needed`, prefer `no-spec-change-needed`
and explain why in the reasoning.

**Empty description:** A bug has no description if its `description` field is
`null`, empty string, or contains only whitespace. Classify as **needinfo**.

### 5c. Scope gauge (needs-spec-change only)

For every **needs-spec-change** bug, also gauge the scope of the spec change
required and assign exactly one additional label:

| Label | When to use |
|-------|-------------|
| `ols-team` | Broad or architectural — touches multiple spec files or repos, cross-repo contracts, or requires team-wide alignment before the spec can be written |
| `subteam` | Localized — touches one or two spec files within a single repo; a small number of people familiar with that area can write the spec update |

### 5d. Draft comments

Draft a comment for every bug. Format:

**needs-spec-change:**
> AI triage: This bug requires a spec update. [State which criterion applies
> and what the conflict or gap is.] The relevant spec is
> `[repo]/.ai/spec/[file]`. Flagging for spec review before implementation
> begins.

**needinfo:**
> AI triage: This bug report lacks sufficient detail to determine whether a
> spec change is needed. Missing: [list specific gaps — expected vs actual
> behavior, reproduction steps, affected version, component]. Please add this
> information so the bug can be properly triaged.

**no-spec-change-needed:**
> AI triage: No spec change required. [One sentence explaining why — e.g.,
> "The spec correctly defines this behavior; the issue is a localized
> implementation error."] Transitioning to Refinement for implementation.

## Step 6: Present Report

Show the full analysis before touching Jira:

```
## Bug Triage — New OLS Bugs (N total, M skipped as already triaged)

### Needs Spec Change (X bugs) → Backlog + labels
| Key | Summary | Criterion triggered | Scope | Relevant spec |
|-----|---------|--------------------| ------|---------------|
| OLS-1234 | ... | Contradicts rule in ... | ols-team | repo/.ai/spec/... |

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

Draft comment for OLS-1236:
> [full draft comment text]

---
Options:
  approve     — apply all actions (comments + labels + transitions) as shown
  revise X    — change the draft comment for OLS-XXXX
  skip X      — drop OLS-XXXX from all actions
  stop        — cancel without touching Jira
```

**Wait for the user.** Do NOT touch Jira before explicit approval.

## Step 7: Human Gate

Wait for the user to respond. Only proceed once the user explicitly approves.

## Step 8: Apply Actions

Process bugs sequentially — one at a time. Do not batch concurrent API calls.

For each approved bug:

### needs-spec-change

1. Post comment via `addCommentToJiraIssue`
2. Fetch current labels (`getJiraIssue` with `fields: ["labels"]`), then set
   the merged label list via `editJiraIssue` — pass the **complete** list of
   existing labels plus `needs-spec-change` and the scope label:
   ```
   editJiraIssue:
     fields:
       labels: [<all existing labels>, "needs-spec-change", "<ols-team|subteam>"]
   ```
3. Transition to Backlog via `transitionJiraIssue`

If the Backlog transition fails (e.g., transition ID not valid for this bug),
log the failure, skip the transition for that bug, and continue.

### needinfo

Post comment only — do NOT transition or add labels.

### no-spec-change-needed

1. Post brief comment via `addCommentToJiraIssue`
2. Transition to Refinement via `transitionJiraIssue`

If the Refinement transition fails, log the failure, skip the transition for
that bug, and continue.

### Summary

Print a summary table when done:

```
| Key | Classification | Comment | Labels added | Transitioned to |
|-----|---------------|---------|--------------|-----------------|
| OLS-1234 | needs-spec-change | yes | needs-spec-change, ols-team | Backlog |
| OLS-1235 | needinfo | yes | (none) | (none) |
| OLS-1236 | no-spec-change-needed | yes | (none) | Refinement |
```

Note any failures (transition errors, label errors) in the summary.

## Constraints

- Human gate is mandatory — there is no force or auto flag
- If no new bugs are found, report that and exit cleanly
- If a repo or spec file is unreadable, warn and continue — do not abort
- Never post comments or apply transitions without explicit user approval
- Process bugs sequentially in Step 8 — do not fire concurrent Jira API calls
