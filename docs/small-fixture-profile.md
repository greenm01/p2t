# Closing the dude-with-holes gap: seq container thrash

Positive result. The remaining single-threaded deficit vs `fast-poly2tri` was
**not** in the geometry kernels — it was Nim `seq` bookkeeping. Per-iteration
`setLen(0)` + regrow on scratch/output buffers zero-filled `triangles.len`
pointer slots on every triangulation, work the reference avoids by carrying flat
preallocated pools across calls. Removing the thrash took dude-with-holes from a
robust **+8..+11%** behind to **+2%**, and turned diamond/star (previously
behind/even) into **6-12% wins**.

This supersedes the "dude is ~+3%, inside the noise band" claim in
`tier2-profile.md`: that figure came from non-interleaved back-to-back runs. With
randomized-order interleaved global-min (see *Methodology* below) the pre-fix
deficit was reproducibly +8..+11% on both the double and float paths.

## How it was found

`sample` self-time on a dude-only 200k-loop harness (`bench/bench_dude_only.nim`),
built **without `-flto`** so the per-phase procs stay distinct symbols instead of
collapsing into one inlined `triangulateCdtRaw`. The flat top-of-stack table
exposed pure container overhead that the LTO build hides:

| symbol (pre-fix)                       | samples | ~%  |
|----------------------------------------|--------:|----:|
| `legalize`                             |     181 | 18.7|
| `mergeSortActivePoints::sortRange`     |     106 | 11.0|
| `sweepPoints`                          |      88 |  9.1|
| `fillAdvancingFront`                   |      78 |  8.0|
| **`setLen(seq[ptr ArenaTriangle])`**   |  **48** |**5.0**|
| `meshClean`                            |      42 |  4.3|
| `fill`                                 |      41 |  4.2|
| `fillBasin`                            |      38 |  3.9|
| `rotateTrianglePairIndexed`            |      34 |  3.5|
| **`add(seq[ptr ArenaPoint])`**         |  **19** |**2.0**|
| **`setLen(seq[ptr ArenaPoint])`**      |  **16** |**1.6**|

`setLen` + `add` summed to **83 samples (~8.5%)** of pure memory-management
overhead. The single biggest non-algorithmic cost — `setLen(seq[ptr
ArenaTriangle])` at 5% — was the scratch DFS stack and the interior-triangle
output buffer being shrunk to 0 each reset and re-grown (zero-filling N pointer
slots) inside `meshClean` every call.

## The fixes

Three buffers in `ArenaWorkspace` are scratch/output owned entirely by their
producer and fully overwritten each use, so resetting their length is wasted
work. Each was changed to keep its grown capacity across workspace reuse and grow
at most once:

1. **`meshStack`** (commit `7bc0bf1`) — scratch DFS stack in `meshClean`, drives
   the walk via `stackCount` and overwrites `[0]`. Dropped both `setLen(0)`
   calls (workspace reset + end of `meshClean`). The existing bounds-grow check
   at the top of `meshClean` still handles inputs that need a deeper stack.

2. **`interiorTriangles`** (commit `8dd9f14`) — the interior-triangle output
   buffer. Was reset to 0, grown to `triangles.len`, then shrunk to
   `rawInteriorCount` every call. Now left at grown capacity; `rawInteriorCount`
   is the authoritative count. The raw path already used `rawInteriorCount` +
   indexed access; the non-raw `triangulateCdt` consumer was changed to iterate
   `0 ..< rawInteriorCount` instead of the seq length.

3. **`sortTemp`** (commit `c197f33`) — merge-sort scratch. Same transform.
   Measured **noise-level** on these fixtures (it was only ~1.3% of self-time and
   regrowing from 0 to a small `activePoints.len` is cheap), but it strictly
   removes a redundant `setLen(0)`+regrow and matters more under heavy reuse.

A fourth change shipped alongside in `legalize` (commit `65f1b2b`): resolve the
opposite apex with a 3-compare `pointCW(pcw)` instead of the 4-compare
`oppositePointAcross(pccw, pcw)`, and defer computing `p`/`pccw` until after the
constrained/Delaunay early-out so they are skipped when the shared edge bails.
Mirrors `MPE_PolyLegalize`. Consistent ~1% across fixtures.

## Result

Latest master vs `fast-poly2tri` (double, fast-float), randomized-order
global-min over 30 runs, both reading fixtures from the repo root:

| fixture          | ours/ref | before this work |
|------------------|---------:|-----------------:|
| diamond          |   -6.2%  | +3..+6% (behind) |
| star             |  -11.5%  | ~even            |
| dude-with-holes  |   +2.1%  | +8..+11% (behind)|
| nazca-monkey     |   -5.5%  | -5.3%            |
| nazca-heron      |  -12.4%  | -6.4%            |

