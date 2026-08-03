# OLS-3352: ModernType TLS Cipher Fix — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix ModernType TLS profile startup crash by correctly routing TLS 1.3 ciphersuites to `SSLContext.set_ciphersuites()` instead of `SSLContext.set_ciphers()`.

**Architecture:** Add a `split_ciphers()` helper in `ols/utils/ssl.py` that separates cipher strings by TLS version. Modify the Uvicorn runner to pass TLS 1.2 ciphers to Uvicorn's config and call `set_ciphersuites()` post-load for TLS 1.3.

**Tech Stack:** Python 3.12, OpenSSL 3.x (`ssl` stdlib), Uvicorn, pytest

## Global Constraints

- Python `ssl` module APIs: `set_ciphers()` for TLS 1.2, `set_ciphersuites()` for TLS 1.3
- Colon-separated format required by both OpenSSL APIs
- `tls.py` cipher data must not be modified (mirrors upstream OpenShift API)
- Existing tests must continue to pass after modifications

---

## File Structure

| File | Responsibility |
|---|---|
| `ols/utils/ssl.py` | `SplitCiphers` dataclass + `split_ciphers()` function |
| `ols/runners/uvicorn.py` | Consumes split ciphers, routes to correct APIs |
| `tests/unit/utils/test_ssl.py` | Unit tests for `split_ciphers()` |
| `tests/unit/runners/test_uvicorn_runner.py` | Updated runner tests with new assertions |

---

### Task 1: Add `split_ciphers()` helper with tests

**Files:**
- Modify: `ols/utils/ssl.py` (add `SplitCiphers` dataclass and `split_ciphers()` at end of file)
- Modify: `tests/unit/utils/test_ssl.py` (add test class at end of file)

**Interfaces:**
- Consumes: cipher strings from `get_ciphers()` (comma-space separated, e.g. `"TLS_AES_128_GCM_SHA256, ECDHE-RSA-AES128-GCM-SHA256"`)
- Produces: `split_ciphers(cipher_string: Optional[str]) -> SplitCiphers` where `SplitCiphers` has `.tls12: Optional[str]` and `.tls13: Optional[str]` (colon-separated)

- [ ] **Step 1: Write the failing tests for `split_ciphers()`**

Add to `tests/unit/utils/test_ssl.py`:

```python
from ols.utils.ssl import SplitCiphers, split_ciphers


class TestSplitCiphers:
    """Tests for the split_ciphers helper."""

    def test_none_input(self):
        """Return both fields as None when input is None."""
        result = split_ciphers(None)
        assert result == SplitCiphers(tls12=None, tls13=None)

    def test_empty_string(self):
        """Return both fields as None when input is empty."""
        result = split_ciphers("")
        assert result == SplitCiphers(tls12=None, tls13=None)

    def test_tls13_only(self):
        """ModernType: all ciphers are TLS 1.3 ciphersuites."""
        cipher_str = (
            "TLS_AES_128_GCM_SHA256, TLS_AES_256_GCM_SHA384, "
            "TLS_CHACHA20_POLY1305_SHA256"
        )
        result = split_ciphers(cipher_str)
        assert result.tls12 is None
        assert result.tls13 == (
            "TLS_AES_128_GCM_SHA256:TLS_AES_256_GCM_SHA384:"
            "TLS_CHACHA20_POLY1305_SHA256"
        )

    def test_tls12_only(self):
        """Custom profile with only TLS 1.2 ciphers."""
        cipher_str = "ECDHE-RSA-AES128-GCM-SHA256, DHE-RSA-AES256-GCM-SHA384"
        result = split_ciphers(cipher_str)
        assert result.tls12 == "ECDHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384"
        assert result.tls13 is None

    def test_mixed_ciphers(self):
        """IntermediateType: mix of TLS 1.2 and TLS 1.3."""
        cipher_str = (
            "TLS_AES_128_GCM_SHA256, TLS_AES_256_GCM_SHA384, "
            "TLS_CHACHA20_POLY1305_SHA256, "
            "ECDHE-ECDSA-AES128-GCM-SHA256, ECDHE-RSA-AES128-GCM-SHA256"
        )
        result = split_ciphers(cipher_str)
        assert result.tls12 == (
            "ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256"
        )
        assert result.tls13 == (
            "TLS_AES_128_GCM_SHA256:TLS_AES_256_GCM_SHA384:"
            "TLS_CHACHA20_POLY1305_SHA256"
        )

    def test_colon_separated_input(self):
        """Accept colon-separated input (OpenSSL native format)."""
        cipher_str = "TLS_AES_128_GCM_SHA256:ECDHE-RSA-AES128-GCM-SHA256"
        result = split_ciphers(cipher_str)
        assert result.tls12 == "ECDHE-RSA-AES128-GCM-SHA256"
        assert result.tls13 == "TLS_AES_128_GCM_SHA256"
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /home/ometelka/projects/ols/lightspeed-service && python -m pytest tests/unit/utils/test_ssl.py::TestSplitCiphers -v`
Expected: FAIL with `ImportError: cannot import name 'SplitCiphers' from 'ols.utils.ssl'`

