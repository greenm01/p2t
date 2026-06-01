# Cleave TODO

## Naming

The partitioned polygon strategy is now **PCDT**: Partitioned Constrained Delaunay Triangulation. Use `pcdt` for benchmark labels and `partitioned-cdt-*` for new build options. The older `partitioned-bw-*` flags remain accepted as deprecated aliases while experiments settle.

Current canonical PCDT command shape:

- `-Dpartitioned-cdt-mode=true`
- `-Dpartitioned-cdt-parallel-mode=true`
- `-Dpartitioned-cdt-threads=N`
- `-Dpartitioned-cdt-max-piece-vertices=N`

## Current Finding

Cleave now reports polygon-interior triangles separately from the full live Delaunay mesh. This makes the `bench-single` comparison with fast-poly2tri fair on simple outer-ring fixtures:

- `nazca-monkey`: `1202` interior triangles, `2409` live mesh triangles.
- `nazca-heron`: `1034` interior triangles, `2073` live mesh triangles.

The old live-triangle count made Cleave look like it was producing about twice the output. The fair output count shows the real issue: Cleave still constructs and maintains the full convex-hull Delaunay mesh, then extracts the polygon interior, while fast-poly2tri directly builds the polygon triangulation.

## Latest Single-Core Gap

Fast-predicate BRIO Cleave remains roughly `1.9-2.4x` slower than fast-poly2tri on the large Nazca fixtures after reducing trusted insertion writes.

- Cleave fast BRIO: about `166-179 us/run` on the current macOS benchmark run.
- fast-poly2tri float/double: about `76-88 us/run`.
- Interior extraction costs only about `10-14 us/run`, so optimizing extraction alone will not close the gap.

The latest single-core insertion cleanups update the spatial hint grid once per inserted point, write each inserted-point vertex hint once, use a trusted dead-slot triangle write after cavity slots are tombstoned, and avoid tombstone-then-refill churn for cavity slots immediately reused as live triangles. This keeps walk fallback counts at zero on the large fixtures while cutting insertion time:

- `nazca-monkey/brio-morton`: about `179 us/run`, insertion about `135 us/run`.
- `nazca-heron/brio-morton`: about `166 us/run`, insertion about `122 us/run`.

The current pass preserves Linux/macOS portability: tests pass on macOS, and `zig build -Dtarget=x86_64-linux` still cross-compiles successfully.

## Latest Cavity-Relevance Diagnostic

`bench-single -Dpredicate-policy=fast -Dinstrument-mesh-stats=true -Dspatial-hints=true` now runs on macOS/Linux-portable benchmark timers and reports one untimed cavity relevance pass after each timed case. Current BRIO results show a large share of insertion cavity work later maps to exterior mesh:

- `dude/brio-morton`: `354` cavity samples, `138` interior, `216` exterior (`61.0%` exterior).
- `nazca-monkey/brio-morton`: `4702` cavity samples, `2355` interior, `2347` exterior (`49.9%` exterior).
- `nazca-heron/brio-morton`: `4078` cavity samples, `1943` interior, `2135` exterior (`52.4%` exterior).

This supports continuing with polygon-aware construction work: a meaningful fraction of insertion/cavity maintenance is spent on triangles that do not contribute to final polygon output.

## Latest Polygon-Output Prototype

`bench-single -Dpredicate-policy=fast -Dinstrument-mesh-stats=true -Dspatial-hints=true -Dpolygon-output-mode=true` now runs an explicit post-recovery polygon-output cull. This preserves the full-mesh path by default, then detaches interior boundary adjacencies and tombstones exterior/super triangles as a separate timed phase.

Current BRIO results:

- `dude/brio-morton`: `92` interior triangles/run, `92` live mesh after cull, cull about `1.0 us/run`.
- `nazca-monkey/brio-morton`: `1202` interior triangles/run, `1202` live mesh after cull, cull about `16.3 us/run`.
- `nazca-heron/brio-morton`: `1034` interior triangles/run, `1034` live mesh after cull, cull about `13.5 us/run`.

