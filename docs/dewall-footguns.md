# DeWall Footguns

This document tracks the current performance risks in the experimental DeWall
DT backend. The goal is to work down this list without changing the topology
contract: DeWall owns raw DT construction, and later CDT work consumes that DT.

## Current Findings

| # | Finding | Status | Next action |
| ---: | --- | --- | --- |
| 1 | Final production dedupe is probably wasted. `profileDewallPrewall` has reported `dups=0` on heron, 10k, 50k, and 100k fixtures. | In progress | Remove dedupe from release triangulation paths; keep profile duplicate counting. |
| 2 | General-purpose hash tables dominate hot wall operations. `wall`, `afl1`, and `afl2` remain `Table` based. | In progress | `closed` and `localSeen` now use `HashSet`; replace active face lists with purpose-built dense/open-addressed edge storage next. |
| 3 | Split side routing used `Table[int,int]` despite dense point ids. | Done | Routing now uses coordinate cuts directly and allocates dense side markers only for tied median splits. |
| 4 | Recursive splits used to fully sort each subproblem. | Done | Commit `50b98af` replaced full sort with median partitioning. `splitSorts` now means split partition calls. |
| 5 | Grid storage allocates many small buckets with `seq[seq[int]]`. | Open | Move to flat bucket storage. |
| 6 | Expanding grid scans revisit many marked cells. | Open | Scan newly added rings/ranges instead of rewalking full boxes. |
| 7 | Brute fallback remains frequent. | Open | Tune grid thresholds and add a small-leaf strategy after grid storage is cleaner. |
| 8 | Candidate geometry does repeated floating-point-heavy work. | Open | Fuse circumcenter/radius/orientation calculations in `considerCandidate`. |
| 9 | Parallel leaf output allocates and copies per leaf. | Open | Replace per-leaf returned seqs with preallocated or append-only result buffers if allocation remains visible. |
| 10 | Triangle prepared DT timing is suspicious. | In progress | Prefer `triangle-full-dt` as the fair reference until prepared-mode mutation/noise is resolved. |

## Validation Rules

- DeWall output must remain identical as a canonical triangle set across serial,
  threaded recursive, fixed prewall, and auto prewall modes.
- Profile duplicate counting must continue to report whether structural
  ownership leaks; production triangulation should not pay for dedupe unless a
  test exposes duplicates.
- Compare DeWall raw DT against Triangle `zQ` raw DT; do not use Triangle
  `-q30` quality refinement for raw DT timing comparisons.

## Repro Tasks

- `nimble testDewall`
- `nimble testDewallHotStats`
- `nimble benchDewallTriangleDtCompare`
- `nimble benchDewallHotStats`
