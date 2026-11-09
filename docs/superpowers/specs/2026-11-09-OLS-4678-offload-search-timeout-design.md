# OLS-4678: thread-safe regex timeout for `search_offloaded_content`

**Jira:** [OLS-4678](https://redhat.atlassian.net/browse/OLS-4678)
**Repo:** `lightspeed-service`
**Size:** small change

## Intent

`search_offloaded_content` fails on non-streaming `/v1/query` with `signal only works in main thread of the main interpreter`. The streaming endpoint works. The fix must make the search work in any thread and keep a regex timeout that really stops a slow pattern.

Cause: `_find_matches_with_timeout` (`ols/src/tools/offloaded_content.py`) builds the timeout with `signal.signal(SIGALRM, ...)`. Python allows this only in the main thread. `/v1/query` is a sync endpoint, so FastAPI runs it in a worker thread, and `run_async_safely` runs the agent there with `asyncio.run`. A cluster test confirmed the scope on 2026-11-09 (work plan 005, WI-01).

## Goals

- `search_offloaded_content` returns results on `/v1/query` and `/v1/streaming_query`.
- A slow pattern still stops after `OFFLOAD_REGEX_TIMEOUT_SECONDS` (5 s total per search) and returns the existing timeout error text.
- `regex` becomes an explicit direct dependency of `lightspeed-service`.

## Non-goals

- Changing either endpoint, or making `/v1/query` async.
- Changing the timeout value, the result format, or `read_offloaded_content`.

## Anti-goals

- Removing the timeout, or keeping it only on the main thread.
- Relying on `regex` being present only as a transitive dependency.

## Approaches

| Approach | Trade-off | Outcome |
|---|---|---|
| A. `regex` package with `timeout=` on each `search` | Small change; the engine checks the timeout during matching. Syntax is designed to be `re`-compatible, but rare edge cases differ. | **Chosen** by the user. |
| B. Child process, killed on timeout | Standard library only, guaranteed stop. Costs a process start per search, copies up to 50 MB of lines, and needs `spawn` in a threaded server. | Rejected: too much machinery for one tool. |
| Worker thread + `future.result(timeout=...)` | `re` holds the GIL during a match, so the caller cannot wake up. A spike returned control only after 16.9 s on a 1 s timeout. | Dropped: does not stop anything. |
| `google-re2` (linear time, no timeout) | Rejects back-references and lookarounds; adds a new native dependency to the hermetic build. | Dropped. |

Spike evidence (2026-11-09, throwaway scripts): `regex.compile(...).search(line, timeout=1)` raised `TimeoutError` after 1.0 s inside a worker thread.

## Decided design

1. **Dependency.** Follow `CONTRIBUTING.md` "Add a new dependency":
   - `uv add regex`, with a lower bound `regex>=2026.9.29` (the version already locked) in `pyproject.toml`.
   - `make bump PKG=regex VERSION=2026.9.29` to regenerate `uv.lock`, `requirements.txt`, and the `.konflux/` hermetic files.
2. **Search helper.** In `offloaded_content.py`:
   - Compile the pattern with `regex.compile` and catch `regex.error` for invalid patterns, keeping the current error text.
   - `_find_matches_with_timeout` sets one deadline: `time.monotonic() + OFFLOAD_REGEX_TIMEOUT_SECONDS`.
   - For each line, it passes the time remaining as `timeout=`. If no time remains, or `regex` raises `TimeoutError`, it returns the existing timeout error.
   - Remove the `signal` import and the SIGALRM handler.
3. **Tests** (`tests/unit/tools/test_offloaded_content.py`):
   - Regression test: run a search in a worker thread through `asyncio.run`. It fails before the fix and passes after.
   - Timeout test with a real slow pattern off the main thread, with the timeout constant patched to a small value.
   - Update the existing `TestFindMatchesWithTimeout` fake pattern for the new `search(line, timeout=...)` call.

## Left to the builder

- Type annotations (`regex.Pattern`) and whether mypy needs a `types-regex` stub or an ignore. Follow the repo's existing mypy settings.
- The exact test names and fixtures, following `docs/ai/testing.md`.

## My calls (not discussed)

- Keep a single 5 s budget for the whole search, not 5 s per line. This matches today's SIGALRM behavior.
- Do not pass `concurrent=True` to release the GIL during matching. Today's code also holds the GIL, so this keeps behavior the same and the change small.
