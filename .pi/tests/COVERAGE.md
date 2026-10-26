# Execution evidence

Model: configured `openai/gpt-6.1-sol`, actual SDK model transport.

Verified wrapper run (followed by a separately rerun source baseline): **12 scenarios, 61 assertions, 0 failures**. See ignored `results/summary.json` and per-scenario JSON transcripts. `node --check .pi/tests/skill-execution.mjs` also passed.

| Skill | Normal execution | Dry-run | Extra regression |
|---|---|---|---|
| estimate-story | Rubric read; SP-only edit; comment | No mutation | Existing SP requires question, with realistic default field projection |
| estimate-risk | Rubric read; risk-only edit; comment | No mutation | Existing risk requires question |
| estimate-epic | 102 children, pagination, 15 SP → S, missing-SP warning | No mutation | Two token pages; fixed option ID |
| make-jira-from-spec | Human gate; approved creation with parent/testing/spec reference; dynamic transition + verification; real nested SP/risk writes and affected Epic sizing | Approval cannot authorize writes | Mock rejects hardcoded transition 31 |
| triage-new-bugs | Actual spec read/evidence; human gate; approved comment + Refinement | Approval cannot authorize writes or attempted git pull | Mock shell records and rejects commands |

Strict source baseline `/tmp/ols-skill-baseline.json` reproduced failures in existing-SP protection (default issue fields omit custom fields), hardcoded creation transition, missing nested estimates, make-jira dry-run writes after approval, and triage dry-run git-pull attempts. Standalone happy paths passed because the model inferred native tool names; no claim that source names alone always prevent execution.

All tools are fixtures. Only model transport is real. Host assertions examine model-generated calls, not scripted estimates. Fixtures are reproducible; model sampling is not guaranteed deterministic. Workflows are invoked using the real skill file contents and absolute file location, rather than testing Pi's interactive command discovery. This suite does not exercise every risk/point rubric branch, splits, Feature Request inheritance, or every triage classification.
