# 0047: Native Go FIPS 140-3 Provider

**Status:** Accepted
**Applies to:** lightspeed-operator, lightspeed-agentic-operator, lightspeed-hub, lightspeed-otel-collector, lightspeed-agentic-alerts-adapter, lightspeed-rag-content
**Tracking:** [OLS-4668](https://redhat.atlassian.net/browse/OLS-4668) / [OCPSTRAT-3923](https://redhat.atlassian.net/browse/OCPSTRAT-3923) / HPSTRAT-723

## Context

OLS Go components were built for FIPS compliance with the Red Hat OpenSSL-based Go toolchain: `CGO_ENABLED=1` + `-tags strictfipsruntime` (or `GOEXPERIMENT=strictfipsruntime`), where Go's standard crypto is replaced by OpenSSL calls via CGo. This approach has known problems: OpenSSL thread contention at scale on FIPS-enabled clusters, toolchain lag behind upstream Go (every crypto change must be rebased against OpenSSL bindings), CGo dependency complicating cross-compilation, and OpenSSL shared-library requirements preventing scratch-like base images.

Go 1.26 ships a native, pure-Go FIPS 140-3 crypto provider with a certified module selectable at build time. The platform-wide HPSTRAT-723 initiative requires all OpenShift components to adopt it; `openshift/check-payload` (run in the Konflux enterprise-contract gates) enforces the native-FIPS rules for Go ≥ 1.27 unconditionally, and for Go 1.26 binaries that opt into `fips140` via GODEBUG. Go 1.26 is a dual-mode transition window in which the legacy OpenSSL path is still accepted; Go 1.27 is the forcing function.

## Decision

All OLS-built Go components use Go's native FIPS 140-3 crypto provider:

- **Build:** `CGO_ENABLED=0 GOFIPS140=certified` (certified FIPS module selected at build time). Exception: `lightspeed-rag-content` (byok-go) keeps `CGO_ENABLED=1` because its CGo usage is faiss/onnxruntime — non-crypto ML libraries; `GOFIPS140` governs only the Go crypto packages and composes with CGo.
- **Runtime default:** `//go:debug fips140=on` directive in the `main` package — FIPS-approved crypto always active, matching the previous `strictfipsruntime` behavior. **`fips140=on`, not `fips140=auto`:** upstream Go's `fips140` GODEBUG accepts only `on`/`off`/`only`; `auto` is an RH go-toolset extension that panics at runtime on upstream toolchains.
- **Startup assertion:** each component checks `/proc/sys/crypto/fips_enabled` and aborts if the host is in FIPS mode but the FIPS module is not active (i.e. an explicit `GODEBUG=fips140=off` override).
- **Base image:** runtime stage is ubi9-micro (no OpenSSL). Pure-Go binaries need only glibc. No component relies on system CA roots for its *own* in-cluster TLS — TLS egress uses mounted volume CAs (kube API service-account CA, config-provided CAs). Exception: the **hub** and the **agentic-operator** accept spoke kubeconfigs without inline `certificate-authority-data`; those connections verify spoke API servers against **system trust roots**, so their images carry the public CA bundle (PEM copied from the builder stage — pure data, parsed natively by Go, no OpenSSL). The otel-collector's egress is in-cluster PostgreSQL (`sslmode=require`) and local file export.

### Component status

| Component | CGO | Notes |
|---|---|---|
| lightspeed-operator | off | standard pattern |
| lightspeed-agentic-operator | off | standard pattern |
| lightspeed-hub | off | standard pattern |
| lightspeed-otel-collector | off | assertion in `init()` — `main.go` is OCB-generated (DO NOT EDIT), so the check lives in a non-generated `fips.go` that survives `make generate` |
| lightspeed-agentic-alerts-adapter | off (already) | was already `CGO_ENABLED=0` on ubi9-micro; FIPS module wiring added |
| lightspeed-rag-content (byok-go) | **on (kept)** | CGo is faiss/onnxruntime (non-crypto); Go crypto (`crypto/sha256`, `crypto/rand`) covered by the FIPS module; image already ubi9-micro with no OpenSSL |

**Out of scope:** `openshift-mcp-server` — consumed by OLS as an operand image, built by another team in `openshift/openshift-mcp-server`. `lightspeed-service` and `lightspeed-agentic-sandbox` are Python (OpenSSL via the `ssl` module; stay on UBI with OpenSSL).

## Alternatives Considered

- **Keep the OpenSSL/CGo path** — rejected: fails check-payload at Go 1.27, keeps the scalability problem and toolchain lag
- **`//go:debug fips140=auto`** — rejected: not valid upstream Go; runtime panic on non-RH toolchains
- **`GOEXPERIMENT=boringcrypto`** — rejected: legacy path, conflicts with `GOFIPS140`, same check-payload endgame
- **`GODEBUG=fips140=...` via container ENV only** — rejected: check-payload validates the compiled-in `DefaultGODEBUG`; the `//go:debug` directive is the compliant mechanism

## Consequences

- Binaries are pure Go (except byok-go) with no OpenSSL dependency; images are smaller with no OpenSSL CVE exposure
- Compliance is validated automatically: check-payload in the Konflux EC gates enforces `fips140` in compiled-in DefaultGODEBUG + certified `GOFIPS140` module + module version range
- In FIPS mode, non-approved key exchange (X25519, X25519MLKEM768) and ciphers are unavailable at runtime — peers offering only non-FIPS TLS parameter sets fail; covered by QE FIPS-cluster e2e regression, not by scanners
- New Go components must follow this pattern from the start (build flags, `//go:debug fips140=on`, startup assertion, ubi9-micro, no system-CA reliance)
