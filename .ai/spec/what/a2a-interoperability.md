# A2A Agent Interoperability [PLANNED]

Cross-repository behavioral contract for OLS as both an A2A client and an A2A server. See `../decisions/0044-a2a-agent-interoperability.md`. A2A uses the [A2A protocol](https://a2a-protocol.org/v1.0.0/specification/) rather than an OLS-specific agent transport.

```text
+----------------------------+           A2A            +----------------------------+
| lightspeed-service         | <----------------------> | External agent             |
| A2A client and server      |   task requests/results  | A2A server and/or client   |
+----------------------------+                          +----------------------------+
```

## Scope and Ownership

1. Classic OLS MUST support outbound delegation to administrator-approved A2A agents and inbound A2A requests from other agents. This feature MUST NOT depend on the Agentic OLS operator or sandbox.
2. `lightspeed-operator` MUST own the administrator-facing allowlist and publish its effective configuration to `lightspeed-service`. `lightspeed-service` MUST own Agent Card discovery, tool adaptation, A2A task calls, and the inbound A2A endpoint.
3. The first release MUST support text input and a final text result. Coordinated multi-agent decomposition, a separate routing model, progress streaming, push notifications, non-text parts, and follow-up-question exchanges are outside this release.

## Administrator Configuration and Discovery

4. The operator MUST accept an optional list of approved outbound agents. Each entry MUST have a unique administrator-chosen name and HTTPS Agent Card URL, and MAY specify a positive request timeout and authentication headers. An absent or empty list MUST disable outbound delegation without disabling the inbound A2A endpoint.
5. The operator MUST validate the configuration and render it into the service's `a2a_agents` configuration. Agent names MUST produce unique, stable tool names that cannot collide with MCP tool names. The operator MUST mount referenced header secrets and make the existing additional CA bundle available to outbound A2A HTTPS connections.

6. Header values MAY explicitly come from the current user's Kubernetes token or an administrator-managed Secret. The default header map MUST be empty: OLS MUST NOT send a user token or other credential merely because an agent is configured. If a required header source cannot be resolved for a request, that agent MUST be unavailable for that request.
7. The service MUST fetch each available agent's Agent Card using that request's resolved headers. Discovery MUST be isolated per agent: timeout, authentication failure, invalid card, or unreachable endpoint MUST omit only that agent from the current query. Per-user authenticated cards MUST NOT be shared between users through a global cache.
8. OLS MUST validate a card's supported A2A interface and require a non-empty agent-level `description`.
9. A card-advertised task endpoint MUST remain within the origin of its administrator-approved Agent Card URL. OLS MUST reject cross-origin endpoints, redirects to an unapproved origin, and unsupported protocol bindings. The operator's allowlist, not Agent Card content, defines where OLS may send a task or configured credential.

### `OLSConfig` example

Example `OLSConfig` fragment (after the introduction of the a2a feature):

```yaml
spec:
  a2aAgents:
    - name: cluster-diagnostics
      agentCardURL: https://diagnostics.example.com/.well-known/agent-card.json
      timeout: 30 # seconds
      headers:
        - name: X-API-Key
          valueFrom:
            type: secret
            secretRef:
              name: diagnostics-api-key
    - name: workload-advisor
      agentCardURL: https://advisor.example.com/.well-known/agent-card.json
      headers:
        - name: Authorization
          valueFrom:
            type: client
```

`diagnostics-api-key` is a Secret in the operator namespace containing the `header` key. The `client` source explicitly passes the current user's Kubernetes token; omitting `headers` sends no credentials. The operator renders these entries under `a2a_agents` in the generated service configuration, using mounted Secret data for `X-API-Key` and the existing additional CA bundle for HTTPS verification.

### `olsconfig.yaml` example

Corresponding planned `olsconfig.yaml` fragment for `lightspeed-service` (the A2A mount path is illustrative; other service settings and CA entries are omitted):

```yaml
a2a_agents:
  - name: cluster-diagnostics
    agent_card_url: https://diagnostics.example.com/.well-known/agent-card.json
    timeout: 30
    headers:
      X-API-Key: /etc/a2a/headers/diagnostics-api-key/header
  - name: workload-advisor
    agent_card_url: https://advisor.example.com/.well-known/agent-card.json
    headers:
      Authorization: client
```

The operator mounts the Secret value at the configured header path. The service resolves `client` from the current request, as it does for MCP headers.

## Outbound Delegation

10. For each available approved agent, the service MUST expose exactly one tool to the existing OLS model tool loop. The tool's name MUST derive from the configured agent name; its description MUST derive from `AgentCard.description`. The tool input MUST be a text task for that agent.
11. The OLS system prompt MUST instruct the model to prefer an available specialist when its described capabilities fit the user's task, while allowing OLS to answer itself when no specialist is a better fit. Agent Card text MUST NOT be inserted into that system instruction.
12. Invoking an agent tool MUST send one A2A text message on behalf of the initiating user and wait for a final text message or completed task. If the agent initially returns a nonterminal task, OLS MUST retrieve its status within the configured deadline. `input-required` or `auth-required` states MUST become controlled tool errors; OLS MUST NOT start an implicit follow-up or credential exchange.
13. The effective deadline MUST be no longer than the agent timeout and the remaining OLS tool-round/request deadline. On timeout, OLS MUST attempt A2A task cancellation when a task ID is available; cancellation is best effort and MUST NOT be reported as a guarantee that remote work or side effects stopped.
14. A remote failure, unsupported result, or exhausted timeout MUST return a sanitized error through the existing tool-result path. A failed agent call MUST NOT prevent OLS from using results from other agents or tools, except where existing concurrent-round safety rules require the whole round to stop.
15. Agent tools MUST follow the existing tool approval strategy and token budget. A2A Agent Cards MUST NOT be treated as MCP read-only annotations; under `tool_annotations` approval mode, an A2A delegation MUST require approval. Successful and failed model-visible A2A results MUST follow `tool-result-inspection.md` when that planned inspection feature is enabled, before SSE emission, model reinjection, or conversation storage.
16. The service MUST preserve the selected agent name, A2A task ID when present, outcome, and elapsed time in its normal tool-call telemetry and audit context. Credentials MUST NOT enter tool descriptions, model prompts, ordinary error messages, or diagnostic logs. The remote agent's LLM usage MUST NOT be counted as OLS's own provider token usage.

## Inbound OLS Agent

17. The service MUST serve an OLS Agent Card at `/.well-known/agent-card.json` and an A2A HTTP JSON-RPC endpoint at `/a2a`. The card MUST advertise a reachable service URL, text input/output, and OLS's ask and troubleshooting capabilities. It MUST advertise only interaction capabilities actually supported by the endpoint; the first release MUST NOT advertise progress streaming or push notifications.
18. The Agent Card MAY be fetched without a user token and MUST contain no secret or user-specific configuration. Every task invocation MUST carry the end user's delegated Kubernetes bearer token in the HTTP `Authorization` header. No service identity or anonymous fallback is permitted for task execution.
19. Before running a task, the A2A endpoint MUST validate the bearer token with the existing Kubernetes TokenReview, enforce the existing `ols-access` SubjectAccessReview, and use the resulting user ID for conversation isolation, quota, and audit. Authentication and authorization failures MUST fail before LLM invocation and MUST map to the appropriate A2A/HTTP error without exposing credentials.
20. A valid inbound ask or troubleshooting request MUST pass its text and authenticated user context into the same OLS query pipeline used by the corresponding chat mode. It MUST apply the same input redaction, model configuration, quota, tool approval policy, result inspection, and transcript/audit rules. If that policy requires human approval for a tool call, the A2A request MUST fail with a controlled result before the tool executes; the first-phase A2A interface has no approval exchange. The A2A adapter MUST NOT construct an unauthenticated `DocsSummarizer` or bypass these checks.
21. The endpoint MUST return the final answer as an A2A text message or completed task. Each inbound request MUST use a fresh OLS conversation identity; it MUST NOT treat an A2A context ID supplied by another agent as authority to access an existing OLS conversation. Empty input and unsupported non-text parts MUST receive a protocol error or rejected task. The first release MUST NOT claim persistent task management or multi-turn continuity that it does not provide.

## Repo Ownership

| Repo | Contract |
| --- | --- |
| `lightspeed-operator` | Validates the outbound allowlist, resolves Secret references and CA mounts, and renders `a2a_agents` service configuration. |
| `lightspeed-service` | Discovers and validates Agent Cards, exposes one tool per approved agent, performs A2A calls, publishes the OLS Agent Card and authenticated endpoint, and applies query/tool safety and telemetry rules. |
| `lightspeed-console` | Uses the existing query, tool-call, approval, and result UI; no new first-phase A2A-specific UI contract. |
