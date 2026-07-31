# 0003: RAG Over Fine-Tuning

**Status:** Accepted
**Applies to:** lightspeed-service, lightspeed-rag-content

## Context

OLS needs product documentation knowledge that changes with each OCP release (approximately quarterly). Fine-tuning would require retraining or updating models per release, per provider, creating a combinatorial maintenance burden. RAG also enables customer BYOK content without model access.

## Decision

Use Retrieval-Augmented Generation (RAG) for knowledge grounding, not model fine-tuning. Knowledge is retrieved at query time from indexed documentation rather than baked into model weights.

## Alternatives Considered

- **Fine-tuned models per OCP version** — rejected because retraining per release per provider is unsustainable
- **Hybrid fine-tune + RAG** — rejected because added complexity without clear benefit given RAG quality is sufficient

## Consequences

- Knowledge updates are a content pipeline change, not a model change
- Customers can bring their own documentation without provider involvement
- RAG quality depends on retrieval accuracy and chunk quality
- Two RAG systems needed (OKP for product docs, FAISS for customer BYOK content)
