# RAG Pipeline

Offline pipeline that builds vector indexes from documentation, packages them as container images, and serves them at runtime for retrieval-augmented generation.

## End-to-End Flow

### Build Phase (lightspeed-rag-content)

1. Content is acquired from multiple sources:
   - **OCP Product Docs**: Clone `openshift/openshift-docs` by branch (e.g., `enterprise-4.18`), convert AsciiDoc to plaintext via custom Ruby converter, filter by distro (`openshift-enterprise`).
   - **Runbooks**: Sparse-checkout `openshift/runbooks:master` alerts directory, keep `.md` files, exclude `deprecated/` and `README.md`.
   - **OKP (Errata)**: Download Markdown with TOML frontmatter, filter by project name and required fields.
2. Documents are split into chunks: 380-token default, 0 overlap, using `SentenceSplitter` (plaintext) or `MarkdownNodeParser` (Markdown/HTML). Whitespace-only chunks are filtered out.
3. Chunks are embedded using `sentence-transformers/all-mpnet-base-v2` (768-dimensional vectors, Apache 2.0 licensed).
4. A FAISS index is created using `IndexFlatIP` (inner product similarity on normalized vectors).
5. Indexes are organized per OCP version under `vector_db/ocp_product_docs/{version}/`. A `latest` symlink points to the highest version. Runbooks are merged into each version index.
6. Each index directory contains: `docstore.json`, `index_store.json`, `graph_store.json`, `vector_store.json`, `metadata.json`.

### Packaging Phase (lightspeed-rag-content)

7. The main RAG container image contains all OCP version indexes, the embedding model, and the `latest` symlink.
8. A separate BYOK tool image contains buildah, the embedding toolchain, and the embedding model for customer custom builds.

### Deployment Phase (lightspeed-operator)

9. The operator reads RAG image references from the `OLSConfig` CR.
10. RAG indexes are mounted into the service pod via init containers that copy content from the OCI image to a shared volume.
11. The operator generates `olsconfig.yaml` with the RAG index paths and embedding model path.

### Runtime Phase (lightspeed-service)

12. At startup, the service loads FAISS indexes from configured `product_docs_index_path`. If the configured path is absent, it tries a `latest` fallback in the parent directory.
13. The service initializes the same embedding model used during the build phase.
14. If index load fails, the service logs a warning and continues with remaining indexes. The readiness probe blocks queries until at least one index is loaded.
15. At query time, the service retrieves top-k chunks via vector similarity, filters by score cutoff, truncates to fit the token budget, deduplicates by URL, and annotates results with `index_id` and `index_origin`.
16. When multiple indexes are configured, results are merged using score dilution (first index no penalty, subsequent indexes penalized).

## Integration Contracts

### Filesystem Paths

| Path | Producer | Consumer | Content |
|---|---|---|---|
| `/rag/vector_db/ocp_product_docs/{version}/` | rag-content | service | FAISS index files (docstore, index_store, graph_store, vector_store, metadata) |
| `/rag/vector_db/ocp_product_docs/latest` | rag-content | service | Symlink to highest version |
| `/rag/embeddings_model/` | rag-content | service | HuggingFace-compatible model directory |

### Configuration (olsconfig.yaml)

| Field | Purpose |
|---|---|
| `ols_config.reference_content.embeddings_model_path` | Path to embedding model (defaults to model shipped in RAG image) |
| `ols_config.reference_content.indexes[].product_docs_index_path` | Path to FAISS index directory |
| `ols_config.reference_content.indexes[].product_docs_index_id` | Optional ID for deserialization |
| `ols_config.reference_content.indexes[].product_docs_origin` | Human-readable label for logging |

### Chunk Metadata

Chunks carry metadata through the pipeline:
- `docs_url` (source URL), `title` (document title)
- HTML pipeline adds: `section_title`, `chunk_index`, `total_chunks`, `token_count`, `source_file`
- For llama-stack backends: `document_id` (for citation linking)

### Invariant

The embedding model used to build indexes must be identical to the model used to query them at runtime. Model mismatch produces meaningless similarity scores. See `constraints.md` rule 8.

## Repo Ownership

| Repo | Owns |
|---|---|
| **lightspeed-rag-content** | Content acquisition, chunking, embedding, FAISS index creation, metadata writing, version organization, container image packaging, BYOK tool image |
| **lightspeed-service** | Index loading at startup, similarity-based retrieval, score dilution across indexes, chunk truncation, deduplication, readiness probe integration |
| **lightspeed-operator** | RAG image reference in OLSConfig CR, init container setup, model path configuration in generated olsconfig.yaml |

## Planned Changes

| Ticket | Summary |
|---|---|
| OLS-2294 | Enhanced chunk metadata generation stage |
| OLS-1729 | Fine-tuned embedding models for domain-specific retrieval |
| OLS-2903 | OKP-based RAG integration |
| OLS-2704 | RAG as service / MCP interface |
| OCPSTRAT-1495 | OCP KCS content inclusion |
| OCPSTRAT-1492 | Layered product knowledge (CNV, ACM, RHOSO) |
| OLS-1872 | BYOK Phase 2: one-click import from Git/Confluence |
| OLS-1812 | Per-index embedding model path in CRD |
