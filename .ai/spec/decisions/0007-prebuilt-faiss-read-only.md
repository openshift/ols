# 0007: Pre-Built FAISS Read-Only Indexes

**Status:** Accepted
**Applies to:** lightspeed-rag-content, lightspeed-service

## Context

RAG content (OCP documentation, customer BYOK docs) is deterministic per release. Building indexes at image build time ensures consistent content across all service replicas and deployments.

## Decision

FAISS vector indexes are pre-built at image build time and loaded read-only at service startup. No runtime indexing or modification.

## Alternatives Considered

- **Runtime indexing** — rejected because it adds compute cost, non-deterministic content across replicas, and requires write access to index
- **External vector database like Milvus/Pinecone** — rejected because it adds operational dependency and is overkill for read-only indexes

## Consequences

- RAG content changes require a new container image build
- All computation (embedding, chunking, indexing) happens at build time
- Service startup loads indexes into memory (no write path needed)
- Content is hermetically sealed in the image