- [ ] **Step 3: Implement `SplitCiphers` and `split_ciphers()` in `ols/utils/ssl.py`**

Add at the top of `ols/utils/ssl.py` (after existing imports):

```python
from dataclasses import dataclass
```

Add at the end of `ols/utils/ssl.py`:

```python
@dataclass(frozen=True, slots=True)
class SplitCiphers:
    """TLS 1.2 ciphers and TLS 1.3 ciphersuites separated for OpenSSL APIs."""

    tls12: Optional[str]
    tls13: Optional[str]


def split_ciphers(cipher_string: Optional[str]) -> SplitCiphers:
    """Separate a cipher string into TLS 1.2 ciphers and TLS 1.3 ciphersuites.

    TLS 1.3 ciphersuites are identified by the 'TLS_' prefix per RFC 8446.
    Output uses colon separation as required by OpenSSL APIs.
    Accepts comma-separated, colon-separated, or mixed input.
    """
    if not cipher_string:
        return SplitCiphers(tls12=None, tls13=None)

    tls12: list[str] = []
    tls13: list[str] = []
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

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd /home/ometelka/projects/ols/lightspeed-service && python -m pytest tests/unit/utils/test_ssl.py::TestSplitCiphers -v`
Expected: All 7 tests PASS

- [ ] **Step 5: Run the full test_ssl.py suite to confirm no regressions**

Run: `cd /home/ometelka/projects/ols/lightspeed-service && python -m pytest tests/unit/utils/test_ssl.py -v`
Expected: All tests PASS (existing + new)

- [ ] **Step 6: Commit**

```bash
cd /home/ometelka/projects/ols/lightspeed-service
git add ols/utils/ssl.py tests/unit/utils/test_ssl.py
git commit -m "$(cat <<'EOF'
OLS-3352 add split_ciphers() helper for TLS 1.2/1.3 separation

Adds SplitCiphers dataclass and split_ciphers() function that separates
a cipher string into TLS 1.2 ciphers and TLS 1.3 ciphersuites based on
the TLS_ prefix. Output uses colon-separated format for OpenSSL APIs.
EOF
)"
```

---

### Task 2: Update Uvicorn runner to use split ciphers

**Files:**
- Modify: `ols/runners/uvicorn.py` (lines 39-57, restructure cipher handling)
- Modify: `tests/unit/runners/test_uvicorn_runner.py` (update mock assertions)

**Interfaces:**
- Consumes: `split_ciphers()` from `ols.utils.ssl` (Task 1), `get_ciphers()` from `ols.utils.ssl`
- Produces: correctly configured Uvicorn SSL context with both `set_ciphers()` and `set_ciphersuites()` applied

- [ ] **Step 1: Write updated runner tests**

Replace the `_assert_start_uvicorn` helper and add ModernType-specific test in `tests/unit/runners/test_uvicorn_runner.py`:

