# Temporary Audit Log Storage

Stopgap audit log persistence for environments without cluster logging or SIEM. Stores agentic system audit events in the existing PostgreSQL instance via a custom OpenTelemetry Collector built with OCB. Logs are tied to AgenticRun lifecycle — deleted when the AgenticRun CR is deleted.

## Requirements & Principles

1. **Agentic system only.** This feature stores audit events from the agentic-operator and agentic-sandbox. OLS service audit events are out of scope.

2. **Default on.** `AgenticOLSConfig.spec.templog` defaults to `true`. The Collector deploys unless the admin explicitly sets `spec.templog: false`.

3. **Run-scoped lifecycle.** Audit logs are tied to their AgenticRun CR. When an AgenticRun is deleted, a finalizer ensures all associated rows are deleted from PostgreSQL before the CR is removed. No separate retention policy, TTL, or eviction logic.

4. **Independent of tracing.** `spec.audit.otel.endpoint` handles spans (tracing). This feature handles logs. Both can operate simultaneously. The custom Collector runs its own log-only pipeline; it does not interfere with the tracing endpoint.

5. **Independent of audit toggle.** `spec.templog` controls Collector deployment. `spec.audit.enabled` controls audit event emission. If audit is disabled (`spec.audit.enabled: false`), the Collector deploys but receives no data. If audit is absent (defaults to enabled), templog works.

6. **Dual emission preserved.** Structured JSON to stdout always emits when audit is enabled (existing behavior). OTLP log emission to the Collector is additive — it does not replace stdout.

7. **Stopgap, not strategic.** This feature exists for customers who lack external log aggregation. It is not a replacement for a proper SIEM or log management solution. The schema and query surface are intentionally minimal.

## Architecture

```
┌──────────────────────┐    ┌──────────────────────┐
│  agentic-operator    │    │  agentic-sandbox     │
│  (OTLP log emitter)  │    │  (OTLP log emitter)  │
└─────────┬────────────┘    └─────────┬────────────┘
          │ OTLP/gRPC logs            │ OTLP/gRPC logs
          └──────────┬────────────────┘
                     ▼
          ┌──────────────────────┐
          │  Custom OTel         │
          │  Collector (OCB)     │
          │  ┌────────────────┐  │
          │  │ postgresexp    │  │
          │  └───────┬────────┘  │
          └──────────┼───────────┘
                     ▼
          ┌──────────────────────┐
          │  PostgreSQL          │
          │  (existing instance) │
          │  schema: templogs    │
          └──────────────────────┘
```

Components:
- **Agentic-operator** and **agentic-sandbox** emit OTLP log records containing audit events to the Collector endpoint.
- **Custom OTel Collector** receives OTLP logs and writes them to PostgreSQL via the custom `postgresexporter`.
- **PostgreSQL** stores audit logs in the `templogs` schema. Same instance already used for conversation cache and quota.

## Configuration Surface

### AgenticOLSConfig CR

```yaml
spec:
  templog: true   # default: true. Set false to disable Collector deployment.
```

Single boolean. The operator derives all other configuration (Collector endpoint, Postgres DSN, schema name) from existing infrastructure.

### Interaction with spec.audit

| `spec.templog` | `spec.audit.enabled` | `spec.audit.otel.endpoint` | Behavior |
|---|---|---|---|
| true (or absent) | true (or absent) | absent | Collector deployed. Audit events emit to stdout + OTLP logs to Collector. No tracing. |
| true (or absent) | true (or absent) | set | Collector deployed. Audit events emit to stdout + OTLP logs to Collector + OTLP spans to tracing endpoint. |
| true (or absent) | false | any | Collector deployed but receives no data. Audit emission is off. |
| false | any | any | Collector not deployed. Audit behavior unchanged from current. |

## Schema & Data Model

Single table in a `templogs` schema:

```sql
CREATE SCHEMA IF NOT EXISTS templogs;

CREATE TABLE templogs.logs (
    id              BIGSERIAL    PRIMARY KEY,
    agentic_run_id  TEXT         NOT NULL,
    phase           TEXT         NOT NULL DEFAULT '',
    timestamp       TIMESTAMPTZ  NOT NULL,
    event           TEXT         NOT NULL,
    body            JSONB
);

CREATE INDEX idx_logs_run_id    ON templogs.logs (agentic_run_id);
CREATE INDEX idx_logs_run_phase ON templogs.logs (agentic_run_id, phase);
CREATE INDEX idx_logs_timestamp ON templogs.logs (timestamp);
```

- **`agentic_run_id`** — AgenticRun `metadata.uid` with hyphens stripped (32-char hex). Primary query and cleanup key. Deterministically derived from the AgenticRun CR, not dependent on any OTEL infrastructure.
- **`phase`** — Audit phase name: `analysis`, `approval`, `execution`, `verification`, `escalation`, `terminal`. Matches the per-phase audit trace model. Enables console to filter logs within a run by phase.
- **`timestamp`** — Event timestamp from the OTLP log record.
- **`event`** — Event discriminator (`audit.agenticrun.received`, `audit.agent.tool.call`, etc.). Extracted from log record attributes for filtering without parsing JSONB.
- **`body`** — Full structured JSON audit event as-is. Same content that goes to stdout. No transformation or field extraction beyond the dedicated columns.

The `templogs` schema is created by the OTEL Collector's `postgres_admin` extension at startup (not by the Postgres bootstrap script).

## Custom OTel Collector

### Build (OCB)

Built with the OpenTelemetry Collector Builder (ocb). The build manifest includes:

- **Receiver:** `otlpreceiver` (standard OTLP gRPC receiver)
- **Exporter:** `postgresexporter` (custom)

The custom exporter:
- Receives log records from the OTLP pipeline
- Extracts `agentic_run_id` (from `agenticrun.uid` log attribute, UUID normalized by stripping hyphens), `phase` (from `agenticrun.phase` log attribute), `timestamp`, and `event` (from `event` log attribute) into dedicated columns
- The OTel log record's native `TraceID` field is not used for column mapping — it carries the per-phase trace ID, not the AgenticRun UID
- Writes the full log record body as JSONB into `body`
- Uses batch inserts for efficiency
- Connects to Postgres using the same credentials the operator manages (shared secret, TLS via service-ca)

### Collector Configuration

Generated by the lightspeed-operator and mounted as ConfigMap:

```yaml
receivers:
  otlp:
    protocols:
      grpc:
        endpoint: 0.0.0.0:4317

exporters:
  postgres:
    dsn: "${POSTGRES_DSN}"
    schema: templogs
    table: logs

service:
  pipelines:
    logs:
      receivers: [otlp]
      exporters: [postgres]
```

### Deployment

- Single-replica Deployment managed by the lightspeed-operator
- Same management patterns as PostgreSQL (operator-managed image, TLS to Postgres via service-ca certs)
- NetworkPolicy allowing ingress from agentic-operator and sandbox pods on port 4317
- Service exposing port 4317 for OTLP gRPC

### Container Image

Built and shipped from the `lightspeed-otel-collector` repository. Single container image containing the custom Collector binary.

## Collector Repository

**Repo:** `lightspeed-otel-collector`

Contents:
- OCB build manifest (`builder-config.yaml`)
- Custom exporter Go code (`postgresexporter/`)
- Dockerfile
- Build pipeline (Konflux)

Ships one artifact: a container image with the custom Collector binary.

## Operator Wiring (lightspeed-operator)

### When `spec.templog: true` (or absent)

1. Add `templogs` schema creation to the Postgres bootstrap script
2. Deploy the custom Collector: Deployment, Service, ConfigMap, NetworkPolicy
3. Set OTLP log endpoint env var on agentic-operator and sandbox pods, pointing at the Collector service: `<collector-service>.<namespace>.svc:4317`

### When `spec.templog: false`

1. Remove the Collector Deployment, Service, ConfigMap, NetworkPolicy if they exist
2. Remove the OTLP log endpoint env var from agentic-operator and sandbox pods
3. The `templogs` schema is left in place (no destructive cleanup of data on disable)

## AgenticRun Finalizer & Cleanup

### Agentic-operator responsibility

