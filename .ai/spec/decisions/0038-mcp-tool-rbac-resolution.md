# 0038: RBAC Resolution for MCP Tool Calls

**Status:** Accepted
**Applies to:** lightspeed-agentic-operator (analysis instructions), lightspeed-operator (ocp-mcp RFE target)
**Related:** [0033](0033-script-grounded-rbac.md) (script-grounded RBAC — extended, not replaced), [0013](0013-mcp-for-tool-integration.md) (MCP for tool integration)

## Context

Agentic execution derives least-privilege RBAC for a remediation by tracing the concrete `oc`/`kubectl` commands the analysis agent produced (decision 0033). Each step runs as a dedicated per-step ServiceAccount whose token is passed through to the API server; the OpenShift MCP server holds no RBAC of its own and authorizes as the caller's token (`lightspeed-operator/.ai/spec/what/ocpmcp.md`).

When a remediation step is an **MCP tool call** rather than a bash command, there is no script to trace. The RBAC target is frequently invisible in the tool arguments: subresources (`pods/exec`, `pods/log`, `nodes/proxy`, `*/scale`) implied by the tool's identity, generic pass-throughs whose group/resource come from `apiVersion`/`kind` arguments (`resources_delete`), a GVK embedded inside a free-form manifest argument (`resources_create_or_update`), or tools whose effect is unbounded (`helm_install` applies arbitrary chart contents). `ToolAnnotations` (`readOnlyHint`/`destructiveHint`) distinguish read from mutate but do not identify the resource or verb, and the MCP specification states annotations MUST NOT be the sole basis for security decisions.

Without a reliable RBAC source, the analysis agent either over-derives (violating least-privilege) or produces incomplete RBAC that 403s at runtime. The enforcement boundary (per-step SA token passthrough) is unaffected — the gap is **giving the analysis agent an authoritative RBAC source for tool calls**.

## Decision

Teach the analysis agent to resolve the RBAC for each MCP tool-call step in a fixed precedence, and report it as standard `PolicyRule`s in the `RemediationOption` — the same format used for `oc`/`kubectl` steps. The operator's RBAC materialization pipeline is unchanged; it materializes whatever PolicyRules appear in the approved option. [PLANNED: OLS-4060] MCP servers, skills, and required secrets are configured only at `AgenticRun.spec.tools` and shared by every step; per-step tool definitions are removed so analysis sees the same MCP servers that execution, verification, and escalation may use.

1. **Server-published `_meta` contract (primary).** The MCP server advertises per-tool required RBAC under `tool._meta["openshift.io/rbac"]` in `tools/list`, using static `rules`, argument-derived (`deriveFromArgs`), manifest-derived (`deriveFromManifest`), `unbounded: true`, or `noRbac: true` forms. This contract is the subject of an RFE to the OpenShift MCP server team (OLS-3680). The analysis instructions direct the agent to use `_meta` **only from operator-managed MCP servers** (the shipped `openshift-mcp-server`); `_meta` from bring-your-own MCP servers is untrusted and ignored.
2. **oc-IR derivation (fallback).** For a tool whose `_meta` is absent/untrusted, the analysis agent expresses the step's effect as equivalent `oc` command intermediate representation and derives RBAC from it via the existing script-grounded pipeline (0033).
3. **Fail-closed (terminal).** A step resolvable by neither path — an opaque tool (`unbounded: true`, or not oc-expressible) on a server whose `_meta` cannot be trusted — causes the remediation option to be rejected at option level; the run terminates in `Escalated` with a diagnosis naming the unresolvable tool.

The analysis agent is the MCP client — it calls `tools/list`, reads `_meta`, and interacts with MCP tools. The operator never communicates with MCP servers. `_meta` and oc-IR are derivation inputs only; enforcement remains the API server acting on the passed-through token. Secret/RBAC access is already blocked server-side by the ocp-mcp TOML deny-list (`ocpmcp.md` rule 16), so the agent cannot derive RBAC for operations the server refuses to perform.

## Alternatives Considered

- **Pure argument-based derivation / prediction** — rejected. Cannot see subresources, manifest-embedded GVKs, or unbounded effects; every consumer re-reverse-engineers each tool and drifts as the server changes. This is the band-aid the `_meta` contract replaces.
- **Out-of-band CRD of tool→RBAC maintained by OLS** (`AgenticMCPToolRBACList`) — rejected as the primary mechanism. Places the declaration in the wrong owner (the tool author knows the answer), drifts from the server, and scales poorly. The schema work was folded into the `_meta` contract instead.
- **Trust `_meta` from any MCP server** — rejected. `_meta` is untrusted per the MCP spec; an arbitrary server could over-declare. Trust is limited to operator-managed servers via analysis instructions, backstopped by the ocp-mcp server-side TOML deny-list.
- **Operator-side `_meta` resolution** — rejected. The operator never communicates with MCP servers; the analysis agent is the MCP client. Having the operator fetch `tools/list` would add an unnecessary coupling. The agent already sees `_meta` during analysis and reports RBAC in the standard RemediationOption format.
- **Operator-side deny ceiling on materialization** — not needed as a separate MCP-specific mechanism. The ocp-mcp TOML deny-list blocks Secret/RBAC access at the server, the cluster-admin approval gate validates proposed RBAC, and the API server enforces the actual token's permissions. Adding a deny ceiling on the operator's generic materialization path is a separate defense-in-depth consideration that applies to all RBAC sources equally, not an MCP-specific concern.
- **MCP Authorization (OAuth 2.1)** — not applicable. It governs client access to the MCP server, not the downstream Kubernetes RBAC a tool call requires.
- **Keep per-step tool definitions and give analysis the union of all MCP servers** — rejected for OLS-4060. It preserves tighter step isolation, but adds merge, deduplication, conflict, and credential-surface rules. The chosen design favors simpler API and operator behavior by making tools run-level only.

## Consequences

- Least-privilege RBAC is derivable for MCP tool calls, including subresource and manifest-embedded targets, without hard-coding tool knowledge in OLS.
- The authoritative RBAC declaration lives with the tool author and travels with the server, discovered over the protocol already in use — pending the RFE landing.
- The design has an external dependency: until the OpenShift MCP server populates `_meta`, tools resolve via the oc-IR fallback or fail closed.
- Opaque tools (Helm) and untrusted BYO MCP servers fail closed rather than over-grant, which may block some remediation options until an operator-managed server declares them.
- The operator's RBAC materialization pipeline requires no changes — MCP-derived PolicyRules arrive in the same RemediationOption format as oc-derived rules.
- Tool configuration becomes less granular: every sandbox step receives the same MCP servers, skills, and required secrets. Step-specific behavior is controlled by prompts/instructions and approval gates rather than by per-step tool sets.
- Consumers must distinguish `noRbac: true` from an absent/empty declaration; empty is treated as undeclared (fail-closed / fallback), never as "needs nothing."
