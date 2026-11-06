# OLS-3939: Shared Tool-Output Redaction Design

**Status:** Proposed; not implemented or committed to an OLS 2.0 release.
**Source:** [OLS-3939](https://redhat.atlassian.net/browse/OLS-3939). The Epic requests full redaction behavior; a September 2026 comment removes it from the OLS 2.0 requirement and proposes a PII spike. This document describes the requested full future behavior, not a release commitment.

## Intent

Prevent recognizable credentials and PII in external tool results from entering either Classic or Agentic model context or an inspection-classifier request. Preserve useful non-sensitive tool data by replacing only matched values with visible category placeholders. Use one policy contract across the two separately deployed runtimes so coverage does not silently diverge.

## Goals, non-goals, and constraints

- Cover model-visible successful results and tool-generated error text from Classic MCP tools and Agentic DeepAgents tools, including shell/skills/MCP results; no MCP Gateway or RHOAI dependency.
- Default-on deterministic protection for API keys (`sk-`, `ghp_`, AWS `AKIA`), JWTs (`eyJ`-prefixed structured tokens), OAuth/bearer tokens, password or credential values in `key=value` lines, email, US/EU phone numbers and US SSNs. Define explicit, testable token boundaries and representative benign Kubernetes fixtures; high-entropy strings cannot reliably be classified by regex alone and must not be advertised as guaranteed detection.
- Replace only matched values with named placeholders such as `[REDACTED:api_key]`; preserve surrounding keys, lines and otherwise harmless data. Do not silently drop an entire result for a redaction match. Report counts and safe rule names, never matched text.
- Shared effective pattern set, rule order, placeholder naming, enablement and operator configuration semantics. Define a versioned conformance corpus consumed by each runtime's offline tests; implementation may differ by language or package.
- Do not change Classic user-prompt redaction behavior or its administrator-configured `query_filters`, injection-classifier decisions, authorization, tool approval, or existing limits. Inspection remains independently enabled/disabled.
- Do not promise perfect DLP, Secret decoding, or wholesale suppression of raw execution evidence from audit/trace systems. Explicitly document residual leakage routes rather than calling this end-to-end data-loss prevention.

## Approaches

1. **Selected: one cross-repo policy contract, separate runtime integrations.** Put canonical rules and conformance examples in the parent `.ai/spec/what/`; Classic and Agentic each implement the same effective policy and run shared vectors. Respects separate runtime ownership, at the cost of cross-repo compatibility checks and coordinated releases.
2. **Shared importable package.** One library for both runtimes reduces code drift but adds a new independently versioned, packaged dependency and coordinated rollout requirements. Not selected for this Epic.
3. **Classic-service-only redaction hook.** Lowest effort but cannot cover the separately executed Agentic DeepAgents sandbox. Rejected.

## Proposed default deterministic matcher

The **built-in rules MUST NOT redact standalone IPv4 or IPv6 addresses or CIDR ranges**. Network addresses are ordinary troubleshooting data; replacing them would make questions about firewall rules, routes and service networks unanswerable. A value in an explicitly credential-named assignment is still redacted because of its key, even if the value resembles an address. An administrator-defined custom rule may have different behavior, but the product default must preserve standalone network values. Test `192.0.2.0/24`, `10.0.0.0/8`, and `2001:db8::/32` inside benign firewall and Kubernetes results.

| Input category | Default behavior |
| --- | --- |
| API keys, JWT candidates, bearer tokens, credential assignment values | Replace the matched value with a named placeholder; preserve keys and `Bearer` prefix |
| Email, plausible US/EU phone numbers, plausible US SSNs | Replace matched value with a named placeholder |
| IPv4, IPv6, CIDR ranges, benign Kubernetes metadata | Keep unchanged |

Example tool result before redaction:

```text
firewall allow: 192.0.2.0/24 -> 10.0.0.0/8; ipv6: 2001:db8::/32
contact: admin@example.com
api_key=sk-abcdefghijklmnopqrst
```

After redaction (the assignment value takes precedence over the embedded API-key alternative):

```text
firewall allow: 192.0.2.0/24 -> 10.0.0.0/8; ipv6: 2001:db8::/32
contact: [REDACTED:email]
api_key=[REDACTED:credential]
```

Complete **single-tool-result** example: an `oc get configmap firewall-config -o yaml` response. The mixed content below is deliberately synthetic; one substitution pass processes the **whole returned string**, not one rule or YAML field at a time.

```text
Tool result, before:
apiVersion: v1
kind: ConfigMap
metadata:
  name: firewall-config
  namespace: operations
data:
  rules: |
    allow 192.0.2.0/24 -> 10.0.0.0/8; allow 2001:db8::/32
    deny all other sources
  incident-notes: |
    Owner admin@example.com (US 415-555-0123, EU +44 20 7946 0958) investigated request 123-45-6789.
    Reproduced with sk-abcdefghijklmnopqrst and ghp_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.
    AWS identity AKIAAAAAAAAAAAAAAAAA; session eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.abcdefghijklmnopqrstuvwxyz.
    Authorization: Bearer abcdefghijklmnopqrst; password=MySecret123!

Model-visible result, after one pass:
apiVersion: v1
kind: ConfigMap
metadata:
  name: firewall-config
  namespace: operations
data:
  rules: |
    allow 192.0.2.0/24 -> 10.0.0.0/8; allow 2001:db8::/32
    deny all other sources
  incident-notes: |
    Owner [REDACTED:email] (US [REDACTED:phone], EU [REDACTED:phone]) investigated request [REDACTED:ssn].
    Reproduced with [REDACTED:api_key] and [REDACTED:github_token].
    AWS identity [REDACTED:aws_access_key]; session [REDACTED:jwt].
    Authorization: Bearer [REDACTED:oauth_token]; password=[REDACTED:credential]
```

The result has ten replacements total (two phone matches, one each of the other eight categories). Firewall ranges, YAML structure and non-sensitive text survive. The model and user-facing tool-result views receive the second version; the first may still exist in existing full-fidelity source audit/trace records. This full-result example is a positive test fixture, not a guarantee of detection for every real-world spelling or format.

Compile one `re.VERBOSE | re.IGNORECASE` matcher per effective configuration revision. The alternatives below are a **candidate baseline**, not a claim of complete PII detection. Each named alternative yields one category-specific `[REDACTED:<category>]` placeholder. The implementation must test Python-regex syntax, actual secrets from fixtures, overlap/precedence, and false positives before freezing the normative pattern. In the sketch, `(?<![A-Za-z0-9_])` / `(?![A-Za-z0-9_])` are identifier boundaries, not word boundaries; a `prefix` group is retained verbatim when substituting key-value or bearer matches.

```regex
(?P<jwt>(?<![A-Za-z0-9_-])eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}(?![A-Za-z0-9_-]))
|(?P<github_token>(?<![A-Za-z0-9_])ghp_[A-Za-z0-9]{36}(?![A-Za-z0-9_]))
|(?P<aws_access_key>(?<![A-Za-z0-9_])AKIA[0-9A-Z]{16}(?![A-Za-z0-9_]))
|(?P<api_key>(?<![A-Za-z0-9_])sk-[A-Za-z0-9_-]{16,}(?![A-Za-z0-9_-]))
|(?P<bearer_token>(?<![A-Za-z0-9_])(?P<bearer_prefix>Bearer[ \t]+)(?P<bearer_value>[A-Za-z0-9._~+/-]{16,}={0,2})(?![A-Za-z0-9_]))
|(?P<credential_assignment>(?<![A-Za-z0-9_])(?P<credential_prefix>(?:password|passwd|pwd|api[_-]?key|access[_-]?token|refresh[_-]?token|client[_-]?secret|secret[_-]?key)[ \t]*=[ \t]*)(?P<credential_value>[^\s,;#]+))
|(?P<email>(?<![A-Za-z0-9._%+-])[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}(?![A-Za-z0-9.-]))
|(?P<ssn>(?<![0-9])(?!(?:000|666|9[0-9]{2})[- ])(?:[0-6][0-9]{2}|7[0-9]{2}|8[0-9]{2})[- ](?!00)[0-9]{2}[- ](?!0000)[0-9]{4}(?![0-9]))
|(?P<phone>(?<![0-9])(?:\+1[ .-]?)?\(?[2-9][0-9]{2}\)?[ .-][2-9][0-9]{2}[ .-][0-9]{4}(?![0-9])|(?<![0-9])\+[1-9][0-9]{0,2}(?:[ .-]?[0-9]){7,12}(?![0-9]))
```

**What the combined regex itself returns:** it has no redacted-text output. `finditer()` yields match objects; for input `"password=MySecret123!"`, one match has `group(0) == "password=MySecret123!"`, `lastgroup == "credential_assignment"`, `group("credential_prefix") == "password="`, and `group("credential_value") == "MySecret123!"`. For input `"admin@example.com"`, one match has `lastgroup == "email"` and `group(0) == "admin@example.com"`. For input `"192.0.2.0/24"`, there is no match. The substitution callback turns those matches into `"password=[REDACTED:credential]"` and `"[REDACTED:email]"` respectively; without that callback, the regex does not redact anything. On the combined ConfigMap example above, `finditer()` produces ten match objects in order: `email`, `phone`, `phone`, `ssn`, `api_key`, `github_token`, `aws_access_key`, `jwt`, `bearer_token`, `credential_assignment`. The callback yields the shown complete model-visible result.

The callback replaces the **entire** token for standalone JWT/key/email/SSN/phone matches. For `bearer_token` and `credential_assignment`, it preserves the respective `prefix` and replaces only the value (e.g. `password=[REDACTED:credential]`, `Bearer [REDACTED:oauth_token]`). Exactly one alternative handles a position; where a value could match both JWT and assignment, precedence and replacement boundaries must ensure no original secret survives (test with embedded JWTs and tokens). Replacement text is never rescanned. Rule names and group names are fixed safe identifiers, not raw operator-supplied expressions.

**Detection boundaries:** `ghp_` length is format-specific and may evolve; other GitHub token prefixes require explicit future rules. `sk-` does not cover every provider key format. `eyJ` is a JWT *candidate*, not proof of a valid JWT. Bearer and assignment rules intentionally match credential-shaped values without entropy estimation. A bare high-entropy string without a recognized prefix or context has no reliable regex-only identification and is not claimed protected. US phone candidates require separators; international candidates require `+`; unformatted digit strings are excluded to avoid redacting cluster IDs. SSN format checks cannot establish that a number is a real SSN. Email, phone, SSN, API keys, JWT and credential assignments all need benign Kubernetes YAML/log examples and adversarial near-misses; custom patterns must not defeat the safe default. Avoid matching multiline values by default and do not log the source text.

## Behavioral design

1. Define canonical category IDs, precedence, named placeholders and test vectors at the parent level. **Compile the effective tool-output rule set once on configuration load/change**, into one regex alternation with named groups; reuse that compiled matcher across requests and perform one substitution pass per result. Never compile rules per tool call. A match callback selects the placeholder and increments per-category counts; return both sanitized text and structured counts/rule names without scanning again. Overlapping alternatives resolve according to documented precedence; match only original input, so generated placeholders are not rematched. Avoid ambiguous unbounded backtracking and benchmark benign and adversarial large Kubernetes results; a combined regex reduces repeated scans but is not a proof of linear time. Classic's `QueryFilter` machinery is administrator-defined and already compiles its patterns at construction, but its `Redactor` logs redacted output at debug level; neither current default coverage nor debug behavior satisfies this policy by itself. Remove full redacted-input and filter-object debug logging from the shared engine; log only safe match counts and validated rule identifiers, never input text or replacement contents. The same compiled-matcher implementation MAY be reused for Classic prompts and tool results only if it preserves existing prompt-specific configured filters, order, and replacement behavior; sharing an implementation MUST NOT make the new tool-output defaults apply to prompts or silently change `query_filters` semantics. Administrator additions/removals must be validated, named, deterministic, and produce the same effective policy on both sides; compile the effective rules into a single matcher where feasible, and explicitly bound or reject patterns that violate the supported safety/performance contract. Configuration failures must surface instead of disabling protection silently.
2. In Classic, sanitize effective tool result and error text after execution and before any classifier request, model reinjection, user-facing stream event, or model-facing wrapper. Preserve the existing concurrent-round inspection/abort semantics: do not emit any result or flag for a rejected round. The model receives the redacted result even if inspection is disabled. **Change the existing Classic raw `tool_result` SSE contract:** its visible `content` MUST contain the sanitized reply, never raw tool text. Add `redacted: boolean` (true iff at least one replacement occurred in any emitted user-visible field of this reply) and `redacted_count: integer` (total replacements across those fields, counted once per source occurrence) to the same tool-result payload, correlated by the existing tool-call ID. For an unmodified result the flag is false and count zero; the UI displays a clear "Sensitive values redacted" indicator when true and never exposes raw text through hover, copy, download or replay. Sanitize user-visible history/transcript replays and secondary `structured_content`/references from the same reply before delivery; if a structured value cannot be safely sanitized, omit that field with a safe indication rather than exposing its raw content. Do not mutate the separate preserved raw execution result used by existing full-fidelity audit obligations. This deliberately supersedes `lightspeed-service/.ai/spec/what/tools.md` rule 18n's current raw-SSE statement for user-facing SSE only; update that rule when writing normative specs.
3. In Agentic, intercept all implemented DeepAgents tool results and tool-generated error content before the inspection classifier and before the next model call, regardless of provider route. Native source spans may still record raw callbacks at completion per the existing inspection and product-trace contracts. Normalized result events and user-facing tool-result views MUST use redacted text and carry the per-reply boolean/count on successful inspection; inspection rejection continues to suppress normalized events and results. The Agentic console has no direct HTTP tool-result stream: provide a structured operator/Result/status handoff for per-reply flags correlated by actual tool-call IDs and render the indicator next to the sanitized reply; **do not** infer flags from pod logs or expose raw tool text in the log viewer. Explicitly test that no unredacted tool result is sent to either main model or classifier or user-facing reply surface. If the framework cannot intercept a tool/error path before model use, fail closed rather than silently bypass redaction; do not alter the existing inspection classifier's own failure policy.
4. Configure default-on `toolOutputRedaction` in `OLSConfig`; the operator conveys an equivalent validated policy and enabled state to both Classic's generated `olsconfig` ConfigMap and the Agentic sandbox via the appropriate operator handoff. Include the agentic-operator in ownership of the handoff. Custom rules and removals must have explicit admin intent and validation; do not assume the Epic's proposed service-local `QueryFilter` list automatically reaches the sandbox. Disablement, if exposed, is an explicit administrator opt-out with security consequences; no missing-field default may disable protection.
5. Produce metadata-only redaction telemetry: tool name, total match count and matched rule names, plus a boolean tool-level indication when any match fires. The Epic proposes `gen_ai.tool.pii_redacted`; check compatibility with the existing GenAI semantic-convention/audit schema before treating it as a standard field. Do not put match values or raw payload snippets in the new event or attribute. Existing full-fidelity audit and native execution spans are not rewritten by this feature, so they remain separate sensitive-data handling obligations.
6. Offline verification uses the same positive and negative corpus in both repos: `sk-`, `ghp_`, `AKIA`, JWT, bearer/OAuth, `password=`, email, US/EU phone, SSN, normal Kubernetes YAML; multiple matches, overlap, tool errors, failure/configuration paths, inspection on/off, and all supported Agentic provider routes. Assert the exact payload seen by classifier and main model as well as safe metadata; include Classic concurrency and Agentic native-span behavior. Test that tool rules are compiled once per configuration revision, never per request; that structured match counts need no second input scan; that debug logging never includes input, secrets, or configured replacement contents; and that Classic prompt-filter ordering and substitutions remain unchanged.

## Logging and telemetry contract

- **Configuration load/reload:** on a successful effective-policy compile, record one INFO-level configuration-state record with enabled status, policy revision/identifier, rule count and origin (built-in versus validated administrator rules); no pattern bodies, replacement contents or input text. Avoid recording the same state on every request. If an administrator explicitly disables protection, record one WARN-level state change (and the disabled configuration state), without per-result warning spam. Failed validation/compilation must produce one safe ERROR-level record identifying only a validated rule ID or controlled error code; reject the bad configuration rather than silently run unprotected. Rule IDs must be sanitized/bounded before any log use.
- **Tool execution, after substitution and before inspection/model use:** when at least one value was replaced, emit **one metadata-only redaction record per tool result** using the existing audit/trace integration, not both an application-log duplicate and an OTel duplicate. Fields: controlled tool identifier, result/error kind, total match count, matched rule IDs (with counts per ID), and a boolean redaction indicator (`gen_ai.tool.pii_redacted` if validated against the deployed semantic-convention schema; otherwise a documented product-namespaced attribute). The event records counts of matches, not numbers of unique values. For Classic concurrent results emit one record per result that is actually processed; preserve existing inspection-round failure rules. For Agentic emit after interception even if subsequent inspection rejects the result, without publishing its payload. Never put raw results, matching substrings, matched-value hashes, replacement contents, result snippets, or unsanitized tool names in these records.
- **No matches:** emit no per-result redaction log or event; ordinary existing tool spans and monitoring continue unchanged. Do not log the entire redacted input at DEBUG: a result with zero matches is identical to the raw input, and a result with partial matches still contains unprotected content.
- **Unexpected redaction failure:** fail closed before classifier or model dispatch; emit one payload-free ERROR with controlled failure code and tool correlation and propagate a safe failure to the caller. Do not fall back to forwarding the raw result or record raw exception text if it may include the payload. Startup/configuration errors and runtime failures must have separate reason codes.
- **Existing evidence boundary:** this metadata policy does **not** change full-fidelity source audit/trace recording, including sandbox native tool spans that may record raw results before interception. It must not falsely claim that a metadata-only redaction event sanitizes those source records. User-facing Classic SSE is explicitly sanitized by this design; its previous raw SSE contract must be amended. Keep any proposal to redact source audit evidence in a separate explicitly approved scope change, aligned with `.ai/spec/decisions/0026-audit-logging-design.md` and `.ai/spec/what/audit-logging.md`.
- **Tests:** assert exactly one safe event on a result with matches, no event for zero matches, one state record per policy load/change, safe behavior on invalid config/runtime failure, no payload in new logs at any level, no duplicate audit emission, and clear separation between raw source evidence and redacted model-visible content.

## Spec placement and ownership

- Parent `.ai/spec/what/tool-output-redaction.md`: canonical behavior, boundaries, rule set, integration contracts, verification expectations and explicit planned status; add README and repo-map entries.
- Classic `lightspeed-service/.ai/spec/what/tools.md`, `security.md`, and configuration/observability specs: local tool hook, existing query redaction distinction, config and audit/SSE boundaries.
- Agentic `lightspeed-agentic-sandbox/.ai/spec/what/provider-contract.md`, `configuration.md`, `audit-logging.md`: middleware, provider-route coverage, handoff and span boundaries.
- `lightspeed-operator` and `lightspeed-agentic-operator` child specs: CRD shape, reconciliation and config handoff; parent audit-logging and inspection specs: only narrowly scoped cross-references where needed. Record an ADR if the final policy/config ownership choice materially constrains future work.

## Remaining builder decisions

Specify the concrete safe default regex alternatives and corpus, benchmark input sizes and latency limits, how admin rule removals are represented across two configuration surfaces, the exact Classic SSE/history/structured-content serialization and Agentic per-reply UI handoff, and how the proposed redaction attribute fits the existing OTel schema. Preserve current full-fidelity audit behavior unless separately approved to change it.
