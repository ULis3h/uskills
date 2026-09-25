# cpp-style eval results

## Iteration 1 (2026-09-25)

Setup: the three prompts in `evals.json`, each run once by an independent
subagent with the skill and once without it (same model, same sandbox,
Abseil/GoogleTest not installed so nothing was compiled). Each output was
graded by a separate subagent against the objective assertions in
`evals.json`, without knowing which configuration produced it.

| Eval | With skill | Without skill |
|---|---|---|
| 1 config loader | 14/14 | 13/14 |
| 2 retry helper | 14/14 | 13/14 |
| 3 legacy refactor | 14/15 | 13/15 |
| **Pass rate** | **98%** | **91%** |
| Tokens per run (mean) | 96k | 56k |
| Wall time per run (mean) | 280 s | 141 s |

### What the skill changed

- **Test assertion style** was the one fully discriminating assertion: all
  three baseline runs asserted status outcomes with `ASSERT_TRUE(s.ok())`
  and `EXPECT_EQ(s.code(), ...)`; all three skill runs used
  `StatusIs` / `IsOkAndHolds` / `IsOk` matchers.
- **Header documentation**: skill runs documented lifetimes and
  thread-safety on every public symbol and included a usage example; the
  one skill failure (eval 3) was an undocumented option struct. Baseline
  runs documented functions but left structs bare (eval 3 failed the same
  assertion).
- **Call-site design** (not captured by an assertion, visible in the
  outputs): the skill's retry helper is called as
  `Retry(op, {.max_attempts = 5})`; the baseline requires
  `Retry<Response>(policy, op)` and stores a `std::function` in the options
  struct. The skill's refactor introduced an `enum class ReportDetail` and
  `std::optional<int> max_regions`; the baseline kept a `bool detailed`
  inside an options struct (which the assertion accepts).
- **Cost**: the skill runs used about 1.7x the tokens and 2x the wall
  time, mostly spent reading the references and iterating on the code.

### What did not change

Most assertions passed in both configurations: the baseline model already
returns `StatusOr`, takes `string_view`, avoids `new`/`delete` and
`using namespace`, and names tests by behavior. The skill's value is at the
margins that reviewers actually argue about (matchers, documentation,
call-site shape, option types), not in gross violations.

### Known weaknesses of this eval set

- Nothing was compiled or run. A sandbox with Abseil and GoogleTest would
  allow "builds with `-Werror`" and "tests pass" assertions, which matter
  more than any style assertion.
- Eval 3 has no assertion for behavior preservation. Both runs silently
  changed tie ordering for equal totals (legacy sort was unstable); a
  grader caught it by compiling the legacy code, the assertions did not.
- The `string_view` assertion is vacuous for evals 2 and 3 (no string
  parameters exist).
- One run per configuration: the ±4% is across evals, not across
  repeated runs of the same eval.

### Next steps

1. Install Abseil and GoogleTest in the eval sandbox and add build/test
   assertions.
2. Add a behavior-preservation assertion (golden output from the legacy
   code) to eval 3, and "does not sleep after the final failure" to eval 2.
3. Run 3 repetitions per configuration before drawing conclusions about
   small deltas.
