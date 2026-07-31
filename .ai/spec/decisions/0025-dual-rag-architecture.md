# 0025: Dual RAG Architecture

**Status:** Accepted
**Applies to:** lightspeed-service, lightspeed-rag-content, lightspeed-operator

## Context

OCP product documentation is managed by a separate team (OKP) with its own infrastructure (Solr). Customer BYOK content has a completely different pipeline (FAISS indexes built from Markdown). The two systems use different embedding models (granite-embedding-30m-english 384-dim for OKP, all-mpnet-base-v2 768-dim for BYOK) because each system's indexes were built with its respective model.

## Decision

Two separate RAG systems: OKP/RHOKP (Solr hybrid search for OCP product documentation) and BYOK (FAISS vector similarity for customer content). OKP retrieval is exposed as a LangChain tool that the LLM invokes on demand; BYOK content is pipeline-injected into every prompt.

## Alternatives Considered

- **Single unified retrieval system** — rejected because OKP and BYOK have fundamentally different content sources, update cadences, and index formats
- **All-FAISS** — rejected because it would require rebuilding the OKP pipeline which is managed by another team
- **All-Solr** — rejected because customers can't run Solr for BYOK

## Consequences

- OKP results are LLM-driven (model decides relevance per query)
- BYOK results are always present in context
- Different embedding models per system (changing either would require reindexing)
- RHOKP deployed as a standalone service (was sidecar, moving to standalone deployment per OLS-3697)
- OKP team owns the Solr infrastructure
