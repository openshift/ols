# 0041: SDK-Delegated Short-Lived Tokens in the Sandbox

**Status:** Accepted [PLANNED: OLS-3050 (Azure Entra ID), OLS-4092 (Bedrock STS)]
**Applies to:** lightspeed-agentic-sandbox, lightspeed-agentic-operator

## Context

Azure OpenAI can be accessed with a static API key or with Entra ID (Azure AD)
service-principal credentials. Many enterprises disable API keys, so the agentic
sandbox must support Entra ID to reach parity with the classic OLS service
(which already implements it). Entra ID authenticates with a **short-lived**
bearer token minted from **long-lived** service-principal credentials
(`client_id` / `tenant_id` / `client_secret`); the token expires within the hour
and must be refreshed transparently during a long agent run.

Two properties of the sandbox shape the design:

- The sandbox is a **one-shot batch process** (`python -m lightspeed_agentic.batch`).
  It reads credentials once at startup and has **no credential hot-reload**
  (unlike the classic service — see OLS-3450, which is classic-only).
- The operator already mounts the whole `LLMProvider` credentials secret
  **unconditionally** for every provider — as env vars (`envFrom`) and as files
  at `/var/run/secrets/llm-credentials/`.

The sandbox's OpenAI adapter also never constructed an Azure client (the OLS-3049
config-mapping half landed; the client-construction half did not), so Entra ID
required building that path first.

## Decision

### The sandbox mounts only the long-lived credential and delegates all short-lived token work to the provider SDK

The sandbox never mints, caches, refreshes, or expires access tokens itself. It
reads the long-lived credential once, hands it to the provider SDK's own
credential object, and lets that library own the token lifecycle. Because only
the short-lived token is refreshed in-run — and the SDK does that internally —
no credential hot-reload is needed for a single run.

| Provider | Long-lived credential (mounted) | SDK that mints/refreshes the token |
|---|---|---|
| Vertex (existing) | `GOOGLE_APPLICATION_CREDENTIALS` service-account key | google-auth |
| Azure Entra ID (OLS-3050) | `client_id` / `tenant_id` / `client_secret` | `azure.identity` `ClientSecretCredential` |
| AWS Bedrock (OLS-4092) | `aws_access_key_id` / `aws_secret_access_key` + optional `role_arn` | botocore credential-provider chain (STS assume-role when `role_arn` is set) |

### Bedrock is a concrete instance, not a redesign of the model path

Anthropic-on-Bedrock is already supported (DeepAgents / `ChatBedrockConverse`).
This decision changes **credential resolution only**: the sandbox reads
`aws_access_key_id` / `aws_secret_access_key` and an optional `role_arn` from the
mounted directory (classic OLS shape, OLS-1895). When `role_arn` is present,
botocore performs the STS assume-role and refreshes the short-lived credentials
for the life of the run; otherwise the static keys are used. `boto3`/`botocore`
are already present via `langchain-aws`, so Bedrock adds no dependency.

The OpenAI SDK also offers built-in Bedrock support (OpenAI-family models via a
Bedrock gateway with SigV4 signing, as the classic service does with `ChatOpenAI`
+ `httpx-aws-auth`). Routing OpenAI-family Bedrock models through the OpenAI
adapter would reuse this exact delegate-to-botocore pattern, but it is **out of
scope here** — this decision covers credential delegation for the existing
Anthropic-on-Bedrock path only.

### Azure uses the OpenAI SDK's built-in Azure support

The adapter constructs the SDK's native `AsyncAzureOpenAI` client (not a plain
`AsyncOpenAI` pointed at an Azure base URL) and wraps it in
`OpenAIChatCompletionsModel`. Authentication uses native parameters only:

- **Entra ID mode:** pass
  `azure_ad_token_provider = get_bearer_token_provider(ClientSecretCredential(...), "https://cognitiveservices.azure.com/.default")`.
  The SDK invokes the provider per request; `azure.identity` caches and refreshes
  the token. No manual token cache, no hand-built `Authorization` header.
- **API-key mode:** pass native `api_key`.

The sandbox selects the mode from the mounted files: Entra ID when all three
service-principal files are present and non-empty; otherwise API key; otherwise
readiness fails at startup.

### The operator validates the credential set; it does not wire tokens

Because the mount is unconditional and key-agnostic, the Entra ID keys flow
through with no operator wiring change. The operator only adds validation: an
`azureOpenAI` `credentialsSecret` must contain **either** `apitoken` **or** all
three service-principal keys, mirroring the classic operator.

### Fail fast on definitive auth failure; leave transient retry to the SDK

Transient faults (network blips, 429/5xx from the token endpoint or the API) are
retried by the SDK layers (azure-core, the OpenAI client) and neither disabled
nor augmented. A **definitive** auth rejection (bad secret, wrong tenant,
credential rejected after SDK retries) terminates the run immediately with a
descriptive error rather than using a broken client. These are orthogonal
concerns — connection retry is SDK-owned; fail-fast is sandbox behavior.

## Alternatives Considered

- **Mint and cache the token in the sandbox** (like the classic service's
  per-process cache with refresh leeway) — rejected. It duplicates logic the SDK
  already owns, adds an expiry/refresh code path to maintain, and buys nothing in
  a one-shot process where the SDK refreshes transparently within the run.
- **Point a plain `AsyncOpenAI` at the Azure base URL with a hand-built bearer
  header** — rejected. The OpenAI SDK ships first-class Azure support
  (`AsyncAzureOpenAI` + `azure_ad_token_provider`); a hand-rolled shim would
  reimplement URL shaping, `api-version` handling, and token injection the SDK
  does correctly.
- **Credential hot-reload in the sandbox** (OLS-3450 style) — rejected as out of
  scope. The sandbox is one-shot; only the short-lived token needs refresh, and
  the SDK handles that. The long-lived credential is read once at startup.
- **Operator-side token minting and injection** — rejected. It would put a
  provider SDK and a refresh loop in the operator, break the "operator sets
  generic env, sandbox owns SDK specifics" contract, and cannot refresh a token
  inside a running sandbox.

## Consequences

- Adding a new short-lived-token provider (e.g. Bedrock) follows one reusable
  rule: mount the long-lived credential, delegate to the provider SDK's
  credential object, write no token-lifecycle code.
- The OLS-3049 Azure-client gap is closed as part of this work — the OpenAI
  adapter now branches on provider type and builds `AsyncAzureOpenAI`.
- Azure adds a **new** dependency: `azure-identity` (module `azure.identity`,
  providing `ClientSecretCredential` / `get_bearer_token_provider`), which pulls
  `azure-core`. The `AsyncAzureOpenAI` client and its `azure_ad_token_provider`
  parameter are already shipped by the `openai` package (present via
  `openai-agents`) — only the credential library is new. It is added to the
  sandbox's `openai` optional extra, the import stays inside the adapter method
  per the optional-extra convention, and the new dependency requires regenerating
  the Konflux hashed requirements/lockfiles.
- One credential-secret shape spans classic and agentic products
  (`client_id` / `tenant_id` / `client_secret` / `apitoken`).
- Long-lived credential rotation still requires a new run — acceptable because
  runs are short-lived and the sandbox has no hot-reload by design.
- Bedrock adds STS assume-role support (`role_arn`) with no new dependency; the
  existing static-key path and the Anthropic-on-Bedrock model routing are
  unchanged. Operator validation gains an `awsBedrock` credential-key check
  (sibling to the Azure check).
