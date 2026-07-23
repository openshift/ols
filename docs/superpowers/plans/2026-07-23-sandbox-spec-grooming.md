# Agentic Sandbox Spec Grooming Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `lightspeed-agentic-sandbox` specs truthful (match code or `[PLANNED: ticket]`), kill Module Map bloat, and open a PR explaining drift + reevaluated spec-first rules.

**Architecture:** Spec-only edits in the sandbox repo. No `src/` or test changes. Decision rule C from `docs/superpowers/specs/2026-07-23-sandbox-spec-grooming-design.md`: match code for orphans; keep `[PLANNED: OLS-3515]` for templog logs.

**Tech Stack:** Markdown specs under `lightspeed-agentic-sandbox/.ai/spec/`, plus `AGENTS.md` and `ARCHITECTURE.md`. Verification via `rg` / file presence checks against `src/lightspeed_agentic/`.

## Global Constraints

- **No code:** Do not modify `src/`, `tests/`, Containerfile, lockfiles, or `pyproject.toml`.
- **Repo cwd for edits:** `/home/ometelka/projects/ols/lightspeed-agentic-sandbox`
- **Design authority:** `/home/ometelka/projects/ols/docs/superpowers/specs/2026-07-23-sandbox-spec-grooming-design.md`
- **Commit prefix:** `OLS-0000:` (no Jira for this grooming)
- **Fork PR:** Push to fork; PR against `openshift/lightspeed-agentic-sandbox` `main`

---

### Task 1: Strip Module Maps from `how/` and refresh architecture notes

**Files:**
- Modify: `.ai/spec/how/project-structure.md`
- Modify: `.ai/spec/how/provider-architecture.md`
- Modify: `.ai/spec/README.md`

- [ ] **Step 1: Rewrite `project-structure.md` without Module Map**

Replace the entire file with:

```markdown
# Project Structure

Package tree (authoritative for agents): see `AGENTS.md` Architecture section.
Do not maintain a duplicate path inventory here.

## Key Entry Points

| Entry point | How invoked |
|---|---|
| `lightspeed_agentic.app:app` | Uvicorn ASGI target (`uvicorn lightspeed_agentic.app:app --host 0.0.0.0 --port 8080`) |
| `config.resolve_sdk()` | Called once at startup in `app.py` before provider construction |
| `create_provider(sdk.name)` | Called once at module load in `app.py` with SDK name from `resolve_sdk()` |
| `build_router(provider, ...)` | Called once at module load in `app.py`, mounted at `/v1/agent` |
| `register_metrics_route(app)` | Registers `GET /metrics` on the FastAPI app |
| Lifespan `init_tracer` / `shutdown_tracer` | OTel TracerProvider setup/teardown in `app.py` |

## Naming Conventions

- **Package:** `lightspeed_agentic` under `src/` (hatchling src-layout).
- **Provider modules:** one file per provider in `providers/`, named after the SDK (`deepagents.py`, `gemini.py`, `openai.py`). Each exports a single `XProvider` class.
- **Route modules:** `routes/` contains `models.py` (Pydantic shapes), `query.py` (endpoint registration), `__init__.py` (router builder).
- **Observability modules:** `audit.py` (span events), `metrics.py` (`/metrics`), `tracing.py` (TracerProvider + traceparent).
- **Config / MCP:** `config.py` maps `LIGHTSPEED_*` → SDK env; `mcp.py` parses `LIGHTSPEED_MCP_SERVERS`.
- **Test layout:** `tests/` mirrors source structure. `tests/e2e/` holds BDD feature files and step definitions. `evals/` is a separate integration test suite run in containers.

## Dependency Organization

The project uses optional extras to gate provider SDKs:

| Extra | Packages |
|---|---|
| `deepagents` | `deepagents`, `langchain-anthropic`, `langchain-google-vertexai`, `langchain-aws`, `langchain-mcp-adapters` |
| `gemini` | `google-adk` |
| `openai` | `openai-agents` |
| `all` | All three provider extras |
| `dev` | All providers + test/lint tools |
| `eval` | Eval-specific test dependencies |
| `e2e` | BDD test dependencies |

Provider SDK imports are always lazy (inside methods or guarded by the factory match) so the base package imports cleanly without any extras installed.
```

- [ ] **Step 2: Rewrite `provider-architecture.md` without Module Map**

