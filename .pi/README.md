# OLS workflows in Pi

Start Pi from the OLS workspace root and grant project trust. Run `/reload` after
updating these resources. These are project resources, not global settings or
resources inherited when starting Pi inside a child repository.

```text
/skill:estimate-story OLS-1234
/skill:estimate-risk OLS-1234
/skill:estimate-epic OLS-1234
/skill:make-jira-from-spec OLS-1234
/skill:triage-new-bugs OLS-1234
```

Append `--dry-run` to preview without Jira mutations or repo synchronization:

```text
/skill:estimate-story OLS-1234 --dry-run
/skill:make-jira-from-spec OLS-1234 --dry-run
/skill:triage-new-bugs OLS-1234 --dry-run
```

Dry-run permits reads; it is not an offline sandbox. Approval does not turn a
dry-run session into live execution. Explicitly request a new live execution to
apply changes. A normal standalone estimate updates the field and posts a
comment; an existing SP/Risk value requires confirmation. Make-jira and triage
always require approval before Jira writes. Normal triage still attempts the
source workflow's repo synchronization; dry-run skips it.

## Structure

- `skills/*/SKILL.md`: thin Pi entry points, discovered natively.
- `skills/references/runtime.md`: native tool mappings, dry-run contract,
  explicit custom-field reads, pagination and per-issue transition handling.
- `../.claude/skills/*/SKILL.md`: unchanged workflow definitions.
- `../story-point-rubric.md`, `../risk-level-rubric.md`: unchanged team rubrics.

Wrappers read both the adapter and the source workflow. They do not maintain
separate copies of the estimation policy. Source edits remain shared, but should
be re-tested because the adapter deliberately overrides runtime mechanics.

Claude Code hooks are **not installed in Pi**. Make-jira invokes its estimation
steps explicitly; unrelated Jira creations do not automatically trigger them.
No model switch is required; the acceptance runner targets `gpt-6.1-sol`.

## Isolated execution tests

From the workspace root:

```bash
node .pi/tests/skill-execution.mjs
```

This invokes the configured model provider and consumes model usage. Jira and
filesystem-facing tools in the model session are fixture-backed; no live Jira
connector, real shell, or project extension is available. The test process writes
only its local result artifacts. It tests actual model tool calls, not just skill
parsing. See the test README for scenarios, baseline invocation and limitations.
