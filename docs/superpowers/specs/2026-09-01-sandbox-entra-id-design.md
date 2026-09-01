# SDK-delegated short-lived credentials in the sandbox (Azure Entra ID + Bedrock STS)

- **Tickets:** [OLS-3050](https://redhat.atlassian.net/browse/OLS-3050) (Azure Entra ID); OLS-4092 (Bedrock STS assume-role — no ticket yet)
- **Depends on:** OLS-3049 (Azure OpenAI adapter for sandbox — closed), OLS-3048 (Entra ID token-refresh spike — closed, superseded by this ticket)
- **Status:** Design
- **Date:** 2026-09-01
- **Repos touched:** `lightspeed-agentic-sandbox`, `lightspeed-agentic-operator`, `ols` (parent spec)

## Problem

Two agentic-sandbox providers can authenticate with **short-lived** tokens
derived from a **long-lived** credential, but the sandbox supports only the
static-credential form of each:

- **Azure OpenAI** works only via a static API key (`AZURE_OPENAI_API_KEY`).
  Customers who manage Azure access through Entra ID (Azure AD) service principals
  cannot use the sandbox — API keys are hard to rotate and many enterprises
  disable them entirely.
- **AWS Bedrock** (Anthropic models — already supported) works only via static
  IAM keys. Customers who use STS assume-role (`role_arn`) for short-lived AWS
  credentials cannot use it.

The classic OLS service already supports both (Entra ID for Azure; IAM + STS
assume-role for Bedrock). The sandbox must reach parity, and both cases share one
principle: mount the long-lived credential, delegate all short-lived token
minting and refresh to the provider SDK.

Support Azure Entra ID authentication using `tenant_id` / `client_id` /
`client_secret`, and Bedrock STS assume-role using `aws_access_key_id` /
`aws_secret_access_key` / optional `role_arn`, both mounted by the operator, with
transparent SDK-owned refresh during long agent runs and a fallback to the
static-credential form when the short-lived credential is absent. The
Anthropic-on-Bedrock **model** path is unchanged — only credential resolution
grows.

## Findings

1. **The classic service already implements this pattern.** `lightspeed-service`
   (`ols/src/llms/providers/azure_openai.py`) acquires an AAD token via
   `ClientSecretCredential.get_token()` scoped to
   `https://cognitiveservices.azure.com/.default`, caches it per-process with a
   30-second refresh leeway, falls back to `apitoken`, and reads
   `client_id`/`tenant_id`/`client_secret` from a mounted credentials directory.
   Specified in `lightspeed-service/.ai/spec/what/llm-providers.md` (rules 20–24)
   and `how/llm-providers.md`.

2. **The sandbox has no Entra ID support.** `config.py::_resolve_azure()` sets
   `AZURE_OPENAI_ENDPOINT` / `AZURE_OPENAI_API_VERSION` and expects only
   `AZURE_OPENAI_API_KEY`. `readiness.py` checks credential presence once at
   startup; there is no token-refresh path (the sandbox is a one-shot batch
   process with no credential hot-reload).

3. **The operator already mounts the whole credentials secret** both as `envFrom`
   and as a read-only volume at `/var/run/secrets/llm-credentials/`,
   unconditionally for every provider type
   (`lightspeed-agentic-operator/.ai/spec/what/sandbox-execution.md` rule 16). So
   extra service-principal keys flow through without operator *code* changes —
   only CRD validation and docs need updating.

4. **The sandbox's OpenAI adapter never constructs an Azure client.**
   `providers/openai.py` always builds a plain `AsyncOpenAI` (reading
   `OPENAI_BASE_URL`) wrapped in `OpenAIResponsesModel`; it does not branch on
   provider type and never instantiates `AsyncAzureOpenAI`. The `AZURE_OPENAI_*`
   env vars set by `_resolve_azure()` are not consumed by the adapter. This
   appears to be a gap left by OLS-3049 (the config-mapping half landed; the
   adapter Azure-client half did not). Entra ID therefore requires the adapter to
   grow a real Azure client-construction path first — this is in scope for
   OLS-3050.

5. **The Azure client is built into the OpenAI SDK, but the credential library
   is not.** The `openai` package (already present transitively via
   `openai-agents`) ships `AsyncAzureOpenAI` and its `azure_ad_token_provider`
   *parameter*. However, `ClientSecretCredential` and `get_bearer_token_provider`
   live in Microsoft's separate `azure-identity` package (module
   `azure.identity`), which also pulls `azure-core`. Neither `azure-identity` nor
   `azure-core` is in the sandbox's `pyproject.toml` / `uv.lock` today. Entra ID
   therefore adds a **new dependency** (see "Dependencies" below).

