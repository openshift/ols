# 0008: Embedding Model Packaged in Image

**Status:** Accepted
**Applies to:** lightspeed-rag-content, lightspeed-service

## Context

The embedding model used to build indexes must be identical to the model used to query them at runtime (constraints.md rule 8). A mismatch between build-time and query-time models produces meaningless similarity scores. Shipping the model in the image guarantees parity.

## Decision

The sentence-transformer model used for building FAISS indexes (all-mpnet-base-v2, 768-dim) is packaged inside the RAG content container image alongside the indexes.

## Alternatives Considered

- **External embedding service** — rejected because it adds a network dependency and a model version coordination problem
- **Model downloaded at startup** — rejected because it breaks disconnected/air-gapped deployments and introduces version drift risk

## Consequences

- Container image is larger (includes model weights)
- Guaranteed model parity between build and query
- Works in disconnected environments
- Model updates require image rebuild
