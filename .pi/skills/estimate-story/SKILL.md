---
name: estimate-story
description: Use when estimating OLS Jira story points in Pi, including Bugs, Tasks, Weaknesses and Vulnerabilities, or previewing estimates with --dry-run.
---

# Estimate story points in Pi

1. Read `../references/runtime.md`, relative to this skill directory, for the Pi runtime adapter.
2. Read `../../../.claude/skills/estimate-story/SKILL.md`, relative to this skill directory, for the original workflow.
3. Execute that workflow using the adapter's native tools, workspace-root rubric paths, explicit story-point field fetch and existing-estimate confirmation gate.

Forward all invocation arguments, including issue keys and `--dry-run`. The adapter takes precedence over conflicting source mechanics. No issue keys: ask Josh. Never treat dry-run approval as permission for live writes.
