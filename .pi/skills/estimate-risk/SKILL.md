---
name: estimate-risk
description: Use when assessing OLS Jira risk levels in Pi, including Bugs, Tasks, Weaknesses and Vulnerabilities, or previewing risk with --dry-run.
---

# Assess risk in Pi

1. Read `../references/runtime.md`, relative to this skill directory, for the Pi runtime adapter.
2. Read `../../../.claude/skills/estimate-risk/SKILL.md`, relative to this skill directory, for the original workflow.
3. Execute that workflow using the adapter's native tools, workspace-root rubric paths and existing-risk confirmation gate.

Forward all invocation arguments, including issue keys and `--dry-run`. The adapter takes precedence over conflicting source mechanics. No issue keys: ask Josh. Never treat dry-run approval as permission for live writes.
