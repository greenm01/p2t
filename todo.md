# Cleave TODO

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
