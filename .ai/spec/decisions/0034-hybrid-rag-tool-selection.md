# 0034: Hybrid RAG for Tool and Skill Selection

**Status:** Accepted
**Applies to:** lightspeed-service

## Context

When a user query arrives, the service must select relevant MCP tools and skills from a potentially large set. Pure dense retrieval misses exact keyword matches; pure keyword matching misses semantic similarity. Hybrid retrieval combines both signals.

## Decision

Tool and skill selection uses hybrid retrieval — dense (vector similarity) + sparse (BM25 keyword) with reciprocal rank fusion.

## Alternatives Considered

- **Pure dense retrieval** — rejected because it is noisy for tool selection where exact names matter
- **Pure keyword/BM25** — rejected because it misses semantic similarity for novel phrasings
- **Intent classification** — rejected because it requires training data per tool and doesn't scale to dynamic tool sets

## Consequences

- Better precision in tool/skill selection vs. either method alone
- Reduced noise in tool selection
- Additional complexity in the retrieval path
- Reciprocal rank fusion combines rankings without learned weights
