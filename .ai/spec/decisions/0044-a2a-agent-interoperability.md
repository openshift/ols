# 0044: A2A Agent Interoperability

**Status:** Accepted for planned implementation

**Applies to:** lightspeed-service, lightspeed-operator

## Context

An OpenShift cluster can run specialist agents alongside OLS. OLS should be able to delegate a suitable user task to an administrator-approved agent, and other agents should be able to invoke OLS for its OpenShift knowledge and troubleshooting capabilities. MCP already connects OLS to tools, but an independently operating agent has its own capabilities, task lifecycle, and A2A interface.

The initial product requirement is to select a specialist from the agent-level description in its Agent Card, without a separate routing stage. This does not rule out future expansion of the routing logic.

## Decision

OLS will support both A2A client and server roles through the A2A HTTP JSON-RPC binding. The classic service will own both roles; the classic operator will expose administrator configuration for the outbound allowlist and publish it to the service. A2A support is available in Classic OLS on supported OpenShift versions and does not require the Agentic OLS layer.

For outbound delegation, each administrator-approved agent is represented by **one** callable tool in the existing OLS tool loop. Its model-visible description comes from `AgentCard.description`. A fixed OLS system instruction tells the model to prefer an approved specialist when its described capabilities fit the user's task. The model makes the initial selection; there is no dedicated agent retrieval index or preliminary routing model. The existing tool approval, budgeting, result inspection, and audit boundaries apply to A2A calls.

The administrator configures each agent's name, HTTPS Agent Card URL, timeout, and optional authentication header sources. OLS sends **no credentials by default**. A current-user Kubernetes token is sent only when explicitly selected as a header source; an administrator-managed Secret may also be selected explicitly. If a card advertises a task URL with a different scheme, host, or port than the administrator-approved card URL, OLS will not call it. If a configured agent's card is unavailable or invalid, OLS omits that agent's tool for the current query; OLS and other approved agents remain available.

For inbound requests, OLS publishes an Agent Card describing its ask and troubleshooting capabilities and accepts A2A text requests at a protocol endpoint. Each task request must carry the end user's delegated Kubernetes bearer token and pass the same authentication, `ols-access` authorization, quota, and audit handling as a normal OLS query. The A2A adapter calls the existing query pipeline with that user's identity.

The first release delegates one text task to a selected agent and waits for its final result within the configured deadline. A later design may add a separate model-based routing step, coordinated decomposition across multiple agents, progress streaming, and multi-turn exchanges. This decision does not preclude the existing tool loop from selecting more than one tool in a query.


## Alternatives Considered

### Separate routing model and agent retrieval index now

Deferred. It could decide whether to delegate before the main model runs and narrow a large agent catalog, but adds model calls, latency, cost, and another routing policy before the initial deployment has demonstrated a need for it.

### Cross-agent human-in-the-loop

Deferred. Cross-agent human-in-the-loop (HITL) approval is deferred beyond the first release. Core A2A can signal an in-task authorization request with `auth-required`, but it does not distinguish human approval from other authorization needs or define an interoperable approval request and approve/deny exchange. Future HITL support requires choosing an A2A extension or another explicit client/server approval contract and defining how the paused task resumes.

### OpenShift Lightspeed Console Plugin update

Deferred. The first release uses the existing console tool-call presentation for A2A delegation. A UI extension that shows agent calls separately from other tool calls is deferred until the initial implementation is landed and proves useful.

### One generic delegation tool for every remote agent

Rejected. It hides each specialist's description from the model's tool choice and moves selection into custom tool logic.

### Unauthenticated inbound A2A execution

Rejected. It would bypass OLS's user authorization and quota boundary and could grant the caller capabilities unrelated to the end user's permissions.

## Consequences

- Agent Card discovery adds request latency, and an unavailable agent is temporarily absent from the model's choices.
- Administrator approval of an endpoint is a trust decision: a delegated task and any explicitly configured credential are sent to that agent. The remote agent enforces its own authorization and accounts for its own model usage; OLS quota covers OLS model usage only.
- A2A results and errors are untrusted tool content. The existing result-safety contract applies before they enter model context; it cannot undo side effects already performed by a remote agent.
- Agent Card descriptions can change between requests. The service validates and bounds card metadata before presenting it as tool metadata; cards cannot change the system instruction or expand the configured allowlist.

The normative behavior and repository ownership are in `../what/a2a-interoperability.md`.