- **Finalizer name:** `agentic.openshift.io/templog-cleanup`
- **Added when:** AgenticRun CR is created and `templog` is enabled (agentic-operator reads this from an env var set by the lightspeed-operator)
- **On AgenticRun deletion:**
  1. Finalizer fires
  2. Operator calls the Collector admin API: `DELETE /api/v1/logs?agentic_run_id=<uid>` (raw UUID with hyphens; collector normalizes)
  3. On success, removes the finalizer — CR deletion proceeds
  4. On failure (Postgres unreachable), finalizer blocks deletion and requeues with standard controller-runtime retry and backoff

### Edge cases

- **`templog` disabled after logs were written.** Finalizer was already added at AgenticRun creation. It still fires on deletion. The operator connects directly to Postgres (which it manages) to delete the rows. The finalizer does not depend on the Collector being present.
- **Postgres unavailable.** Finalizer blocks. AgenticRun CR cannot be deleted until cleanup succeeds. Correct behavior for a compliance-adjacent feature.

## Agentic Component Changes

### Agentic-operator

- When the OTLP log endpoint env var is set, emit audit events as OTLP log records to that endpoint
- Dual emission: stdout always, OTLP when configured (same pattern as the existing tracing design)
- Add `agentic.openshift.io/templog-cleanup` finalizer to new AgenticRuns when templog is enabled
- Finalizer handler: delete audit log rows from Postgres on AgenticRun deletion

### Agentic-sandbox

- When the OTLP log endpoint env var is set, emit audit events as OTLP log records to that endpoint
- Dual emission: stdout always, OTLP when configured

## Repo Ownership

| Repo | Templog Responsibilities |
|---|---|
| **lightspeed-otel-collector** | OCB manifest, custom `postgresexporter` Go code, Dockerfile, Konflux build pipeline. Ships the Collector container image. |
| **lightspeed-operator** | Read `AgenticOLSConfig.spec.templog`. Deploy/remove Collector Deployment, Service, ConfigMap, NetworkPolicy. Add `templogs` schema to Postgres bootstrap. Wire OTLP log endpoint to agentic pods. CRD change: add `spec.templog` to `AgenticOLSConfig`. |
| **lightspeed-agentic-operator** | Add OTLP log emission when endpoint is configured. Add `agentic.openshift.io/templog-cleanup` finalizer to AgenticRuns. Finalizer handler: delete rows from `templogs.logs` on AgenticRun deletion. |
| **lightspeed-agentic-sandbox** | Add OTLP log emission when endpoint is configured. |

## Child Spec Updates Required

| Repo | File | Content |
|---|---|---|
| lightspeed-operator | `what/templog.md` | Collector lifecycle reconciliation, schema bootstrap, pod wiring |
| lightspeed-agentic-operator | `what/crd-api.md` (update) | Add `spec.templog` to `AgenticOLSConfig` |
| lightspeed-operator | `what/postgres.md` (update) | Add `templogs` schema to bootstrap |
| lightspeed-agentic-operator | `what/templog.md` | Finalizer implementation, OTLP log emission, Postgres cleanup |
| lightspeed-agentic-operator | `what/audit-logging.md` (update) | Add OTLP log emission (dual: stdout + OTLP when endpoint configured) |
| lightspeed-agentic-sandbox | `what/audit-logging.md` (update) | Add OTLP log emission (dual: stdout + OTLP when endpoint configured) |

## Cross-References

- `audit-logging.md` — Audit event catalog, correlation model, structured JSON format
- `agentic-runs.md` — AgenticRun lifecycle, CRD definitions, phase transitions
- Lightspeed-operator `postgres.md` — PostgreSQL deployment, bootstrap, credentials

## Planned Changes

| Ticket | Summary |
|---|---|
| OLS-3295 | Rename `Proposal` → `AgenticRun` across templog finalizer, cleanup, and audit event references |
| OLS-3328 | Implement temporary audit log storage |
| OLS-3696 | Rename `trace_id` → `agentic_run_id`, add `phase` column, update admin API. See design spec `docs/superpowers/specs/2026-07-22-templog-phase-storage.md`. |