## Decisions

| # | Decision | Rationale |
|---|---|---|
| D1 | **Read service-principal values from the mounted files** at `/var/run/secrets/llm-credentials/` (`client_id`, `tenant_id`, `client_secret`; `apitoken` for the key fallback). | Matches the classic service's directory-of-files convention and key names — one credential-secret shape across the whole product. The operator already mounts this volume. |
| D2 | **Use the OpenAI SDK's built-in Azure support and delegate token generation/refresh to it.** Construct the SDK's native `AsyncAzureOpenAI` client and pass `azure_ad_token_provider = get_bearer_token_provider(ClientSecretCredential(...), "https://cognitiveservices.azure.com/.default")` to it. | The `openai` SDK ships first-class Azure support (`AsyncAzureOpenAI`) with a native `azure_ad_token_provider` hook; `azure.identity` caches and refreshes the short-lived access token internally, transparently across a long run. No manual token cache, no base-URL shim, no hand-built `Authorization` header in the sandbox. The client is built in; the credential provider comes from a new `azure-identity` dependency (see "Dependencies"). |
| D3 | **Update both operator and sandbox specs.** Operator adds `azureOpenAI` credential validation (either `apitoken` OR all three service-principal keys); sandbox adds the credential resolution + adapter path. | Completes the cross-repo contract and prevents the CRD from silently accepting an incomplete Entra secret. |
| D4 | **Fail fast on definitive auth failure; rely on SDK layers for transient retry.** | See "Failure and retry" below. |
| D5 | **Spec the full Azure client-construction path here** (`AsyncAzureOpenAI` + `OpenAIChatCompletionsModel` + api-key/Entra selection). | Entra ID cannot work without it; the OLS-3049 gap (Finding 4) is closed as part of this work. |
| D6 | **Generalize the short-lived-token principle** in the sandbox provider contract. | Vertex already delegates token lifecycle to google-auth; Azure Entra and Bedrock STS are two more instances of one reusable rule (see below). |
| D7 | **Add Bedrock STS assume-role as credential resolution only** — read `aws_access_key_id` / `aws_secret_access_key` / optional `role_arn` from the mounted files; when `role_arn` is set, let `botocore` perform the STS assume-role and refresh short-lived credentials. Do **not** touch the Anthropic-on-Bedrock model path. | Anthropic-on-Bedrock already works (DeepAgents / `ChatBedrockConverse`); the only gap is short-lived AWS credentials. `boto3`/`botocore` already ship via `langchain-aws`, so this adds no dependency. Mirrors classic OLS (IAM keys + `role_arn` STS, OLS-1895) and makes Bedrock a concrete third instance of the delegated-token principle. Tracked as OLS-4092 (no ticket yet). |

## Design

### Sandbox — credential resolution (`config.py`)

`_resolve_azure()` inspects `/var/run/secrets/llm-credentials/`:

- If `client_id` **and** `tenant_id` **and** `client_secret` files are all present
  and non-empty → **Entra ID mode**.
- Else if `apitoken` (or `AZURE_OPENAI_API_KEY` from `envFrom`) is present →
  **API-key mode**.
- Else → readiness fails at startup with a descriptive error naming the missing
  credential set.

The resolved mode is carried to the adapter (e.g. via an env flag or the
`ResolvedSDK` structure). No `AZURE_OPENAI_API_KEY` env var is set in Entra mode.

### Sandbox — readiness (`readiness.py`)

Readiness validates credential **presence** only — it does not make a network
call. Azure readiness passes when either an API key is present, or all three
service-principal files exist and are non-empty. Token acquisition happens at
adapter init / first request; a persistent failure terminates the run (see
"Failure and retry").

### Sandbox — OpenAI adapter (`providers/openai.py`)

The design **fully leverages the OpenAI SDK's built-in Azure support**. When
`LIGHTSPEED_PROVIDER=azure`, the adapter constructs the SDK's native
`AsyncAzureOpenAI` client — passing the SDK's own Azure parameters
(`azure_endpoint`, `api_version`, and `azure_deployment` for the deployment
name) — and wraps it in `OpenAIChatCompletionsModel`. It does **not** reuse the
plain `AsyncOpenAI` + `OpenAIResponsesModel` path (that path is native OpenAI
only), and it does **not** point a generic client at an Azure base URL.

