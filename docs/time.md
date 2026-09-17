# Time

Current behavior of `Hetoimasia.Foundation.Time`: monotonic instants,
non-negative durations, validated construction, deadline arithmetic, and
elapsed-time sampling. The accepted policy lives in
[the runtime scheduling design](runtime_scheduling_design.md) (P-1, D-1, and
D-3); this document describes what the code does today.

Scope: the values, the arithmetic over them, the injected clock, and how a
clock failure is reported. Update policy, including capping a long sample,
turning elapsed time into steps, and pausing, belongs to the runtime. Converting
a duration into a native timed wait belongs to GLFW. The runtime's update
policy is described in [scheduling](scheduling.md); native wait conversion does
not exist yet, and nothing in the owner loop, the command path, or the logging
clock uses this module today.

The module owns no state, imports no runtime, GLFW, or wall-clock module, and
chooses no simulation rate. It takes the validated `Component` from
[the logging module](logging.md) and reports failures through
[the failure module](failures.md); it needs no logger.

## Ownership

| Owner      | Owns                                                                                   |
| ---------- | -------------------------------------------------------------------------------------- |
| Foundation | `MonotonicSource`, `Instant`, `Duration`, validation, deadline arithmetic, sampling    |
| Runtime    | Update policy: elapsed caps, step budgets, remainders, discarded time, pause and resume |
| GLFW       | Converting a `Duration` into a native wait                                             |

## Public interface

```haskell
data Duration                       -- Eq, Ord, Show
durationNanoseconds     ∷ Duration → Natural
zeroDuration            ∷ Duration
minimumPositiveDuration ∷ Duration  -- 1 ns
maximumDuration         ∷ Duration  -- 2^64 - 1 ns

data DurationRequirement = AllowZero | RequirePositive
data DurationRejected
  = DurationNegative | DurationZero | DurationNotFinite
  | DurationBelowResolution | DurationAboveMaximum

durationFromNanoseconds ∷ DurationRequirement → Integer → Either DurationRejected Duration

data SecondsConversion = SecondsConversion
  { convertedDuration ∷ Duration, convertedRounding ∷ Rational }
durationFromSeconds ∷ DurationRequirement → Double → Either DurationRejected SecondsConversion

data Instant                        -- Eq, Ord, Show
scriptedInstant ∷ Duration → Instant

data TimeOverflow = TimeOverflow
addDuration     ∷ Instant → Duration → Either TimeOverflow Instant
addDurations    ∷ Duration → Duration → Either TimeOverflow Duration
elapsedBetween  ∷ Instant → Instant → Duration   -- earlier, later
remainingUntil  ∷ Instant → Instant → Duration   -- now, deadline
deadlineReached ∷ Instant → Instant → Bool       -- now, deadline

data MonotonicSource
monotonicSource    ∷ MonotonicSource
scriptedSource     ∷ IO Instant → MonotonicSource
readInstant        ∷ HasCallStack ⇒ MonotonicSource → IO Instant
timeComponent      ∷ Component   -- foundation.time
readClockOperation ∷ Operation   -- read-monotonic-clock

data ElapsedBaseline                -- Eq, Show
noBaseline      ∷ ElapsedBaseline
baselineInstant ∷ ElapsedBaseline → Maybe Instant
advanceBaseline ∷ Instant → ElapsedBaseline → (Duration, ElapsedBaseline)
sampleElapsed   ∷ HasCallStack ⇒ MonotonicSource → ElapsedBaseline → IO (Duration, ElapsedBaseline)
```

`Instant`, `Duration`, `ElapsedBaseline`, and `MonotonicSource` are abstract.
No constructor is exported, so a client cannot name one, coerce a number or a
wall-clock value such as a C `time_t` into one, or write a numeric literal as
one. There is no `Num`, `Read`, `UTCTime`, or serializable representation.
`Show` is diagnostic output, not a save format.

## Units and range

Both values are whole nanoseconds in an unsigned 64-bit integer, so neither can
be negative. The smallest positive duration is one nanosecond; the largest
duration or instant is `2^64 - 1` nanoseconds, about 584 years. An instant is a
point in its clock domain, not a wall-clock or calendar timestamp, and is never
a portable value to write into a save file.

## Validated construction

Every duration built from caller input states what it requires:

- `AllowZero` for an elapsed duration or a remainder, which may be zero.
- `RequirePositive` for a configured period, cap, or timed wait, which must be
  finite and strictly positive.

A refused input is reported as a `DurationRejected` reason; it is never clamped.