Replace the entire file with:

```markdown
# Architecture: data flow, SDK integration

Audience: AI agents. File paths and symbols allowed here.
Package tree: `AGENTS.md`. Behavioral rules: `what/run-api.md`, `what/provider-contract.md`, `what/configuration.md`, `what/audit-logging.md`.

## Data Flow

1. Startup: `config.resolve_sdk()` maps `LIGHTSPEED_*` → SDK env; `parse_reasoning_config()`; `create_provider(sdk.name)`; `build_router(...)`; register health + metrics; lifespan initializes tracer.
2. Client (operator) `POST /v1/agent/run` with JSON body and optional `traceparent` / `x-agenticrun-uid`.
3. FastAPI validates `RunRequest`; `run_endpoint` computes timeout, system prompt, optional context prefix + query; may resolve MCP servers via `mcp.parse_mcp_servers()`.
4. Handler calls `provider.query(ProviderQueryOptions(...))` with model, turns, budget, tools, cwd, schema, reasoning_config, and resolved MCP server configs.
5. Handler async-iterates events; `EventLogger` and `AuditLogger` side effects; metrics updated; stops at first `result` event.
6. Handler parses `result.text` as JSON object or falls back to plain summary; returns `RunResponse`.

## Key Abstractions

- **Config mapping:** `resolve_sdk()` owns env → SDK name; factory does not read provider env vars.
- **Factory:** `create_provider(name)` lazy-imports the selected adapter.
- **Events:** Normalized `ProviderEvent` union decouples route layer from vendor streaming models.
- **Options:** `ProviderQueryOptions` is the single bundle passed into every adapter (includes `mcp_servers`, `reasoning_config`).
- **Router builder:** Env-based model resolution and default router parameters.

## Integration Points

- **FastAPI / Uvicorn:** ASGI entry `lightspeed_agentic.app:app`.
- **deepagents (+ langchain-anthropic, langchain-google-vertexai, langchain-aws, langchain-mcp-adapters):** `create_deep_agent`, `LocalShellBackend`, `ChatAnthropic` / Vertex / Bedrock, MCP via `MultiServerMCPClient`.
- **google-adk / google.genai:** `Agent`, `Runner`, `InMemorySessionService`, `ExecuteBashTool`, `SkillToolset`. MCP via `McpToolset` + `StreamableHTTPConnectionParams`.
- **openai-agents (+ openai):** `SandboxAgent`, `Runner`, `UnixLocalSandboxClient`. MCP via `MCPServerStreamableHttp`.
- **OpenTelemetry / Prometheus:** `tracing.py` TracerProvider; `audit.py` GenAI spans/events; `metrics.py` `/metrics`.

## Implementation Notes

- **DeepAgents model routing:** `_resolve_model()` checks `CLAUDE_CODE_USE_VERTEX` and `CLAUDE_CODE_USE_BEDROCK`.
- **DeepAgents thinking:** From `AIMessage` content / content_blocks; yield `ThinkingDeltaEvent` then `ContentBlockStopEvent`.
- **DeepAgents streaming:** `astream(stream_mode="messages")`.
- **Gemini bash:** Monkey-patches `run_async` for confirmation and `bash -c` wrapping.
- **OpenAI init:** One-time verbose logging and tracing disable.
- **MCP Secret headers:** Read first file (sorted by name) under `/var/secrets/mcp/<secretName>/` — see `what/configuration.md` (current behavior; stricter path was an orphan promise).
- **Containerfile:** Multi-stage hermetic Python/RPM build; `oc`/`kubectl` from ose-cli stage; no ripgrep install; user `agent`; `catatonit`; Uvicorn on 8080.
- **Tests / evals:** HTTP clients target `POST /v1/agent/run` (see `tests/` and `evals/`).
```

- [ ] **Step 3: Update `.ai/spec/README.md` how/ blurbs**

In the how/ table, change descriptions to:

```markdown
| [project-structure.md](how/project-structure.md) | Entry points, naming conventions, dependency extras (package tree in AGENTS.md) |
| [provider-architecture.md](how/provider-architecture.md) | Data flow, abstractions, SDK integration points, implementation notes |
```

In Quick Start, ensure audit logging points at `what/audit-logging.md`. In Cross-Reference, keep `what/provider-contract.md` → `how/provider-architecture.md`; add:

