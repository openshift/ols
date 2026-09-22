# OLS-4210 Tool-Output Inspection Configuration Design

## Goal

Define one cluster-wide configuration contract that controls tool-result inspection for both Classic OLS and the DeepAgents runtime.

## Scope

This change establishes the configuration contract only. Runtime classifier behavior, sandbox environment injection, and failure handling are implemented by OLS-4211 through OLS-4213.

Repositories in scope:

- `lightspeed-operator`
- `agentic-operator`

## Configuration contract

The cluster administrator configures inspection through `OLSConfig`:

```yaml
spec:
  ols:
    guardrails:
      toolResultInspection:
        enabled: false
```

The field is optional. The effective value is `true` unless the administrator explicitly sets `enabled: false`.

The contract uses the following typed structure:

- `GuardrailsConfig` under `OLSSpec.guardrails`
- `ToolResultInspectionConfig` under `GuardrailsConfig.toolResultInspection`
- `enabled` as a pointer Boolean so omission can be distinguished from `false`

## Data flow

```text
OLSConfig.spec.ols.guardrails.toolResultInspection.enabled
    -> lightspeed-operator effective-value resolution
    -> Classic service configuration
    -> lightspeed-agentic-configuration:
         tool-output-inspection-enabled: "true|false"
    -> agentic-operator configuration cache
    -> OLS-4213 sandbox environment injection
```

The handoff ConfigMap key is exactly:

```text
tool-output-inspection-enabled
```

The value is the lowercase string `"true"` or `"false"`.

## Classic operator behavior

`lightspeed-operator` will:

1. Add the CRD fields and regenerate the CRD manifests.
2. Resolve the effective value with default-enabled behavior.
3. Include the effective value in the generated Classic service configuration.
4. Always publish the handoff ConfigMap key during normal reconciliation.
5. Update the handoff ConfigMap when the configured value changes.

The operator must not infer the value from unrelated feature gates or deployment mode.

## Agentic operator behavior

`agentic-operator` will:

1. Define the handoff key in its configuration package.
2. Parse the handoff value into the cached configuration.
3. Treat `true` and `false` as valid values, case-insensitively after whitespace trimming.
4. Treat missing, empty, or malformed values as enabled.
5. Expose only the effective Boolean value to later sandbox provisioning code.

OLS-4210 does not inject the environment variable into Pods. That behavior belongs to OLS-4213, which will consume this cached value.

## Error handling and compatibility

- Existing ConfigMaps without the new key remain valid.
- Missing or malformed handoff values fail safely to the enabled state.
- No classifier calls or runtime termination behavior are added by this change.
- The existing sandbox, OTEL, MCP, and RHOKP handoff fields remain unchanged.
- Gemini ADK and OpenAI Agents are not changed by this contract.

## Testing

### Classic operator

Tests will verify:

- omitted guardrail configuration produces `true`;
- explicit `enabled: true` produces `true`;
- explicit `enabled: false` produces `false`;
- the Classic generated configuration contains the effective value;
- the handoff ConfigMap contains the exact key and string value;
- reconciliation updates the key when the CR value changes.

### Agentic operator

Tests will verify:

- `true` and `false` values are parsed correctly;
- whitespace and case variations are accepted;
- missing, empty, and malformed values resolve to enabled;
- existing configuration fields continue to parse unchanged.

## Files expected to change

### `lightspeed-operator`

- `api/v1alpha1/olsconfig_types.go`
- generated CRD and deepcopy files
- `internal/controller/utils/types.go`
- `internal/controller/appserver/assets.go`
- `internal/controller/agenticintegration/assets.go`
- `internal/controller/utils/constants.go`
- related unit tests

### `agentic-operator`

- `pkg/configuration/constants.go`
- `pkg/configuration/config.go`
- related configuration tests

## Out of scope

- Classifier implementation and provider calls.
- Chunking, retry, deadline, telemetry, or quota behavior.
- Sandbox environment injection.
- DeepAgents middleware and tool-result interception.
- AgenticRun failure propagation.
- Cross-runtime integration and real-model evaluation.
