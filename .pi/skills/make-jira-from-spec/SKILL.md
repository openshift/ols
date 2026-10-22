---
name: make-jira-from-spec
description: Use when turning OLS spec changes or spec PRs into Jira Epics and Stories in Pi, updating work items from specs, or previewing that work with --dry-run.
---

# Make Jira from specs in Pi

1. Read `../references/runtime.md`, relative to this skill directory, for the Pi runtime adapter.
2. Read `../../../.claude/skills/make-jira-from-spec/SKILL.md`, relative to this skill directory, for the original workflow.
3. Execute that workflow with chat-only brainstorming, explicit parent and test-coverage gates, native tools, per-issue transition discovery and verification, and nested Pi estimation wrappers.

Forward all invocation arguments, including PR URLs, issue keys and `--dry-run`. The adapter takes precedence over conflicting source mechanics. Wait for approval before all Jira mutations; split approval is separate. Read each nested estimation wrapper rather than executing a slash command in bash. Never treat dry-run approval as permission for live writes.
