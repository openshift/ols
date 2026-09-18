# Temporary Audit Log Storage

Stopgap audit log persistence for environments without cluster logging or SIEM. Stores agentic system audit events in the existing PostgreSQL instance via a custom OpenTelemetry Collector built with OCB. Logs are tied to AgenticRun lifecycle — deleted when the AgenticRun CR is deleted.

## Requirements & Principles

1. **Agentic system only.** This feature stores audit events from the agentic-operator and agentic-sandbox. OLS service audit events are out of scope.

2. **Default on.** `AgenticOLSConfig.spec.templog` defaults to `true`. Its log/PostgreSQL pipeline deploys unless the admin explicitly sets `spec.templog: false`.

3. **Run-scoped lifecycle.** Audit logs are tied to their AgenticRun CR. When an AgenticRun is deleted, a finalizer ensures all associated rows are deleted from PostgreSQL before the CR is removed. No separate retention policy, TTL, or eviction logic.

4. **Independent of tracing.** `spec.audit.otel.endpoint` handles spans (tracing). This feature handles logs. Both can operate simultaneously. The custom Collector runs its own log-only pipeline; it does not interfere with the tracing endpoint.

5. **Independent of audit toggle.** `spec.templog` controls the templog pipeline. `spec.audit.enabled` controls audit event emission. If audit is disabled (`spec.audit.enabled: false`), the templog pipeline may remain deployed but receives no data. If audit is absent (defaults to enabled), templog works.

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
  templog: true   # default: true. Set false to disable the templog pipeline, not other Collector consumers.
```

Single boolean. The operator derives all other configuration (Collector endpoint, Postgres DSN, schema name) from existing infrastructure.

### Interaction with spec.audit

| `spec.templog` | `spec.audit.enabled` | `spec.audit.otel.endpoint` | Behavior |
|---|---|---|---|
| true (or absent) | true (or absent) | absent | Collector deployed for templog. Audit events emit to stdout + OTLP logs to Collector. No configured compliance trace export. |
| true (or absent) | true (or absent) | set | Collector deployed for templog. Audit events emit to stdout + OTLP logs to Collector + OTLP spans to the configured compliance endpoint. |
| true (or absent) | false | any | Collector deployed for templog but receives no compliance audit logs. |
| false | any | any | Templog log pipeline is absent. The shared OTLP endpoint remains available for product traces and any other Collector consumer; compliance audit behavior is otherwise unchanged. |

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

## Cross-Repository Wiring

1. `AgenticOLSConfig.spec.templog` controls only the Collector's OTLP-log-to-PostgreSQL pipeline. The lightspeed-operator includes or removes that pipeline while preserving the Collector resources when another feature needs them.
2. The existing `lightspeed-agentic-configuration` OTLP endpoint is shared by logs and traces and remains available independently of the templog setting. Disabling templog MUST NOT remove the endpoint from agentic-operator or sandbox pods or suppress Agentic product traces.
3. Agentic producers receive no templog enablement value. When compliance audit and the shared OTLP endpoint are active, they emit the templog audit copies defined by their local audit specifications; Collector pipeline configuration determines whether those logs are stored.
4. Disabling templog leaves the PostgreSQL schema and existing rows in place. It does not perform destructive cleanup.

## AgenticRun Cleanup Boundary

The agentic-operator owns the `agentic.openshift.io/templog-cleanup` finalizer and calls the Collector admin API to remove run-scoped logs. The Collector owns PostgreSQL access. Exact retry, give-up, and finalizer-removal behavior belongs to the agentic-operator `what/templog.md` implementation contract; the agentic-operator does not connect directly to PostgreSQL.

## Repo Ownership

| Repo | Templog Responsibilities |
|---|---|
| **lightspeed-otel-collector** | OCB manifest, OTLP-log-to-PostgreSQL pipeline, schema administration, run-scoped cleanup API, and Collector image |
| **lightspeed-operator** | Reconcile Collector resources and the conditional templog pipeline; publish the shared OTLP and admin connectivity handoff without using it as a templog gate |
| **lightspeed-agentic-operator** | Own the `AgenticOLSConfig.spec.templog` API, emit audit log copies through shared OTLP, and implement run cleanup/finalizer behavior |
| **lightspeed-agentic-sandbox** | Emit audit log copies through shared OTLP when compliance audit is enabled |

## Separation from Agentic Product Data Collection

Templog is the only consumer of Agentic OTLP logs in the in-cluster Collector. Agentic product collection consumes traces only and has no PostgreSQL path. Its independent enablement, ready-file/export topology, and loss semantics are defined in `agentic-data-collection.md`.

## Cross-References

- `audit-logging.md` — Audit event catalog, correlation model, structured JSON format
- `agentic-runs.md` — AgenticRun lifecycle, CRD definitions, phase transitions
- Lightspeed-operator `postgres.md` — PostgreSQL deployment, bootstrap, credentials
- `agentic-data-collection.md` — Trace-only Agentic product-data candidate streams and Dataverse handoff

## Planned Changes

| Ticket | Summary |
|---|---|
| [DONE: OLS-3295] | Rename `Proposal` → `AgenticRun` across templog finalizer, cleanup, and audit event references |
| OLS-3328 | Implement temporary audit log storage |
| OLS-3696 | Rename `trace_id` → `agentic_run_id`, add `phase` column, update admin API. See design spec `docs/superpowers/specs/2026-07-22-templog-phase-storage.md`. |
