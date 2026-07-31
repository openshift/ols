# 0010: Konflux Hermetic Builds

**Status:** Accepted
**Applies to:** all repos with container images

## Context

Supply chain security requires reproducible, auditable builds. Network access during build allows dependency confusion attacks and produces non-deterministic images. Konflux is Red Hat's standard CI/CD platform for product images.

## Decision

All container images across OLS repos are built with Konflux CI using hermetic builds — no network access during build. Dependencies (Python wheels, RPMs, Go modules, npm packages) are declared in lockfiles and prefetched by Cachi2.

## Alternatives Considered

- **Non-hermetic CI** — rejected because of supply chain security risk and non-reproducible builds
- **GitHub Actions only** — rejected because it doesn't meet Red Hat product image pipeline requirements
- **Manual builds** — rejected because they are not reproducible or auditable

## Consequences

- All dependencies must be declared in lockfiles (PDM, go.sum, package-lock.json)
- Dual lockfiles needed for some repos (e.g., CPU/GPU variants for RAG content)
- CLI binaries (oc, kubectl) copied from Red Hat image stages, not downloaded
- Any new dependency requires lockfile update before CI passes
- Images are reproducible and auditable
