# 0048: x86-64-v2 ISA Level Guarantee for Go Binaries

**Status:** Accepted
**Applies to:** lightspeed-operator, lightspeed-agentic-operator, lightspeed-hub, lightspeed-otel-collector, lightspeed-agentic-alerts-adapter, lightspeed-rag-content
**Tracking:** [OLS-2703](https://redhat.atlassian.net/browse/OLS-2703) (original incident), [OLS-4668](https://redhat.atlassian.net/browse/OLS-4668) (migration that changed the enforcement model)

## Context

OCP supports x86-64 CPUs at ISA level v2 at minimum (documented per release). In OLS-2703 (Feb 2026), OLS 1.0.8/1.0.9 failed to start on Xeon E5-2650L v2 CPUs with:

```
/manager: CPU ISA level is lower than required
```

RCA: the operator was built with a UBI10-based go-toolkit. RHEL 10's baseline is x86-64-v3, so the *toolchain default* (no explicit setting) produced a v3-marked binary. Fixed at the time by moving to UBI9 tooling.

The clean error message came from **glibc's dynamic loader (`ld.so`)**, which reads the `GNU_PROPERTY_X86_ISA_1_NEEDED` ELF note (`.note.gnu.property`, per the x86-64 psABI feature levels v1–v4) and refuses to run a binary whose declared ISA level exceeds the CPU. The Linux kernel itself does not enforce the ISA bits (it only acts on CET properties in the same note) — for dynamically linked binaries, ld.so is the enforcement point.

The FIPS migration (decision [0047](0047-native-go-fips.md)) changed the enforcement mechanics: pure-Go builds (`CGO_ENABLED=0`, Go's internal linker) are statically linked, so ld.so never runs, and Go's internal linker does not emit the `GNU_PROPERTY_X86_ISA_1_NEEDED` note at any `GOAMD64` level. However, Go's runtime performs its **own startup check**: `rt0` (runtime/asm_amd64.s) compares CPUID against the compiled `GOAMD64` level before any user code runs and aborts with `This program can only be run on AMD64 processors with vN microarchitecture support` on an insufficient CPU. Consequences:

| | CGo / gcc-linked | Pure Go / static |
|---|---|---|
| Toolchain defaults to v3 | binary marked v3 via ELF note | v3 codegen, no ELF note |
| Runtime on v2 CPU | clean ld.so error (OLS-2703 behavior) | clean Go runtime fatal error (microarchitecture message) |
| Runtime enforcement | glibc `ld.so` (ELF note) | Go runtime `rt0` (compiled `GOAMD64` level) |

## Decision

Every Go binary the OLS project ships is verified at image build time to target at most x86-64-v2, via a shared `cmd/check-isa-level` tool with two tiers:

1. **ELF note present** (gcc/externally linked binaries — e.g. rag-content's byok-go): check `GNU_PROPERTY_X86_ISA_1_NEEDED` bits directly.
2. **ELF note absent** (pure-Go, internal linker): read the `GOAMD64` build setting recorded in the binary's build info (Go records it even when defaulted) and fail if it exceeds v2. Fail closed if build info or the setting is missing — the codegen baseline cannot be verified.

Additionally, pure-Go builds pin **`GOAMD64=v2` explicitly** in the build invocation. This closes the OLS-2703 footgun at the source: a toolchain whose default baseline exceeds v2 (e.g. a future UBI10 go-toolset) would otherwise silently raise the codegen level.

The check runs in the image builder stage of every Go component's Dockerfile/Containerfile (non-x86-64 target ELF binaries pass — the checker dispatches on the target's ELF machine type). Both runtime enforcement points produce clean errors rather than SIGILL, so the build-time check's value is **shift-left**: a toolchain default that raises the ISA level fails in CI with clear attribution instead of failing at pod startup on a customer cluster — OLS-2703 was discovered by a customer precisely because the failure only surfaced at runtime. The `GOAMD64=v2` pin additionally prevents the failure from occurring at all. The checker also covers the mixed CGo case where the GNU property note (aggregated from the C objects) stays at baseline while the Go code was compiled at a raised `GOAMD64` level.

## Alternatives Considered

- **Rely on runtime checks alone (ld.so / Go rt0)** — rejected: both produce clean errors, but only at pod startup on customer clusters; OLS-2703 showed toolchain defaults surface exactly there
- **External linking (`-linkmode external`) to get the ELF note** — rejected: requires gcc at link time and loses internal-linker properties, to obtain a note that is still only tool-enforced
- **Instruction-level disassembly scan** — rejected: fragile and unnecessary; the realistic risk is toolchain defaults (OLS-2703), which the declared-baseline checks catch

## Consequences

- All Go components run `check-isa-level` in CI image builds; a v3/v4 baseline fails the build instead of failing a customer cluster at pod startup (where Go's rt0 would abort it, or ld.so for CGo binaries)
- New Go repos/components must include `cmd/check-isa-level` (copy from lightspeed-operator), pin `GOAMD64=v2`, and run the check in the builder stage
- Toolchain or builder-image changes (e.g. UBI10 go-toolset) that raise the default ISA level are caught in CI
- The build-info tier verifies the *declared codegen baseline* (`GOAMD64`), not emitted instructions; hand-written assembly using v3+ without markers would not be caught — accepted risk, no hand-written assembly exists in these repos
- Upstream Go could close the gap natively by emitting the psABI note from `GOAMD64`; the ELF-note tier would then cover pure-Go binaries too (potential upstream issue)
