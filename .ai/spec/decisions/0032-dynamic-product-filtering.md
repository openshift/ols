# 0032: Dynamic Product Filtering for Documentation Search

**Status:** Accepted
**Applies to:** lightspeed-service, lightspeed-operator

## Context

OKP's Solr corpus contains ~1.1M documents across ~98 products. Without filtering, searches return noisy cross-product results. Hardcoding product filters is inflexible as the product catalog grows.

## Decision

The `search_openshift_documentation` tool gains an optional `additional_products` parameter. Products are discovered from Solr at startup. The LLM selects relevant products per query. OCP is always the baseline. ROSA products are handled separately via operator-side cluster detection.

## Alternatives Considered

- **Hardcoded product list** — rejected because it is inflexible and requires code changes for new products
- **No filtering** — rejected because it is too noisy with 98 products
- **User-specified products** — rejected because users don't know the product taxonomy

## Consequences

- LLM dynamically selects relevant products per query
- OCP is always included as baseline
- ROSA detection uses Console brand + Infrastructure topology on the operator side, passed as `OLS_ROSA_PRODUCT` env var
- Product discovery at startup means new products appear without code changes
