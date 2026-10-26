# 0041: SDK-Delegated Short-Lived Tokens in the Sandbox

**Status:** Accepted [PLANNED: OLS-4092 (Bedrock STS)]
**Applies to:** lightspeed-agentic-sandbox, lightspeed-agentic-operator
**Azure integration update:** OLS-4470 / OLS-4471; implementation status does not establish live API-key or Entra acceptance.

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

At the original decision, the sandbox's OpenAI adapter did not construct an Azure
client (the OLS-3049 config-mapping half landed; the client-construction half did
not), so Entra ID required building that path first. OLS-4470 / OLS-4471 now carry
this credential-delegation decision into the shared DeepAgents Azure integration;
the legacy OpenAI Agents runtime adapter is removed.

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
| Azure Entra ID (OLS-3050) | `client_id` / `tenant_id` / `client_secret` | `azure.identity.aio.ClientSecretCredential` and native async bearer-token provider |
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
+ `httpx-aws-auth`). Routing OpenAI-family Bedrock models through a model
integration would reuse this exact delegate-to-botocore pattern, but it is **out of
scope here** — this decision covers credential delegation for the existing
Anthropic-on-Bedrock path only.

### Azure uses the OpenAI SDK's built-in Azure support

Both authentication modes use one `AzureChatOpenAI` model integration through the
shared DeepAgents harness, backed by native `AsyncAzureOpenAI` endpoint,
deployment, API-version, and authentication semantics. It MUST NOT point a plain
`AsyncOpenAI` at an Azure base URL or use the retired Agents SDK model wrappers.
API-version-dependent Chat Completions/Responses selection belongs to the model
integration; exact transport and shaping rules remain in the sandbox child spec.

- **Entra ID mode:** use `azure.identity.aio.ClientSecretCredential` and its native
  async bearer-token provider for `https://cognitiveservices.azure.com/.default`,
  forwarded through `AzureChatOpenAI` to `AsyncAzureOpenAI`. The SDK owns token
  acquisition, caching, and refresh. No manual token cache or hand-built
  `Authorization` header is permitted.
- **API-key mode:** pass the resolved native `api_key`; no other provider's ambient
  key may substitute for the selected source.

The sandbox selects Entra ID when all three mounted service-principal files are
present and non-empty; otherwise it selects a nonempty mounted `apitoken` or
`AZURE_OPENAI_API_KEY`; otherwise readiness fails at startup. Resolution passes a
typed credential snapshot without constructing clients, acquiring tokens, or
rewriting SDK environment settings. Model cleanup closes constructor-owned
credential resources on success, failure, and cancellation.

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
- The OLS-3049 Azure-client gap is addressed through the shared DeepAgents Azure
  model integration, not a provider branch in the retired OpenAI Agents adapter.
- Azure uses the existing `azure-identity` optional dependency (including
  `azure.identity.aio`), native `openai` clients, and `langchain-openai`. Optional
  SDK imports remain lazy. Declared legacy harness dependency cleanup is separate
  from runtime retirement; dependency changes require regenerating the applicable
  Konflux hashed requirements/lockfiles.
- Offline construction/workflow tests do not establish live API-key or Entra
  acceptance. Route-specific evidence and telemetry compatibility review remain
  governed by the sandbox provider contract and parent collection contract.
- One credential-secret shape spans classic and agentic products
  (`client_id` / `tenant_id` / `client_secret` / `apitoken`).
- Long-lived credential rotation still requires a new run — acceptable because
  runs are short-lived and the sandbox has no hot-reload by design.
- Bedrock adds STS assume-role support (`role_arn`) with no new dependency; the
  existing static-key path and the Anthropic-on-Bedrock model routing are
  unchanged. Operator validation gains an `awsBedrock` credential-key check
  (sibling to the Azure check).