```python
import ssl as stdlib_ssl
from types import SimpleNamespace
from unittest.mock import Mock, patch

import pytest

from ols import constants
from ols.app.models.config import Config, TLSSecurityProfile
from ols.runners.uvicorn import start_uvicorn
from ols.utils import tls
from ols.utils.ssl import split_ciphers


@pytest.fixture
def default_config():
    """Fixture providing default configuration."""
    return Config(
        {
            "llm_providers": [],
            "ols_config": {
                "default_provider": "test_default_provider",
                "default_model": "test_default_model",
                "conversation_cache": {
                    "type": "memory",
                    "memory": {
                        "max_entries": 100,
                    },
                },
                "logging_config": {
                    "app_log_level": "error",
                },
                "certificate_directory": "/foo/bar/baz",
                "authentication_config": {"module": "foo"},
            },
            "dev_config": {"disable_tls": "true"},
        }
    )


def _assert_start_uvicorn(
    config: Config,
    *,
    host: str,
    port: int,
    min_tls_version,
    ssl_ciphers,
    expected_ciphersuites=None,
) -> None:
    """Assert the Uvicorn runner configures and starts the server."""
    fake_ssl_context = SimpleNamespace(
        minimum_version=None,
        set_ciphersuites=Mock(),
    )
    fake_uvicorn_config = SimpleNamespace(
        ssl=fake_ssl_context,
        loaded=False,
    )
    fake_uvicorn_config.load = Mock(
        side_effect=lambda: setattr(fake_uvicorn_config, "loaded", True)
    )
    fake_server = SimpleNamespace(run=Mock())

    with (
        patch("ols.runners.uvicorn.uvicorn.Config") as mocked_config,
        patch("ols.runners.uvicorn.uvicorn.Server") as mocked_server,
    ):
        mocked_config.return_value = fake_uvicorn_config
        mocked_server.return_value = fake_server
        start_uvicorn(config)

        mocked_config.assert_called_once_with(
            "ols.app.main:app",
            host=host,
            port=port,
            workers=1,
            log_level=30,
            ssl_keyfile=None,
            ssl_certfile=None,
            ssl_keyfile_password=None,
            ssl_version=constants.DEFAULT_SSL_VERSION,
            ssl_ciphers=ssl_ciphers,
            access_log=False,
        )
        assert fake_uvicorn_config.loaded is True
        assert fake_ssl_context.minimum_version == min_tls_version

        if expected_ciphersuites is not None:
            fake_ssl_context.set_ciphersuites.assert_called_once_with(
                expected_ciphersuites
            )
        else:
            fake_ssl_context.set_ciphersuites.assert_not_called()

        mocked_server.assert_called_once_with(fake_uvicorn_config)
        fake_server.run.assert_called_once_with()


def test_start_uvicorn(default_config):
    """Test the function to start Uvicorn server."""
    default_ciphers = split_ciphers(constants.DEFAULT_SSL_CIPHERS)
    _assert_start_uvicorn(
        default_config,
        host="0.0.0.0",  # noqa: S104
        port=8080,
        min_tls_version=None,
        ssl_ciphers=default_ciphers.tls12 or "DEFAULT",
        expected_ciphersuites=default_ciphers.tls13,
    )


def test_start_uvicorn_with_tls(default_config):
    """Test the function to start Uvicorn server with TLS enabled."""
    default_config.dev_config.disable_tls = False
    default_ciphers = split_ciphers(constants.DEFAULT_SSL_CIPHERS)
    _assert_start_uvicorn(
        default_config,
        host="0.0.0.0",  # noqa: S104
        port=8443,
        min_tls_version=None,
        ssl_ciphers=default_ciphers.tls12 or "DEFAULT",
        expected_ciphersuites=default_ciphers.tls13,
    )


def test_start_uvicorn_on_localhost(default_config):
    """Test the function to start Uvicorn server."""
    default_config.dev_config.run_on_localhost = True
    default_ciphers = split_ciphers(constants.DEFAULT_SSL_CIPHERS)
    _assert_start_uvicorn(
        default_config,
        host="localhost",
        port=8080,
        min_tls_version=None,
        ssl_ciphers=default_ciphers.tls12 or "DEFAULT",
        expected_ciphersuites=default_ciphers.tls13,
    )


def test_start_uvicorn_on_non_default_port(default_config):
    """Test the function to start Uvicorn server on a non-default port."""
    default_config.dev_config.uvicorn_port_number = 8081
    default_ciphers = split_ciphers(constants.DEFAULT_SSL_CIPHERS)
    _assert_start_uvicorn(
        default_config,
        host="0.0.0.0",  # noqa: S104
        port=8081,
        min_tls_version=None,
        ssl_ciphers=default_ciphers.tls12 or "DEFAULT",
        expected_ciphersuites=default_ciphers.tls13,
    )


@pytest.mark.parametrize(
    "profile_type,min_tls_version",
    [
        ("IntermediateType", stdlib_ssl.TLSVersion.TLSv1_2),
        ("ModernType", stdlib_ssl.TLSVersion.TLSv1_3),
    ],
)
def test_start_uvicorn_applies_min_tls_version(
    default_config, profile_type, min_tls_version
):
    """Test the function to start Uvicorn server with a TLS security profile."""
    default_config.dev_config.disable_tls = False
    default_config.ols_config.tls_security_profile = TLSSecurityProfile(
        {"type": profile_type}
    )
    cipher_str = tls.ciphers_for_tls_profile(profile_type)
    ciphers = split_ciphers(cipher_str)
    _assert_start_uvicorn(
        default_config,
        host="0.0.0.0",  # noqa: S104
        port=8443,
        min_tls_version=min_tls_version,
        ssl_ciphers=ciphers.tls12 or "DEFAULT",
        expected_ciphersuites=ciphers.tls13,
    )
```

