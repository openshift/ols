<!-- markdownlint-disable MD029 MD013 -->

# Provider-Egress TLS and CA

Cross-repo extension specification for provider-egress TLS and CA handling
across the classic operator, agentic operator, and agentic sandbox. It extends
the handoff foundation defined in
`docs/superpowers/specs/2026-07-21-inter-operator-handoff.md` and covers
OLS-3038 / OLS-3041 / OLS-3042. It adds TLS and CA parameters without
replacing the existing handoff behavior. OLS-3857, including per-MCP-server CA
configuration or trust selection, is explicitly out of scope.

## Behavioral Rules

### Configuration Ownership

1. **Classic source of truth.** The classic `lightspeed-operator` is the
   source of truth for the existing `OLSConfig` TLS and CA configuration. It
   validates user input, resolves OpenShift TLS profile defaults, and
   publishes the resulting non-secret values and object references.

2. **Existing API surface.** The configuration MUST reuse
   `spec.ols.tlsSecurityProfile` and
   `spec.ols.additionalCAConfigMapRef`. No TLS or CA configuration MAY be
   added to `AgenticOLSConfig`.

3. **Classic validation.** The classic operator MUST validate
   `additionalCAConfigMapRef` using the existing additional-CA validation
   behavior. It MUST resolve `tlsSecurityProfile` to a profile type, minimum
   TLS version, and cipher-suite list using the existing OpenShift
   profile/default logic.

4. **Agentic pass-through.** The agentic operator MUST NOT calculate TLS
   profile defaults or translate cipher names. It consumes the resolved
   values and passes them to newly created sandbox Pods.

### Handoff ConfigMap

1. **Handoff resource.** The classic operator MUST publish the handoff through
   the existing `lightspeed-agentic-configuration` ConfigMap in the shared OLS
   namespace. Every handoff value is a string in `ConfigMap.data`.

2. **TLS profile keys.** The handoff MUST use these keys:

   | Key | Value | Presence and meaning |
   | --- | --- | --- |
   | `tls-profile` | `Intermediate`, `Modern`, `Old`, or `Custom` | Resolved OpenShift TLS profile type. |
   | `tls-min-version` | `VersionTLS12` or `VersionTLS13` | Resolved minimum TLS protocol version. |
   | `tls-cipher-suites` | JSON array of cipher-suite names | Resolved cipher list. It is absent only when the resolved profile has no explicit list. An empty JSON array is not used to mean “use defaults.” |

3. **CA reference keys.** The handoff MUST use these keys for CA source
   references:

   | Key | Value | Presence and meaning |
   | --- | --- | --- |
   | `additional-ca-configmap` | ConfigMap name | Present when `spec.ols.additionalCAConfigMapRef` is configured; absent otherwise. |
   | `otel-ca-secret` | Secret name | Existing operator-managed OTEL client-CA reference. |
   | `mcp-ca-secret` | Secret name | Existing operator-managed MCP client-CA reference when the standalone MCP endpoint is enabled. |
   | `rhokp-ca-secret` | Secret name | Existing operator-managed RHOKP client-CA reference when RHOKP is enabled. |

**Optional configuration behavior:**

- When `spec.ols.additionalCAConfigMapRef` is unset,
  `additional-ca-configmap` MUST be absent and the agentic operator MUST NOT
  add an `additional-ca/` volume. The system trust store and independently
  configured integration CA sources remain in effect.
- When `spec.ols.tlsSecurityProfile` is unset, the classic operator MUST use
  its existing effective-profile resolution: the cluster API server TLS
  profile, falling back to the existing operator default when the API server
  does not specify one. It MUST publish the resolved TLS values; the sandbox
  MUST NOT calculate a separate default.

4. **No certificate data in handoff.** The classic operator MUST publish
   object names only. Certificate bytes MUST NOT be copied into the handoff
   ConfigMap.

5. **Existing CA Secret contracts.** The existing operator-managed Secret
   contracts remain unchanged:

   - `lightspeed-agentic-otel-ca` contains the existing OTEL client CA key.
   - `lightspeed-agentic-mcp-ca` contains the existing MCP client CA key.
   - `lightspeed-agentic-rhokp-ca` contains the existing RHOKP client CA key.

