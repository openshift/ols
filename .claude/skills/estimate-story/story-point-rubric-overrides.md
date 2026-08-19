# Story-Point Rubric — Calibration Overrides (v11)

Validated on ~900 completed OLS stories (blind test-and-fix + out-of-sample holdouts).
**These overrides take precedence over the base `story-point-rubric.md` where they conflict.**
Best measured config: base rubric + these overrides + retrieval neighbors
(see SKILL.md) — 59% exact / 90% within-1 / MAE 0.52 on held-out stories,
vs ~40% for the base rubric alone.

A. **Do not use 0.** The team no longer uses 0. The smallest value is 0.5 (a genuinely tiny
   one-line / one-file change). Anything with real work is 1+.

B. **Low end (1 vs 2): no thumb on the scale.** Decide 1 vs 2 on the normal rules. Do NOT
   round a 1 up to 2 — 1s are already over-called, so avoid inflating them.

C. **2 vs 3: lean UP (reliable correction).** True 3s are routinely under-called as 2. If a
   story shows even ONE clear size signal — touches multiple repos; a new subsystem / service
   / CRD / provider; a real migration / refactor; changes across 3+ surfaces (schema +
   controller + UI); or a multi-concern description — call it **3, not 2**. When genuinely
   torn between 2 and 3, choose **3**.

D. **3 vs 5: lean up only GENTLY.** True 5s are rare (~4%) and hard to tell from 3s in text.
   Assign **5 only when TWO OR MORE independent strong signals** are present (e.g. cross-repo
   AND new subsystem AND multi-surface), or the work is unmistakably architectural /
   epic-scale. When merely torn between 3 and 5 with only one signal, stay at **3** — do not
   reach for 5 without real evidence. (Selectivity beats brute-force rounding: this scored
   higher on true-5s than an aggressive "always round up" rule.)

E. **No 8.** 8 is unused; a story that feels like 8 is a 5 (team practical max) or should be
   split. Never round a large story DOWN to 2-3, but do not assign 8.

## Note on the residual hard cases

Even with the above, actual **5s** (~21% exact) and **8s** (~0%) remain near the text-only
ceiling — they are rare and textually indistinguishable from 3s, and retrieval finds no good
neighbors for them. Do not chase them with more aggressive rules; that only over-calls 2s/3s.
