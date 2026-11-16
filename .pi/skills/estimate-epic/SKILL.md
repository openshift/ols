---
name: estimate-epic
description: Use when sizing specific OLS Jira Epics or all unsized open Epics in Pi, or previewing epic sizes with --dry-run.
---

# Size Epics in Pi

1. Read `../references/runtime.md`, relative to this skill directory, for the Pi runtime adapter.
2. Read `../../../.claude/skills/estimate-epic/SKILL.md`, relative to this skill directory, for the original workflow.
3. Execute that workflow using the adapter's native tools, Epic validation and token-based pagination before summing points.

Forward all invocation arguments, including issue keys and `--dry-run`. The adapter takes precedence over conflicting source mechanics. No issue keys means all unsized open Epics, as in the source workflow. Never treat dry-run approval as permission for live writes.