```markdown
| `what/audit-logging.md` | `how/provider-architecture.md` (observability integration) |
```

- [ ] **Step 4: Verify no Module Map headings remain in how/**

Run: `rg -n '^## Module Map' .ai/spec/how/`
Expected: no matches

- [ ] **Step 5: Commit**

```bash
cd /home/ometelka/projects/ols/lightspeed-agentic-sandbox
git add .ai/spec/how/project-structure.md .ai/spec/how/provider-architecture.md .ai/spec/README.md
git commit -m "$(cat <<'EOF'
OLS-0000: remove Module Maps from how/ specs

Keep entry points, data flow, and gotchas; package tree lives in AGENTS.md.
EOF
)"
```

---

### Task 2: Reconcile `configuration.md` with code (orphans → truth)

**Files:**
- Modify: `.ai/spec/what/configuration.md`

- [ ] **Step 1: Fix Vertex/google mapping row**

In rule 2 table, change the `vertex` / `google` row SDK env vars cell to:

```markdown
| `vertex` | `google` | `gemini` | `GEMINI_MODEL`, `GOOGLE_GENAI_USE_VERTEXAI=true`, `GOOGLE_APPLICATION_CREDENTIALS`, `GOOGLE_CLOUD_PROJECT`, `GOOGLE_CLOUD_LOCATION` |
```

- [ ] **Step 2: Fix hermetic / system package rules (drop ripgrep / empty binary lockfile claims)**

Replace rules 17 and 19 with:

```markdown
17. **Hermetic / Konflux build inputs.** Release images are built with network isolation after prefetch: per-architecture Python requirements files with hashes and RPM lockfile input. The generic binary artifacts lockfile may be empty when binaries are copied from other image stages (e.g. `oc`/`kubectl` from `ose-cli`). Regeneration of Python/RPM artifacts is via project automation commands (see `how/provider-architecture.md`).

19. **System packages — minimum expectations.** Runtime image includes Bash, Git, OpenShift CLI (`oc`), Kubernetes CLI (`kubectl`), and supporting OS utilities per the container recipe. Ripgrep is not currently installed in the image.
```

- [ ] **Step 3: Fix MCP rules 20–21 to match `mcp.py`**

Replace rules 20–21 with:

```markdown
20. **MCP server configuration.** When `LIGHTSPEED_MCP_SERVERS` is set, the sandbox MUST parse it as a JSON array of MCP server entries. Each entry has the shape `{"name": string, "url": string, "timeout": int, "headers": [{"name": string, "source": string, "secretName"?: string}]}`. When `source` is `Secret` and `secretName` is missing, empty, or not a string, the sandbox MUST skip that header (warn) and continue — it MUST NOT reject the entire server entry. The sandbox MUST build SDK-native MCP client configs from this array and pass them into provider adapters via `ProviderQueryOptions.mcp_servers` (see `provider-contract.md`). When the env var is absent or empty, no MCP servers are configured.

21. **MCP header resolution.** For each header in an MCP server entry, the sandbox MUST resolve the value based on the `source` field:

    | `source` | Resolution |
    |---|---|
    | `ServiceAccountToken` | Read the projected SA token from `/var/run/secrets/kubernetes.io/serviceaccount/token` and format as `Bearer <token>`. |
    | `Secret` | List files under `/var/secrets/mcp/<secretName>/`, sort by name, and read the first regular file. If the directory is missing, empty, unreadable, or `secretName` is invalid, skip the header (warn). Path traversal outside the mount root MUST be rejected. |
    | `Client` | Skip — not resolved by the sandbox. Reserved for future client-passthrough flows. |

    Note: A stricter deterministic path (`.../<secretName>/<secretName>`) and reject-on-missing-`secretName` were written into this spec via review-only commit `1508589` without code or a follow-up ticket (orphan promise). Current behavior is first-file as above.
```

Keep surface row `/var/secrets/mcp/<secretName>/` as-is (directory mount).

- [ ] **Step 4: Commit**

```bash
git add .ai/spec/what/configuration.md
git commit -m "$(cat <<'EOF'
OLS-0000: align configuration.md with sandbox code

MCP Secret first-file behavior, Vertex Google env vars, packaging truth.
EOF
)"
```

---

### Task 3: Reconcile `audit-logging.md`

**Files:**
- Modify: `.ai/spec/what/audit-logging.md`

- [ ] **Step 1: Fix uid, thinking, metrics, audit-disabled, templog planned, MCP planned wording**

Apply these replacements:

1. Rule 4 table `agenticrun.uid` description →:
   `AgenticRun CR metadata.uid as received (hyphens preserved) — cross-trace correlation key`

2. Rule 7 thinking bullet →:
   `Thinking/reasoning output: a gen_ai.choice event with gen_ai.reasoning_content when the adapter emits thinking (DeepAgents, and Gemini/OpenAI when reasoning is configured per provider-contract.md). When the model emits both completion and thinking content, they MAY be combined into a single gen_ai.choice event with both attributes.`

3. Rules 16–17 → acknowledge thinking when configured:

```markdown
16. **OpenAI** (`providers/openai.py`): Emit `gen_ai.choice` with `gen_ai.completion` from stream text deltas (buffered). Emit `gen_ai.reasoning_content` from reasoning delta items when present. Create `execute_tool {name}` spans from tool call/output items. Set token usage from the stream end.

17. **Gemini** (`providers/gemini.py`): Emit `gen_ai.choice` with `gen_ai.completion` from text parts (buffered). Emit `gen_ai.reasoning_content` from thought parts when present. Create `execute_tool {name}` spans from function_call/response parts. Set token usage from the stream end.
```

4. Rule 18 metric names → Prometheus form:

```markdown
| Metric | Type | Unit | Labels |
|---|---|---|---|
| `gen_ai_client_token_usage` | Histogram | `{token}` | `gen_ai_token_type`, `gen_ai_request_model`, `gen_ai_provider_name`, `gen_ai_operation_name` |
| `gen_ai_client_operation_duration_seconds` | Histogram | `s` | `gen_ai_request_model`, `gen_ai_provider_name`, `gen_ai_operation_name` |
| `gen_ai_execute_tool_duration_seconds` | Histogram | `s` | `gen_ai_tool_name` |
```

5. Rule 20 →:

```markdown
20. The sandbox receives audit config from the operator via environment variables (`LIGHTSPEED_AUDIT_ENABLED`, `LIGHTSPEED_CAPTURE_CONTENT`, OTEL endpoint). When audit is disabled (`LIGHTSPEED_AUDIT_ENABLED` false/unset per implementation), the sandbox MUST NOT emit `gen_ai.choice` content events and MUST NOT use the stdout audit exporter path gated by that flag. Inference and tool spans may still be created for the request path (current code and unit tests). When audit is enabled, spans and span events emit per the rules above.
```

6. Section heading + rules 22–25 → mark planned:

```markdown
### OTLP Log Emission (Templog) [PLANNED: OLS-3515]

22. [PLANNED: OLS-3515] When the OTLP log endpoint environment variable is set (wired by the lightspeed-operator when `spec.templog` is enabled), the sandbox MUST also emit audit span data as OTLP log records to that endpoint. This is in addition to the stdout and OTLP trace exporters.

23. [PLANNED: OLS-3515] Each OTLP log record MUST carry: `agenticrun.uid` as a log record attribute (raw Kubernetes `metadata.uid` with hyphens, via `x-agenticrun-uid`), `agenticrun.phase` (from `derive_phase()`), and the span event data as the log record body. TraceID carries the per-phase trace id from `traceparent`.

24. [PLANNED: OLS-3515] The OTLP log endpoint is independent of the OTEL tracing endpoint. Both can be active simultaneously.

25. [PLANNED: OLS-3515] When the OTLP log endpoint is absent, no OTLP log records are emitted. Graceful degradation.
```

7. MCP section 26 heading/wording → MCP runtime exists; attrs still untracked:

```markdown
### MCP Semantic Conventions [UNTRACKED]

26. MCP tool connectivity is implemented. Additional MCP span attributes (`mcp.method.name`, `mcp.session.id`, `mcp.protocol.version`, `network.transport`) are not implemented and have no Jira story. Do not treat this table as a current MUST until a ticket exists. Prefer `gen_ai.tool.*` on tool spans today.
```

8. Cross-ref `templog.md` →:

```markdown
- Parent workspace `ols/.ai/spec/what/templog.md` — Temporary audit log storage (cross-repo); sandbox emission tracked by OLS-3515
```

- [ ] **Step 2: Commit**

```bash
git add .ai/spec/what/audit-logging.md
git commit -m "$(cat <<'EOF'
OLS-0000: reconcile audit-logging.md with code and OLS-3515

Mark templog OTLP logs planned; fix uid, metrics names, thinking, disabled behavior.
EOF
)"
```

---

### Task 4: Reconcile remaining `what/` specs

**Files:**
- Modify: `.ai/spec/what/provider-contract.md`
- Modify: `.ai/spec/what/health-probes.md`
- Modify: `.ai/spec/what/e2e-testing.md`
- Modify: `.ai/spec/what/system-overview.md`

- [ ] **Step 1: `provider-contract.md` — mcp_servers shape + reasoning keys**

Replace rule 17 with:

```markdown
17. **ProviderQueryOptions — `mcp_servers`.** Optional list of `ResolvedMCPServer` values from `mcp.parse_mcp_servers()`. Each entry carries `name`, `url`, `timeout`, and `headers` as a list of `ResolvedMCPHeader` (`name`, `value`). Adapters MAY convert headers to a dict at the SDK boundary. When non-empty, adapters MUST wire these servers into their SDK's native MCP client mechanism (see rules 31–34). When empty or absent, no MCP servers are configured.
```

Replace rule 18 unrecognized-keys sentence with:

```markdown
18. **ProviderQueryOptions — `reasoning_config`.** Optional dict (JSON object). When present, adapters MUST map it to their SDK's native reasoning/thinking parameters. When absent or `None`, adapters MUST NOT set any reasoning parameters and SDK defaults apply. DeepAgents passes only the `thinking` key through to `ChatAnthropic*`. Gemini constructs `ThinkingConfig(**config)` and OpenAI constructs `Reasoning(**rc)` — extra keys are forwarded to the SDK constructors (not stripped by the adapter); invalid values fail at SDK/API invocation time.
```

Align rules 20–21 with that (remove “Unknown keys in the config are ignored” absolute language for Gemini; say forwarded into `ThinkingConfig`).

- [ ] **Step 2: `health-probes.md` — R3 orphan**

Replace R3 line with:

```markdown
**R3 — MCP server reachability.** Not implemented. Previously marked “[PLANNED: when MCP support lands]” but MCP runtime shipped (OLS-3185 / OLS-3443) without an R3 story (OLS-3046 / OLS-3060 closed with R1/R2 only). No current MUST. File a story before specifying R3 again.
```

- [ ] **Step 3: `e2e-testing.md`**

In “Not feasible” table, replace the R3 row with:

```markdown
| Readiness rule R3 (MCP reachability) | Not implemented; no tracked story | — |
```

In “Feasible” or a new “Also covered” note, add feature files:

```markdown
| MCP connectivity | Live/container scenarios for MCP wiring | [mcp.feature](../../../tests/e2e/features/mcp.feature) |
| Reasoning config | Live/container scenarios | [reasoning_config.feature](../../../tests/e2e/features/reasoning_config.feature) |
```

(If the harness section has a verification map listing only three features, add `mcp.feature` and `reasoning_config.feature` there too.)

- [ ] **Step 4: `system-overview.md`**

Replace rules 4–5 and 6–8 as needed:

```markdown
4. The system has these major components: HTTP API layer (routes, models), provider abstraction (factory, query options, event model), provider adapters (DeepAgents, Gemini, OpenAI), configuration mapping (`config.py`), MCP resolution (`mcp.py`), health probes, and observability (`audit.py`, `metrics.py`, `tracing.py`).

5. Component behavioral rules: `run-api.md`, `provider-contract.md`, `configuration.md`, `health-probes.md`, `audit-logging.md`, `e2e-testing.md`.

6. At startup, the process runs `resolve_sdk()` / reasoning config parse, constructs a provider via the factory, builds the API router, registers health and metrics routes, initializes tracing in the app lifespan, and serves on port 8080.

8. Model resolution uses canonical `LIGHTSPEED_MODEL` (mapped to SDK-specific model env vars), with package default fallback.
```

In Configuration Surface table, ensure primary model field is `LIGHTSPEED_MODEL` (not only per-SDK names).

- [ ] **Step 5: Commit**

```bash
git add .ai/spec/what/provider-contract.md .ai/spec/what/health-probes.md .ai/spec/what/e2e-testing.md .ai/spec/what/system-overview.md
git commit -m "$(cat <<'EOF'
OLS-0000: reconcile remaining what/ specs with sandbox reality

Provider MCP/reasoning shapes, R3 orphan, e2e map, system inventory.
EOF
)"
```

---

### Task 5: Update `AGENTS.md` and `ARCHITECTURE.md`

**Files:**
- Modify: `AGENTS.md`
- Modify: `ARCHITECTURE.md`

- [ ] **Step 1: Expand AGENTS Architecture tree**

Replace the Architecture tree block with:

```text
src/lightspeed_agentic/
├── app.py                # FastAPI entry; resolve_sdk, provider, router, metrics, tracer lifespan
├── config.py             # LIGHTSPEED_* → SDK env mapping; resolve_sdk(); reasoning parse
├── factory.py            # create_provider(name) — SDK name from config.resolve_sdk()
├── health.py             # GET /health, GET /ready
├── mcp.py                # parse_mcp_servers(); header resolution
├── audit.py              # AuditLogger GenAI spans/events
├── metrics.py            # Prometheus /metrics
├── tracing.py            # TracerProvider, traceparent helpers
├── logging.py            # EventLogger (debug thinking buffer)
├── tools.py              # DEFAULT_ALLOWED_TOOLS only
├── types.py              # Provider events, query options, AgentProvider ABC
├── providers/
│   ├── deepagents.py     # deepagents (langchain-anthropic) adapter
│   ├── gemini.py         # google-adk adapter
│   └── openai.py         # openai-agents adapter
└── routes/
    ├── __init__.py       # build_router(...)
    ├── query.py          # POST /run endpoint
    └── models.py         # Pydantic request/response models
```

Update the sentence about `tools.py` to: shared allowlist constant only; do not invent shared path helpers there.

- [ ] **Step 2: AGENTS read table + env table**

Add row:

```markdown
| Audit / OTel / metrics | [audit-logging.md](.ai/spec/what/audit-logging.md) |
```

In Environment Variables table add:

```markdown
| `LIGHTSPEED_AUDIT_ENABLED` | Enable audit span exporters / choice events (see audit-logging.md) |
| `LIGHTSPEED_CAPTURE_CONTENT` | Opt-in content attributes on choice events |
| `LIGHTSPEED_MCP_SERVERS` | JSON array of MCP server configs |
| `CLAUDE_CODE_USE_BEDROCK` | Set by config mapping for Bedrock → DeepAgents |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | OTLP gRPC endpoint for traces |
```

- [ ] **Step 3: Fix ARCHITECTURE.md**

Replace Key Decision bullet:

```markdown
- **One provider per pod:** The provider is selected at startup via `LIGHTSPEED_PROVIDER` (mapped to an SDK name by `config.resolve_sdk()`). This keeps pods simple and disposable — the operator chooses which provider to target when creating the pod.
```

Update Internal Architecture mermaid (or a short bullet list under it) to mention `config.py`, `mcp.py`, `audit.py`, `metrics.py`, `tracing.py` if the diagram still shows only HTTP + factory + adapters.

Softening hermetic bullet if it claims all external binaries are in lockfiles:

```markdown
- **Hermetic builds:** Python wheels and RPMs are declared in lockfiles and prefetched. Some CLI binaries (`oc`, `kubectl`) are copied from Red Hat image stages rather than a generic binary lockfile.
```

- [ ] **Step 4: Commit**

```bash
git add AGENTS.md ARCHITECTURE.md
git commit -m "$(cat <<'EOF'
OLS-0000: sync AGENTS.md and ARCHITECTURE.md with package reality

Fix LIGHTSPEED_PROVIDER; own the package tree; document audit/MCP env.
EOF
)"
```

---

### Task 6: Verification gate + PR

**Files:** none (verification + git/gh only)

- [ ] **Step 1: Spec-only diff check**

```bash
cd /home/ometelka/projects/ols/lightspeed-agentic-sandbox
git diff origin/main...HEAD --name-only
```

Expected: only under `.ai/spec/`, `AGENTS.md`, `ARCHITECTURE.md` (and optionally README paths already included).

- [ ] **Step 2: Consistency greps**

```bash
rg -n '^## Module Map' .ai/spec/how/ || true
rg -n 'LIGHTSPEED_AGENT_PROVIDER' ARCHITECTURE.md AGENTS.md .ai/spec || true
rg -n 'hyphens stripped' .ai/spec/what/audit-logging.md || true
rg -n 'reject entries where .source. is .Secret' .ai/spec/what/configuration.md || true
rg -n 'PLANNED: OLS-3515' .ai/spec/what/audit-logging.md
rg -n 'when MCP support lands' .ai/spec/what/ || true
```

Expected: no Module Map; no `LIGHTSPEED_AGENT_PROVIDER`; no “hyphens stripped” / reject-Secret MUST; OLS-3515 present; no “when MCP support lands”.

- [ ] **Step 3: Push fork branch and open PR**

```bash
# detect fork remote from gh api user
USER=$(gh api user -q .login)
# find remote containing $USER
git checkout -b docs/OLS-0000-sandbox-spec-grooming
git push -u <fork-remote> HEAD
gh pr create --repo openshift/lightspeed-agentic-sandbox --head "$USER:docs/OLS-0000-sandbox-spec-grooming" --base main \
  --title "OLS-0000: groom agentic-sandbox specs (truth + planned)" \
  --body "$(cat <<'EOF'
## Summary

Spec-only grooming of `lightspeed-agentic-sandbox` after an audit of session usage and spec↔code drift.

- Remove unused `## Module Map` tables from `how/` (agents navigate via Glob/Grep; maps were triple-maintained and stale).
- Reconcile `what/`, `AGENTS.md`, and `ARCHITECTURE.md` with current code.
- Mark intentional futures with tickets (`[PLANNED: OLS-3515]` templog OTLP logs).
- Demote **orphan promises** (spec ahead of code, no Jira) to documented current behavior.

Design: `openshift/ols` `docs/superpowers/specs/2026-07-23-sandbox-spec-grooming-design.md`.

## What was wrong

1. **Module Maps** — high maintenance, near-zero navigation use across sessions; duplicated in `project-structure.md`, `provider-architecture.md`, and `AGENTS.md`; lagged modules (`audit`, `metrics`, `tracing`, `config`).
2. **Code without nav updates** — features landed with tests/`what/` but not `how/`/AGENTS trees.
3. **Bare MUST for unimplemented work** — templog OTLP logs written as current rules; now `[PLANNED: OLS-3515]`.
4. **Orphan promises (no ticket)** — MCP Secret deterministic path + reject missing `secretName` from CodeRabbit spec-only commit `1508589` after OLS-3185 closed; MCP R3 left as “when MCP support lands” after MCP shipped; uid hyphen-strip never implemented or ticketed.
5. **Incomplete renames** — `ARCHITECTURE.md` still said `LIGHTSPEED_AGENT_PROVIDER`.

## Spec-first reevaluation

Spec-first (promise for other AI sessions) stays useful **only if**:

1. Unimplemented MUST ⇒ `[PLANNED: OLS-XXXX]` with a real ticket, or don’t write the rule.
2. Spec-only review that tightens contracts must update code **or** open a ticket + `[PLANNED]` — never a new bare MUST.
3. `AGENTS.md` owns the package tree; `how/` owns data flow / gotchas — not path tables.
4. Closing an epic requires stories (or removal) for leftover PLANNED sub-behaviors.

## Follow-ups (not in this PR)

- File stories if product still wants: MCP deterministic Secret path + reject; MCP readiness R3; hyphen-stripped span uid.
- Implement OLS-3515 (sandbox OTLP log emission).

## Test plan

- [ ] `rg` gates in plan Task 6 pass
- [ ] Human skim of `configuration.md` MCP rules vs `mcp.py`
- [ ] Confirm no `src/` / test diffs

EOF
)"
```

- [ ] **Step 4: Report PR URL to the user**

---

## Plan self-review

| Design requirement | Task |
|---|---|
| Remove Module Maps | Task 1 |
| configuration MCP/packaging/Vertex | Task 2 |
| audit-logging + OLS-3515 + orphans | Task 3 |
| provider/health/e2e/system-overview | Task 4 |
| AGENTS + ARCHITECTURE | Task 5 |
| PR narrative + verification | Task 6 |
| No code changes | Global constraint + Task 6 name-only check |

No TBD/TODO placeholders in steps. Spec-only commits; no TDD (docs).