The post-hoc cull proves the output mode and gives clean polygon-only live meshes, but it adds time rather than closing the gap. The next optimization should move polygon awareness earlier so exterior regions avoid some insertion, hint, adjacency, or legalization work instead of only being removed after the full mesh is built.

An incremental boundary-recovery prototype was tested and rejected. Recovering polygon edges as soon as both endpoints were inserted preserved output counts, but it moved recovery work into insertion and caused many more global edge lookup fallbacks. On the large BRIO fixtures it regressed badly (`nazca-monkey` about `369 us/run`, `nazca-heron` about `257 us/run`). The next polygon-aware attempt should not interleave full corridor recovery with point insertion unless edge lookup and recovery locality are redesigned first.

In polygon-output mode, the post-cull live triangle count is already the interior output count. The benchmark should use `liveTriangleCount()` after cull instead of running a second exterior-marking pass for extraction timing.

## Latest Polygon-Seed Prototype

`bench-single -Dpredicate-policy=fast -Dinstrument-mesh-stats=true -Dspatial-hints=true -Dpolygon-seed-mode=true` now runs an Earcut-style simple outer-ring seed path. It builds only polygon-interior triangles, marks boundary edges constrained, and then legalizes unconstrained diagonals with the existing Cleave legalizer.

This validates the construction idea but rejects the naive seed+full-legalize approach as a single-core win:

- `dude/seed`: `92` interior triangles/run, `92` live mesh, about `23.0 us/run`; seed about `6.9 us/run`, legalization about `15.0 us/run`, `81` flips/run.
- `nazca-monkey/seed`: `1202` interior triangles/run, `1202` live mesh, about `779.9 us/run`; seed about `336.7 us/run`, legalization about `442.1 us/run`, `2621` flips/run.
- `nazca-heron/seed`: `1034` interior triangles/run, `1034` live mesh, about `543.2 us/run`; seed about `169.8 us/run`, legalization about `372.4 us/run`, `2123` flips/run.

The seed avoids exterior mesh inflation, but the arbitrary ear-clipped diagonals are far from Delaunay and the full legalizer does too much work. Keep the flag as a correctness/profiling prototype, not as the next optimization path. A future polygon-only path needs either a better Delaunay-biased seed, localized legalization scheduling, or a divide-and-conquer/partitioned CDT construction rather than full legalization over all earcut triangles.

## Latest Trapezoid Domain-Decomposition Prototype

`bench-single -Dpredicate-policy=fast -Dinstrument-mesh-stats=true -Dspatial-hints=true -Dtrapezoid-dd-mode=true` now runs a deterministic visibility-diagonal decomposition prototype. It partitions a simple ring into subpolygons, seeds each piece, temporarily constrains partition diagonals, legalizes pieces, clears the diagonals, and legalizes seam-adjacent triangles.

Current results reject this naive decomposition as a single-core optimization, but they give useful seam data:

- `dude/trapezoid-dd`: `92` interior triangles/run, `92` live mesh, about `26.6 us/run`; no partition at the current 256-vertex cutoff.
- `nazca-monkey/trapezoid-dd`: `1202` interior triangles/run, `1202` live mesh, about `2469.8 us/run`; `7` pieces, `6` diagonals, decomposition about `1880.9 us/run`, local legalization about `409.9 us/run`, seam legalization about `33.8 us/run`, seam flips `209/run`.
- `nazca-heron/trapezoid-dd`: `1034` interior triangles/run, `1034` live mesh, about `1568.0 us/run`; `5` pieces, `4` diagonals, decomposition about `1063.8 us/run`, local legalization about `347.4 us/run`, seam legalization about `37.7 us/run`, seam flips `227/run`.

