# Tier 2 hot-path profile (corridor clearing + SIMD: negative result)

Negative result. Two candidate "Tier 2" levers drawn from `cleave.md` —
single-threaded **corridor-clearing constraint recovery** and **SIMD geometric
predicates** — were both disproven by measurement *before* implementation. The
profile instead redirects Tier 2 to continued constant-factor micro-optimization
(the Tier 1 approach) on the functions that actually dominate runtime. This
documents the spike so the question stays settled and reproducible.

## Why this was investigated

After Tier 1 (`applyRotatedFlags` + `nextFlipTriangle` index reuse, commit
`81d8541`), the only remaining gap vs `fast-poly2tri` (double, fast-float) was
dude-with-holes at roughly +3% (down from +9.1%). The hypothesis from
`cleave.md` was that the dude-with-holes gap is an *algorithmic* cost in the
constraint-recovery edge-flip cascade, recoverable via corridor clearing
(replace O(cascading flips) with O(n) pseudo-polygon retriangulation), and that
the broad legalize cost is recoverable via SIMD `InCircle`.

The agreed plan was measurement-first: size both levers before writing code.
Both measurements contradicted the hypothesis.

## Measurement 1: operation counts (`-d:p2tCdtStats`)

`nimble benchCdtStats` (`bench/bench_cdt_stats.nim`), arena CDT + front hash.

| fixture          | flipEvents | flipScans | rotations | legalizeCalls | incircleCalls |
|------------------|-----------:|----------:|----------:|--------------:|--------------:|
| large-shape (512)|          0 |         0 |       492 |          1750 |          1159 |
| diamond          |          0 |         0 |         1 |            18 |            16 |
| star             |          0 |         0 |         1 |            16 |            15 |
| dude-with-holes  |          4 |         0 |        54 |           302 |           296 |
| nazca-monkey     |          2 |         0 |       837 |          3950 |          3218 |
| nazca-heron      |          0 |         0 |       569 |          2958 |          2635 |

The constraint-recovery flip cascade is **negligible**: 4 flips total on
dude-with-holes, 0 on large-shape / heron / diamond / star, 2 on nazca-monkey.
`flipScans` is 0 everywhere in this fixture set.

Crucially, `rotations` (total edge flips) is 1-2 orders of magnitude larger than
`flipEvents` (54 vs 4 on dude; 837 vs 2 on monkey). Almost all flips happen
inside `legalize` during **unconstrained point insertion**, not during
constraint recovery. This is why Tier 1's `applyRotatedFlags` produced -5.8% on
dude-with-holes even though only 4 of its 54 rotations were constraint flips.

**Implication:** corridor clearing targets the `flipEvents` path (~1.5% of
runtime, see below) and would replace 0-4 flips per fixture. It cannot move the
benchmark. Dropped.

## Measurement 2: time profile (`sample`, symbolized)

Symbolized build (tuned flags + `--debugger:native --passC:-g`, no strip),
profiled with macOS `sample` across the full `bench/bench_p2t.nim` fixture loop.
675 root samples on the main thread. Self-time (top-of-stack):

| function                                        | self % | inlined predicate |
|-------------------------------------------------|-------:|-------------------|
| fill family (`fillBasin`+`fillAdvancingFront`+`fill`+`fillBasinReq`) | 19.4% | orient2d |
| `legalize`                                      |  10.5% | incircle          |
| `sweepPoints` (driver / inlined point+edge events) | 8.7% | mixed             |
| `meshClean` (output extraction)                 |   5.9% | -                 |
| `locate` family (`locateNode`+`nearestBucketNode`) | 4.6% | orient2d          |
| `rotateTrianglePairIndexed` (Tier 1 already)    |   3.6% | -                 |
| `edgeEvent` (constraint recovery)               |   1.5% | -                 |

Two findings kill both levers:

1. **Corridor clearing — dead.** Constraint recovery (`edgeEvent`) is 1.5% of
   runtime, consistent with the 0-4 flips above. There is nothing to clear.