Authentication uses the native `AsyncAzureOpenAI` auth parameters — nothing
hand-rolled:

- **Entra mode:** pass the SDK's built-in
  `azure_ad_token_provider = get_bearer_token_provider(ClientSecretCredential(tenant_id, client_id, client_secret), "https://cognitiveservices.azure.com/.default")`.
  The SDK invokes this provider per request and `azure.identity` owns caching and
  refresh — the sandbox writes no token-lifecycle code.
- **API-key mode:** pass the native `api_key=<apitoken>` parameter.

The `openai-agents` SDK consumes the Azure client through
`OpenAIChatCompletionsModel(openai_client=...)`. Provider SDK imports stay inside
the method per the repo's optional-extra import convention.

### Sandbox — Bedrock credential resolution (`config.py::_resolve_bedrock`)

The Anthropic-on-Bedrock **model** path is unchanged: `_resolve_bedrock()` still
sets `ANTHROPIC_MODEL`, `CLAUDE_CODE_USE_BEDROCK=1`, `AWS_REGION`, and
`ANTHROPIC_BASE_URL`, and the DeepAgents adapter still builds
`ChatAnthropicBedrock` (`providers/deepagents.py`). Only credential resolution
grows. `_resolve_bedrock()` reads from `/var/run/secrets/llm-credentials/`:

- `aws_access_key_id` **and** `aws_secret_access_key` (required) — the long-lived
  IAM identity.
- `role_arn` (optional) — when present, selects **STS assume-role mode**.

In static-key mode the IAM keys are used directly (today's behavior). In
assume-role mode, `botocore` performs the STS `AssumeRole` call and refreshes the
resulting short-lived credentials transparently for the life of the run — the
sandbox writes no token-refresh code (the delegated-token principle below). This
mirrors the classic service's Bedrock auth (IAM keys + optional `role_arn`,
OLS-1895).

No new dependency: `boto3`/`botocore` already ship transitively via
`langchain-aws` (the `deepagents` extra). The OpenAI-family-on-Bedrock path
(Mantle gateway / SigV4-signed `httpx-aws-auth`, as the classic service uses for
non-Anthropic models) is **out of scope** — this work covers the existing
Anthropic-on-Bedrock path only.

### Operator — CRD validation (`crd-api.md`, `sandbox-execution.md`)

No operator code redesign — credentials are already mounted unconditionally
(rule 16). The spec adds two validation contracts:

- An `azureOpenAI` `credentialsSecret` MUST contain **either** `apitoken` **or**
  all three of `client_id`, `tenant_id`, `client_secret` — mirroring the classic
  operator (`lightspeed-operator/.ai/spec/what/security.md` rule 11).
- An `awsBedrock` `credentialsSecret` MUST contain both `aws_access_key_id` and
  `aws_secret_access_key`; `role_arn` is optional (its presence selects STS
  assume-role). An incomplete key pair is rejected.

## Dependencies

Entra ID adds one new runtime dependency to the sandbox:

- **`azure-identity`** (module `azure.identity`; provides `ClientSecretCredential`
  and `get_bearer_token_provider`), which transitively pulls **`azure-core`**.
- The `AsyncAzureOpenAI` client and its `azure_ad_token_provider` parameter are
  already available — they ship in the `openai` package, present transitively via
  `openai-agents`. No change needed there.

Packaging:

- Add `azure-identity` to the sandbox's `openai` optional extra in
  `pyproject.toml` (Azure runs through the OpenAI adapter, so the natural home is
  that extra; a dedicated `azure` extra is an alternative if isolation is
  preferred later).
- Keep the `azure.identity` import inside the adapter method, matching the
  repo's optional-extra import convention.
- Konflux hermetic build: a new dependency requires regenerating the hashed
  per-architecture requirements and lockfiles (`make bump-deps` /
  `make requirements`, then `make lock`), committed together.

Bedrock STS adds **no** new dependency: `boto3`/`botocore` (which perform the STS
assume-role and credential refresh) already ship transitively via `langchain-aws`
in the `deepagents` extra.

## Failure and retry

Two orthogonal concerns, kept separate in the spec:

