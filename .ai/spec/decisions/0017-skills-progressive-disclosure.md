# 0017: Skills Progressive Disclosure

**Status:** Accepted
**Applies to:** lightspeed-service

## Context

A skill is a document that augments the system prompt for a specific topic (e.g., "troubleshooting etcd", "managing Routes"). With many skills available, loading all full skill content into every prompt would exhaust the token budget. Progressive disclosure lets the LLM load only what it needs.

## Decision

Skills use three disclosure levels: metadata (name + description, always loaded for RAG matching), skill.md body (loaded when the skill is selected), and support files (loaded on-demand via tool call).

## Alternatives Considered

- **Load all skills into every prompt** — rejected because it exhausts the token budget with many skills
- **Only metadata, no body loading** — rejected because the skill body contains essential step-by-step instructions
- **Hardcoded skill routing** — rejected because it doesn't scale and requires code changes for new skills

## Consequences

- Skill metadata is cheap to include in every prompt for matching
- Hybrid RAG (dense + BM25) selects relevant skills from metadata
- Full skill body loaded only when matched
- Support files loaded only when the LLM needs additional detail
- Total skill token usage is proportional to relevance, not total skill count
