# 0011: Multi-Provider LLM Support with Self-Registration

**Status:** Accepted
**Applies to:** lightspeed-service, lightspeed-operator

## Context

Enterprise customers have different LLM provider preferences driven by contracts, compliance requirements, and existing infrastructure. Red Hat cannot mandate a single LLM provider. The service must work with whatever backend the customer has — from managed cloud services like Azure OpenAI and AWS Bedrock to on-premises deployments like RHEL AI/vLLM.

## Decision

Support 8+ LLM providers (OpenAI, Azure OpenAI, WatsonX, RHEL AI/vLLM, Bedrock, Vertex AI, Anthropic, Gemini) through a provider abstraction layer with self-registration. Providers register via a decorator and are instantiated through a factory pattern based on config.

## Alternatives Considered

- **Single provider** — rejected because it excludes most enterprise customers who have existing LLM contracts and compliance requirements tied to specific providers.
- **OpenAI-compatible API only** — rejected because WatsonX and RHEL AI use fundamentally different APIs that cannot be adapted to the OpenAI interface.
- **Provider-agnostic proxy** — rejected because it would need its own deployment and management, adding operational burden without solving the credential and config management problem.

## Consequences

- Providers register via `@register_llm_provider_as("type")` decorator pattern
- Factory pattern instantiates the correct provider from OLSConfig CR configuration
- OLSConfig CR defines provider credentials and model mappings
- Provider-specific reasoning config handled via freeform map pass-through
- New providers can be added without modifying the core query pipeline