The seam-fix phase can be much smaller than full Earcut legalization, especially on the large fixtures, but the current visibility splitter is too expensive and local piece legalization still does most of the global flip work. A serious version would need a much cheaper partition builder and a more Delaunay-biased per-piece seed before this domain-decomposition strategy can help.

## Latest Partitioned Bowyer-Watson Prototype

`bench-single -Dpredicate-policy=fast -Dinstrument-mesh-stats=true -Dspatial-hints=true -Dpartitioned-bw-mode=true` now partitions with the same visibility-diagonal scaffold, runs local Cleave Bowyer-Watson CDT inside each piece, merges live local triangles into one global polygon mesh, temporarily constrains partition diagonals, clears them, and legalizes seam-adjacent triangles. The benchmark validates topology, boundary constraint flags, and CDT legality after each case.

Current macOS results:

- `dude/partitioned-bw`: `92` interior triangles/run, `92` live mesh, about `28.2 us/run`; no partition at the current 256-vertex cutoff.
- `nazca-monkey/partitioned-bw`: `1202` interior triangles/run, `1202` live mesh, about `2237.4 us/run`; decomposition about `1891.3 us/run`, total piece BW about `260.4 us/run`, max piece BW about `67.5 us/run`, assembly about `47.8 us/run`, seam legalization about `35.9 us/run`.
- `nazca-heron/partitioned-bw`: `1034` interior triangles/run, `1034` live mesh, about `1368.8 us/run`; decomposition about `1079.0 us/run`, total piece BW about `217.1 us/run`, max piece BW about `64.0 us/run`, assembly about `32.9 us/run`, seam legalization about `37.7 us/run`.

This rejects the current scaffold as a single-core win because decomposition dominates. It also makes the useful signal sharper: replacing Earcut-local seed plus local legalization with local Bowyer-Watson cuts the non-decomposition piece work substantially, and the estimated per-case critical path without decomposition is about `151 us/run` for monkey and `135 us/run` for heron. That is finally in the neighborhood of the current full-mesh BRIO path (`183 us/run` monkey, `167 us/run` heron on the same run), but only if partition construction becomes cheap enough.

Next serious experiment: replace the O(n * sampled-diagonal) visibility splitter with a low-overhead partition builder. Keep the local Bowyer-Watson merge path; the bottleneck has moved to decomposition, not piece triangulation or seam repair.

## Latest Parallel Partitioned Bowyer-Watson Smoke Test

`bench-single -Dpredicate-policy=fast -Dinstrument-mesh-stats=true -Dspatial-hints=true -Dpartitioned-bw-parallel-mode=true` now runs local piece Bowyer-Watson construction on worker threads. Decomposition, global assembly, temporary partition constraints, seam legalization, extraction, and validation remain serial. `-Dpartitioned-bw-threads=N` controls workers; `0` uses detected CPU count, capped by piece count.

Current macOS 4-worker results:

- `dude/partitioned-bw-parallel`: `92` interior triangles/run, `92` live mesh, about `26.7 us/run`; only one piece, so no parallelism.
- `nazca-monkey/partitioned-bw-parallel`: `1202` interior triangles/run, `1202` live mesh, about `2079.1 us/run`; decomposition about `1826.7 us/run`, piece BW wall about `172.4 us/run`, serial piece sum about `319.1 us/run`, assembly about `34.3 us/run`, seam legalization about `33.0 us/run`.
- `nazca-heron/partitioned-bw-parallel`: `1034` interior triangles/run, `1034` live mesh, about `1240.9 us/run`; decomposition about `1026.3 us/run`, piece BW wall about `141.8 us/run`, serial piece sum about `284.2 us/run`, assembly about `29.2 us/run`, seam legalization about `35.5 us/run`.

CPU-count mode used `7` workers for monkey and `5` for heron. It produced similar totals (`2028.3 us/run` monkey, `1262.7 us/run` heron) and did not materially change the conclusion.