- **Connection retry (SDK-owned).** Transient HTTP faults — network blips,
  429/5xx from a token endpoint (AAD, STS) or the model API — are retried by the
  SDK layers (azure-core's pipeline / botocore's retry config for the token
  endpoints; the OpenAI or LangChain client for API calls). The sandbox neither
  disables nor augments this.
- **Fail fast (sandbox behavior).** Once auth is *definitively* rejected
  (invalid `client_secret`, wrong tenant, an `AssumeRole` denial, a credential
  rejected after SDK retries are exhausted), the run terminates immediately with
  a descriptive error in the Result CR rather than constructing or using a broken
  client. This applies the lesson from OLS-3782 (classic Entra failures dropped
  the connection) to the one-shot batch context. Run-level re-execution is the
  operator's concern and is out of scope here.

## Generalized principle: SDK-delegated short-lived tokens

The sandbox mounts only the **long-lived** credential (client secret, service
account key, or AWS role identity) and delegates all **short-lived** token
minting and refresh to the provider SDK's own credential object. The sandbox
performs no manual token caching.

- **Vertex (existing):** `GOOGLE_APPLICATION_CREDENTIALS` → google-auth mints and
  refreshes tokens internally.
- **Azure Entra ID (OLS-3050):** `ClientSecretCredential` via
  `azure_ad_token_provider` — `azure.identity` mints and refreshes the bearer
  token.
- **AWS Bedrock (OLS-4092, this work):** `aws_access_key_id` /
  `aws_secret_access_key` + optional `role_arn` → `botocore` mints and refreshes
  short-lived STS credentials when `role_arn` is set. This covers the existing
  Anthropic-on-Bedrock model path; the OpenAI-family-on-Bedrock path (OpenAI SDK
  built-in Bedrock support / SigV4 gateway) would reuse the same delegate-to-botocore
  pattern but is out of scope here.

This is recorded as an ADR and as a rule in the sandbox `provider-contract.md`.
Because the sandbox reads the long-lived credential once at startup (no
hot-reload), only the short-lived token is refreshed in-run — which is all a
single run needs.

## Out of scope

- Credential hot-reload in the sandbox (OLS-3450 is classic-only; the sandbox
  reads credentials once at startup).
- The OpenAI-family-on-Bedrock path (OpenAI SDK built-in Bedrock support / SigV4
  gateway, as classic OLS uses for non-Anthropic Bedrock models). This work
  covers credential resolution for the existing Anthropic-on-Bedrock path only;
  the Bedrock **model** routing is unchanged.
- Run-level retry / re-execution policy (operator concern).

## Verification

- Sandbox unit tests (`test_config.py`, `test_ready.py`): Azure Entra-vs-key mode
  selection from mounted files; Bedrock static-key-vs-`role_arn` mode selection;
  readiness pass/fail for complete vs incomplete credential sets (both
  providers).
- Sandbox adapter tests: `AsyncAzureOpenAI` construction with a token provider vs
  an API key; fail-fast on definitive token-acquisition failure. Bedrock: assert
  the Anthropic model path is unchanged and `_resolve_bedrock()` surfaces the
  `role_arn` for botocore assume-role.
- Operator tests: `azureOpenAI` credential validation (either `apitoken` or all
  three service-principal keys); `awsBedrock` credential validation
  (`aws_access_key_id` + `aws_secret_access_key`, optional `role_arn`).
- Live: an Entra ID e2e against an Azure OpenAI deployment (mirrors classic
  OLS-992); a Bedrock `role_arn` assume-role e2e (mirrors classic OLS-1895).

## References

- Classic service Entra ID: `lightspeed-service/.ai/spec/what/llm-providers.md`
  (rules 20–24), `how/llm-providers.md`.
- Classic service Bedrock (IAM keys + `role_arn` STS):
  `lightspeed-service/.ai/spec/what/llm-providers.md` (rules 42–45).
- Classic operator credential validation:
  `lightspeed-operator/.ai/spec/what/security.md` (rule 11).
- Sandbox credential mount: `lightspeed-agentic-operator/.ai/spec/what/sandbox-execution.md`
  (rule 16).
- ADR: `.ai/spec/decisions/0041-sandbox-sdk-delegated-tokens.md`.
- Related tickets: OLS-599, OLS-620, OLS-992 (classic Entra ID lineage); OLS-1895
  (classic Bedrock IAM + assume-role); OLS-3782 (fail-fast lesson).
