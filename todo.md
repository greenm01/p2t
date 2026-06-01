# Cleave TODO

## Current Finding

Cleave now reports polygon-interior triangles separately from the full live Delaunay mesh. This makes the `bench-single` comparison with fast-poly2tri fair on simple outer-ring fixtures:

- `nazca-monkey`: `1202` interior triangles, `2409` live mesh triangles.
- `nazca-heron`: `1034` interior triangles, `2073` live mesh triangles.

The old live-triangle count made Cleave look like it was producing about twice the output. The fair output count shows the real issue: Cleave still constructs and maintains the full convex-hull Delaunay mesh, then extracts the polygon interior, while fast-poly2tri directly builds the polygon triangulation.

## Latest Single-Core Gap

Fast-predicate BRIO Cleave remains roughly `4x` slower than fast-poly2tri on the large Nazca fixtures.

- Cleave fast BRIO: about `340-353 us/run`.
- fast-poly2tri float/double: about `76-88 us/run`.
- Interior extraction costs only about `10-14 us/run`, so optimizing extraction alone will not close the gap.

## Next Structural Work

1. Add a polygon-output construction mode.
   - Keep the current full-mesh CDT path as the correctness baseline.
   - Prototype a mode that reduces work on exterior triangles after boundary recovery.
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
