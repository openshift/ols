# Query Pipeline

End-to-end flow for processing a user question: from console submission through LLM generation with tool calling to streamed response.

## End-to-End Flow

### Request Entry

1. The user types a question in the console chat UI, optionally attaching context (YAML, logs, alerts, error messages).
2. The console submits `POST /v1/streaming_query` to the service via the console API proxy (avoids CORS). The request contains: query text, conversation_id, optional provider/model override, attachments, mode (`ask` or `troubleshooting`), and MCP headers.

### Stage 1 — Validation & Redaction (lightspeed-service)

3. The service authenticates the user via Kubernetes token validation.
4. It generates or validates the conversation_id (UUID format).
5. Query filters (regex-based PII redaction) are applied to the query text.
6. The provider/model is validated against configuration. If not specified, defaults are used.
7. User token quota is checked — the request is rejected if quota is exhausted.

### Stage 2 — Attachment Processing (lightspeed-service)

8. Attachments are validated (type and content_type against allowed sets), redacted, and formatted as Markdown code blocks with language tags.
9. YAML attachments get resource kind/name extracted for contextual introduction.
10. Formatted attachments are appended to the query text.

### Stage 3 — Token Budget & RAG Retrieval (lightspeed-service)

11. The token budget is computed: `context_window - response_reserve (4096) - tool_reserve (25% default)` = prompt budget.
12. If BYOK indexes are configured, RAG chunks are retrieved via FAISS vector similarity from pre-loaded BYOK indexes. OCP product documentation is retrieved via the OKP tool in Stage 7.
13. Chunks below the similarity score cutoff are filtered. Remaining chunks are truncated to fit the prompt budget. (Applies to BYOK FAISS retrieval only.)
14. When multiple BYOK indexes are configured, results are merged using score dilution and deduplicated by URL. (Applies to BYOK FAISS retrieval only.)

### Stage 4 — History Retrieval & Compression (lightspeed-service)

15. Conversation history is fetched from the cache (PostgreSQL or in-memory).
16. If history overflows the effective budget, it is compressed via LLM summarization combined with recent verbatim entries.
17. Compression emits `history_compression_start` / `history_compression_end` streaming events.

### Stage 5 — Skill Selection (lightspeed-service)

18. If skills are configured, the query is matched against the skills directory using hybrid RAG (dense + BM25).
19. If a match is found and budget permits, skill content is loaded and a `skill_selected` event is emitted.

### Stage 6 — Prompt Composition (lightspeed-service)

20. The final system prompt is assembled: base prompt (mode-dependent) + agent instructions + RAG instructions + history instructions + skill content + RAG context.
21. Conversation history is added as message history.
22. The user query is appended. Total token usage is validated against the prompt budget.

### Stage 7 — LLM Generation with Tool Calling (lightspeed-service)

23. MCP tools are resolved from configured servers. The `search_openshift_documentation` tool is always registered when OKP/Solr hybrid is configured, providing LLM-driven retrieval of OCP product documentation. Tool filtering (hybrid RAG) is applied if enabled.
24. If the model has `reasoning_config` set in its configuration, provider-specific reasoning/thinking parameters are applied to the LLM invocation. The config is a freeform map — each provider interprets the keys it understands (e.g., OpenAI: `effort`/`summary`; Gemini: `thinking_level`/`thinking_budget`; Anthropic: `type`/`display`; vLLM: `enabled`). When `reasoning_config` is absent, the provider uses standard non-reasoning defaults (temperature, top_p, etc.).
25. The LLM is invoked with the composed prompt. Response tokens and reasoning chunks are streamed. Reasoning chunks arrive via LangChain `content_blocks` (OpenAI, Gemini, Anthropic) or `additional_kwargs["reasoning_content"]` (vLLM via `ChatVLLMReasoning` subclass).
26. If the LLM requests tool calls:
    - Tools are resolved to executable definitions.
    - Approval gates are checked (`never`/`always`/`tool_annotations`). If approval required, an `approval_required` event is emitted and execution blocks until the user responds.
    - Tools execute concurrently with retries (2 retries for transient failures, exponential backoff).
    - Tool output is truncated to fit the tool budget.
    - Results are fed back to the LLM for the next iteration.
27. The tool-calling loop runs up to `max_iterations` (ask=5, troubleshooting=15 by default). On the final iteration, tools are removed to force a text-only answer.
28. Streaming events are emitted throughout: `token`, `reasoning`, `tool_call`, `tool_result`, `approval_required`.

