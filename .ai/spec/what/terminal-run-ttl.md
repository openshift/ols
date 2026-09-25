# Terminal AgenticRun Retention [PLANNED: OLS-4280]

Agentic runs have a bounded retention period after reaching a terminal phase. A cluster administrator may shorten or lengthen the default in `OLSConfig`; an individual run may request only earlier deletion. The operator records a fixed, user-visible deletion deadline when the run first becomes terminal. This replaces the older `AgenticOLSConfig` TTL source and per-run seconds/zero-disables-cleanup semantics. No migration or conversion of existing resources is part of OLS-4280.

## Behavioral Rules

1. The optional `OLSConfig.spec.agenticOLS.terminalTTLDays` is a positive whole number of days (minimum 1). It has **no CRD default**. When absent, including when `spec.agenticOLS` is absent, the classic operator omits the `terminal-ttl-days` key from `lightspeed-agentic-configuration`.
2. The classic operator publishes a configured value as a decimal day count in that ConfigMap. The agentic operator reads the key if present; if absent, its own built-in retention ceiling is **14 days**. `AgenticOLSConfig.spec.lifecycle.terminalTTL` and its containing `lifecycle` field are removed from the CRD and are not consulted.
3. `AgenticRun.spec.ttlAfterTerminal` retains its name but is redefined as **positive whole days** (minimum 1), not seconds. It is optional and never filled from cluster configuration. A run may request a shorter TTL; a request above the cluster ceiling is accepted but does not lengthen retention. Zero is invalid and no longer disables cleanup.
4. At the first transition to a terminal state, the agentic operator stamps `status.terminalTime` and computes `status.deleteAfter = terminalTime + min(run TTL, cluster ceiling)`; if the run TTL is absent, use the ceiling. Both timestamps are operator-owned status values; `deleteAfter` is a timestamp, not a duration. The operator does not write or replace the run's TTL request in spec. On subsequent reconciles it uses the recorded `deleteAfter`, requeuing until the deadline and deleting the `AgenticRun` at or after it. Deletion cascades to owned resources.
5. `deleteAfter` is fixed for that terminal transition. Later edits to OLSConfig, changes to the handoff ConfigMap, or edits to a run's spec cannot move it. A post-terminal change to `spec.ttlAfterTerminal` is not allowed. When a permitted revision returns a terminal run to analysis, the operator clears `status.terminalTime` and `status.deleteAfter`; the next terminal transition computes a new deadline from the configuration and run request then in effect.
6. A failed run marked `agentic.openshift.io/preserve-sandbox: "true"` is a debugging exception: keep its existing preservation and explicit-deletion behavior, and leave `status.deleteAfter` unset (clear it if preservation is enabled after the deadline was stamped). The annotation, not a zero TTL, is the debugging hook. Once preserved, the run requires explicit deletion; removing the annotation does not retrospectively construct a new deadline. The UI may display `status.deleteAfter` for ordinary terminal runs and must not present a deletion deadline for preserved failed runs.

## Integration Contract and Ownership

| Owner | Contract |
| --- | --- |
| `lightspeed-operator` | Validates `OLSConfig.spec.agenticOLS.terminalTTLDays`; publishes or removes `terminal-ttl-days` on the existing `lightspeed-agentic-configuration` ConfigMap. Does not compute run deadlines. |
| `lightspeed-agentic-operator` | Owns the 14-day fallback, run TTL validation, the removal of `AgenticOLSConfig.spec.lifecycle`, first-terminal deadline stamping and TTL deletion. Reads the handoff key without importing the classic operator's API types. |
| `lightspeed-agentic-console` | May display `AgenticRun.status.deleteAfter` directly; no TTL precedence calculation is required in the UI. |

The handoff value is an optional base-10 positive integer in days. An absent key selects the operator default; an invalid present value is a configuration error, not an instruction to silently use the default. A failure to read the configured value must not lead the agentic operator to stamp a different deadline; it retries when configuration is available.

## Verification

- Validate 1+ day values and rejection of zero/negative values for both API fields; verify OLSConfig omission does not default or publish a key.
- Check handoff creation, updates, and removal of the optional key; check agentic fallback of 14 days only when the key is absent.
- Check run TTL omitted, shorter than, equal to, and longer than the ceiling, including the one-day minimum and accepted-but-capped requests.
- Check atomic status timestamps, restarts, fixed deadlines after configuration changes, terminal revision/reset, deletion at expiry, and the preserved failed-run exception (including late annotation and later annotation removal).

## Child Specs

- `lightspeed-operator/.ai/spec/what/crd-api.md` and `lightspeed-operator/.ai/spec/what/agentic-sandbox-profile.md` — admin API and handoff publishing.
- `lightspeed-agentic-operator/.ai/spec/what/crd-api.md` and `lightspeed-agentic-operator/.ai/spec/what/run-lifecycle.md` — run API and retention lifecycle.
