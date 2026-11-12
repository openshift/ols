# 0048: Unified Configuration Surface with a Root OLSConfig and Reusable Resources

**Status:** Accepted for planned implementation
**Date:** 2026-11-12
**Applies to:** lightspeed-operator, lightspeed-agentic-operator, lightspeed-agentic-sandbox, lightspeed-service, lightspeed-hub, lightspeed-agentic-console
**Supersedes in part:** [ADR 0046](0046-hubconfig-driven-multicluster-lifecycle.md) (Hub activation resource only)

## Context

Classic, Agentic, and Hub are configured through separate, overlapping resources: `OLSConfig` with inline providers and MCP servers, `AgenticOLSConfig`, `LLMProvider`, `Agent`, `ApprovalPolicy`, and the planned `HubConfig`. Admins must assemble several objects before Agentic works, and Classic and Agentic describe providers, credentials, and MCP servers differently. The team wants one coherent CRD-based experience with sensible defaults and simple overrides, without a new UI and without forcing Classic to be installed for Agentic.

## Decision

- One root `OLSConfig` holds installation-wide settings and optional `chat`, `agentic`, and `hub` sections. The presence of a section enables that capability; there are no `enabled` flags. `AgenticOLSConfig` and `HubConfig` settings move into the root.
- Independently usable entities are separate cluster-scoped resources: `LLMProvider`, `Agent`, and a new `MCPServer`. The root never embeds their definitions, and it is not a registry: users create and use them freely.
- Providers are always `LLMProvider` resources. Each keeps the current typed connection blocks and name-only `credentialsSecret` contract, gains `models` and a required `defaultModel`, and adds `VLLM` and `Fake` types. The operator never guesses a model.
- Chat and Agentic have independent default providers. With exactly one provider, the operator initializes unset defaults once; with several, admission requires explicit defaults. New providers never change selections.
- A built-in, operator-managed default agent works without an Agent CR. To customize it, admins create an `Agent` and select it in the root.
- Overrides replace, never append. Omitted fields inherit; an explicit empty list means none. The MCP list has two levels (root default, then `AgenticRun`); `Agent` has no tool fields. A run changes its model only by selecting another Agent.
- `introspectionEnabled` keeps its current meaning. When on, the operator creates a protected, operator-owned `MCPServer/openshift` and adds it to the default lists; overrides can drop it.
- TLS profiles and additional CAs live in the root. Feature gates, Classic's `credentialKey`, per-provider TLS overrides, and `replicas` on single-instance components are removed.
- Cross-resource references are validated by an admission webhook, intra-resource rules by CRD schema and CEL, and runtime health by reconciliation status.

Normative behavior, superseded locations, and out-of-scope topics are in [configuration-surface.md](../what/configuration-surface.md).

## Alternatives Considered

- **One comprehensive CR:** easy to locate, but it grows without bound and mixes reusable definitions with installation settings.
- **Independent composable CRs only:** flexible, but it keeps today's assembly burden for the happy path.
- **Inline bootstrap provider in the root:** one fewer resource initially, but two ways to define a provider and extra precedence rules.
- **Operator-created, editable default Agent CR:** easier first edit, but unclear ownership, upgrade, reset, and GitOps handoff rules.
- **Root as registry or allowlist for providers and agents:** explicit inventory, but it blocks users from creating and using resources freely.
- **Separate `HubConfig` CR (ADR 0046):** keeps fleet configuration apart, but adds a second root-level object; Hub becomes a root section like Chat and Agentic.
- **Common credential structure with authentication type and key mapping:** supports arbitrary Secret keys, but adds configuration without improving the happy path over Agentic's documented Secret entries.
- **Appending or merging lists across levels:** convenient additions, but the effective configuration is harder to predict and access can broaden silently.
- **Reserved `openshift` reference with no backing CR:** avoids an operator-owned object, but makes MCP reference resolution non-uniform.
- **Always injecting ocp-mcp:** matches today's Chat behavior, but creates an exception to the replace rule.
- **MCP references on Agent CRs:** couples prompts with tools, but steps of one run could get different tools; adding the field later is non-breaking, while removing it is not.
- **Inline model override on AgenticRun:** finer control, but a second way to choose a model that bypasses admin-curated Agents.

## Consequences

- The minimum installation is a credentials Secret, one `LLMProvider`, and the root `OLSConfig`.
- `LLMProvider` becomes the provider definition for both Classic and Agentic; the service and sandbox must honor the same model definitions and root TLS settings.
- `MCPServer/openshift` requires an admission rule that only the operator's service account can satisfy, and a reserved name.
- Hub activation follows root-section presence. The drain-before-decommission lifecycle of ADR 0046 is retained as intent, but its mapping to section removal still needs design.
- Emergency stop becomes a root field, so Kubernetes RBAC cannot grant access to only that field.
- Migration of existing installations, the per-level configurability matrix, run snapshot behavior, and the placement of approval policy and alerts-adapter configuration remain open and are listed as out of scope.
- Child CRD specs must be aligned when the planned behavior is implemented; this record does not claim code changes.
