# 0006: Security Baseline

**Status:** Accepted
**Applies to:** lightspeed-service, lightspeed-operator, lightspeed-otel-collector

## Context

Enterprise deployment in regulated environments requires defense-in-depth. Filesystem-path credentials prevent secret leakage in configuration files, logs, and error messages. FIPS compliance is mandatory for US government deployments. Service-CA provides zero-config TLS on OpenShift while custom certs serve enterprise PKI requirements.

## Decision

All API keys, passwords, and secrets are specified as filesystem paths in configuration — the service reads values at startup, never from plaintext config values. TLS 1.2 is the minimum version; TLS 1.0/1.1 and OldType profile are unconditionally prohibited. OpenShift service-CA is the default TLS certificate provider; custom certificates are optional via Secret reference. The system is FIPS-ready, using FIPS-validated cryptographic modules and deployable on FIPS-enabled clusters. When no TLS security profile is configured, the operator falls back to the cluster API server's TLS profile.

## Alternatives Considered

- **Plaintext secrets in config** — rejected because of leakage risk in config files, logs, and error messages
- **TLS 1.0/1.1 support** — rejected because of known vulnerabilities
- **cert-manager for TLS** — rejected because it adds a dependency; service-CA is the standard OpenShift mechanism
- **Custom CA infrastructure** — rejected because of unnecessary complexity when service-CA handles rotation automatically

## Consequences

- Startup reads credential files and fails fast on missing paths
- OldType TLS profile rejected at config load time
- PostgreSQL TLS is always service-CA with SSL mode `require` (not user-configurable)
- TLS profile fallback inherits cluster-wide security posture
- FIPS mode is transparent to application code
