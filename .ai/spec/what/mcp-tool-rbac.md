# MCP Tool RBAC Resolution

How the agentic sandbox admits MCP tools and supplies least-privilege Kubernetes RBAC for remediation steps that are **MCP tool calls**. The sandbox filters unsafe tools before they are exposed to the LLM; admitted mutating Kubernetes tools must publish an RBAC contract that the analysis agent reports as standard `PolicyRule`s for the operator to materialize. Motivated by [OLS-4059](https://redhat.atlassian.net/browse/OLS-4059). Design rationale: decision [0038](../decisions/0038-mcp-tool-rbac-resolution.md).

## Architecture

The **analysis agent** (running in the sandbox) is the MCP client — it calls `tools/list`, sees `_meta`, and interacts with admitted MCP tools. The **agentic operator** owns the built-in analysis instructions and passes them to the sandbox; those instructions teach the agent how to use admitted MCP tools and resolve their RBAC metadata. The operator never communicates with MCP servers or inspects discovered tools. The sandbox filters tools before LLM exposure; for an admitted non-read-only Kubernetes tool, the analysis agent derives RBAC from the tool metadata and reports standard `PolicyRule`s in the `RemediationOption`.

The **operator** reads PolicyRules from the approved option and materializes them onto the per-step SA — unchanged from the existing pipeline. The enforcement boundary (per-step SA token passthrough to the API server) is also unchanged.

The gap this spec closes is **admitting MCP tools safely before LLM exposure and defining the prompt contract for admitted tools**. The sandbox classifies servers by their configured authentication, filters non-compliant Kubernetes tools during one-shot tool discovery, and passes the remaining tools to the provider. The agentic operator supplies analysis instructions that describe the admitted-tool contract; the analysis agent derives and reports RBAC metadata for admitted mutating tools and does not receive tools that lack the required contract.

[PLANNED: OLS-4060] MCP server definitions are run-level only: `AgenticRun.spec.tools.mcpServers` is the single MCP server list for analysis, execution, verification, and escalation. Per-step tool overrides are removed, so analysis sees the same MCP servers that later steps may use and can derive remediation RBAC and validation requirements from the complete tool universe.

## Problem

For `oc`/`kubectl` steps, the analysis agent derives least-privilege RBAC by tracing the concrete commands. For MCP tool calls there is no command to trace, and the RBAC target is often invisible in the tool arguments:

- **Subresources** implied by the tool identity, not the arguments — `pods_exec` → `create pods/exec`, `pods_log` → `get pods/log`, `nodes_log`/`nodes_stats_summary` → `nodes/proxy`, `resources_scale` → `*/scale`.
- **Generic pass-throughs** whose group/resource come from `apiVersion`/`kind` arguments — `resources_get`/`resources_list`/`resources_delete`.
- **Manifest-embedded GVK** — `resources_create_or_update` carries the target inside a free-form manifest argument.
- **Unbounded effect** — `helm_install`/`helm_uninstall` apply whatever the chart contains; RBAC is not a function of the arguments.

The `_meta["openshift.io/rbac"]` contract gives the analysis agent an RBAC source published by the tool author, discoverable over the MCP protocol the agent already speaks. For Kubernetes-authenticated mutating tools, this declaration is required before the tool is exposed to the LLM.

## Behavioral Rules

### Tool admission (one-shot discovery)

These rules govern the **sandbox** before the LLM receives MCP tools. The sandbox performs this admission once during each one-shot invocation after `tools/list`; there is no dynamic tool refresh during the invocation.

1. **Kubernetes-authenticated server.** An MCP server is Kubernetes-authenticated when any configured `LIGHTSPEED_MCP_SERVERS[].headers[].source` is `ServiceAccountToken`. The sandbox MUST compute this classification from the raw configuration before resolving header values and carry it with the server into provider construction; resolved header values alone do not retain their source type. This classification applies to the entire server because authentication is configured per server, not per tool.
2. **Non-Kubernetes servers.** Servers authenticated only with `Secret` or `Client` header sources are outside this Kubernetes RBAC filter and their discovered tools are allowed.
3. **Read-only tools.** On a Kubernetes-authenticated server, a tool is admitted without an RBAC declaration when its MCP annotations explicitly identify it as read-only (`readOnlyHint=true` and no contradictory destructive indication). This is a trust assumption: a configured MCP server is trusted to classify read-only tools honestly. The annotation is not an API-server enforcement boundary.
4. **Mutating tools.** A non-read-only tool on a Kubernetes-authenticated server is admitted only when it contains a structurally valid `_meta["openshift.io/rbac"]` declaration.
5. **Structural validation.** The sandbox MUST require the RBAC metadata to be an object using a supported declaration form (`rules`, `deriveFromArgs`, or `deriveFromManifest`). `noRbac: true`, `unbounded: true`, missing, empty, or malformed declarations are invalid for a non-read-only tool and cause it to be filtered. The sandbox validates shape only; detailed rule resolution remains the analysis agent's responsibility.
6. **Filtering.** A filtered tool MUST NOT be exposed to the LLM. If filtering removes every tool from a server, the sandbox MUST omit that server from the provider configuration. Removing a tool or server is not by itself a workflow failure or escalation; the analysis proceeds with the reduced capability set and MUST NOT claim to have used a filtered tool.
7. **Logging.** The sandbox MUST emit structured application logs for each filtered tool and each server removed because no tools remain. Logs include server/tool names, classification, reason, and run/step correlation when available. Logs MUST NOT include tokens, secret values, authorization headers, or complete RBAC metadata payloads.

### RBAC derivation after admission

1. **Metadata input.** For an admitted non-read-only Kubernetes tool, the analysis agent reads `tool._meta["openshift.io/rbac"]` from the `tools/list` response and resolves it against the actual call arguments. The contract supports static rules, argument-derived rules, and manifest-derived rules. The sandbox's admission layer validates only the top-level shape and supported form; it does not claim that the resulting rules are sufficient until the analysis agent resolves them.
2. **Argument-scoped resolution.** For `deriveFromArgs`/`deriveFromManifest` forms and rules with argument references, the agent MUST map `kind → resource` via the cluster's discovery/RESTMapper and scope the reported PolicyRule to the specific namespace/object where the contract provides `namespaceFrom`/`resourceNamesFrom`.
3. **`resourceNames` limitation.** The agent MUST NOT rely on `resourceNames` to scope `list`/`watch` — Kubernetes RBAC cannot restrict those verbs to named objects. Read-listing tools resolve to namespace-wide read.

### Analysis instruction contract (agentic-operator-owned)

1. **Admitted-tool availability.** The built-in analysis instructions MUST tell the analysis agent that it may use only the MCP tools exposed by the sandbox. A filtered tool or removed server is unavailable and MUST NOT be represented as available or used in a remediation option.
2. **RBAC resolution.** For an admitted non-read-only Kubernetes MCP tool, the analysis instructions MUST require the agent to read `_meta["openshift.io/rbac"]`, resolve the declaration against the actual call arguments, and report the resulting standard `PolicyRule`s in the `RemediationOption`.
3. **Non-Kubernetes tools.** The analysis instructions MUST allow non-Kubernetes MCP integrations to be used without Kubernetes RBAC metadata, while preserving any provider/server-specific authorization requirements.
4. **No oc-IR fallback.** The analysis instructions MUST NOT direct the agent to translate a filtered or non-compliant MCP tool into oc-IR to bypass admission. If the required tool is unavailable, the agent MUST propose only an alternative supported by the tools it received or explain that no remediation can be proposed.
5. **Prompt ownership and precedence.** The agentic operator owns the built-in analysis prompt and its rendering into `/input/system-prompt` or `/input/query`. User-configured `Agent.spec.instructions.analysis` values retain the existing precedence and override behavior, but MUST NOT weaken the sandbox admission contract.

The operator transports configuration and instructions; it does not inspect `tools/list`, validate `_meta`, or resolve MCP metadata itself.

### Operator materialization

1. **Unchanged pipeline.** The operator materializes PolicyRules from the approved `RemediationOption` onto the per-step SA — the same code path used for `oc`/`kubectl` steps (`sandbox-execution.md` rule 21). It does not distinguish MCP-derived rules from oc-derived rules. No MCP-specific operator code is required.
2. **Split by scope.** Namespaced rules materialize as Role/RoleBinding; cluster-scoped rules as ClusterRole/ClusterRoleBinding. Both bind to the per-step execution SA (`agentic-security.md` rule 7), never the shared `lightspeed-agent` SA.

## Integration Contracts

### `_meta["openshift.io/rbac"]` (MCP `tools/list`)

The MCP server publishes, per tool, a versioned RBAC document. Supported admission forms are `rules` (static, optionally argument-scoped), `deriveFromArgs` (target from named arguments), and `deriveFromManifest` (target from a manifest argument). `unbounded: true` and `noRbac: true` are declaration states understood by the contract, but are not valid for admitting a non-read-only Kubernetes tool. Full schema and examples are specified in the OLS-3680 RFE to the MCP server team. This is an external dependency: until a Kubernetes-authenticated server publishes valid metadata for its non-read-only tools, those tools are filtered.

### RemediationOption RBAC

The RBAC requirements attached to each `RemediationOption` (`agentic-runs.md` — AnalysisResult schema) are the union computed by the analysis agent from admitted tool metadata, provenance-tagged. The operator materializes them in Phase 4 (`agentic-runs.md` rule 17) before provisioning the execution pod.

## Repo Ownership

| Repo | Owns |
| --- | --- |
| **lightspeed-agentic-operator** | Run-level `AgenticRun.spec.tools` transport, built-in analysis instructions for admitted MCP tools, prompt rendering, and unchanged generic RBAC materialization. It does not inspect discovered tools or resolve MCP metadata. |
| **lightspeed-agentic-sandbox** | One-shot MCP discovery, raw-configuration authentication classification, Kubernetes-authenticated tool admission/filtering, provider integration, structured removal logs, and runtime exposure of admitted tools. The analysis agent running in the sandbox resolves admitted RBAC metadata according to operator-provided instructions. |

## Child Spec Boundary

The sandbox child spec is the implementation authority for admission and provider enforcement. The agentic-operator child spec is the implementation authority for the analysis instruction contract and prompt transport.

| Repo | Spec File | Update |
| --- | --- | --- |
| lightspeed-agentic-operator | `what/sandbox-execution.md` | Define the built-in analysis instructions for admitted MCP tools, no oc-IR bypass, filtered-tool unavailability, and prompt transport. |
| lightspeed-agentic-sandbox | `what/configuration.md`, `what/provider-contract.md` | Define one-shot MCP tool admission, raw-configuration Kubernetes-authenticated server classification, RBAC metadata validation, provider filtering, server removal, and structured logging. |

## Constraints

- MCP server read-only annotations are trusted for configured Kubernetes-authenticated servers; they are an admission shortcut, not an API-server security boundary.
- Kubernetes-authenticated mutating tools require a structurally valid `_meta["openshift.io/rbac"]` declaration. There is no oc-IR fallback.
- The sandbox performs structural validation, filtering, and provider enforcement; the analysis agent resolves admitted declarations into standard PolicyRules using agentic-operator-provided instructions.
- The operator's RBAC materialization pipeline is generic — it does not distinguish MCP-derived PolicyRules from other PolicyRules. No MCP-specific operator code is needed.
- [PLANNED: OLS-4060] Run-level tools intentionally expose the same MCP servers, skills, and required secrets to every sandbox step. This simplifies API and operator behavior but removes per-step tool isolation; step behavior is constrained by instructions, approval gates, and per-step ServiceAccount RBAC.
- The raw MCP configuration's `headers[].source` is the authority for Kubernetes-authenticated classification. Resolved secret values MUST NOT be used to infer authentication class.

## Planned Changes

| Ticket | Summary |
| --- | --- |
| OLS-4059 | Sandbox admission for Kubernetes-authenticated MCP tools: read-only tools are allowed; non-read-only tools require structurally valid `_meta["openshift.io/rbac"]`; non-compliant tools are filtered before LLM exposure. |
| [PLANNED: OLS-4060] | Simplify tool configuration to run-level only (`AgenticRun.spec.tools`) so every sandbox step receives the same declared MCP server set. |
| [PLANNED] | Non-resource / aggregated-API RBAC form for the `metrics` toolset (Thanos/Alertmanager), pending alignment in the RFE. |
