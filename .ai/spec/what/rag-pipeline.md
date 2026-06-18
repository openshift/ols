# RAG Pipeline

Dual-architecture retrieval system: OKP (Red Hat product docs via Solr hybrid search) for OCP documentation and BYOK (customer FAISS indexes) for customer-provided content.

## End-to-End Flow

### A) OKP Flow (OCP Product Docs) — Runtime Retrieval

1. The operator always deploys an RHOKP sidecar container alongside the app-server pod. RHOKP serves Red Hat knowledge content (OCP docs, errata, runbooks) via a Solr HTTP API on localhost:8080.
2. The operator generates `solr_hybrid` config in `olsconfig.yaml` pointing to the RHOKP sidecar.
3. At startup, the service initializes a `SolrHybridSearch` client with the configured Solr HTTP base URL and loads the `ibm-granite/granite-embedding-30m-english` embedding model for query vectorization.
4. At query time, the `search_openshift_documentation` LangChain tool is registered. The LLM decides when to invoke it.
5. When invoked, the tool normalizes the query (stop-word removal, hyphenated-term quoting), embeds it with the granite model, and POSTs a hybrid-search request to Solr.
6. The Solr hybrid-search uses lexical edismax as the primary query with KNN vector reranking.
7. Results are deduped by parent document, filtered by score threshold, and returned as JSON passages (text, score, title, docs_url).
8. The LLM grounds its answer on the returned passages.

### B) BYOK Flow (Customer Content) — Unchanged

1. Customers build FAISS indexes from Markdown using the BYOK tool image.
2. Customer RAG images are referenced in the `OLSConfig` CR (`spec.ols.rag[]`).
3. The operator mounts BYOK indexes via init containers into a shared volume.
4. At startup, the service loads BYOK FAISS indexes using `sentence-transformers/all-mpnet-base-v2`.
5. At query time, BYOK chunks are retrieved via vector similarity, truncated to fit the token budget, and merged into the prompt context as direct RAG.
6. When both OKP and BYOK are active, BYOK chunks go into prompt context first, then the LLM can additionally call the OKP tool.

## Integration Contracts

### OKP — Solr HTTP Contract

| Endpoint | Method | Purpose |
|---|---|---|
| `http://localhost:8080/solr/portal-rag/hybrid-search` | POST | Hybrid search (lexical + KNN vector reranking) |

### OKP Configuration (olsconfig.yaml)

| Field | Purpose |
|---|---|
| `ols_config.solr_hybrid.url` | Solr HTTP base URL (operator-generated, always `http://localhost:8080`) |
| `ols_config.solr_hybrid.max_results` | Maximum passages returned per query |
| `ols_config.solr_hybrid.score_threshold` | Minimum score for passage inclusion |

### BYOK — Filesystem Paths

| Path | Producer | Consumer | Content |
|---|---|---|---|
| `/rag/vector_db/{index_name}/` | BYOK init container | service | FAISS index files (docstore, index_store, graph_store, vector_store, metadata) |
| `/rag/embeddings_model/` | service image | service | HuggingFace-compatible model directory (all-mpnet-base-v2) |

### BYOK Configuration (olsconfig.yaml)

| Field | Purpose |
|---|---|
| `ols_config.reference_content.embeddings_model_path` | Path to BYOK embedding model |
| `ols_config.reference_content.indexes[].product_docs_index_path` | Path to FAISS index directory |
| `ols_config.reference_content.indexes[].product_docs_index_id` | Optional ID for deserialization |
| `ols_config.reference_content.indexes[].product_docs_origin` | Human-readable label for logging |

Note: `ols_config.reference_content` is only populated when BYOK `rag[]` entries exist in the CR. It is no longer used for OCP product docs.

### Embedding Models

| Model | Used For | Dimensionality |
|---|---|---|
| `ibm-granite/granite-embedding-30m-english` | OKP query vectorization (client-side) | 384 |
| `sentence-transformers/all-mpnet-base-v2` | BYOK FAISS queries | 768 |

Both models are bundled in the service image. [PENDING] Ask OKP team if server-side embedding is supported (preferred; would eliminate granite model from service).

### Chunk Metadata

**BYOK chunks** carry metadata through the pipeline:
- `docs_url` (source URL), `title` (document title)
- HTML pipeline adds: `section_title`, `chunk_index`, `total_chunks`, `token_count`, `source_file`
- For llama-stack backends: `document_id` (for citation linking)

**OKP passages** carry:
- `text` (passage content), `score` (relevance score), `title` (document title), `docs_url` (source URL)
- `parent_id` (parent document deduplication key), `index_origin: "solr_hybrid"`

## Repo Ownership

| Repo | Owns |
|---|---|
| **lightspeed-rag-content** | BYOK tool image only. Main RAG content image deprecated. |
| **lightspeed-service** | BYOK index loading, OKP tool registration, Solr hybrid search client, query embedding (granite + mpnet), score filtering, deduplication, readiness probe integration |
| **lightspeed-operator** | RHOKP sidecar deployment, `solr_hybrid` config generation, BYOK init container setup, embeddings model path configuration |

## Planned Changes

| Ticket | Summary |
|---|---|
| OLS-2704 | RAG as service / MCP interface |
| OCPSTRAT-1492 | Layered product knowledge (CNV, ACM, RHOSO) |
| OLS-1872 | BYOK Phase 2: one-click import from Git/Confluence |
| — | Multi-product OKP filtering (RFE pending with OKP product) |
| — | Multi-version OKP support (RFE pending with OKP product) |
