# 0018: Ask vs Troubleshooting Query Modes

**Status:** Accepted
**Applies to:** lightspeed-service, lightspeed-console

## Context

User questions range from simple documentation lookups ("how do I create a route?") to complex diagnostics ("why is my pod crashing?"). Simple questions need few or no tool calls; diagnostics require extended tool use with cluster introspection.

## Decision

Two query modes — `ask` (general Q&A, max 5 tool iterations) and `troubleshooting` (diagnostic workflows, max 15 tool iterations) — with different system prompts and agent instructions.

## Alternatives Considered

- **Single mode with dynamic budget** — rejected because it is hard for the LLM to self-regulate iteration count
- **More granular modes** — rejected because added complexity without clear user benefit; two modes cover the spectrum
- **User-configurable iteration limits** — rejected because users don't have intuition for iteration counts

## Consequences

- Console presents mode selection to the user
- Different system prompts per mode shape LLM behavior
- Troubleshooting mode gets 3x the tool iteration budget
- Mode affects token budget allocation