This validates that piece construction can be run independently and merged deterministically, but it is not enough to beat current BRIO. Thread spawn/allocation overhead keeps the piece phase above the ideal max-piece bound, and the serial visibility decomposition is still the dominant cost. The next serious optimization remains a cheaper partition builder; a reusable worker pool is only worth building after decomposition stops dominating.

## Latest Decomposition Fast-Visible Prototype

`-Ddecomposition-fast-visible=true` now adds local cone pruning and segment AABB rejection to the visibility-diagonal splitter, while preserving the existing midpoint-in-ring and edge-crossing checks as correctness guards. Decomposition diagnostics are reported when mesh instrumentation is enabled.

Baseline diagnostics show why decomposition was expensive:

- `nazca-monkey`: about `1919` candidate diagonals/run, `1,017,949` midpoint scan iterations/run, and `78,940` edge scans/run.
- `nazca-heron`: about `1212` candidate diagonals/run, `535,513` midpoint scan iterations/run, and `34,774` edge scans/run.

Fast-visible results with serial partitioned BW:

- `nazca-monkey/partitioned-bw`: total about `799.5 us/run`; decomposition down to about `487.6 us/run`; midpoint scans down to `287,753`, edge scans down to `4,826`, cone rejects `1312`, AABB rejects `20,863`.
- `nazca-heron/partitioned-bw`: total about `563.7 us/run`; decomposition down to about `276.5 us/run`; midpoint scans down to `142,375`, edge scans down to `821`, cone rejects `878`, AABB rejects `12,997`.

Fast-visible plus 4-worker piece construction:

- `nazca-monkey/partitioned-bw-parallel`: about `705.5 us/run`; decomposition `475.3 us/run`, piece BW wall `156.7 us/run`, assembly `31.4 us/run`, seam `31.7 us/run`.
- `nazca-heron/partitioned-bw-parallel`: about `481.6 us/run`; decomposition `273.6 us/run`, piece BW wall `136.3 us/run`, assembly `29.1 us/run`, seam `35.3 us/run`.

This is a real decomposition improvement but still not competitive with current BRIO. The remaining decomposition cost is mostly candidate count plus midpoint scans; the next decomposition experiment should avoid repeated point-in-ring scans entirely, either by using a cheaper guaranteed-internal candidate construction or replacing this sampled visibility splitter with a proper monotone/trapezoid-style partition builder.

## Latest Cone-Visible Decomposition Prototype

`-Ddecomposition-cone-visible=true` keeps endpoint cone pruning and AABB-pruned edge intersection checks, but skips the midpoint point-in-ring scan. On simple polygons this uses the standard diagonal visibility criterion: locally visible at both endpoints and not crossing polygon edges.

Current serial partitioned BW results:

- `nazca-monkey/partitioned-bw`: about `502.9 us/run`; decomposition down to about `169.2 us/run`; midpoint scans `0`, edge scans `15,826`, AABB rejects `101,522`, cone rejects `1312`.
- `nazca-heron/partitioned-bw`: about `344.1 us/run`; decomposition down to about `55.8 us/run`; midpoint scans `0`, edge scans `3,441`, AABB rejects `35,800`, cone rejects `878`.

Current 4-worker partitioned BW results:

- `nazca-monkey/partitioned-bw-parallel`: about `417.4 us/run`; decomposition `178.2 us/run`, piece BW wall `162.2 us/run`, assembly `32.9 us/run`, seam `33.4 us/run`.
- `nazca-heron/partitioned-bw-parallel`: about `266.3 us/run`; decomposition `54.6 us/run`, piece BW wall `141.4 us/run`, assembly `27.1 us/run`, seam `36.1 us/run`.

This validates that the midpoint scan was the main decomposition tax. The remaining gap to BRIO is now mostly piece construction overhead, seam legalization, and thread/assembly overhead. The next experiment should either reuse local worker state to cut piece BW overhead or reduce seam/assembly work; a full replacement partition builder is less urgent for the current fixtures than it was before cone-visible.

