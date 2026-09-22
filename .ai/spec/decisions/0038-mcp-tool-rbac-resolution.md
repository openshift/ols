# 0038: MCP Tool Admission and RBAC Metadata

**Status:** Accepted
**Applies to:** lightspeed-agentic-sandbox
**Related:** [0033](0033-script-grounded-rbac.md) (script-grounded RBAC for shell remediation), [0013](0013-mcp-for-tool-integration.md) (MCP for tool integration), [OLS-4059](https://redhat.atlassian.net/browse/OLS-4059)

## Context

Agentic sandbox invocations are one-shot processes. The sandbox receives run-level MCP server configuration, connects to each server, discovers its tools, and gives the resulting tool set to an LLM. A server may authenticate with a Kubernetes ServiceAccount token or with an external/client credential.

Mutating Kubernetes MCP tools need an RBAC contract so the analysis agent can report the permissions required by a remediation. Read-only tools do not need that contract under the accepted trust assumption below. The operator already materializes standard `PolicyRule`s and does not communicate with MCP servers.

## Decision

The sandbox filters MCP tools once, after `tools/list` and before the tool list is exposed to the LLM.

1. **Kubernetes-authenticated server.** A server is Kubernetes-authenticated when any configured `LIGHTSPEED_MCP_SERVERS[].headers[].source` is `ServiceAccountToken`. The sandbox computes this from raw configuration before resolving header values and carries the classification into provider construction. This classification applies to the entire server because authentication is configured per server, not per tool.
2. **Non-Kubernetes server.** A server using only `Secret` or `Client` header sources is outside this Kubernetes RBAC filter. Its discovered tools are allowed.
3. **Read-only admission.** A tool on a Kubernetes-authenticated server is allowed without RBAC metadata when its MCP annotations explicitly identify it as read-only (`readOnlyHint=true` and no contradictory destructive indication).
4. **Trust assumption.** A configured MCP server is trusted to classify read-only tools honestly. The read-only annotation is an admission shortcut, not an API-server security boundary. Kubernetes authorization remains enforced by the ServiceAccount token.
5. **Mutating admission.** A non-read-only tool on a Kubernetes-authenticated server is allowed only when `_meta["openshift.io/rbac"]` is structurally valid. Supported forms are `rules`, `deriveFromArgs`, and `deriveFromManifest`. Missing, empty, malformed, `noRbac: true`, or `unbounded: true` declarations cause the tool to be filtered.
6. **Filtering and server removal.** A filtered tool is never exposed to the LLM. If all tools from a server are filtered, the sandbox removes that server from the provider configuration. Tool/server removal alone does not fail or escalate the workflow; analysis continues with the reduced capability set and cannot claim to have used a filtered tool.
7. **Logging.** The sandbox emits structured application logs for each filtered tool and each removed server. Logs include server/tool names, classification, reason, and run/step correlation where available. Logs exclude tokens, secret values, authorization headers, and complete RBAC metadata payloads.
8. **RBAC derivation.** For an admitted non-read-only Kubernetes tool, the analysis agent resolves the metadata against actual call arguments and reports standard `PolicyRule`s in the `RemediationOption`. The operator materializes those rules through its existing generic pipeline.
9. **No oc-IR fallback.** The sandbox does not translate a non-compliant MCP tool into an `oc`/`kubectl` intermediate representation to admit it. The tool is filtered instead.

## Alternatives Considered

- **Require RBAC metadata for every Kubernetes tool** — rejected. The accepted design permits explicitly read-only tools without metadata, relying on the trusted-server classification assumption.
- **Use oc-IR as a fallback for mutating MCP tools** — rejected. Admission is simpler and safer when mutating Kubernetes tools without a contract are removed before LLM exposure.
- **Classify authentication per tool** — rejected. `LIGHTSPEED_MCP_SERVERS` configures headers per server, so server-wide classification is conservative and avoids inventing an unsupported per-tool security model.
- **Fail or escalate when all tools are removed** — rejected. Tool filtering is capability reduction; the analysis agent can continue with the remaining capabilities and report that a remediation is unavailable.
- **Operator-side MCP resolution** — rejected. The operator only passes MCP configuration and materializes standard `PolicyRule`s; the sandbox is the MCP client and owns discovery/filtering.

## Consequences

- Mutating Kubernetes tools without a valid RBAC declaration are never visible to the LLM.
- Non-Kubernetes MCP integrations such as Jira remain available without Kubernetes RBAC metadata.
- The sandbox owns MCP admission, filtering, and removal logging; the agentic operator requires no MCP-specific behavior.
- A dishonest read-only annotation can bypass the metadata requirement. This is an explicit trust assumption for configured Kubernetes-authenticated MCP servers, not a replacement for Kubernetes API authorization.
- The analysis may receive a reduced tool set and must not represent filtered capabilities as available.
- The `_meta["openshift.io/rbac"]` declaration remains an external MCP-server contract; until a server publishes it, its non-read-only Kubernetes tools are filtered.
