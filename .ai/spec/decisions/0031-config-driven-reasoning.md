# 0031: Config-Driven Reasoning Model Enablement

**Status:** Accepted
**Applies to:** lightspeed-service, lightspeed-operator

## Context

Provider APIs return 400 errors if reasoning parameters are sent to non-reasoning models. There is no reliable cross-provider API to auto-detect reasoning capability. Current model-name checks (hardcoded prefixes) break as new models ship. Each provider has different reasoning config keys that change across model generations, making a typed schema impractical.

## Decision

Reasoning model enablement is an explicit per-model config choice via `reasoningConfig` in the OLSConfig CR, using a freeform `map[string]interface{}` pass-through rather than model-name detection or typed CRD structs. The admin explicitly opts into reasoning for each model that supports it.

## Alternatives Considered

- **Model-name detection** — rejected because it breaks with new models, doesn't generalize across providers, and requires service updates every time a provider releases a new reasoning model.
- **Typed CRD struct per provider** — rejected because it requires CRD schema changes every time a provider ships a new model generation, leading to combinatorial explosion of provider-model combinations.

## Consequences

- Admin explicitly opts into reasoning per model via OLSConfig
- Freeform map passes provider-specific reasoning config without interpretation by the service or operator
- No CRD changes needed when new reasoning models are released
- vLLM reasoning requires a `ChatVLLMReasoning` subclass of BaseChatOpenAI due to LangChain not accepting the upstream change
