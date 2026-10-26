# Isolated skill execution tests

Run from the OLS workspace root using the installed Pi SDK and configured credentials:

```sh
node .pi/tests/skill-execution.mjs --baseline  # existing .claude skills
node .pi/tests/skill-execution.mjs             # .pi/skills wrappers
```

Tested with Pi SDK **1.3.0**, Node.js, and npm. The runner resolves a locally installed `@earendil-works/pi-coding-agent` package first, then the global npm installation via `npm root --global`. For a non-npm installation, set `PI_SKILL_TEST_SDK` to the absolute SDK entry file (`dist/index.js`); required exports are validated before execution. No dependencies are installed automatically.

Requires configured `openai/gpt-6.1-sol` (or `PI_PROVIDER` for the same model ID). Calls the real model; may incur model costs. No Jira service or live shell tool is registered. A mock `bash` records and rejects every command without executing it; git-pull attempts fail dry-run assertions. The SDK resource loader is replaced, preventing global/project extension discovery. All `read` and `atlassian_*` tools are deterministic in-memory mocks. The host reads SDK credential/model configuration and fixture source files, and may run `npm root --global` to locate the SDK. There is no git command, including dry-run pull. Human-gated mock writes are rejected before the harness sends an explicit approval follow-up.

Scenarios:
- Story: read actual story-point rubric, fetch unpointed typo story, update only SP and comment.
- Risk: read actual risk rubric, update only risk and comment.
- Epic: 102 children across two token pages, 15 total SP, S option 12588, one missing-SP warning.
- Creation: provided spec change and confirmed Epic; propose work/test coverage without writes, approve in follow-up, create with parent/testing/spec reference, transition and verify.
- Triage: single bug, mocked index and actual spec read, draft evidence and wait; follow-up approval posts comment and transitions to Refinement.
- Existing SP and existing risk: ask to re-estimate/re-assess or skip, with no write. Issue reads return only explicitly requested fields; default reads omit custom fields, matching Jira's tool default.
- All five skills with `--dry-run`: no writes, including after workflow approval; no attempted `git pull` through the recording shell mock.
- Transitions use fixture IDs 19/47 and `to.name`; hardcoded transition 31 is rejected. Creation also requires actual nested SP and risk writes.

Model behavior is intentionally not scripted. Assertions inspect actual tool calls and assistant output. Failures are reported, not automatically patched or treated as success. Each scenario has a three-minute abort timer. JSON transcripts and summary are in ignored `results/`; baseline summary is `/tmp/ols-skill-baseline.json`. The fixture is intentionally small and does not prove every branch of these workflows.
