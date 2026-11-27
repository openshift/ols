# OLS-3663: LiteLLM Proxy compatibility design

**Status:** Approved

**Tracking:** [OLS-3663](https://redhat.atlassian.net/browse/OLS-3663)

## Goal and scope

Validate that the agentic sandbox can use a customer-managed LiteLLM Proxy for model traffic through the existing OpenAI-compatible API. The deliverables are a documented configuration contract and repeatable Konflux coverage, not a new provider integration.

## Design decision

Run the existing sandbox E2E suite in an additional Konflux scenario. Use the same test cases and candidate sandbox image as the direct-provider run, but point the model clients at LiteLLM Proxy over the existing OpenAI-compatible Chat Completions route instead of calling the upstream model directly. Keep the direct-provider and vLLM scenarios unchanged.

The scenario represents a customer who already has a working LiteLLM endpoint. There is no pre-existing CI proxy: the scenario provisions a disposable proxy as a test fixture. Production OLS only connects to the customer-supplied endpoint; it does not deploy or manage the proxy.

No new LiteLLM provider type, operator API, sandbox client, or in-process LiteLLM dependency is planned. If the E2E test exposes a gap in the shared route, address that gap rather than introducing a dedicated provider by default.

## How the proxy works

```text
Sandbox (agent, inspection classifier, result shaper)
  → HTTPS Chat Completions (model alias + proxy key)
  → LiteLLM Proxy (alias routing + upstream credentials)
  → Upstream model deployment
```

Set the Agent's `spec.model` to a proxy alias, not an upstream model ID. Two Agents can share the same endpoint and use different aliases—for example, `ci-anthropic` for direct Anthropic or `ci-claude-bedrock` for Bedrock. The sandbox sends the alias in the request's `model` field. Provider prefixes and upstream authentication stay on the proxy. Configuring the proxy route is not a network boundary; enforce pod egress separately if bypass prevention is required.

## Example proxy configuration

Use the standard `ghcr.io/berriai/litellm` image, pinned to a tested release or digest. Mount the YAML read-only at `/app/config.yaml` and start with `--config /app/config.yaml --host 0.0.0.0 --port 4000`. Expose it through HTTPS for cluster tests. For a local smoke test, run the image with Podman.

```yaml
model_list:
  - model_name: ci-anthropic
    litellm_params:
      model: anthropic/claude-haiku-5-5
      api_key: os.environ/ANTHROPIC_API_KEY
  - model_name: ci-claude-bedrock
    litellm_params:
      model: bedrock/global.anthropic.claude-haiku-5-5
      aws_region_name: os.environ/AWS_REGION

general_settings:
  master_key: os.environ/LITELLM_MASTER_KEY
```

These aliases and model IDs are examples; validate them against the pinned LiteLLM version and CI deployments. Use only one alias for the initial lane. Inject credentials into the proxy via Secret references; for Bedrock, use the AWS credential chain. Give the sandbox a restricted proxy key, not the master key. The existing Deep Agents client uses `ChatOpenAI` with the proxy `/v1` base URL, that proxy key, and the alias, with the Responses API disabled.

## Sandbox configuration: reuse the vLLM route

The sandbox connects to LiteLLM the same way it connects to an OpenAI-compatible vLLM endpoint. Point the **URL at the proxy** and source the **API key from a Kubernetes Secret containing the proxy key**. Use the LiteLLM alias as the model. For the Konflux test runner, the effective settings are:

| Setting | Example or source |
| --- | --- |
| `OPENAI_BASE_URL` | `https://litellm.example.com/v1` |
| `OPENAI_API_KEY` | Restricted LiteLLM proxy key from a Secret |
| `OPENAI_MODEL` | `ci-anthropic` (the alias in `model_list`) |

The existing vLLM lane reads its URL and model from the `endpoint` and `model` files in its credential mount. The new lane should reuse that route and also inject `OPENAI_API_KEY` from the proxy credential Secret; it must not assume the proxy is keyless just because the existing vLLM fixture is. The upstream credential Secret is separate and is mounted only by LiteLLM. No proxy key value belongs in the checked-in configuration.

## CI fixture

1. Deploy a pinned LiteLLM Proxy image in the test cluster. Start with one upstream already available in CI and configure one model alias for it. Keep the upstream credential in a Secret consumed only by the proxy.
2. Make the proxy's HTTPS `/v1` endpoint reachable from the sandbox. Configure the existing vLLM/OpenAI-compatible route with that base URL, a restricted proxy key, and the model alias. The sandbox sends the alias as the model ID; the proxy maps it to the actual upstream model. Do not inject upstream credentials into the sandbox or configure direct-provider fallback.
3. Use the shared Chat Completions path. Do not assume that vLLM-specific request options work against a proxy or every upstream model.

The proxy deployment is a CI fixture only. In production, customers supply and manage their own proxy endpoint, model aliases, and upstream credentials; the operator does not deploy or manage LiteLLM.

## Acceptance criterion

The same sandbox E2E suite passes with LiteLLM Proxy in place of the direct LLM endpoint, with no changes to test cases or expectations.

The Konflux scenario takes a `LITELLM_PROXY_IMAGE` parameter with a digest-pinned default. Override it for a run to test a specific LiteLLM release with the same E2E suite and candidate sandbox image, without rebuilding the sandbox. This is a CI parameter, not an OLS setting.