## Latest Seam Seed Lookup Cleanup

Partitioned BW no longer marks partition diagonals constrained and immediately unmarks them only to collect seam seed triangles. The partitioned path now collects adjacent seam triangles with a single edge lookup pass and leaves partition diagonals unconstrained before seam legalization.

With `-Ddecomposition-cone-visible=true`:

- Serial `nazca-monkey/partitioned-bw`: about `482.7 us/run`; edge lookup calls down to `6/run`, scanned triangles down to `2841/run`.
- Serial `nazca-heron/partitioned-bw`: about `343.5 us/run`; edge lookup calls down to `4/run`, scanned triangles down to `1565/run`.
- 4-worker `nazca-monkey/partitioned-bw-parallel`: about `406.9 us/run`; assembly about `30.0 us/run`, seam about `31.6 us/run`.
- 4-worker `nazca-heron/partitioned-bw-parallel`: about `259.8 us/run`; assembly about `24.2 us/run`, seam about `35.1 us/run`.

This is a small cleanup, not a strategic shift. The remaining large cost is still local piece BW wall time plus seam legalization.

## Latest Piece-Size Sweep

`-Ddecomposition-max-piece-vertices=N` now controls the partition cutoff for trapezoid/partitioned prototypes. The prototype default moved from `256` to `768` after a cone-visible + 4-worker sweep.

Current cone-visible 4-worker results:

- Cutoff `128`: monkey about `510.1 us/run`, heron about `428.3 us/run`; more pieces caused much more seam legalization, and the splitter still left oversized failed pieces.
- Cutoff `512`: monkey about `286.0 us/run`, heron about `214.7 us/run`; fewer seams were much better.
- Cutoff `768`: monkey about `272.9 us/run`, heron about `208.9 us/run`; best tested balance, usually one split/two pieces on the large fixtures.
- Cutoff `1024`: monkey about `291.0 us/run`, heron about `208.3 us/run`; monkey regressed from larger piece BW wall time.

This changes the current best prototype shape: partition sparingly, avoid seam work, and use parallelism only where one cheap split gives useful independent piece jobs.

## Latest PCDT Worker-Executor Prototype

`bench-single -Dpredicate-policy=fast -Dinstrument-mesh-stats=true -Dspatial-hints=true -Dpartitioned-cdt-parallel-mode=true -Dpartitioned-cdt-threads=4 -Ddecomposition-cone-visible=true -Dpartitioned-cdt-max-piece-vertices=768` now keeps PCDT workers alive for each benchmark case instead of spawning threads for every timed iteration. Results are still merged deterministically by piece index, and one-piece decompositions fall back to the serial piece path.

Current macOS results:

- `dude/pcdt-parallel`: about `25.1 us/run`; one piece, no parallel dispatch.
- `nazca-monkey/pcdt-parallel`: about `276.7 us/run`; decomposition `55.0 us/run`, piece CDT wall `164.3 us/run`, dispatch/wait `16.1 us/run`, assembly `32.2 us/run`, seam `21.0 us/run`.
- `nazca-heron/pcdt-parallel`: about `186.2 us/run`; decomposition `13.0 us/run`, piece CDT wall `139.9 us/run`, dispatch/wait `14.0 us/run`, assembly `28.1 us/run`, seam `1.0 us/run`.

This makes PCDT competitive with BRIO on heron in this run (`186.2 us/run` versus BRIO `161.8 us/run`) but still slower on monkey (`276.7 us/run` versus BRIO `175.3 us/run`). The remaining useful targets are local piece CDT wall time and assembly; thread spawn is no longer part of the timed inner loop, and seam cost is fixture-dependent.

## Latest PCDT Piece-Order Sweep

