# int32-index vs pointer arena (hot-path A/B)

Negative result. The pointer arena (`-d:p2tArenaCdt`, `arena_cdt.nim`) stays the
production hot path. This documents the experiment so the question stays settled
and reproducible.

## What was tested

`idx_cdt.nim` (`-d:p2tIdxCdt`) is a faithful, line-for-line twin of
`arena_cdt.nim`: identical Poly2Tri advancing-front algorithm, identical control
flow, identical front-hash accelerator. The *only* variable changed is the mesh
representation:

- pointer arena: each handle is a `ptr ArenaTriangle/Point/Node/Edge` into a
  reusable buffer (single deref to reach a field).
- index twin: each handle is a 32-bit index (`NilId = -1`) into the workspace
  seqs, reached through explicit `ws.tri(id).field` / `ws.pt(id).field`
  accessors (seq base load + `id * sizeof` to reach a field).

Structs are still Array-of-Structs in both; only the handle width changes
(`ArenaTriangle` 56B with 6 pointers → `IdxTriangle` 28B with 6 int32). Tests:
`nimble testIdxCdt` (18/18). Bench: `nimble benchIdxTuned`. Both built with the
tuned flags (`--mm:arc --threads:off -d:release --opt:speed -d:p2tUnsafeCdt
-d:p2tFastRawCdt` + LTO + `-mcpu=native`), single-shot (`--threads:off`).

## End-to-end result (best-of-5, microseconds)

| fixture          |  ptr  | idx (28B) | idx pad (32B) | pad vs ptr |
|------------------|------:|----------:|--------------:|-----------:|
| small-ui-quad    |   906 |     1276  |        1233   |   1.36x    |
| fixture-test     |  1723 |     2483  |        2327   |   1.35x    |
| star             |  2579 |     3814  |        3688   |   1.43x    |
| diamond          |  3236 |     4724  |        4328   |   1.34x    |
| dude-with-holes  |  5021 |     6926  |        6596   |   1.31x    |
| medium-icon      |  4222 |     6849  |        6087   |   1.44x    |
| nazca-heron      |  6059 |     8996  |        8207   |   1.35x    |
| nazca-monkey     |  7596 |    10895  |       10262   |   1.35x    |
| large-shape      | 17423 |    31372  |       27594   |   1.58x    |

The index twin is **1.3-1.8x slower on every fixture**, and the gap widens with
size. Padding the int32 structs to a power-of-two (`-d:p2tIdxPad`, kills the
non-pow2 `imul` in element addressing) recovers only ~10-25% and never crosses
over: the addressing multiply was a minor, secondary cost.

## Per-loop attribution (macOS `sample`, 512-gon, self-time per triangulation)

| hot loop                      | ptr   | idx   | idx slowdown |
|-------------------------------|------:|------:|-------------:|
| meshClean                     |  1.77 |  1.77 |   **1.00x**  |
| fillAdvancingFront            |  2.93 |  3.30 |     1.12x    |
| sortRange                     |  8.71 | 10.70 |     1.23x    |
| legalize                      | 12.66 | 22.06 |     1.74x    |
| locateNode                    |  2.60 |  4.64 |     1.78x    |
| fill                          |  5.30 |  9.88 |     1.86x    |
| sweepPoints (inlined predics) | 25.51 | 48.72 |     1.91x    |
| rotateTrianglePairIndexed     |  3.43 |  7.16 |     2.09x    |
| fillBasin                     |  8.69 | 19.67 |     2.26x    |

There is **no loop where the index layout wins**. It is:

- neutral (1.0-1.2x) only where it moves *handles* and not *data* — `meshClean`
  (flag-walk + stack of ids), `fillAdvancingFront`, and `sortRange` (swapping
  int32 ids is nearly as cheap as swapping pointers). Here the handle is the
  payload.
- strictly worse (1.7-2.3x) everywhere coordinates/fields are dereferenced,
  scaling with deref density — peaking in the geometry-predicate loops
  (`fillBasin`, `rotateTrianglePairIndexed`, `sweepPoints` via `orient2d` /
  `incircle`), each of which reads many `ws.pt(id).x` two-step loads per call.

## Why

To reach a field through an index you re-derive the address (`seqBase + id*size`)
on every touch; the pointer arena holds the address once and reuses it. The "half
the struct width = better cache" bet never pays off here: the working set fits
well enough that the density saving is immediately given back (and then some) by
the per-access addressing arithmetic. Making indices competitive requires
materializing a local pointer per proc (`let tr = addr ws.triangles[id]`) — i.e.
reintroducing the pointer. This matches fast-poly2tri's pointer-based design.

## Why better sorting and front hash do not rescue idx

The later champion work combines two kinds of wins: default pdqsort in the
pointer arena and the front-hash accelerator shared by the arena and idx twins.
They attack a different variable from the pointer-vs-index gap.

The clean model is `time ~= c * N`:

- better sorting and the front hash shrink `N`, the number of operations. Better
  sort means fewer/cooler ordering costs; better front hints mean fewer
  surviving front-walk steps.
- the pointer arena shrinks `c`, the cost of each operation. A front step is a
  dependent-load traversal; pointer handles reach the next node and its fields
  with lower latency than re-deriving `seqBase + id*size` through accessors.

Because `idx_cdt.nim` and `arena_cdt.nim` run the same triangulation algorithm,
front hash reduces locate-step `N` on both. A better hash can take a Nazca
fixture from tens of thousands of locate steps to a few thousand, but it does
not change what each remaining step costs. Those remaining steps are still more
expensive in idx because every node/point/triangle touch pays the index
addressing path. Likewise, sort improvements are front-loaded point-ordering
wins; they do not change the cost of the surviving dependent-load traversal in
`locateNode`, `fill`, `legalize`, and the predicate-heavy loops.

This is why giving idx the best hinting still leaves it behind, and why a better
sort cannot close the core gap: algorithmic wins remove shared work; the
surviving hot work is dominated by per-step latency, exactly where the pointer
arena has the advantage. Better hashing can even make that more visible: once
step count is crushed, the constant cost of each surviving step is a larger
share of the runtime.

## Scope / caveat

This condemns *only* swapping pointers for int32 indices inside the **same
AoS layout with per-access accessors**. It does **not** evaluate the
Structure-of-Arrays + Morton-order direction in `cleave.md`, where int32 indices
are the right call for a different reason (SoA column streaming, parallel radix
sort, SIMD cavity evaluation). That layout is a separate, untested hypothesis.

## Reproduce

```
nimble testIdxCdt        # 18/18, index twin correctness
nimble benchIdxTuned     # index twin timings
nimble benchBestTuned    # pointer arena timings
# per-loop: build bench/prof_driver.nim with -d:p2tIdxCdt vs -d:p2tArenaCdt
#           (--passC:-g --debugger:native, no strip), then `sample <pid> 4`.
```
