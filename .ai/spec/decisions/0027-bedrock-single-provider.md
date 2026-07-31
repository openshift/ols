# 0027: Bedrock as Single Provider with Model-Prefix Routing

**Status:** Accepted
**Applies to:** lightspeed-service, lightspeed-operator

## Context

AWS Bedrock (accessed via Red Hat's Mantle gateway) is a single endpoint with one credential that serves multiple model families (Anthropic Claude, OpenAI-compatible, and others). Requiring separate provider configs per model family would force duplicate credentials and not reflect the single-gateway reality that customers experience.

## Decision

A single `bedrock` provider type in OLSConfig with model-prefix routing. The provider detects the model name prefix (`anthropic.*`, `openai.*`, or other) and selects the appropriate LangChain class and API path. Bearer token authentication ships first; STS/IAM auth is deferred for later implementation.

## Alternatives Considered

- **Separate provider types per API family** (`bedrock_anthropic`, `bedrock_openai`) — rejected because it forces duplicate credentials and doesn't reflect the single-gateway reality where one endpoint serves all model families.
- **Delegate to existing OpenAI/Anthropic providers** — rejected because it couples Bedrock to those providers' internals, creating fragile dependencies and preventing Bedrock-specific optimizations.

## Consequences

- Simplest user config: one provider block for all Bedrock models
- Model-prefix routing in service code selects the right LangChain class
- Bearer token auth serves non-AWS and on-prem clusters immediately
- STS/IAM auth deferred for ROSA/AWS production environments
- Code structured for STS extensibility via BedrockConfig class
