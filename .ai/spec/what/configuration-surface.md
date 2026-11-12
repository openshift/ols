# Unified Configuration Surface

**Status:** All requirements below are [PLANNED]; this document does not assert implementation.
**Decision:** [ADR 0048](../decisions/0048-unified-configuration-surface.md).

## Purpose and Scope

Make the CRD-based configuration of OLS Classic (chat), Agentic, and Hub easier to use. Admins configure the capabilities they want; they do not assemble the components that implement them. This spec defines the target configuration surface: which resources exist, what each owns, how defaults are resolved, and how references are validated.

The scope is the configuration surface only. No new UI is introduced. Migration of existing installations, backward compatibility, and upgrade behavior are out of scope (see [Out of Scope](#out-of-scope)).

API versions of existing kinds are real. Field names follow the design examples; exact names and nesting are finalized in the child CRD specs during implementation.

## Experience Requirements

1. One root configuration enables Chat, Agentic, Hub, or any combination. Only the configured capabilities are deployed. Agentic MUST NOT require Chat to be configured or deployed.
2. The minimum configuration is a credentials Secret, one `LLMProvider`, and the root `OLSConfig`. Admins MUST NOT have to create routine supporting resources (Agent CRs, MCP server CRs, RBAC) for the basic installation to work.
3. Agentic setup is complete when an authorized user can manually start an investigation. Alert-driven automatic investigations are a separate opt-in and MUST NOT be enabled by configuring Agentic alone. Their absence is not a readiness failure.
4. A built-in default agent is ready once a valid provider and model are configured. It uses a clearly disclosed, standard read-only permission set. Execution permissions and custom access are separate, deliberate choices.
5. Status MUST identify missing or invalid configuration with an actionable message. Intentionally unconfigured capabilities MUST NOT make the installation NotReady.

## Resource Model

| Resource | API version | Scope | Responsibility |
|---|---|---|---|
| `OLSConfig` (root) | `ols.openshift.io/v1alpha1` | Cluster singleton | Capability enablement, installation-wide settings, Chat settings, Agentic settings, Hub settings, defaults |
| `LLMProvider` | `agentic.openshift.io/v1alpha1` | Cluster | Provider connection, credentials Secret reference, model definitions, required default model |
| `Agent` | `agentic.openshift.io/v1alpha1` | Cluster | Custom agent: provider and model selection, prompts, timeouts, turn limits |
| `MCPServer` | API group not decided | Cluster | Reusable MCP server connection: URL, timeout, header authentication |
| `SpokeCluster` | Unchanged | Unchanged | One managed cluster registration (see [multicluster operations](multicluster-ops.md)) |
| `AgenticRun` | `agentic.openshift.io/v1alpha1` | Unchanged | Runtime request: the work to perform, per-step agent selection, run-level tools |
| Secrets | `v1` | Operator namespace | Credential values |

```text
OLSConfig/cluster
├── chat     [optional; presence enables Chat]
│   ├── defaultProvider ──► LLMProvider ──► credentials Secret
│   └── mcpServerRefs ────► MCPServer
├── agentic  [optional; presence enables Agentic]
│   ├── defaultProvider ──► LLMProvider   (configures the built-in agent)
│   ├── defaultAgentRef ──► Agent         (optional custom default agent)
│   └── mcpServerRefs ────► MCPServer     (default list for runs)
├── hub      [optional; presence enables Hub]
└── installation-wide settings (TLS, trust, deployment, storage, collection, introspection, ...)

Agent ──► LLMProvider
AgenticRun ──► Agent (per step), MCPServer (run-level list), SpokeCluster (optional target)
```

6. The root owns installation-wide configuration, capability enablement, and default selections. Independently usable entities (providers, agents, MCP connections) are separate resources. The root MUST NOT embed inline provider, agent, or MCP server definitions.
7. The root is not a registry. Users MAY create `LLMProvider` and `Agent` resources and use them without listing them in the root. Creating a resource MUST NOT attach it to any consumer automatically, and referencing a resource MUST NOT grant authorization by itself.
8. The separate `AgenticOLSConfig` and `HubConfig` resources are not part of the target surface. Their settings move into the root (see [Superseded Locations](#superseded-locations)).

## Capability Enablement

9. The presence of `spec.chat`, `spec.agentic`, or `spec.hub` enables that capability. An absent section means the capability is not configured. No `enabled` flags exist.
10. An empty section (`chat: {}`) MUST remain meaningful and enable the capability. Defaulting MUST NOT create an absent section.
11. `spec.agentic.suspended` is the installation-wide emergency stop for Agentic. It is not an enablement flag. The existing suspension, admission, and acknowledgement contract in [agentic-run-termination.md](agentic-run-termination.md) applies unchanged at this location. Removing `spec.agentic` or deleting the root while suspended is subject to the admission rule that today covers deleting a suspended `AgenticOLSConfig`.
12. Presence of `spec.agentic` replaces the explicit creation of an `AgenticOLSConfig` as the Agentic workflow opt-in. The OCP version gate in [ADR 0042](../decisions/0042-unified-olm-bundle-runtime-gating.md) still applies.
13. Presence of `spec.hub` replaces the creation of a `HubConfig` as Hub activation intent. The section carries the fleet settings that `HubConfig` defined: `clusterRegistryMode` (`secret` or `mce`) and the optional MCE selector. `SpokeCluster` remains a separate resource.

## Default Provider and Model

14. Chat and Agentic have independent defaults: `spec.chat.defaultProvider` and `spec.agentic.defaultProvider`, each with a provider `name` and an optional `model`.
15. **Initialization.** When the root is created and exactly one `LLMProvider` exists, the operator writes that provider into the unset `defaultProvider` of each present Chat or Agentic section. This is a one-time initialization. Explicit selections are preserved.
16. When the root is created and more than one `LLMProvider` exists, admission MUST reject a root whose present Chat or Agentic section has no `defaultProvider`. The error names the fields to set.
17. Creating another `LLMProvider` MUST NOT change any selection. To change a default, the admin edits the root.
18. Every `LLMProvider` MUST declare `defaultModel`, which MUST name one of its `models`, even when it defines only one model.
19. Wherever a provider is selected (root Chat, root Agentic, `Agent`), a model override MUST be supported. Without an override, the provider's `defaultModel` is used. The operator MUST NOT guess a model or substitute another one. An invalid model selection fails validation.

## LLMProvider

20. `LLMProvider` keeps the current `type` discriminator and its typed connection blocks (`anthropic`, `googleCloudVertex`, `openAI`, `azureOpenAI`, `awsBedrock`), including the existing Azure and Vertex fields. No `apiMode` field is exposed.
21. Credentials keep the current contract: a name-only `credentialsSecret` reference in the provider block, to a Secret in the operator namespace with documented, provider-specific entries. No authentication-type field, no custom key mapping, and no credential-key override are introduced. Missing or invalid required entries MUST produce an actionable configuration error. Credential values never appear in CRs.
22. `spec.models[]` holds model definitions currently in `OLSConfig.spec.llm.providers[].models[]`: `name`, optional `url`, `contextWindowSize`, and `parameters` (`maxTokensForResponse`, `toolBudgetRatio`, `temperature`, `reasoningConfig`). An omitted temperature MUST stay distinct from an explicit zero.
23. A `VLLM` type covers RHOAI and RHEL AI vLLM endpoints. It MUST preserve the existing vLLM model and reasoning behavior, not relabel the endpoint as generic OpenAI.
24. A `Fake` type supports testing. It preserves the existing fake MCP tool-call option and requires no endpoint or credentials Secret.

## Agents

25. When no custom default is selected, Agentic uses an operator-managed built-in agent. It uses `spec.agentic.defaultProvider` and the read-only permission set from rule 4. The operator MUST NOT expose it as an editable Agent CR.
26. To customize the default, the admin creates an `Agent` and sets `spec.agentic.defaultAgentRef`. Removing the reference restores the built-in agent.
27. A custom agent's own provider and model selection governs runs that use it. The root's Agentic provider selection MUST NOT override it.
28. Existing Agent settings are retained: `llmProvider`, `model` (optional; omission uses the provider's `defaultModel`), `timeouts`, `maxTurns`, per-step `instructions`, and `reasoningConfig`.
29. `Agent` has no MCP server or other tool fields.

## MCP Servers

30. External MCP connections are defined by `MCPServer` resources. Consumers reference them by CR name, using an object with a `name` field (as `LLMProviderReference` does). The resource preserves the existing URL, timeout, and header-authentication capabilities. Header sources that a consumer cannot use (for example, client-token forwarding in background Agentic runs) MUST be rejected for that consumer.
31. Trust for user MCP servers with private CAs comes from the root additional-CA ConfigMap. `MCPServer` has no CA field.
32. `introspectionEnabled` stays in the root with its current meaning and default `true`. When it is on, the operator deploys the built-in OpenShift MCP server (ocp-mcp) as exactly one instance. When it is off, the operator removes it.
33. When `introspectionEnabled` is on, the operator creates an `MCPServer` named `openshift` that represents ocp-mcp. It sets an owner reference to `OLSConfig`, copies the service URL and the root ocp-mcp timeout into it, and stores no credentials (ocp-mcp uses the caller's token). When the flag is off, the operator deletes the CR.
34. The `openshift` name is protected. Admission MUST reject create, update, and delete requests for `MCPServer/openshift` from any identity except the operator's service account, including cluster admins. Reconciliation restores drift as a backup. The recommended mechanism is a `ValidatingAdmissionPolicy`.
35. ocp-mcp is configured only through the root. Its readiness is reported by the root `MCPServerReady` condition, not by the `openshift` CR status. The operator supplies service-CA trust for ocp-mcp to its consumers automatically.

## Configuration Inheritance

36. A setting configurable at more than one level follows these rules, from least to most specific: root default, then `Agent` where applicable, then `AgenticRun`.
    - An omitted field inherits from the level below.
    - An explicitly empty list (`[]`) means nothing is used. It does not inherit.
    - A non-empty list replaces the inherited list. Lists are never merged or appended.
    - Struct fields are overridden individually.
37. APIs MUST preserve the omitted-versus-empty distinction. Defaulting MUST NOT turn an explicit empty list into an inherited value.
38. The MCP server list has two levels: `spec.agentic.mcpServerRefs` in the root, then `AgenticRun.spec.tools.mcpServerRefs`. When `introspectionEnabled` is on, the operator adds `openshift` to the root default list; the admin's default list is extended, not replaced, including when it is empty or omitted. A run that sets its own list keeps ocp-mcp only if the list names `openshift`.
39. Chat follows the same list rules for `spec.chat.mcpServerRefs`. The operator adds `openshift` to the effective Chat list when `introspectionEnabled` is on.

## AgenticRun

40. Explicit per-step agent selection (`analysis`, `execution`, `verification`) and approval-time agent overrides stay as they are. A step without an agent uses the installation default agent (rules 25–26).
41. A run changes its model only by selecting a different Agent. `AgenticRun` has no model field.
42. Tools are not configured per step. One effective tool configuration applies to every step of a run.
43. Inline MCP connection definitions in `AgenticRun.spec.tools` are replaced by `mcpServerRefs`. Skills and `requiredSecrets` stay on the run. `requiredSecrets` configures tool Secrets, not LLM credentials.
44. `targetCluster` stays the way a run targets a spoke. Runs do not reference Hub configuration.
45. Installation settings (TLS, trust, sandbox configuration, retention ceiling, suspension) are read from the root. They are not copied into each run.

## Root Installation Settings

46. Settings that Agentic-only installations also need MUST NOT be reachable only through `spec.chat`. These include TLS, trust, proxy, deployment, storage, data collection, audit, built-in MCP, and RHOKP settings.
47. The root keeps every existing configuration capability not explicitly removed by rule 52. Required groups:

| Group | Settings preserved |
|---|---|
| Outbound TLS and trust | `tlsSecurityProfile` and `additionalCAConfigMapRef` at root level, applied to provider and MCP connections by both Chat and Agentic runtimes. Certificate-chain and hostname verification remain mandatory. |
| Serving TLS | Backend serving-certificate Secret reference and endpoint TLS profile. A serving certificate MUST never be treated as outbound trust material. |
| Proxy | Proxy URL and proxy CA ConfigMap and key |
| Built-in MCP | `introspectionEnabled` and the ocp-mcp timeout |
| Built-in knowledge (RHOKP) | `byokRAGOnly`, at root level because Agentic sandboxes also consume RHOKP |
| Deployment | Root `deployment` section with resources, tolerations, and node selector for each component; replicas only for components that support more than one (API) |
| Storage | Volume size and storage class |
| Data collection | Feedback and transcript switches and collector log level. Transcript opt-out also governs Agentic collection, so it MUST NOT depend on `spec.chat`. |
| Audit | Service audit emission, Agentic compliance audit (`AgenticOLSConfig.spec.audit`), the temporary audit log pipeline (`AgenticOLSConfig.spec.templog`), Collector storage, and trace export as distinct controls |
| Credential rotation | Existing hot-reload behavior |
| Chat behavior (`spec.chat`) | Log level, conversation cache tuning, query filters, system prompt, iteration limit, BYOK RAG sources, image-pull Secrets, quotas, tool filtering, tool approval |
| Agentic runtime (`spec.agentic`) | Sandbox mode and sandbox pod configuration, terminal-run retention ceiling, suspension and its acknowledgement status |

48. Components that run as a single instance (built-in MCP server, RHOKP, consoles, database, alerts adapter, OTel Collector) and the Agentic sandbox configuration MUST NOT expose `replicas`. A value MUST NOT be accepted and then ignored.
49. Deployment overrides MUST NOT enable a capability or an optional integration. Arbitrary PodSpecs, environment variables, volumes, or affinity rules are not introduced.
50. Presence of the tool filtering configuration enables tool filtering. Referencing an MCP server configures its use.
51. Chat tool approval and Agentic workflow-stage approval remain distinct settings.
52. Deliberate removals from the current surface:
    - `spec.featureGates` (`MCPServer`, `ToolFiltering`)
    - Classic's custom credential-key selection (`credentialKey`)
    - Per-provider TLS security profile overrides; the root profile applies
    - `replicas` on single-instance components (rule 48)

## Validation and Status

53. CRD schema and CEL validate rules within one resource, such as `defaultModel` membership in `models`.
54. A validating admission webhook validates cross-resource references in both directions and blocks known configuration-breaking changes. It MUST reject:
    - Deleting an `LLMProvider` selected by the root or referenced by an `Agent`.
    - Removing a model that the root or an `Agent` selects explicitly.
    - Deleting an `Agent` selected as `defaultAgentRef`.
    - Deleting an `MCPServer` referenced by the root.
    - A root, `Agent`, or `AgenticRun` that references a missing provider, model, agent, or MCP server.
    - A root or `AgenticRun` reference to `openshift` while `introspectionEnabled` is off.

    Protection of `MCPServer/openshift` is specified separately in rule 34.
55. Changing a provider's `defaultModel` to another valid model is allowed. Consumers without a model override follow it.
56. Admission errors MUST name the referencing resources and the fix. Example: `Cannot delete LLMProvider "production": selected by OLSConfig/cluster (spec.chat.defaultProvider) and referenced by Agent/thinking. Update those references first.`
57. Admission protects configuration integrity, not operational success. Kubernetes does not apply several resources atomically, and concurrent requests can race. Reconciliation MUST detect invalid references and report actionable conditions. Endpoint reachability and credential validity are readiness conditions, not admission checks.
58. Existing component conditions, aggregate status, and pod diagnostics are preserved.

## Superseded Locations

When implemented, the following settings move. Their behavior is unchanged unless this spec states otherwise. Existing specs that reference the current locations remain authoritative for that behavior.

| Current location | Target location |
|---|---|
| `OLSConfig.spec.llm.providers[]` | `LLMProvider` resources |
| `OLSConfig.spec.ols.defaultProvider`, `defaultModel` | `spec.chat.defaultProvider` |
| `OLSConfig.spec.mcpServers[]` | `MCPServer` resources, referenced by `spec.chat.mcpServerRefs` |
| `AgenticRun.spec.tools.mcpServers[]` | `MCPServer` resources, referenced by `AgenticRun.spec.tools.mcpServerRefs` |
| `OLSConfig.spec.ols.*` installation-wide settings | Root installation settings (rule 47) |
| `OLSConfig.spec.ols.deployment` | Root `deployment` section |
| `OLSConfig.spec.agenticOLS` | `spec.agentic` |
| `AgenticOLSConfig.spec.suspended` | `spec.agentic.suspended` |
| `AgenticOLSConfig.spec.audit`, `spec.templog` | Root audit settings (rule 47) |
| `HubConfig` | `spec.hub` ([ADR 0046](../decisions/0046-hubconfig-driven-multicluster-lifecycle.md) activation resource, superseded in part by [ADR 0048](../decisions/0048-unified-configuration-surface.md)) |

## Out of Scope

These topics are excluded from this spec. They need separate design decisions:

- Migration, backward compatibility, and upgrade behavior for existing installations, including an existing user MCP server named `openshift`.
- Which settings each of `LLMProvider`, `Agent`, and `AgenticRun` can configure and override, beyond the MCP server list and model selection decided here.
- Whether an `AgenticRun` snapshots its effective configuration at creation, and how runs in progress react to a removed or changed referenced resource.
- Precedence between an Agent's `reasoningConfig` and the selected model's `reasoningConfig`.
- Placement of `ApprovalPolicy` and alerts-adapter configuration.
- How removing `spec.hub` maps to the drain-and-decommission lifecycle of [ADR 0046](../decisions/0046-hubconfig-driven-multicluster-lifecycle.md), including re-adding the section during shutdown; whether `spec.hub` requires `spec.agentic`; and Hub workload resource overrides.
- Delegated RBAC for the emergency stop now that it is a root field.
- Classic provider types other than vLLM and Fake that have no `LLMProvider` type (for example, Watsonx), and unauthenticated vLLM endpoints.
- Per-chat provider or model selection by end users.
- Behavior when an admin later removes an initialized `defaultProvider` from the root (rule 15 covers creation only).

## Examples

Illustrative only.

```yaml
apiVersion: agentic.openshift.io/v1alpha1
kind: LLMProvider
metadata:
  name: company-llm
spec:
  type: OpenAI
  openAI:
    url: https://llm.example.com/v1
    credentialsSecret:
      name: llm-credentials
  defaultModel: standard
  models:
    - name: standard
      contextWindowSize: 128000
      parameters:
        maxTokensForResponse: 4096
    - name: reasoning
---
apiVersion: ols.openshift.io/v1alpha1
kind: OLSConfig
metadata:
  name: cluster
spec:
  introspectionEnabled: true
  tlsSecurityProfile:
    type: Intermediate
  additionalCAConfigMapRef:
    name: corporate-ca
  chat:
    defaultProvider:
      name: company-llm            # written by the operator if unset (rule 15)
    mcpServerRefs:
      - name: documentation
  agentic:
    defaultProvider:
      name: company-llm
      model: reasoning
    mcpServerRefs:
      - name: documentation        # effective default: [documentation, openshift]
  hub:
    clusterRegistryMode: secret
```

```yaml
apiVersion: agentic.openshift.io/v1alpha1
kind: AgenticRun
metadata:
  name: docs-question
  namespace: my-project
spec:
  request: Summarize the upgrade prerequisites.
  analysis:
    agent: thinking                # model comes from Agent/thinking
  tools:
    mcpServerRefs:
      - name: documentation        # replaces the default; openshift is dropped
```

## Ownership and Implementation Navigation

| Repo | Responsibility | Child specs to align during implementation |
|---|---|---|
| lightspeed-operator | Root `OLSConfig` schema, initialization, Chat config generation, ocp-mcp and `MCPServer/openshift` lifecycle, Hub activation from `spec.hub`, root settings handoff to Agentic | `what/crd-api.md`, `what/ocpmcp.md`, `what/app-server.md`, `what/agentic-sandbox-profile.md`, `how/config-generation.md` |
| lightspeed-agentic-operator | `LLMProvider` models, `defaultModel`, vLLM and Fake types; `Agent` defaults; `AgenticRun` MCP references; default-agent resolution; admission webhooks | `what/crd-api.md`, `what/run-lifecycle.md`, `what/sandbox-execution.md` |
| lightspeed-agentic-sandbox | Provider runtime for vLLM and Fake types; model parameters from `LLMProvider` | `what/configuration.md`, `what/provider-contract.md` |
| lightspeed-service | Chat consumption of `LLMProvider` model definitions and `MCPServer` connections | `what/config.md`, `what/llm-providers.md`, `what/tools.md` |
| lightspeed-hub | Fleet settings sourced from `spec.hub` instead of `HubConfig` | `what/system-overview.md`, `what/spoke-lifecycle.md` |
| lightspeed-agentic-console | Configuration views for the relocated resources | `what/configuration.md` |

This change adds no implementation code or implementation plan.
