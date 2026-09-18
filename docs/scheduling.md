# Scheduling

Current behavior of `Hetoimasia.Runtime.UpdatePolicy`: demand deadlines,
bounded variable-step elapsed time, fixed steps with bounded catch-up, and
explicit pause and resume. The accepted policy lives in
[the runtime scheduling design](runtime_scheduling_design.md) (P-2, D-1, and
D-2); this document describes what the code does today.

Scope: pure policy over the [time values](time.md) the foundation supplies.
The policy owns no rendering decision: it does not decide when a frame is
drawn, and it composes no per-window render demand. Window visibility is not a
pause; hiding or minimizing a window never invokes pause or resume. Converting
a demand into a native wait belongs to GLFW, and so does composing a `Demand`
with per-window demand: GLFW's [render demand
helper](glfw.md#render-demand) takes the `Demand` this module produces,
weighs it against each window's observed eligibility and its own dirtiness and
frame deadline, and answers the schedule GLFW's [scheduled owner
turn](glfw.md#the-scheduled-owner-turn) waits on. That helper's worked
composition is the reference for driving owner turns from this module. Nothing
in the command path, supervision, or the console executable uses this module
today.

The module imports only `base` and `Hetoimasia.Foundation.Time`. It reads no
clock, sleeps, starts no thread, holds no global, and needs no logger.

## Ownership and state

| Value             | Owner  | Lifetime                                  | Reset                              |
| ----------------- | ------ | ----------------------------------------- | ---------------------------------- |
| `Demand`          | Caller | Whatever the consumer returns each turn   | Replaced by the next value         |
| `FixedStepPolicy` | Caller | Threaded from one turn's result to the next | `pauseFixedStep`/`resumeFixedStep` |
| `ElapsedBaseline` | Caller | Threaded from one sample to the next      | `resumeBaseline` on resume         |

Every value is immutable. The caller samples its own `MonotonicSource`, passes
the sample instant and elapsed duration in, and keeps the returned policy.

## Public interface

```haskell
data Demand = NoDemand | ImmediateDemand | DeadlineDemand Instant
removeDeadline  ∷ Demand → Demand
data DemandQuery = NotDemanded | DemandDue | DemandPending Duration
queryDemand     ∷ Instant → Demand → DemandQuery          -- now, demand
demandRemaining ∷ Instant → Demand → Maybe Duration       -- now, demand

data PolicyRejected
  = StepDurationNotPositive | ElapsedCapNotPositive | StepBudgetNotPositive

data VariableStepConfig                                   -- abstract
variableStepConfig     ∷ Duration → Either PolicyRejected VariableStepConfig
variableStepElapsedCap ∷ VariableStepConfig → Duration

data FixedStepConfig                                      -- abstract
fixedStepConfig     ∷ Duration → Duration → Int → Either PolicyRejected FixedStepConfig
fixedStepDuration   ∷ FixedStepConfig → Duration
fixedStepElapsedCap ∷ FixedStepConfig → Duration
fixedStepBudget     ∷ FixedStepConfig → Int

data VariableStep = VariableStep { deliveredElapsed, clippedElapsed ∷ Duration }
boundElapsed ∷ VariableStepConfig → Duration → VariableStep

data FixedStepPolicy                                      -- abstract
fixedStepPolicy       ∷ FixedStepConfig → FixedStepPolicy
fixedStepPolicyConfig ∷ FixedStepPolicy → FixedStepConfig
fixedStepRemainder    ∷ FixedStepPolicy → Duration
data FixedStepTurn = FixedStepTurn
  { stepsToRun        ∷ Int
  , retainedRemainder ∷ Duration
  , clippedTime       ∷ Duration
  , droppedStepTime   ∷ Duration
  , discardedTime     ∷ Duration
  , nextStepDue       ∷ Either TimeOverflow Instant
  }
advanceFixedStep      ∷ Instant → Duration → FixedStepPolicy → (FixedStepTurn, FixedStepPolicy)
interpolationFraction ∷ FixedStepPolicy → Rational

data PausedFixedStep                                      -- abstract
pauseFixedStep  ∷ FixedStepPolicy → PausedFixedStep
resumeFixedStep ∷ Instant → PausedFixedStep → (FixedStepPolicy, ElapsedBaseline)
resumeBaseline  ∷ Instant → ElapsedBaseline
```

The configurations and policies export no constructor or record selector, so a
caller cannot build or update one past validation.

## Demand

An event-driven consumer has no periodic deadline and returns `NoDemand`. A
deadline consumer returns `ImmediateDemand` or an absolute `DeadlineDemand`.

| Demand at `now`                  | `queryDemand`                | `demandRemaining` |
| -------------------------------- | ---------------------------- | ----------------- |
| `NoDemand`                       | `NotDemanded`                | `Nothing`         |
| `ImmediateDemand`                | `DemandDue`                  | `Just` zero       |
| `DeadlineDemand d`, `d <= now`   | `DemandDue`                  | `Just` zero       |
| `DeadlineDemand d`, `d > now`    | `DemandPending` (positive)   | `Just` the time left |

An expired deadline is due; it is never reported as pending with a zero or
negative wait. The zero `demandRemaining` returns once a demand is due is query
evidence, not a native wait instruction. `removeDeadline` turns a deadline into
`NoDemand` and leaves other demand unchanged. A consumer that returns
`ImmediateDemand` every turn has explicitly chosen a busy loop.

## Configuration

Every duration and budget must be strictly positive. A refused value is
reported before any policy exists, so a loop never starts with an invalid
configuration. `fixedStepConfig` checks the step, then the cap, then the budget,
and reports the first refusal.

| Input                        | Result                    |
| ---------------------------- | ------------------------- |
| Zero step duration           | `StepDurationNotPositive` |
| Zero elapsed cap             | `ElapsedCapNotPositive`   |
| Zero or negative step budget | `StepBudgetNotPositive`   |

A `Duration` cannot be negative, so zero is the only refused duration.

## Variable step

`boundElapsed` hands the consumer at most the cap and reports the rest:
`deliveredElapsed + clippedElapsed` is exactly the raw sample below, at, and
above the cap. A long pause is visible as clipped time rather than delivered.

## Fixed step

For one raw elapsed sample taken at instant `t`:

1. The accepted elapsed time is the sample capped at the elapsed cap; the rest
   is `clippedTime`.
2. The accepted time is added to the retained remainder.
3. The whole steps it contains run, up to the budget (`stepsToRun`).
4. Whole steps beyond the budget are dropped (`droppedStepTime`).
5. Only the sub-step remainder is kept (`retainedRemainder`, less than a step).
6. `discardedTime` is clipped plus dropped time, each counted once.
7. `nextStepDue` is `t + step - retainedRemainder`.

In nanoseconds, for every input:

```text
old remainder + raw elapsed = stepsToRun × step + retainedRemainder + discardedTime
```

The arithmetic runs on unbounded naturals, so no intermediate sum wraps, and
every reported duration is representable. Only `nextStepDue` can fail to fit,
near the end of the clock's range, and it then reports `TimeOverflow`. No
replay queue grows with an interruption.

Worked example: a 4 ms remainder, 85 ms elapsed, a 70 ms cap, 10 ms steps, and
a three-step budget. 15 ms is clipped; 74 ms holds seven whole steps; three run
(30 ms), four are dropped (40 ms), 4 ms is retained, 55 ms is discarded, and the
next step is due 6 ms after the sample.

The next step is absolute. Time the caller spends executing the steps consumes
the interval to it rather than resetting it: if those three steps take 4 ms, a
`DeadlineDemand` on it is pending with 2 ms left, and once they take 6 ms or
more it is due.

`interpolationFraction` is the retained remainder divided by the step, as an
exact `Rational` in `[0,1)`. Converting it to floating point is the caller's
choice and may round a value just below one up to one.

## Pause, resume, and rate changes

`pauseFixedStep` discards the remainder as outstanding debt and returns a
policy that cannot be advanced. `resumeFixedStep r` returns a policy with no
remainder and the elapsed baseline `resumeBaseline r`, stored at the resume
instant. Sampling from that baseline at `r + d` contributes only `d`: neither
the paused interval nor the pre-pause remainder is simulated. The caller
composes this with its own sampler by replacing the baseline it holds.

These are the only operations that clear a remainder. Advancing by zero elapsed
time keeps it.

There is no in-place reconfiguration. A different rate or budget is a new
`FixedStepConfig` and a new `fixedStepPolicy`, which starts from no remainder,
so an existing remainder is never reinterpreted under a new step.

## Verification

The `Update policy` subgroup of `runtime-tests` covers these contracts with
scripted instants and a scripted source, asserting exact values without
sleeping:

```bash
cabal test hetoimasia-runtime:runtime-tests --test-show-details=direct \
  --test-options='--match "Update policy"'
```

It covers each configuration rejection; zero elapsed; exactly one step; a
fraction of a step; a long jump that both clips and drops steps; the worked
example; accounting over a sequence of samples and at the limits of the
representation; an overflowing next-step instant; querying the next step after
work has consumed or exceeded its interval; interpolation at zero and just
below one; variable-step delivery below, at, and above the cap; expired,
future, and removed deadlines; pause and resume composed with the elapsed
sampler; and immediate demand returned continuously.