`-Dpartitioned-cdt-piece-order=brio|morton|ring` now controls local piece insertion order for PCDT benchmarks. The default remains `brio`.

Current cone-visible, cutoff-768, 4-worker macOS results:

- `brio`: monkey about `257.3 us/run`, heron about `196.4 us/run`.
- `morton`: monkey about `306.3 us/run`, heron about `224.6 us/run`.
- `ring`: monkey about `294.4 us/run`, heron about `191.0 us/run`.

Ring order avoids local sort allocation and improves seam-edge lookup locality, but it regresses monkey piece construction badly. Morton is worse on both large fixtures. Keep BRIO as the production candidate and use the new flag only for diagnostics or future decomposition-specific order tests.

## Latest BRIO Parallel Scaffold

`-Dbrio-parallel-mode=true` now runs the large single-mesh benchmark through a BRIO bucket threaded scaffold. `-Dbrio-threads=N` controls worker count. The mode processes BRIO rounds as serial barriers, splits each round into worker chunks, and currently protects the existing trusted insertion path with a coarse insertion lock. Constraint recovery remains serial.

Current macOS results with fast predicates and spatial hints:

- BRIO baseline: monkey about `181.6 us/run`, heron about `154.4 us/run`.
- 2-worker `brio-parallel`: monkey about `273.4 us/run`, heron about `255.6 us/run`.
- 4-worker `brio-parallel`: monkey about `341.0 us/run`, heron about `331.5 us/run`.

This validates the threaded benchmark harness, BRIO bucket barriers, and cross-platform worker plumbing, but it is not a speedup yet. The coarse insertion lock serializes all useful work, and extra worker/barrier overhead grows with thread count. The next parallel experiment should shrink the lock: pre-reserve all append slots or add an append allocator so independent transactional cavities can mutate disjoint locked triangles without taking a whole-insertion mutex.

## Latest BRIO Staged-Planning Prototype

The BRIO parallel path now builds insertion plans in worker threads for each BRIO bucket, then commits valid plans serially in deterministic order. A plan captures the walk/cavity result, boundary edges, footprint triangles, and triangle version snapshots. If a plan is stale, the benchmark switches the rest of that bucket to the existing trusted serial insertion path.

Current 4-worker macOS results with fast predicates and spatial hints:

- `dude/brio-parallel`: about `90.7 us/run`; planning about `67.0 us/run`, commit+fallback about `12.0 us/run`, `7/94` insertions committed from plans.
- `nazca-monkey/brio-parallel`: about `420.7 us/run`; planning about `195.4 us/run`, commit+fallback about `169.0 us/run`, `9/1204` insertions committed from plans.
- `nazca-heron/brio-parallel`: about `384.5 us/run`; planning about `180.4 us/run`, commit+fallback about `148.3 us/run`, `9/1036` insertions committed from plans.

This rejects one-shot pre-bucket speculative planning as the next speedup. BRIO bucket insertions are strongly dependent: after the first few commits, most plans are stale. The useful signal is that safe parallel planning alone is not enough; the next BRIO parallel attempt needs either smaller spatial wavefronts with commit between waves, true concurrent disjoint-cavity commits, or a different partitioned strategy where independent work is established before insertion.

## NNG Applicability Review

Reviewed three nearest-neighbor graph references before changing the BRIO ordering experiment.

- `l2knng-0.1.0`: exact/approximate KNN graph construction for high-dimensional sparse cosine-similarity data. The L2-norm pruning idea is domain-specific and does not map directly to exact 2D CDT insertion.
- `~/src/nngraph`: active learning of nearest-neighbor graphs from noisy distance samples. It relies on oracle sampling and `n x n` confidence matrices, so it is not appropriate for Cleave's exact coordinate input.
- `~/src/nngd`: R/Rcpp wrapper around a KD-tree kNN query, plus graph/commute-time distance tooling. The useful takeaway is only that a future Zig-native exact 2D kNN diagnostic could test Hilbert/Morton candidate windows against KD-tree or brute-force neighbors.