2. **SIMD — dead in this code.** There are no `incircle`/`orient2d` symbols in
   the profile: both are **inlined as single scalar evaluations** scattered
   through `fillBasin` / `legalize` / `locateNode`. `cleave.md`'s SIMD premise is
   a Bowyer-Watson cavity testing many `InCircle` candidates against one shared
   point (a natural 4-8 wide batch). This engine is a Poly2Tri sweep + advancing
   front; that batch never forms. NEON-vectorizing a lone 3-flop `orient2d` or a
   ~9-mul `incircle` evaluation yields effectively nothing, and M4 is 2-wide for
   f64 regardless. (A 4-wide f32-path experiment was considered but the same
   "no batch exists" structural problem applies.)

## Redirected Tier 2

`fast-poly2tri` runs the *same* sweep + advancing-front + iterative-flip
algorithm, so beating it decisively is a **constant-factor game on the genuinely
hot functions**, i.e. continue the Tier 1 method (diff against the `MPE_*`
reference, cut ops) on, in priority order:

1. **Fill family (~19%)** — the single largest cluster; advancing-front filling,
   orient2d-heavy. Reference: `MPE_*` fill equivalents.
2. **`legalize` (~10.5%)** — incircle + recursion shape.
3. **`meshClean` (~6%)** — pure output extraction, *our* code. Worth checking
   whether `fast-poly2tri`'s timed "default" path does equivalent work; if not,
   this is removable overhead rather than a constant-factor fight.

Neither corridor clearing, SIMD, multithreading, nor SoA (already disproven in
`idx-vs-pointer.md`) from `cleave.md` maps to where this single-threaded code
spends time.

## Follow-up: the hot functions are already reference-competitive

Diffing the hot functions against the `fast-poly2tri` reference found little
headroom:

- **Fill family** is already *ahead* of the reference. `MPE_PolyFill` calls the
  generic `MPE_PolyMarkNeighborTri` (a 3x3 = 9-way point scan to find the shared
  edge); our `fill` sets its own neighbors by known edge index and calls a
  *targeted* `markNeighbor(p1, p2, other)` (6 comparisons) only for the back
  pointer. `fillBasin`/`fillBasinReq` match `MPE_FillBasin*` line-for-line.
- **`legalize`** already matches `MPE_PolyLegalize` structurally. The one
  divergence — our constrained/Delaunay skip does 3 flag reads + a branchy
  `setFlag`, vs the reference's single combined-mask test + masked write — was
  ported and measured. Result: a **wash** (interleaved global-min, 16x then 24x:
  signs flipped run-to-run, e.g. heron +3.0% then 0%, dude 0% then +2.8%, within
  the +-3% noise floor and slightly negative on large fixtures, likely an
  icache/alignment shift in the hottest recursive function). Reverted.

Conclusion: the meaningful single-threaded win was Tier 1 (`applyRotatedFlags`,
commit `81d8541`). The engine is already at parity-or-ahead of `fast-poly2tri`
on most fixtures (only diamond/dude remain ~+3%, inside the noise band), and
further constant-factor micro-opts on these already-tuned hot paths land in the
measurement noise. Tier 2 is closed without a net code change beyond Tier 1.

## Reproduce

```
nimble benchCdtStats            # operation counts (-d:p2tCdtStats)

# symbolized time profile
nim c --mm:arc --threads:off -d:release --opt:speed -d:p2tArenaCdt \
  -d:p2tUnsafeCdt -d:p2tFastRawCdt -d:p2tFrontHash --path:src --panics:on \
  --passC:-mcpu=native --passL:-mcpu=native --debugger:native --passC:-g \
  -o:/tmp/p2t_bench_sym bench/bench_p2t.nim
( /tmp/p2t_bench_sym >/dev/null & P=$!; sleep 0.2; sample $P 4 -mayDie )
```
