# Tool-Output Redaction [PLANNED: OLS-3939]

Cross-repository behavioral contract for Classic chat and Agentic runs. This specification describes planned full behavior, **not shipped behavior or a commitment to OLS 2.0**. The later comment on [OLS-3939](https://redhat.atlassian.net/browse/OLS-3939) says PII protection is not an OLS 2.0 requirement and proposes a spike. The full design was requested separately; implementation remains subject to review. See [Classic chat](tool-output-redaction-chat.md) and [Agentic runs](tool-output-redaction-agentic.md) for local boundaries. The [design](../../../docs/superpowers/specs/2026-11-06-OLS-3939-tool-output-redaction-design.md) contains a candidate regex, not a production-validated detector.

## Policy and scope

1. [PLANNED: OLS-3939] Before *any* tool result or tool-generated error is sent to either an inspection classifier or the main model, OLS MUST replace detected sensitive values with visible named placeholders. Tool results MUST NOT be discarded merely because a value was detected. The rule applies to effective model-visible content after existing output limits, including offload previews and subsequent reads. It MUST apply even when prompt-injection inspection is disabled. An inspection failure still fails closed according to [inspection policy](tool-result-inspection.md); redaction never converts an unsafe result into an inspection pass.
2. The same **effective tool-output policy** (category, matching and replacement semantics, precedence, default-on configuration, and conformance cases) MUST hold for Classic and Agentic. The runtimes MAY have separate implementations. Classic's administrator-configured `query_filters` for prompts and attachments are a separate rule set: when absent or empty they match nothing. This change MUST NOT change their defaults or ordering. A shared matching implementation MAY serve both sets only if prompt semantics remain unchanged.
3. Built-in categories are `api_key` (e.g. `sk-`), `github_token` (`ghp_`), `aws_access_key` (`AKIA`), `jwt` (three-part `eyJ`-prefixed candidate), `oauth_token` (bearer token), `credential` (value in a `password=`, `passwd=`, `pwd=`, `api_key=`, `access_token=`, `refresh_token=`, `client_secret=`, or `secret_key=` assignment), `email`, `phone` (plausible separated US or `+`-prefixed international number), and `ssn` (plausible US format). Additional aliases and exact regexes require corpus tests before shipping. Matched **values**, not surrounding text, MUST be replaced with `[REDACTED:<category>]`; retain `Bearer `, the credential key and `=`, and unaffected document structure. The default rules MUST NOT redact standalone IPv4/IPv6 addresses or CIDR ranges. An address appearing as the value of an explicitly credential-named assignment is governed by the credential rule, not an address rule.
4. One compiled, named-alternative effective matcher MUST be created **once per configuration revision** and reused across tool replies; apply one substitution pass to each result. The callback MUST return both sanitized text and metadata from that same pass: `redacted` (whether any replacement occurred), `redacted_count` (number of replacements), and per-category counts. At a given input offset, one alternative wins according to documented precedence; generated placeholders MUST NOT be rescanned. Redaction metadata counts source occurrences once even if a reply has multiple projections. Recompiling per tool call or rescanning to count matches is forbidden. A candidate implementation and its limitations are in the design, not a mandatory untested regex.
5. Operators MUST expose default-on `toolOutputRedaction` configuration in `OLSConfig` and deliver an equivalent validated effective policy to both runtimes. Missing configuration MUST enable the built-in policy; an explicit administrator opt-out MUST be observable. Additions/removals MUST be explicit, have stable category names and deterministic precedence, and reach both runtimes before being considered effective. Reject invalid or unsafe patterns rather than silently disabling redaction or applying a divergent policy. Constrain custom regex complexity and benchmark large benign and adversarial tool results. No MCP Gateway or RHOAI dependency is permitted.
6. Match-only regex protection is **not complete PII detection or certified DLP**. Bare high-entropy values without a recognized prefix or key context, names, addresses, changed token formats, unformatted international numbers and encoded Secrets are not guaranteed to match. No claim of zero false positives or that raw data never leaves the cluster is authorized by this spec. Broader PII detection is separate P1 work.

## Example: one complete tool reply

A single tool returns this synthetic ConfigMap (not ten separate tool calls):

```yaml
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
```

Its **entire** model- and user-visible tool reply after one substitution pass is:

```yaml
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

Here `redacted=true`, `redacted_count=10`, `phone=2`, and each other matched category has count 1. A plain `192.0.2.0/24` yields no regex match; `password=MySecret123!` yields a `credential` match retaining `password=`. The regex itself yields matches, **not** replacement text; the callback produces the placeholder and signal.

## User-visible signal and evidence boundary

7. Every user-visible tool reply MUST carry its sanitized content and a correlated per-reply `redacted: boolean` and `redacted_count: integer` in the same structured result. A reply with no replacements carries `false` and `0`. The UI MUST show a clear "Sensitive values redacted" indicator when true, without revealing original values in a tooltip, copy action, replay, download, structured attachment, or secondary result field. Results rejected by inspection MUST NOT produce a partial reply or misleading redaction signal. See the Classic and Agentic specs for transport differences.
8. New redaction telemetry MUST contain only a controlled tool identifier, result/error kind, total and per-category match counts, and a redaction boolean; never matched values, snippets, hashes, full raw or partially sanitized content, replacement contents, or unvalidated custom rule IDs. Emit one record per processed tool reply with replacements, none for zero matches. Avoid duplicate application-log and OTel audit emission. The proposed `gen_ai.tool.pii_redacted` attribute MUST be validated against the adopted GenAI conventions; otherwise use a documented product-namespaced attribute rather than mislabel it as standard.
9. At policy load/change record one payload-free configuration-state message (enabled status, revision, built-in/custom rule counts). Warn once on explicit disablement. On configuration failure, reject the change with a safe controlled reason; on runtime redaction failure, fail closed before classifier/model/UI exposure and emit one safe error with correlation, not the exception payload. Never log redacted text at DEBUG: zero matches or incomplete matches may leave raw secrets. In particular, remove the current Classic redactor's debug logging of the filter objects and post-redaction input when reusing it.
10. Redaction of model/UI projections does **not** rewrite existing full-fidelity audit/source execution evidence: Agentic native tool spans can record raw successful callback output at completion, and Classic retains raw source audit records. This is an explicit residual exposure governed by [audit policy](audit-logging.md) and [ADR 0026](../decisions/0026-audit-logging-design.md); changing that policy requires separate approval. Classic's existing **raw user-facing SSE** contract, by contrast, MUST change to sanitized content under this feature. New telemetry is never a substitute for handling raw evidence under its existing access controls.

## Conformance

11. Both runtimes MUST run the same fixture corpus for API keys (`sk-`, `ghp_`, `AKIA`), JWTs, bearer/OAuth values, credential assignments, email, US/international phone, SSNs, benign Kubernetes YAML, IP/CIDR ranges, overlapping matches, multiple matches and near-misses. Verify one pass, precompilation once per policy revision, exact placeholders, per-reply counts and absence of input text in new logs. Test tool-generated errors, enabled/disabled inspection, rejection, concurrent calls, size limits, invalid custom rules, safe failure, and user-facing secondary content. For Agentic, test every implemented DeepAgents route; for Classic, test streaming, replay and concurrent-round behavior. These are planned verification requirements, not claims of passing tests.

## Ownership

| Concern | Owner |
| --- | --- |
| Shared categories, defaults, evidence and signal contract | This document (parent `ols/.ai/spec/what/`) |
| Tool execution, Classic SSE, history, query-filter separation | `lightspeed-service`; [chat contract](tool-output-redaction-chat.md) |
| DeepAgents interception, source trace separation, Agentic UI handoff | `lightspeed-agentic-sandbox`, `lightspeed-agentic-operator`, `lightspeed-agentic-console`; [Agentic contract](tool-output-redaction-agentic.md) |
| `OLSConfig` and handoff to Classic and Agentic | `lightspeed-operator` and `lightspeed-agentic-operator` |
| User-facing Classic indicator and sanitized result rendering | `lightspeed-console` |