### Agentic Operator Pod Wiring

12. **Read-only source mounts.** For every new sandbox Pod, the agentic
    operator MUST mount configured CA sources read-only beneath:

    ```text
    /var/run/secrets/lightspeed/tls/
    ├── additional-ca/       # additional-ca-configmap, when present
    ├── otel/                 # otel-ca-secret, when present
    ├── mcp/                  # mcp-ca-secret, when present
    └── rhokp/                # rhokp-ca-secret, when present
    ```

13. **No operator-side aggregation.** The agentic operator MUST pass source
    files through. It MUST NOT inspect certificate contents, aggregate
    certificates, deduplicate references, or attach `CASource` purpose
    metadata.

14. **No individual CA knowledge in sandbox code.** Individual CA Secret
    names and source-specific filenames MUST NOT appear in sandbox runtime
    code. They are handoff and Pod-mount concerns only.

15. **TLS value pass-through.** The agentic operator MUST pass the resolved
    TLS values to the sandbox using the sandbox runtime configuration
    interface. It MUST pass values unchanged and MUST NOT implement
    provider-specific CA selection.

### Sandbox Runtime

14. **Generic certificate discovery.** The sandbox MUST scan regular `.crt`
    and `.pem` files below `/var/run/secrets/lightspeed/tls/`, including files
    supplied by the additional CA ConfigMap and operator-managed integration
    Secrets.

15. **Combined runtime bundle.** The sandbox MUST validate required mounted
    certificate material, combine valid mounted certificates with the
    platform/system trust store, and use the resulting runtime bundle. It
    MUST NOT replace or mutate the system trust store.

16. **Bundle-only provider use.** Runtime and provider TLS code MUST use the
    combined bundle as the CA source. It MUST NOT contain individual OTEL,
    MCP, RHOKP, or additional-CA Secret names, paths, or provider-specific CA
    selection logic.

17. **Resolved TLS settings.** The sandbox MUST apply the resolved minimum
    TLS version and cipher-suite list using native runtime/provider behavior.
    It MUST NOT infer OpenShift profile defaults or translate OpenShift cipher
    names.

18. **No custom sources.** When no additional CA reference or integration CA
    is configured, existing system-trust behavior MUST be preserved.

19. **Certificate failure.** Missing or malformed required mounted certificate
    material MUST produce an actionable sandbox configuration failure. It MUST
    NOT be silently ignored.

20. **Non-CA Secrets.** Provider credentials, client certificates/keys, and MCP
    authentication Secrets are not CA-bundle inputs. They remain separate when
    required by their protocols.

### Updates and Watches

21. **Handoff updates.** Changes to the TLS profile, resolved values, or
    referenced object names MUST update the handoff ConfigMap. The agentic
    operator reloads the handoff and uses new values for subsequently created
    Pods.

22. **Mounted source updates.** Updates to data in a referenced ConfigMap or
    Secret follow Kubernetes mounted-volume propagation. Existing Pods are
    not recreated solely because a referenced source object changed.

23. **Watch boundary.** The agentic operator MUST watch only
    `lightspeed-agentic-configuration`. It MUST NOT add watches for
    `additional-ca-configmap` or any referenced CA Secret.

24. **Changed references.** A changed source-object name MUST be delivered by
    a handoff ConfigMap update. Neither operator watches source objects to
    rebuild or rewrite the runtime bundle.

25. **Invalid handoff.** If the handoff is absent, malformed, or contains an
    invalid required reference, the affected sandbox configuration path MUST
    fail with an actionable error. The agentic operator MUST NOT invent TLS
    defaults.

## Integration Contracts

### User Configuration

```yaml
spec:
  ols:
    tlsSecurityProfile: # optional OpenShift TLSSecurityProfile
      type: Intermediate
    additionalCAConfigMapRef: # optional ConfigMap reference
      name: provider-ca
```

### Runtime TLS Environment

The agentic operator passes the resolved handoff values to the sandbox as:

