# Agentic Disconnected Operation

Cross-repo contract for running Agentic OpenShift Lightspeed on a restricted-network cluster and verifying it with an on-cluster Gemma 4 model. This feature extends the product-wide disconnected-operation decision (`decisions/0012-disconnected-operation.md`).

> **Status:** All OLS-3472 rules are planned.

## Behavioral Rules

1. [PLANNED: OLS-3472] The agentic product MUST complete an `AgenticRun` without internet access when its container images and model artifacts have been provisioned and its LLM endpoint is reachable inside the cluster.
2. [PLANNED: OLS-3472] Gemma 4 MUST be served on a GPU-enabled cluster by RHOAI/KServe and vLLM through an OpenAI-compatible API. Gemma support MUST reuse the existing `OpenAI` `LLMProvider` discriminator with `spec.openAI` configuration and the sandbox OpenAI adapter; it MUST NOT introduce a Gemma-specific provider type or adapter.
3. [PLANNED: OLS-3472] Agentic runtime workloads, including per-run sandbox Pods and the vLLM inference Pods used by the run, MUST use only cluster-internal dependencies after provisioning. They MUST NOT download models, dependencies, tools, skills, or images from external locations after the disconnected boundary is enabled. Sandbox and OCI skill pullspecs MUST resolve to a cluster-local registry so kubelet-managed `PullAlways` requests cannot bypass Pod NetworkPolicy through a public registry.
4. [PLANNED: OLS-3472] Product verification MUST use `lightspeed-agentic-operator` product-e2e tests, not LSEval or a sandbox output-quality evaluation suite.
5. [PLANNED: OLS-3472] The disconnected product-e2e run MUST use the existing `E2E_SCENARIO_TAGS=core` filter. Scenario membership comes from tags in each `rhobs/troubleshooting-scenarios` `evals.yaml`; the disconnected job MUST NOT maintain a scenario allowlist.
6. [PLANNED: OLS-3472] CI MAY use a connected GPU cluster for provisioning, but MUST install temporary Kubernetes `NetworkPolicy` restrictions before starting product-e2e. This variant MUST use `bare-pod` sandbox mode so the sandbox policy can select every run Pod by its stable `agentic.openshift.io/run` label. The policies MUST also select the actual vLLM inference Pods, deny external egress, and preserve only required cluster-internal DNS, Kubernetes API, and sandbox-to-vLLM traffic.
7. [PLANNED: OLS-3472] Before product-e2e starts, CI MUST prove both sides of the boundary from policy-selected or policy-equivalent probe Pods: a previously reachable HTTPS egress canary is denied, while authenticated Kubernetes API and vLLM models-API requests succeed. Selector checks MUST prove that the policies match the actual runtime Pods.
8. [PLANNED: OLS-3472] A failure after egress restriction MUST remain a test failure. The harness MUST NOT restore external access and retry the run.

## Provisioning and Runtime Flow

1. CI requires `LIGHTSPEED_SERVICE_REF` as exactly 40 hexadecimal characters, verifies it resolves to a commit object, checks out `lightspeed-service` at that revision, and verifies the resulting HEAD.
2. CI invokes `tests/rhoai/scripts/provision-vllm.sh --profile gemma4 --output-env <path>` from that checkout.
3. RHOAI/KServe starts vLLM on a GPU node and prepares the selected model while provisioning access is available.
4. CI waits for the `InferenceService` and its OpenAI-compatible API to become ready.
5. CI installs Agentic OLS, mirrors sandbox and core-scenario OCI skill images to a cluster-local registry, and configures all runtime pullspecs to use that registry.
6. CI installs NetworkPolicies for sandbox Pods (selected by `agentic.openshift.io/run`) and vLLM Pods (selected by the provisioning output), then verifies the boundary described in rule 7.
7. Product-e2e creates an `OPENAI_API_KEY` Secret from the CI-provided vLLM key, an `LLMProvider` with `spec.type: OpenAI` and `spec.openAI.url` set to the internal URL returned by provisioning, and an `Agent` using the exact model identifier returned by vLLM.
8. The product-e2e runner clones `rhobs/troubleshooting-scenarios`, selects its existing `core` subset through `E2E_SCENARIO_TAGS`, and applies existing lifecycle and result-CR assertions.

## Repository Ownership

| Repository | Responsibility |
|---|---|
| `lightspeed-service` | Own reusable RHOAI/KServe/vLLM provisioning assets; accept a selectable model profile while preserving classic-test defaults |
| `lightspeed-agentic-operator` | Own the disconnected product-e2e variant, reuse of existing `E2E_SCENARIO_TAGS` filtering, NetworkPolicies/preflight probes, real-provider fixtures, lifecycle assertions, diagnostics, and cleanup |
| `lightspeed-agentic-sandbox` | Run Gemma 4 through the existing OpenAI adapter and custom OpenAI-compatible base URL |
| `ols` parent | Own this end-to-end contract and disconnected boundary |

`lightspeed-agentic-operator` CI checks out `lightspeed-service` separately. There is no Git submodule and no production dependency between the repositories.

## Failure and Diagnostic Contract

- Provisioning MUST fail clearly when GPU capacity, RHOAI/KServe readiness, image mirroring, model preparation, or vLLM readiness fails.
- Model-specific inputs MUST be validated before resource creation; an invalid or absent requested profile MUST NOT silently fall back to the classic Llama profile.
- Failure artifacts SHOULD include relevant operator conditions, Kubernetes events, ServingRuntime/InferenceService status, NetworkPolicies and selector checks, vLLM logs, AgenticRun conditions, result CRs, sandbox termination messages, and sandbox logs.
- Artifact collection MUST redact credentials and occur before cleanup removes evidence.
- Cleanup MUST be best-effort and MUST NOT obscure the original failure.

## Out of Scope

- LSEval datasets, LLM judges, and response-quality thresholds
- A Gemma-specific `LLMProvider` CRD branch or sandbox adapter
- A Git submodule or extracted shared-infrastructure repository
- Duplicating the OCP 5.x bundle and related-image requirements already specified by `lightspeed-operator`
- Productization process and CMDB/PIA records, which are managed outside runtime specifications