### Stage 8 — Response Storage & Quota (lightspeed-service)

29. Both text and reasoning chunks are accumulated into the response string during streaming. Reasoning content is included in the stored response so the model has access to its own reasoning within the current conversation turn.
30. The conversation turn (history + tool interactions) is stored in the cache as a plain-string `AIMessage`. No structured reasoning blocks or provider-specific signatures are preserved in the cache. [PLANNED: OLS-3442 — revisit cache schema if evals show structured reasoning storage improves multi-turn quality]
31. If data collection is enabled, the full transcript is stored (provider, model, user, query, response, RAG chunks, tools used).
32. Tokens are deducted from the user's quota (per-user and per-cluster limiters).
33. The `end` event is emitted with referenced documents, token counts, and remaining quota.

### Response Rendering (lightspeed-console)

34. The console renders streamed tokens as they arrive, displays referenced documents, and visualizes tool call results. Reasoning events are already rendered by the console — no changes needed.
35. The conversation is added to the user's history sidebar.

## Integration Contracts

### REST API (lightspeed-service)

| Endpoint | Purpose |
|---|---|
| `POST /v1/streaming_query` | Primary query endpoint. SSE streaming response. |
| `POST /v1/query` | Non-streaming query. [PLANNED: OLS-2682 — removal] |
| `GET /v1/conversations` | List user's conversations |
| `GET /v1/conversations/{id}` | Fetch full chat history |
| `DELETE /v1/conversations/{id}` | Delete conversation |
| `POST /v1/feedback` | Submit user feedback |
| `POST /v1/mcp-apps/tools/call` | Proxy tool calls to MCP servers |
| `POST /v1/tool-approvals/decision` | Submit approval/rejection for pending tool execution |

### Streaming Events (SSE, application/json)

| Event | Payload | When |
|---|---|---|
| `start` | conversation_id | Stream begins |
| `token` | id, token | LLM output chunk |
| `reasoning` | id, reasoning | Chain-of-thought chunk |
| `tool_call` | name, args, id, type | LLM requests tool execution |
| `approval_required` | approval_id, tool metadata | User must approve tool |
| `tool_result` | id, status, content, round | Tool execution completed |
| `skill_selected` | name | Skill matched to query |
| `history_compression_start/end` | — | History being compressed |
| `end` | referenced_documents, token counts | Stream complete |
| `error` | status_code, response, cause | Error occurred |

### Request Format

```
LLMRequest:
  query: string
  conversation_id: string (UUID)
  provider: string (optional)
  model: string (optional)
  attachments: [{attachment_type, content_type, content}]
  mode: "ask" | "troubleshooting"
  mcp_headers: {server_name: {header: value}}
  media_type: "application/json" | "text/plain"
```

### Token Budget Partitioning

- Context window = response reserve (4096) + tool reserve (25%, configurable 10-60%) + prompt budget (remainder)
- Prompt budget charged in order: base prompt → RAG → skill → history
- Tool budget charged: tool definitions (once) + per-round AI/tool messages + per-round cap

## Repo Ownership

| Repo | Owns |
|---|---|
| **lightspeed-service** | All 8 query processing stages: validation, redaction, attachment processing, RAG retrieval, history management, skill selection, prompt composition, LLM generation with tool loop, quota tracking, transcript storage |
| **lightspeed-console** | Query submission, streaming event rendering, conversation history UI, tool result visualization, approval UI for tool execution, feedback submission |
| **lightspeed-operator** | Generates `olsconfig.yaml` with provider credentials, RAG paths, MCP servers, quota config, tool filtering config, skills config, per-model `reasoning_config` |
| **lightspeed-rag-content** | BYOK tool image for customer custom FAISS indexes |

## Planned Changes

| Ticket | Summary |
|---|---|
| OLS-2682 | Remove `/v1/query` non-streaming endpoint |
| OLS-2680 | Add OpenAI `/responses` API compatibility layer |
| OLS-2684 | Remove client MCP headers (`mcp_headers` request field) |
| OLS-2825 | Consolidate context window token budget into single module |
| OLS-2840 | Refactor DocsSummarizer: extract ToolCallingAgent class |
| OLS-2898 | Raise `max_iterations` to 50 |
| OLS-2521 | Support Google Gemini as direct LLM provider |
| OLS-2776 | Support Anthropic as direct LLM provider |
| OLS-1660 | Llama Stack integration |
| OLS-3442 | Reasoning token support: per-model `reasoningConfig` for all providers, streaming accumulation fix, vLLM `ChatVLLMReasoning` subclass |
