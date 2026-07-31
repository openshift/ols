# 0015: Token Budget Partitioning

**Status:** Accepted
**Applies to:** lightspeed-service

## Context

LLM context windows are finite. Without partitioning, any single category (RAG chunks, conversation history, tool results) could consume the entire window, leaving no room for the response or tool calls. The charge order ensures essential context (system prompt, RAG) takes priority over nice-to-have context (history).

## Decision

The context window is partitioned into three reserves: response (4096 tokens), tool (25% of remaining, configurable 10-60%), and prompt (the rest). The prompt budget is charged in priority order: base prompt, RAG chunks, skill content, conversation history.

## Alternatives Considered

- **No partitioning with truncation at overflow** — rejected because it produces unpredictable truncation
- **Per-component fixed limits** — rejected because it is inflexible across different model context window sizes
- **Dynamic budgets** — rejected because they are harder to reason about and debug

## Consequences

- Predictable context usage across different model sizes
- Conversation history is the first thing truncated when space is tight
- Tool budget is separate from prompt budget to prevent tool-heavy queries from crowding out the prompt
- Configurable tool percentage allows tuning per deployment
