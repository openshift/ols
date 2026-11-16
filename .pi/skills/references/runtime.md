# OLS skills: Pi runtime adapter

This adapter applies to all five OLS Pi wrappers. Read the original Claude skill
named by the wrapper and follow its workflow and rubric. Where the source uses
Claude-specific mechanics or conflicts with this adapter, apply this adapter.
Do not change point scales, risk policy, size thresholds, or human approval gates.

## Paths and skill invocation

The workspace root is the directory containing `.pi` and `.claude`. Derive it
from the wrapper's absolute path (three parents above its skill directory), not
from the current working directory. Source instructions live at
`<root>/.claude/skills/<name>/SKILL.md`; rubrics live at
`<root>/story-point-rubric.md` and `<root>/risk-level-rubric.md`.
Spec paths are relative to that root. Resolve them explicitly before reading.

Pi commands are `/skill:estimate-story`, `/skill:estimate-risk`,
`/skill:estimate-epic`, `/skill:make-jira-from-spec`, `/skill:triage-new-bugs`.
A source instruction to invoke `/estimate-*` means read the corresponding Pi
wrapper and execute its instructions inline with the listed issue keys.
Do not run slash commands in bash or rely on a Claude Skill tool.
For `superpowers:brainstorming`, read the advertised brainstorming skill and use
chat-only decomposition. Jira decomposition is not a request to author or commit
a design, push a branch, or open a PR. Ask Josh about unresolved scope choices.

## Native tools

Use the tools exposed by this Pi session. Both Claude prefixes
`mcp__plugin_atlassian_atlassian__` and `mcp__atlassian__`, and unqualified
Atlassian operation names, map to native `atlassian_<operation>` tools:

| Source operation | Pi tool |
| --- | --- |
| getJiraIssue | atlassian_getJiraIssue |
| editJiraIssue | atlassian_editJiraIssue |
| createJiraIssue | atlassian_createJiraIssue |
| addCommentToJiraIssue | atlassian_addCommentToJiraIssue |
| searchJiraIssuesUsingJql | atlassian_searchJiraIssuesUsingJql |
| getTransitionsForJiraIssue | atlassian_getTransitionsForJiraIssue |
| transitionJiraIssue | atlassian_transitionJiraIssue |
| getAccessibleAtlassianResources | atlassian_getAccessibleAtlassianResources |
| createIssueLink | atlassian_createIssueLink |
| getIssueLinkTypes | atlassian_getIssueLinkTypes |

Use `read` for files and `bash` only for permitted shell operations. Never invent
a missing tool or claim an action succeeded without its result. If a required
tool is absent, explain the blocker. No model-specific tools or Opus dependency
are required. Use the configured model; do not silently switch models.

Use `redhat.atlassian.net` as cloudId first. If the tool rejects that identifier,
use accessible resources to resolve the site's UUID. Use markdown contentFormat
and responseContentFormat where supported. Put custom creation fields and labels
in `additional_fields`; edits use `fields`.

Use Rovo `atlassian_search` for free-form Jira/Confluence discovery unless JQL is
explicitly part of the request/workflow. The source skills explicitly prescribe
JQL for their structured searches, so use the JQL tool for those queries.

## Dry run: an execution contract

If arguments contain `--dry-run`, or Josh requests a preview/read-only run, apply
this contract throughout this workflow and every nested skill:

1. Read local rubrics/specs and permitted Jira data, or supplied fixtures.
2. Compute estimates/classifications and draft intended requests normally.
3. Present a **DRY RUN — not applied** report with proposed field values,
   comments, links, creation payloads, transitions, and any unresolved choices.
4. Do not call Jira mutation tools (create/edit/comment/transition/link/worklog),
   even if the next message says `approve`. Approval does not exit dry-run mode;
   require an explicit request for a new live execution.
5. Do not pull/fetch repos, edit files, commit, push, open PRs, or invoke shell
   operations that change the workspace. Triage's sync step is skipped: warn
   that local specs may be stale. Read-only git status/diff/show is permitted.
6. For items that do not yet exist, show placeholders for keys and describe
   follow-on estimation; do not invent Jira keys or claim transitions occurred.

Dry-run with live read tools is a read-only preview, not a mock test. Isolated
acceptance tests instead expose only fixture-backed tools; mocked writes test
normal execution and approval flow without reaching Jira.

## Fields and complete results

Default get-issue fields exclude custom fields. Explicitly fetch:

- Story estimates: `summary`, `description`, `components`, `labels`, `issuetype`,
  `customfield_10028`. A non-null value (including zero) requires the source's
  re-estimate-or-skip confirmation before any mutation.
- Risk: the source's fields including `customfield_10976`; retain the same gate.
- Epic targets: `summary`, `issuetype`, `customfield_10795`. Check the issue is
  an Epic before computing its size; otherwise report and skip.
- Make-jira starting context: `summary`, `description`, `issuetype`, `parent`,
  `labels`, `status`. For a Story input, resolve its Epic and confirm the intended
  parent/scope with Josh; never silently reinterpret the input.
- Immediately before updating descriptions/labels: fetch `description`, `labels`
  and merge without losing unrelated content or labels.

For JQL, follow every returned `nextPageToken` until complete before summing
Epic points or matching children. Do not use `startAt` or request unnecessary
counts. Paginate unsized-Epic discovery and Feature-child searches as well.
Keep triage's intentional 100-bug cap and warn when the cap/token indicates more.
Keyword Epic discovery is a candidate list, not proof of exhaustive absence.

For triage, call `atlassian_getJiraIssue` with `fields: ["comment"]` for each
candidate before drafting and inspect `fields.comment.comments`, including bugs
with no special labels; prior needinfo comments may be unlabeled.
If the returned history is incomplete, disclose that idempotency cannot be
verified and ask before posting a potentially duplicate comment. Respect the
existing `needs-spec-change` label skip. Read actual spec passages as required.

## Workflow and approval details

Invoking a standalone estimate requests its normal field/comment updates unless
in dry-run mode; existing SP/Risk still requires re-estimate/reassess approval.
Make-jira and triage must show proposed actions and await explicit approval
before **any** mutation, including estimates, comments, links or transitions.
Selecting a parent does not approve execution. Splits require separate approval.
Preserve all test-coverage gates, label inheritance, and sequential triage writes.
Top-level Epic creation omits `parent`; never send a placeholder or empty string.
The make-jira scoped-search constraint applies to child matching after parent
selection; Step 3's explicit project-level Epic discovery remains allowed.

Resolve transitions for each issue at its current status with
`atlassian_getTransitionsForJiraIssue`. Match the intended destination by
`to.name` (or the transition name if destination metadata is absent), and use
that returned ID. Do not assume ID `31` or reuse another issue's transitions.
For make-jira, transition each created item immediately to Refinement, read
`status` to verify, and allow at most two attempts total; report failures.
Triage skips unavailable transitions with a warning and continues sequentially.
Show the original story's proposed disposition during split approval; do not
invent closure transitions. Fetch link types when creating issue links.

After make-jira creates/updates approved items, read and execute the Pi estimate
wrappers for every affected Story and Epic, forwarding dry-run mode. Existing
estimates still trigger their confirmation gates. Do not claim all items were
estimated if a gate or unavailable tool prevented it.

## Automation boundary

These wrappers replace manual Claude skill invocation, not Claude Code hooks.
The make-jira workflow explicitly invokes its estimation steps. Creating an issue
outside these workflows does not automatically trigger Pi estimation. Do not
claim a Claude PostToolUse hook is installed or active in Pi.