Do not vendor or port these packages for the current path. Keep the immediate experiment focused on Hilbert ordering versus Morton ordering in the existing BRIO benchmark.

## Latest Hilbert Ordering Sweep

`bench-single -Dpredicate-policy=fast -Dspatial-hints=true` now compares `morton`, `brio-morton`, `hilbert`, and `brio-hilbert` in the normal single-mesh benchmark path. Hilbert ordering is implemented directly in Zig and validated against the 4x4 table produced from `~/src/hilbert_hpp`; no C++ dependency was added.

Current macOS results:

- `dude`: `brio-hilbert` about `13.2 us/run`, `brio-morton` about `14.2 us/run`, `hilbert` about `14.3 us/run`, `morton` about `17.3 us/run`.
- `nazca-monkey`: `brio-morton` about `195.3 us/run`, `brio-hilbert` about `196.8 us/run`, `hilbert` about `214.6 us/run`, `morton` about `251.1 us/run`.
- `nazca-heron`: `brio-morton` about `168.1 us/run`, `brio-hilbert` about `171.0 us/run`, `hilbert` about `239.7 us/run`, `morton` about `242.5 us/run`.

Hilbert is not the next production ordering from this sweep. BRIO-Hilbert is competitive but does not beat BRIO-Morton on the large fixtures, and Hilbert order construction is more expensive than Morton (`~227-280 us` versus `~45-85 us` for the large fixtures). Keep it as a benchmarkable diagnostic, but keep BRIO-Morton as the default baseline.

## Latest LFQT Diagnostic

After reviewing `delaunayhpg.pdf`, `bench-single -Dpredicate-policy=fast -Dspatial-hints=true -Dlfqt-diagnostic-mode=true -Dlfqt-bin-vertices=N` now builds a linear floating-point quadtree diagnostic. It uses monotone IEEE-754 `f64` bit transforms, 128-bit 2D Morton codes, recursive first/last XOR splitting, and existing local point insertion inside each independent bin. It does not implement the Dwyer merge phase or CDT constraint recovery.

Current macOS results:

- Bin target `64`: monkey `40` bins, max `62`, sort `162 us`, split `2 us`, local serial `386 us`, estimated 4-worker wall `261 us`; heron `29` bins, max `62`, sort `161 us`, split `3 us`, local serial `482 us`, estimated 4-worker wall `286 us`.
- Bin target `128`: monkey `19` bins, max `124`, sort `219 us`, split `2 us`, local serial `600 us`, estimated 4-worker wall `373 us`; heron `16` bins, max `116`, sort `204 us`, split `1 us`, local serial `529 us`, estimated 4-worker wall `348 us`.
- Bin target `256`: monkey `10` bins, max `235`, sort `161 us`, split `1 us`, local serial `445 us`, estimated 4-worker wall `285 us`; heron `7` bins, max `252`, sort `189 us`, split `0 us`, local serial `518 us`, estimated 4-worker wall `337 us`.

The diagnostic supports the paper's broad direction but rejects an immediate LFQT pivot for the current small polygon fixtures. The split builder is cheap, but the current comparison sort plus 128-bit code construction dominates, and the estimated critical path is slower than the current BRIO baseline. LFQT is only worth revisiting with a radix sort and a real bottom-up merge prototype, or on substantially larger unconstrained point sets.

## Latest BRIO Plan-Window Sweep

`-Dbrio-plan-window=N` now caps the number of staged BRIO insertion plans built before serial commit. `0` preserves the previous whole-BRIO-round behavior. The goal was to see whether replanning within a BRIO bucket could reduce stale-plan invalidation enough to make speculative planning useful.

Current 4-worker macOS results with fast predicates and spatial hints:

