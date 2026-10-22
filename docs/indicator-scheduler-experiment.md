# Fixed indicator scheduler experiment

This is a **diagnostic experiment, not a replacement acceptance gate**. It does
not authorize a release or a production scheduling change. Default application
behavior, the default cache fixture's Foundation Timer, all original assertions,
the 3-second indicator budget, the 1.6–2.1-second real observation window, and the
120 ms hover cadence limit remain unchanged. No App Nap activity assertion,
watchdog adjustment, animation time override, forced display or new normal-user
instrumentation is added.

## Why this experiment

Run #83 (`1d22513993b253c328019cd814e80c8d086b7d79`) failed the indicator's
original `native-evidence-bounded` assertion at 3.056904 seconds. Its 18 retained
wake rows locate 6.61–158.32 ms of delay between requested target and Timer callback;
the largest callback-to-awaiter delay was 6.29 ms. They do not identify App Nap,
main-thread occupancy, system load or the source of the earlier hover failure.
The same run's adaptive hover had a 507.22 ms gap, while the strict-dispatch
fallback profile passed its unchanged cadence gate. These observations motivate
a controlled scheduler comparison, not a conclusion about the user's jitter.

## Fixed procedure and scope

The manual `Indicator scheduler diagnostic experiment (not release acceptance)`
workflow builds one native-architecture, ad-hoc-signed app using the unchanged
`build-app.sh --app-only`. It creates no distributable ZIP/DMG and has read-only
repository permissions. The normal full CI workflow is unchanged.

The runner executes exactly:

1. The **unchanged** `check-native-motion.py` gate.
2. A1: complete original cache gate with default Foundation Timer fixture waits.
3. B1: same complete gate, with `--indicator-strict-dispatch-test`.
4. B2: same experimental gate again.
5. A2: same original default gate again.
6. The unchanged hover gate again.

The optional flag is read only after both existing synthetic Music/cache test
mode guards pass. It switches only indicator fixture waits to owned, one-shot,
strict main-queue DispatchSources. Default Timer interval, tolerance zero and
common run-loop mode are preserved. An early wake still rechecks the actual
monotonic target; strict dispatch is best effort, not a real-time guarantee.
Every original cache/indicator assertion and exported PNG hash is validated by
the existing parser, imported without modification. Each cache run has a fresh
working directory, preventing stale PNG evidence. Debug capture is not enabled.

There are no retries, adaptive iteration counts, warm-up exclusions, selective
sample deletion, deadline extensions or success substitutions. Both hover runs
are retained even if the first fails. All four scheduled cache observations are
retained even if an earlier one fails, so an unfavorable result is not hidden.
A process cannot exceed the original cache's 40-second timeout; the unchanged
hover runner retains its 45-second timeout, with a 55-second outer cleanup bound.
The experiment runner keeps at most 2 MiB of combined output per child and kills
only its owned process group on timeout/output overflow. A hard CI kill cannot
guarantee a final receipt; already saved partial results remain artifacts when
artifact upload is able to run.

## Receipts and result interpretation

Each invocation retains stdout, stderr, exit status, timeout/overflow status,
wall duration and log hashes. The summary binds source commit/tree and executable
SHA-256 to embedded build-source metadata. The original indicator receipt still
records complete-cycle presentation samples, all lifecycle assertions and PNG
hashes. The diagnostic wake receipt adds `wakeScheduler` and retains the actual
`target`, `interval`, `armed`, `fired` and `resumed` clocks relative to indicator
start, with sequence/stage, capacity 256 and dropped count. Positive target-to-fire
lateness and callback-to-resume delay are reported separately. The raw logs are
retained; aggregates never replace them.

The only result allowing a **proposal** for a later fixture change is:

- Both A runs fail specifically the original indicator evidence deadline, with
  exact failure/shutdown lines and diagnostic time greater than 3 seconds.
- Both B runs pass **all** original cache checks, including original observation,
  lifecycle, timing and PNG-file checks, without missing/dropped wake evidence.
- Both unchanged hover gates pass.
- Both B runs' maximum and mean positive callback lateness are smaller than both
  A runs' corresponding values. This is descriptive separation, not statistical
  proof or a replacement timing threshold.

The runner reports `supports-fixture-scheduler-followup-only` for that pattern.
**The A failures remain failures**, and `releaseEligible` and `fullCI` remain
false even if the diagnostic job exits zero. It does not establish the user's
field root cause, a production fix, or complete application acceptance.

Every other pattern reports `inconclusive-stop` and exits nonzero. This includes
all A runs passing (no reproduced contrast), either B failing, absent/inconsistent
clocks, any crash, wrong failure, process timeout, output overflow, or either
hover gate failing. Stop after this fixed experiment. Do not keep rerunning,
add further timing instrumentation or change production based on an inconclusive
result. A remaining native scheduling failure requires a separately approved
native performance sample or field evidence, not another speculative patch.

Even a supported pattern requires independent review and new approval before
adopting the alternative fixture scheduler and running full acceptance. No
production behavior or release is changed by this workflow.

## Cost and local validation limits

Expected native experiment time is roughly 2–3 minutes; its step budget is
5 minutes. Native-architecture build has an 8-minute budget; the entire job has a
15-minute budget including evidence upload. Expected total is about 4–8 minutes,
not guaranteed under runner contention. This is intentionally not full CI.

Local Python self-tests check malformed/duplicated clock receipts, wrong
scheduler, missing/dropped/nonfinite clocks, early wakes, exact failure contracts,
wrong ordering, ambiguous ABBA outcomes, failed hover controls, and real owned
subprocess timeout/output bounds. The existing cache parser negative suite also
runs unchanged. Linux-only validation cannot establish Swift compilation,
DispatchSource/macOS scheduling behavior, actual PNG capture or native success.