| Input                                          | Result                    |
| ---------------------------------------------- | ------------------------- |
| Negative                                       | `DurationNegative`        |
| Zero with `RequirePositive`                    | `DurationZero`            |
| NaN or an infinity                             | `DurationNotFinite`       |
| Positive, but rounds to zero nanoseconds       | `DurationBelowResolution` |
| Above `maximumDuration` after rounding         | `DurationAboveMaximum`    |

`durationFromNanoseconds` is exact. `durationFromSeconds` converts the `Double`
exactly and then rounds to the nearest nanosecond, ties to even. It never loses
precision silently: `convertedRounding` is the returned duration minus the exact
input, in nanoseconds, at most one half in magnitude. `0.1` seconds, for
example, becomes 100,000,000 ns with a small non-zero rounding, because `0.1`
has no exact binary representation. A positive input that would round to zero
is rejected under either requirement, so a positive configuration is never
accepted as zero. Negative zero is zero.

## Arithmetic

`addDuration` and `addDurations` return `TimeOverflow` when the result does not
fit. Nothing wraps, saturates, or truncates.

`elapsedBetween earlier later` is the time from `earlier` to `later`, and zero
when `later` is not after `earlier`. `remainingUntil now deadline` is the time
left before `deadline`, and zero once it has been reached; `deadlineReached`
holds from the deadline onward. These zeros are the specified meaning of a
repeated or backward sample and of an expired deadline, not an overflow
response. Deadlines are ordered with `Instant`'s `Ord` instance, so `min` picks
the earlier of two.

## Clock domains

Comparing, subtracting, or sampling instants is meaningful only within one clock
domain. The types do not distinguish domains; keeping them apart is the
caller's obligation.

- `monotonicSource` reads the process's monotonic clock
  (`GHC.Clock.getMonotonicTimeNSec`). Every use shares that clock's epoch, which
  no source resets, so instants from independently obtained production sources
  are comparable.
- `scriptedSource` returns whatever its action returns, for tests. Its domain
  is the one the script defines: instants built with `scriptedInstant` as
  offsets from the script's own origin. A script may repeat, move backwards, or
  fail. Its instants are never comparable with production instants.

## Elapsed sampling

`advanceBaseline` is the pure rule; `sampleElapsed` reads a source and applies
it. The caller owns the `ElapsedBaseline` and threads it from one sample to the
next.

| Sample, compared with the stored instant | Elapsed          | Stored instant afterwards |
| ---------------------------------------- | ---------------- | ------------------------- |
| First sample (no baseline)               | zero             | the sample                |
| Equal                                    | zero             | the sample                |
| Earlier                                  | zero             | the sample                |
| Later                                    | full difference  | the sample                |

The stored instant is always the latest raw sample. A backward sample
contributes nothing and replaces the baseline, so no time is replayed later. A
long forward jump is reported in full and uncapped; capping it is update policy.
Because the stored instant then moves to that sample, the next sample measures
only the interval since it, and a suspended interval is never charged twice.

## Clock failure

`readInstant`, and therefore `sampleElapsed`, attributes a failure of the source
through [the failure module](failures.md):

- A synchronous failure keeps its own type, payload, and every annotation it
  already carried. If it carried no engine origin, it gains one naming
  `foundation.time` and `read-monotonic-clock`, attributed to the caller's site;
  if it already had one, that earlier origin stays the origin. In both cases it
  gains an operation context naming the same component and operation.
- The reading is evaluated before it is returned, so a faulting reading fails
  inside this attribution.
- No instant is returned or fabricated, and a failed `sampleElapsed` returns no
  new baseline; the caller still holds the previous one.
- Cancellation stays cancellation: an asynchronous exception, delivered or
  thrown synchronously, propagates with nothing added.

## Verification

The `Time` group of `foundation-tests` covers these contracts with scripted
sources that assert exact values and never sleep, one ordering check over the
process's monotonic clock, and external clients compiled against the built
package:

```bash
cabal test hetoimasia-foundation:foundation-tests --test-show-details=direct \
  --test-options='--match /Time/'
```

It covers first, repeated, and backward samples; zero and maximum-boundary
arithmetic; a long forward jump reported in full; expired and future deadlines;
each rejection reason; seconds rounding and its range boundaries; native and
already-annotated source failures; and cancellation. Its opacity examples reject
naming each constructor, coercing a nanosecond count or a C `time_t` into a
value, and a numeric literal, and link and run a client that uses the public
API. The group initializes no GLFW and needs no display.