- [ ] **Step 2: Run the updated tests to verify they fail**

Run: `cd /home/ometelka/projects/ols/lightspeed-service && python -m pytest tests/unit/runners/test_uvicorn_runner.py -v`
Expected: FAIL — the runner still passes the old unsplit cipher string

- [ ] **Step 3: Update `ols/runners/uvicorn.py`**

Replace the full file content with:

```python
"""Uvicorn runner."""

import logging

import uvicorn

from ols.utils import ssl as ssl_utils
from ols.utils.config import AppConfig

logger: logging.Logger = logging.getLogger(__name__)


def start_uvicorn(config: AppConfig) -> None:
    """Start Uvicorn-based REST API service."""
    logger.info("Starting Uvicorn")

    # use workers=1 so config loaded can be accessed from other modules
    host = (
        "localhost"
        if config.dev_config.run_on_localhost
        else "0.0.0.0"  # noqa: S104 # nosec: B104
    )
    port = config.dev_config.uvicorn_port_number or (
        8080 if config.dev_config.disable_tls else 8443
    )
    log_level = config.ols_config.logging_config.uvicorn_log_level

    # The tls fields can be None, which means we will pass those values through to Uvicorn.
    ssl_keyfile = config.ols_config.tls_config.tls_key_path
    ssl_certfile = config.ols_config.tls_config.tls_certificate_path
    ssl_keyfile_password = config.ols_config.tls_config.tls_key_password

    # setup SSL version and allowed SSL ciphers based on service configuration
    # when TLS security profile is not specified, default values will be used
    # that default values are based on default SSL package settings
    sec_profile = config.ols_config.tls_security_profile
    ssl_version = ssl_utils.get_ssl_version(sec_profile)
    min_tls_version = ssl_utils.get_min_tls_version(sec_profile)
    ssl_ciphers_str = ssl_utils.get_ciphers(sec_profile)
    ciphers = ssl_utils.split_ciphers(ssl_ciphers_str)

    uvicorn_config = uvicorn.Config(
        "ols.app.main:app",
        host=host,
        port=port,
        workers=config.ols_config.max_workers,
        log_level=log_level,
        ssl_keyfile=ssl_keyfile,
        ssl_certfile=ssl_certfile,
        ssl_keyfile_password=ssl_keyfile_password,
        ssl_version=ssl_version,
        ssl_ciphers=ciphers.tls12 or "DEFAULT",
        access_log=log_level < logging.INFO,
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

- [ ] **Step 4: Run runner tests to verify they pass**

Run: `cd /home/ometelka/projects/ols/lightspeed-service && python -m pytest tests/unit/runners/test_uvicorn_runner.py -v`
Expected: All tests PASS

- [ ] **Step 5: Run the full unit test suite to confirm no regressions**

Run: `cd /home/ometelka/projects/ols/lightspeed-service && python -m pytest tests/unit/ -v --timeout=60`
Expected: All tests PASS

- [ ] **Step 6: Run linting**

Run: `cd /home/ometelka/projects/ols/lightspeed-service && python -m ruff check ols/runners/uvicorn.py ols/utils/ssl.py tests/unit/runners/test_uvicorn_runner.py tests/unit/utils/test_ssl.py`
Expected: No errors

- [ ] **Step 7: Commit**

```bash
cd /home/ometelka/projects/ols/lightspeed-service
git add ols/runners/uvicorn.py tests/unit/runners/test_uvicorn_runner.py
git commit -m "$(cat <<'EOF'
OLS-3352 fix ModernType TLS profile startup crash

Route TLS 1.3 ciphersuites to SSLContext.set_ciphersuites() post-load
instead of passing them to Uvicorn's ssl_ciphers (which only calls
set_ciphers() for TLS 1.2). ModernType now starts successfully.
EOF
)"
```
