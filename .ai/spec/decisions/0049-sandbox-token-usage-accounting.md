# 0049: Callback-Based Token Accounting per Sandbox Invocation

**Status:** Proposed [PLANNED: OLS-3760]
**Applies to:** lightspeed-agentic-sandbox, lightspeed-agentic-operator

## Context

OLS-3661 publishes input/output token counts per Result CR, but the DeepAgents provider sums stream chunks and structured-output responses separately, misses classifier and summarization calls, and reports no reasoning, model, tool or context data. OLS-3760 asks for enough data to estimate cost by hand and to understand context usage. Providers report reasoning inconsistently through LangChain: Anthropic on Bedrock (streaming) and Vertex currently drop it; OpenAI uses tier-prefixed keys. No API reports tool-result tokens. Contract: [`what/token-usage.md`](../what/token-usage.md).

## Decision

- Count usage with one LangChain `UsageMetadataCallbackHandler` subclass per sandbox invocation, attached so that every model call (main agent, structured output, classifier, summarization) reaches it. The subclass adds a model-name fallback and per-call reasoning completeness tracking.
- Keep `outputTokens` as the provider's billed total; report `reasoningTokens` as an optional "of which", published only when complete.
- Derive tool and skill tokens from provider-reported input differences between consecutive main-agent calls, validated by the message list; never tokenize locally.
- Report `peakInputTokens` (largest single main-agent call input) for context occupancy.
- Accept missing reasoning on Anthropic Bedrock/Vertex until upstream fixes are adopted; no local hooks.

## Alternatives

- **Own accumulator in `GenerationCallback`:** duplicates upstream summing and conflicts with span filters in the same class. Rejected.
- **Extend existing scattered summing:** three code paths, already incomplete. Rejected.
- **Redefine `outputTokens` as visible output:** silently changes a shipped field and diverges from invoices and OTel metrics. Rejected.
- **Local tokenizer for tool tokens:** CPU cost and provider tokenizer mismatch; measured difference method is within 0.2–3.5%. Rejected.
- **Local hooks restoring Anthropic reasoning on Bedrock/Vertex:** relies on private LangChain names; upstream PRs exist. Deferred.

## Consequences

- Classifier and summarization tokens enter totals; totals rise versus OLS-3661 for the same work.
- One model per invocation is assumed; a separately configured classifier model would require per-model reporting.
- Tool/skill tokens are estimates (slight overstatement from framing and echoed reasoning; undercount when summarization invalidates a pair).
- Reasoning appears on Anthropic Bedrock/Vertex only after dependency bumps.