- Whole round (`0`): monkey about `407.5 us/run`, `10` windows/run, `9/1203` committed plans; heron about `383.6 us/run`, `9` windows/run, `9/1036` committed plans.
- Window `16`: monkey about `1275.9 us/run`, `80` windows/run, `100/1203` committed plans; heron about `1143.3 us/run`, `70` windows/run, `90/1036` committed plans.
- Window `32`: monkey about `873.6 us/run`, `44` windows/run, `52/1203` committed plans; heron about `773.9 us/run`, `38` windows/run, `49/1036` committed plans.
- Window `64`: monkey about `639.7 us/run`, `26` windows/run, `30/1203` committed plans; heron about `582.1 us/run`, `22` windows/run, `26/1036` committed plans.

This rejects micro-batched speculative planning. Smaller windows do raise the commit rate, but repeated worker dispatch and planning dominate, and the total remains much slower than both whole-round staged planning and the serial BRIO baseline. The next BRIO parallel attempt needs true concurrent disjoint-cavity commits or a different independent-work structure; more serial replan/commit windows are not promising.

## Latest BRIO Disjoint-Footprint Diagnostic

`-Dbrio-disjoint-diagnostic=true` now computes a greedy wave grouping over staged BRIO insertion-plan footprints. The diagnostic is intentionally opt-in because the naive grouping is O(plan footprint comparisons) and pollutes runtime; use it for structure, not timing.

Current 4-worker whole-round macOS results with fast predicates and spatial hints:

- `dude`: `94` planned footprints, `43` disjoint waves/run, first waves total `34` plans/run, max wave `22`.
- `nazca-monkey`: `1203` planned footprints, `85` disjoint waves/run, first waves total `834` plans/run, max wave `463`.
- `nazca-heron`: `1036` planned footprints, `78` disjoint waves/run, first waves total `569` plans/run, max wave `344`.

This shows there is substantial disjoint planned work inside BRIO buckets. The current staged commit loop still commits only about one plan per bucket because it switches the whole remaining bucket to serial fallback after the first stale plan. Before attempting true concurrent commits, test a deterministic serial "continue after stale" commit loop that tries later planned footprints individually.

That serial "continue after stale" experiment was attempted and rejected before commit. Even though later plans may still pass the version snapshot check, allowing commits after an intervening fallback produced `InvalidTriangleAdjacency` during the benchmark. The version footprint is therefore not a sufficient safety proof once fallback mutation has occurred. Any next BRIO parallel commit experiment must either commit a locked disjoint wave before any fallback mutation, or strengthen the transaction validation to cover the topology assumptions used by plan emission.

## Next Structural Work

1. Add a polygon-output construction mode.
   - Keep the current full-mesh CDT path as the correctness baseline.
   - The post-recovery cull prototype is in place behind `-Dpolygon-output-mode=true`.
   - Next: move from post-hoc deletion toward avoiding exterior-triangle maintenance earlier.
   - Measure whether exterior culling can avoid legalization, hint updates, or adjacency maintenance outside the constrained polygon.

2. Profile insertion against interior relevance.
   - Track how much insertion/cavity work lands in triangles later classified as exterior.
   - Report interior/exterior cavity counts after boundary recovery.
   - Use that data to decide whether early polygon-awareness can pay off.

3. Reduce full-mesh maintenance overhead.
   - Audit hot insertion writes that update hints, circumcircle data, versions, locks, and edge flags for triangles that will become exterior.
   - Split trusted single-thread state from future transactional state where the current path pays concurrency overhead unnecessarily.

4. Keep fair benchmark reporting.
   - Continue reporting both `interior triangles/run` and `live mesh`.
   - Compare fast-poly2tri only against the interior count.
   - Keep extraction timing separate from insertion and constraint recovery.

## Guardrails

- Do not replace the CDT algorithm with ear clipping.
- Do not treat fast predicates as the correctness baseline.
- Do not optimize benchmark counting in ways that hide the cost of producing usable polygon output.
