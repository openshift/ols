# RAG Pipeline

Dual-architecture retrieval system: OKP (Red Hat product docs via Solr hybrid search) for OCP documentation and BYOK (customer FAISS indexes) for customer-provided content.

## End-to-End Flow

### A) OKP Flow (OCP Product Docs) — Runtime Retrieval

1. The operator always deploys an RHOKP sidecar container alongside the app-server pod. RHOKP serves Red Hat knowledge content (OCP docs, errata, runbooks) via a Solr HTTP API on localhost:8080.
2. The operator generates `solr_hybrid` config in `olsconfig.yaml` pointing to the RHOKP sidecar.
3. At startup, the service initializes a `SolrHybridSearch` client with the configured Solr HTTP base URL and loads the `ibm-granite/granite-embedding-30m-english` embedding model for query vectorization. The client uses lazy init with retry: if the initial connection fails, every subsequent access re-attempts the connection until it succeeds; once connected, the client is cached normally. There is no retry cap — the operator's wait-for-rhokp init container guarantees RHOKP is reachable at startup, so retries are a safety net for rare post-startup connectivity drops.
4. [PLANNED: OLS-3697] The operator deploys a standalone RHOKP Deployment (`lightspeed-rhokp`) with a ClusterIP Service on HTTPS port 8443. RHOKP serves Red Hat knowledge content (OCP docs, errata, runbooks) via a Solr HTTP API, now accessible to any pod in the operator namespace (app-server, agentic sandbox). TLS is provided by OpenShift service-ca.
5. The operator generates `solr_hybrid` config in `olsconfig.yaml` pointing to the standalone RHOKP Service (`https://lightspeed-rhokp.<ns>.svc:8443`).
6. At startup, the service initializes a `SolrHybridSearch` client with the configured Solr HTTP base URL and loads the `ibm-granite/granite-embedding-30m-english` embedding model for query vectorization.
7. At query time, the `search_openshift_documentation` LangChain tool is registered. The LLM decides when to invoke it.
8. When invoked, the tool normalizes the query (stop-word removal, hyphenated-term quoting), embeds it with the granite model, and POSTs a hybrid-search request to Solr.
7 .The Solr hybrid-search uses lexical edismax as the primary query with KNN vector reranking.
8. Results are deduped by parent document, filtered by score threshold, and returned as JSON passages (text, score, title, docs_url).
9. The LLM grounds its answer on the returned passages.

### B) BYOK Flow (Customer Content) — Unchanged

1. Customers build FAISS indexes from Markdown using the BYOK tool image.
2. Customer RAG images are referenced in the `OLSConfig` CR (`spec.ols.rag[]`).
3. The operator mounts BYOK indexes via init containers into a shared volume.
4. At startup, the service loads BYOK FAISS indexes using `sentence-transformers/all-mpnet-base-v2`.
5. At query time, BYOK chunks are retrieved via vector similarity, truncated to fit the token budget, and merged into the prompt context as direct RAG.
6. When both OKP and BYOK are active, BYOK chunks go into prompt context first, then the LLM can additionally call the OKP tool.

## BYOK Content Prioritization

When BYOK chunks are present in the prompt context, the system adjusts prompt instructions to prioritize customer domain knowledge over OKP tool results. This prevents the LLM from reflexively preferring generic OCP documentation over organization-specific content.

### Prompt Priority Rules

When BYOK context is present:

1. **BYOK context instruction** — the generic "Use the retrieved document" instruction is replaced with a BYOK-aware variant that labels the content as domain-specific knowledge provided by the organization. The instruction tells the LLM to treat BYOK content as authoritative for topics it addresses, but to disregard it if the chunks appear unrelated to the user's query.
2. **OKP tool guidance** — the `SOLR_DOCS_TOOL_SUPPLEMENT` is replaced with a variant that positions OKP as supplementary. The "ALWAYS call this tool" directive is removed. The LLM is instructed to use `search_openshift_documentation` only to fill in general OpenShift details that the domain knowledge does not cover, and never to contradict or override relevant domain knowledge.
3. **Chunk labeling** — BYOK chunks are formatted with a `"Domain Knowledge:"` prefix instead of the generic `"Document:"` prefix, reinforcing the source distinction in the prompt.

When BYOK context is **not** present (OKP-only): all prompt instructions remain unchanged from current behavior.

### Rationale

The current prompts contain two competing "ALWAYS" directives: the base instruction says to always use provided context as the primary source of truth, while the OKP tool supplement says to always call `search_openshift_documentation` before answering. The OKP directive is more specific and actionable, so LLMs preferentially follow it — even when BYOK content directly answers the question with organization-specific procedures.

The qualified instruction ("if they address the user's specific question") mitigates the risk of low-relevance BYOK chunks polluting answers. FAISS retrieval always returns top-K results regardless of relevance, and the current similarity cutoff (0.3) is permissive. Rather than tuning numeric thresholds, the prompt lets the LLM judge whether the domain knowledge is relevant to the specific query.

## Integration Contracts

### OKP — Solr HTTP Contract

| Endpoint | Method | Purpose |
|---|---|---|
| `https://lightspeed-rhokp.<ns>.svc:8443/solr/portal-rag/hybrid-search` | POST | [PLANNED: OLS-3697] Hybrid search (lexical + KNN vector reranking) via HTTPS |

### OKP Configuration (olsconfig.yaml)

| Field | Purpose |
|---|---|
| `ols_config.solr_hybrid.url` | Solr HTTPS base URL (operator-generated, `https://lightspeed-rhokp.<ns>.svc:8443`) [PLANNED: OLS-3697] |
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

Both models are bundled in the service image. [PLANNED] Ask OKP team if server-side embedding is supported (preferred; would eliminate granite model from service).

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
| **lightspeed-operator** | [PLANNED: OLS-3697] RHOKP standalone Deployment/Service, `solr_hybrid` config generation, BYOK init container setup, embeddings model path configuration |

## Planned Changes

| Ticket | Summary |
|---|---|
| OLS-2704 | RAG as service / MCP interface |
| OCPSTRAT-1492 | Layered product knowledge (CNV, ACM, RHOSO) |
| OLS-1872 | BYOK Phase 2: one-click import from Git/Confluence |
| OLS-3697 | RHOKP standalone HTTPS Deployment — sidecar replaced by `lightspeed-rhokp` Service, TLS via service-ca, ServiceMonitor for Solr metrics |
| — | Multi-product OKP filtering (RFE pending with OKP product) |
| — | Multi-version OKP support (RFE pending with OKP product) |
| OLS-3799 | Operator: add wait-for-rhokp init container to block app-server startup until RHOKP Solr is reachable. Service: replace `@cached_property` with lazy init + unlimited retry for `SolrHybridSearch` client to prevent permanent connection loss. |
| OLS-3599 | BYOK content prioritization — conditional prompt instructions to elevate BYOK domain knowledge and demote OKP tool guidance when both are active |
