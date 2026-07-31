# 0035: Remove Claude SDK

**Status:** Accepted
**Applies to:** lightspeed-agentic-sandbox

## Context

The Claude Code binary carries Anthropic's proprietary license (not OSI-approved), creating redistribution risk for a Red Hat product image shipped via registry.redhat.io. Red Hat products must use OSI-approved licenses for included binaries.

## Decision

Remove `@anthropic-ai/claude-code` (~220MB proprietary binary), `claude-agent-sdk`, Node.js runtime, and `ClaudeProvider` from the agentic sandbox image. Three config paths (anthropic, vertex/anthropic, bedrock) will break and are deferred for rerouting via alternative SDKs.

## Alternatives Considered

- **Keep Claude SDK** — rejected because of proprietary license redistribution risk
- **License exception** — rejected because it is not feasible for Red Hat product images
- **Wrap all providers behind Claude SDK** — rejected because it deepens the dependency

## Consequences

- ~220MB image size reduction
- Three Anthropic-related config paths temporarily broken
- Replacement SDK selection deferred to implementation planning (candidates: google-adk for Vertex, openai-agents for Bedrock, or custom agent loop on anthropic Python SDK)
- Remaining providers (OpenAI, Gemini, WatsonX) unaffected
- Tracked as OLS-3473
