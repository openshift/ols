# OLS-3352: ModernType TLS Profile Cipher Fix

## Problem

Starting OLS with `tlsSecurityProfile.type: ModernType` causes a fatal
`ssl.SSLError: ('No cipher can be selected.',)` during Uvicorn startup.

OpenSSL exposes two separate APIs for cipher configuration:

- `SSL_CTX_set_cipher_list` → Python's `SSLContext.set_ciphers()` → TLS 1.2 cipher strings
- `SSL_CTX_set_ciphersuites` → Python's `SSLContext.set_ciphersuites()` → TLS 1.3 ciphersuites

Uvicorn only calls `set_ciphers()` via its `ssl_ciphers` parameter. ModernType's
cipher list contains exclusively TLS 1.3 ciphersuites (`TLS_AES_*`, `TLS_CHACHA20_*`),
which `set_ciphers()` does not recognize → error.

IntermediateType works accidentally because it includes TLS 1.2 cipher strings
alongside TLS 1.3 ciphersuites. `set_ciphers()` ignores the unrecognized TLS 1.3
names and succeeds on the TLS 1.2 entries. TLS 1.3 suites are then enabled by
OpenSSL's default behavior regardless.

## Solution

Split the cipher string into TLS 1.2 and TLS 1.3 components at the point of
consumption (the Uvicorn runner), then route each to the correct OpenSSL API.

### New helper: `split_ciphers()` in `ols/utils/ssl.py`

```python
@dataclass(frozen=True, slots=True)
class SplitCiphers:
    tls12: Optional[str]  # colon-separated for set_ciphers(), None if empty
    tls13: Optional[str]  # colon-separated for set_ciphersuites(), None if empty


def split_ciphers(cipher_string: Optional[str]) -> SplitCiphers:
    """Separate a cipher string into TLS 1.2 ciphers and TLS 1.3 ciphersuites.

    TLS 1.3 ciphersuites are identified by the 'TLS_' prefix per RFC 8446.
    Output uses colon separation as required by OpenSSL APIs.
    """
    if cipher_string is None:
        return SplitCiphers(tls12=None, tls13=None)

    tls12, tls13 = [], []
    for cipher in (c.strip() for c in cipher_string.replace(":", ",").split(",")):
        if not cipher:
            continue
        if cipher.startswith("TLS_"):
            tls13.append(cipher)
        else:
            tls12.append(cipher)

    return SplitCiphers(
        tls12=":".join(tls12) if tls12 else None,
        tls13=":".join(tls13) if tls13 else None,
    )
```

### Modified runner: `ols/runners/uvicorn.py`

```python
def start_uvicorn(config: AppConfig) -> None:
    # ... existing setup ...
    ssl_ciphers_str = ssl_utils.get_ciphers(sec_profile)
    ciphers = ssl_utils.split_ciphers(ssl_ciphers_str)

    uvicorn_config = uvicorn.Config(
        # ... other params ...
        ssl_ciphers=ciphers.tls12 or "DEFAULT",
    )
    uvicorn_config.load()

    if uvicorn_config.ssl is not None:
        if min_tls_version is not None:
            uvicorn_config.ssl.minimum_version = min_tls_version
        if ciphers.tls13 is not None:
            uvicorn_config.ssl.set_ciphersuites(ciphers.tls13)

    server = uvicorn.Server(uvicorn_config)
    server.run()
```

When `tls12` is `None` (ModernType), `"DEFAULT"` is passed so Uvicorn's
`set_ciphers()` succeeds with OpenSSL's compiled-in defaults. These TLS 1.2
ciphers are never reachable because `minimum_version = TLSv1_3` prevents
TLS 1.2 handshakes entirely.

## Design Decisions

### Why split at the runner, not in `tls.py`?

The `TLS_CIPHERS` dict in `tls.py` mirrors the upstream OpenShift API definition
verbatim. Keeping it as a flat list per profile preserves this 1:1 mapping. The
split is an implementation detail of how we hand ciphers to OpenSSL — it belongs
at the consumption point.

### Why colon-separated output?

`SSLContext.set_ciphersuites()` strictly requires colon-separated format.
`SSLContext.set_ciphers()` accepts both commas and colons (OpenSSL behavior).
Using colons for both is correct and consistent.

### ModernType with `ssl_ciphers="DEFAULT"`

Uvicorn's `Config` class expects a string for `ssl_ciphers` (it passes the value
directly to `ctx.set_ciphers()`). Passing `None` would cause a TypeError. When
there are no TLS 1.2 ciphers (ModernType), we pass `"DEFAULT"` — a valid OpenSSL
cipher string meaning "use compiled-in defaults". These TLS 1.2 ciphers are never
reachable because `minimum_version = TLSv1_3` prevents TLS 1.2 handshakes entirely.
Security posture is fully enforced by: min-version (protocol) + set_ciphersuites
(allowed suites).

### Delimiter normalization

The existing `tls.ciphers_from_list()` outputs comma-space separated strings.
`split_ciphers()` accepts any mix of commas, colons, and spaces as input, and
always outputs colon-separated. This makes the function robust against format
changes upstream.

## Behavior Matrix

| Profile | tls12 | tls13 | Runner behavior |
|---|---|---|---|
| ModernType | `None` → passes `"DEFAULT"` | `TLS_AES_128_GCM_SHA256:TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256` | `set_ciphers("DEFAULT")` (irrelevant, min TLS 1.3), `set_ciphersuites()` post-load |
| IntermediateType | 8 ciphers | 3 ciphersuites | Both APIs called with explicit lists |
| OldType | 14 ciphers | 3 ciphersuites | Both APIs called with explicit lists |
| No profile (default) | 14 ciphers | 3 ciphersuites | Both APIs called with explicit lists |
| Custom (TLS 1.2 only) | N ciphers | `None` | Only `set_ciphers()`, no post-load patching |

## Files Changed

| File | Change |
|---|---|
| `ols/utils/ssl.py` | Add `SplitCiphers` dataclass and `split_ciphers()` function |
| `ols/runners/uvicorn.py` | Use `split_ciphers()`, pass TLS 1.2 to Uvicorn, call `set_ciphersuites()` post-load |
| `tests/unit/utils/test_ssl.py` | Add tests for `split_ciphers()` covering all profiles, None, empty |
| `tests/unit/runners/test_uvicorn_runner.py` | Update mock assertions: `ssl_ciphers` is now TLS 1.2 only (or None), add `set_ciphersuites()` assertion |

## Verification

- Unit tests cover the split logic and runner wiring.
- `make tls-scan` (OLS-2866) exercises this end-to-end: starts OLS with ModernType
  and runs `openshift/tls-scanner` against it. Currently fails at startup; after
  this fix it should pass.

## Not in Scope

- Upstreaming a `ssl_ciphersuites` parameter to Uvicorn (nice-to-have, not blocking).
- Changing `tls.py` cipher list format or `ciphers_from_list()` separator.
- Fixing the "dead code" issue where TLS 1.3 entries in IntermediateType/OldType
  were never actually applied by `set_ciphers()` — this fix makes them properly
  effective via `set_ciphersuites()`.
