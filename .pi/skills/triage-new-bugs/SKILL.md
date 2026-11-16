---
name: triage-new-bugs
description: Use when triaging New OLS Jira bugs against workspace specs in Pi, analyzing a specific bug, or previewing triage with --dry-run.
---

# Triage New bugs in Pi

1. Read `../references/runtime.md`, relative to this skill directory, for the Pi runtime adapter.
2. Read `../../../.claude/skills/triage-new-bugs/SKILL.md`, relative to this skill directory, for the original workflow.
3. Execute that workflow with native tools, actual spec evidence, comment idempotency checks, mandatory human approval and per-issue transition discovery.

Forward all invocation arguments, including an optional issue key and `--dry-run`. The adapter takes precedence over conflicting source mechanics. In dry-run mode skip the source's repo-pull step, warn about potentially stale specs, and report proposed actions without applying them. Never treat dry-run approval as permission for live writes.