| Environment variable | Source handoff key | Value |
| --- | --- | --- |
| `LIGHTSPEED_TLS_PROFILE` | `tls-profile` | OpenShift profile type. |
| `LIGHTSPEED_TLS_MIN_VERSION` | `tls-min-version` | OpenShift minimum-version value. |
| `LIGHTSPEED_TLS_CIPHER_SUITES` | `tls-cipher-suites` | JSON array of cipher-suite names. |

The exact provider-client mapping is owned by the sandbox specification. The
sandbox applies the supplied values but does not derive profile defaults or
translate cipher names.

## Repo Ownership

| Repo | Owns |
| --- | --- |
| **lightspeed-operator** | Validate classic TLS/CA configuration, resolve profile values, manage CA Secrets, and publish handoff references/values. |
| **lightspeed-agentic-operator** | Consume handoff values and wire read-only ConfigMap/Secret mounts into sandbox Pods. |
| **lightspeed-agentic-sandbox** | Discover mounted certificates, build the runtime trust bundle, configure Python/provider TLS, and apply resolved TLS settings. |

## Child Spec Updates Required

| Repo | Spec files | Required update |
| --- | --- | --- |
| lightspeed-operator | `what/tls.md` | Document profile resolution, additional-CA validation, handoff keys, and existing CA Secret references. |
| lightspeed-agentic-operator | `what/sandbox-execution.md`, `docs/inter-operator-handoff-design.md` | Document read-only source mounts, handoff pass-through, stable mount paths, and the watch boundary. |
| lightspeed-agentic-sandbox | `what/configuration.md` | Document generic certificate discovery, combined-bundle use, runtime TLS variables, and the exclusion of individual CA Secret knowledge from code. |

## Required Test Coverage

### Classic Operator

- `spec.ols.tlsSecurityProfile` resolves to the expected profile type,
  minimum version, and cipher list.
- `spec.ols.additionalCAConfigMapRef` is validated using the existing classic
  validation path.
- The handoff contains object names and resolved values but no certificate
  bytes.
- Existing operator-managed CA Secret refresh behavior remains unchanged.

### Agentic Operator

- Handoff TLS values are passed through without default calculation or cipher
  translation.
- Additional CA and integration CA sources are mounted read-only beneath the
  common TLS root.
- The operator watches the handoff only, not referenced Secrets or ConfigMaps.
- References are not deduplicated and no purpose metadata is added.
- A changed handoff affects subsequently created Pods.

### Agentic Sandbox

- Certificate files are discovered generically below the common TLS root.
- The runtime bundle includes system trust plus mounted CA certificates.
- Provider/runtime TLS code uses the combined bundle rather than an individual
  source path.
- The sandbox code contains no individual CA Secret names or source-specific
  CA filenames.
- Malformed required certificate material produces an actionable failure.
- Provider credentials, client certificates/keys, and MCP authentication
  Secrets remain separate from the CA bundle.

## Constraints

- Certificate bytes MUST NOT be copied into the handoff ConfigMap.
- Neither operator MAY aggregate certificates.
- The agentic operator MUST NOT watch referenced CA ConfigMaps or Secrets.
- The agentic operator MUST NOT deduplicate CA references.
- The sandbox MUST preserve the system trust store and add mounted CA material
  through a runtime bundle.
- No `AgenticOLSConfig` TLS/CA API is introduced.
- OLS-3857 and per-MCP-server CA configuration/trust selection are out of
  scope.

## Planned Changes

| Tracking item | Scope |
| --- | --- |
| [EPIC: OLS-3038] | Parent tracking item for the cross-repository provider-egress TLS and CA work. |
| [PLANNED: OLS-3041] | Agentic-operator implementation: consume the handoff and mount CA sources into sandbox Pods. |
| [PLANNED: OLS-3042] | Agentic-sandbox implementation: build the combined CA bundle and configure Python/provider TLS to use it. |
| [PLANNED: new classic-operator ticket] | Classic `lightspeed-operator` implementation: validate/resolve configuration and publish the handoff values and references. |
| [OUT OF SCOPE: OLS-3857] | Per-MCP-server CA configuration and trust selection are not part of this design. |
