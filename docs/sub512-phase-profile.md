# Sub-512 Phase Profile

## Result

The sub-512 cold path already uses a zero-build locality hint: `locateNode`
starts from `front.searchNode`, walks both directions, and writes the located
node back. The phase profile confirms that locate is not the bottleneck on small
fixtures.

| Fixture | Points | Best us/run | Locate | Point | Fill | Legalize | Edge | Setup | Sort | Unattr |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| small-ui-quad | 4 | 0.54 | 5.0% | 12.4% | 9.8% | 12.1% | 7.0% | 6.6% | 1.9% | 43.2% |
| fixture-test | 6 | 1.17 | 4.9% | 12.5% | 6.3% | 22.9% | 9.5% | 4.9% | 1.2% | 36.5% |
| diamond | 10 | 1.58 | 5.7% | 13.9% | 7.6% | 18.2% | 11.7% | 3.6% | 1.0% | 37.1% |
| star | 10 | 1.42 | 5.8% | 14.7% | 10.9% | 17.0% | 6.7% | 3.9% | 1.1% | 38.8% |
| medium-icon | 48 | 9.50 | 4.9% | 12.0% | 8.5% | 37.6% | 5.1% | 2.0% | 1.5% | 27.4% |
| dude-with-holes | 104 | 19.46 | 5.2% | 12.8% | 11.9% | 29.3% | 6.6% | 2.1% | 1.9% | 28.9% |
| large-shape | 512 | 109.75 | 4.8% | 11.5% | 13.0% | 35.3% | 4.7% | 1.8% | 2.5% | 25.1% |
| stress-small | 532 | 131.29 | 4.2% | 10.0% | 9.0% | 39.9% | 9.5% | 1.8% | 2.6% | 21.8% |

`unattr` includes the profiler's own enter/exit overhead and any work outside
the marked engine phases. It is expected to be large on tiny fixtures because
timer overhead is a meaningful fraction of sub-microsecond runs.

## Decision: Closed

Do not add a second finger/search hint for sub-512 polygons. The existing
`searchNode` write-back is already that mechanism, and locate is only about
4-6% of measured small-fixture time.

Setup/sort are also small in the steady-state workspace-reuse path measured
here, so the cheap structural win is already captured. The named dominant phase
is legalize, followed by point/fill work. The legalize cost is not currently a
cheap optimization target: the follow-up in-circle diagnostic shows intrinsic
Delaunay flip/predicate work rather than redundant re-testing.

Sub-512 is considered optimized for the current fixture set. The remaining
possible legalize changes are correctness-sensitive and low expected value, so
they are not pursued.

## In-Circle Diagnostic

`benchIncircleProfile` checks whether legalize is doing many redundant in-circle
predicate evaluations. The answer is no on the main small/near-threshold cases:
tests per successful legalize flip stay low, and every skipped legalize edge is
classified by a concrete guard.

| Fixture | Tests/pt | Tests/success | Success % | Nil nbr | Skip delaunay | Skip constrained |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| medium-icon | 2.30 | 2.35 | 42.59% | 34.06% | 26.57% | 11.59% |
| dude-with-holes | 2.87 | 5.92 | 16.89% | 39.04% | 12.89% | 12.17% |
| large-shape | 2.27 | 2.36 | 42.45% | 34.80% | 24.94% | 12.21% |
| stress-small | 4.06 | 3.69 | 27.12% | 29.19% | 23.11% | 14.52% |

The tuned unsafe generated C for the arena `legalize` loop has no bounds checks
or `raiseIndexError` paths in the hot body. That rules out the cheap
bounds-check win. With low tests/success and no unclassified skip bucket, the
remaining legalize cost appears to be intrinsic flip/predicate work rather than
obvious redundant re-testing.

The in-circle predicate itself is already a plain floating-point computation,
not exact-always adaptive arithmetic. Adding a filtered predicate would add
branching and robustness risk with little expected payoff because these fixtures
only run about 2.3-4.1 in-circle tests per point.

## Future Work

Only reopen this if a future workload makes legalize the dominant end-to-end
cost at a scale that matters. The next investigation would be structural:
insertion-order effects on flip count, batched/deferred legalization, or other
algorithm-level changes. Those are research-scale changes, not a sub-512 tuning
task.

## Repro

Run:

```sh
nimble benchPhaseProfile
```

The task builds the champion arena raw path with `-d:p2tPhaseProf`, warms a
reused workspace once per fixture, and reports exclusive phase percentages.

For in-circle work ratios, run:

```sh
nimble benchIncircleProfile
```