The `setLen(seq[ptr ArenaTriangle])` symbol is now **gone** from the profile; the
remaining `seq[ptr ArenaPoint]` container cost dropped from 83 to ~26 samples.
dude's residual +2.1% is now distributed across the geometry kernels (`legalize`
~18%, fill family ~22%, `sweepPoints` ~9%, `locateNode` ~5%) which match the
reference structurally — diminishing returns from here.

## Closing dude: pdqsort replaces the merge sort (commit `66f98c4`)

The "diminishing returns" call above was wrong about one thing: the sort. Earlier
work had concluded our hybrid merge sort was a settled strength — it beat
poly2tri's merge and a naive recursive quicksort (`-d:p2tQuickSort`, which lost
because it had no insertion base and recursed to size 1) in an isolated
microbench. That conclusion did not test a *good* quicksort.

Swapping in **pdqsort** (pattern-defeating quicksort, Orson Peters' algorithm,
vendored from `~/dev/fastsort-nim`) as the default `sortActivePoints` won on
**every** fixture, randomized-order 40-run global-min, two batches:

| fixture          | pdqsort vs merge |
|------------------|-----------------:|
| dude-with-holes  |    -4.0..-4.1%   |
| nazca-monkey     |    -5.3..-6.1%   |
| nazca-heron      |    -2.6..-4.6%   |
| diamond          |    -2.0..-2.3%   |
| star             |    -0.5..-2.6%   |
| large-shape      |    wash          |

**Why it wins is not the comparison count** — pdqsort and our merge both use an
insertion base at 24, and on dude (104 pts) both do divide-and-conquer. The
difference is memory traffic: the merge sort copies each run out to `sortTemp`
and back into `activePoints` on every merge level; pdqsort partitions **in
place**. On these small-to-medium pointer arrays the copy-back dominates.
Stability (merge stable, pdqsort not) is irrelevant: `pointCmp` returns 0 only
for exact-duplicate points, which poly2tri rejects upstream, so no equal keys
ever reach the sort.

This flipped dude from **+2.1% to -2.9%** vs `fast-poly2tri` and widened every
other margin. The engine now beats `fast-poly2tri` (double, fast-float) on the
entire fixture set:

| fixture          | ours/ref (pre-pdq) | ours/ref (pdq) |
|------------------|-------------------:|---------------:|
| diamond          |     -6.2%          |   -5.8%        |
| star             |    -11.5%          |   -9.6%        |
| dude-with-holes  |     +2.1%          |   **-2.9%**    |
| nazca-monkey     |     -5.5%          |   -9.0%        |
| nazca-heron      |    -12.4%          |  -18.9%        |

`skaSort` (LSD radix, also in `fastsort-nim`) was assessed and rejected: it sorts
numeric values, not pointers; our key is a 128-bit lexicographic (y,x) of two
float64s exceeding its 64-bit width; and it only engages at >=256 elements —
fixtures we already win. `-d:p2tMergeSort` / `-d:p2tQuickSort` keep the old
implementations available for A/B.

**Lesson:** "our sort is already fastest" was true only against the alternatives
previously benchmarked. A microbench that omits the strongest candidate proves
nothing about it.


## Methodology (important)

The `legalize` A/B initially showed a clear win, then **flipped sign entirely**
when the two binaries' execution order was swapped — a ~+-1.5..2% position-in-
iteration bias. **Fixed-order interleaving is not enough.** All numbers above use
**randomized order per iteration** (coin-flip which binary runs first) plus
global-min over 40 runs. The reference binaries read fixtures relative to CWD, so
they must be run from the repo root. Machine run-to-run noise is +-3..5%, so only
signals consistent across two independent randomized batches were kept; the
`sortTemp` change failing this bar is why it is documented as noise-level.

## Reproduce

```
# no-LTO per-phase self-time profile of dude only
nim c --mm:arc --threads:off -d:release --opt:speed -d:p2tArenaCdt \
  -d:p2tUnsafeCdt -d:p2tFastRawCdt -d:p2tFrontHash --path:src --panics:on \
  --passC:-mcpu=native --passL:-mcpu=native --debugger:native --passC:-g \
  -o:/tmp/p2t_dude bench/bench_dude_only.nim
( /tmp/p2t_dude >/dev/null & sleep 0.3; sample $(pgrep -n p2t_dude) 3 1 )
# read the "Sort by top of stack" table at the bottom

# A/B must randomize order per iteration and take global-min across >=40 runs.
```
