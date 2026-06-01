# Cleave vs. Poly2tri: Architecture, Tradeoffs, and Roadmap

This document compares the Cleave constrained-Delaunay triangulation direction with
Poly2tri / Zalik-style sweep-line CDT. The goal is not to claim that one design is
universally better. The important engineering question is which workload each design
can win, what costs are inherent, and what must be measured before making stronger
performance claims.

## 1. Algorithmic Shape

Poly2tri is a sweep-line/front algorithm. Its scalar hot path is extremely small:
maintain the advancing front, place the next point, perform orientation tests, and
link a small number of triangles. That gives it excellent latency on small polygons
and makes it a difficult single-core target.

Cleave is a hybrid:

- Morton ordering keeps point insertion spatially local.
- Bowyer-Watson insertion builds a Delaunay base mesh via local cavities.
- Constraint recovery clears a corridor and retriangulates the two resulting
  pseudo-polygons.
- The mesh is represented with flat index-based storage rather than pointer-heavy
  topology.

This trades a heavier scalar insertion path for stronger locality, clearer mutation
boundaries, and a plausible path toward safe parallel mutation.

## 2. Robustness Tradeoff

The sweep-line/front approach is fast partly because it does less work per point.
It also depends on the advancing front remaining topologically consistent under
floating-point decisions. Well-engineered sweep implementations can be reliable, but
degenerate inputs and near-degenerate predicates are an important risk area.

Cleave's Bowyer-Watson core leans more directly on geometric predicates such as
`orient2d` and `incircle`. The default predicate policy is adaptive and can fall
back to exact `f128` arithmetic. That is a robustness advantage, but it is not free:
exact fallback can dominate some runs, and even the adaptive filter costs more than
a minimal scalar front update.

The right framing is: Cleave buys robustness and mutation isolation with additional
per-point work.

## 3. Performance Reality Today

Current small-fixture measurements show the tradeoff clearly. Robust Cleave is much
faster than earlier versions, but fast-poly2tri still wins scalar latency on the
overlapping fixtures.

Approximate recent robust Cleave timings:

- `fixture-test`: about `0.91 us/run`
- `diamond`: about `2.58 us/run`
- `star`: about `2.02 us/run`

Against fast-poly2tri on the same small fixtures, Cleave is still roughly `4-6x`
slower. The exact ratio varies by run, compiler, CPU state, and float/double mode,
but the conclusion is stable: Poly2tri remains the scalar latency target.

Cleave also has an unsafe measurement mode, `-Dpredicate-policy=fast`, which removes
exact fallback and shows a lower performance ceiling. That mode is useful for
isolating predicate cost, but it is not the correctness baseline.

## 4. Amdahl's Law and Throughput

The phrase "infinite horizontal scaling" is not accurate for a single triangulation.
Amdahl's law still applies:

```text
speedup(N) = 1 / (serial_fraction + parallel_fraction / N + overhead)
```

Single-mesh latency is bounded by work that is serial or effectively serial:

- input setup and spatial ordering
- chunk boundary conflicts and retries
- long constraints that cross many chunks
- exact predicate fallback
- final extraction/validation
- memory bandwidth and cache-coherence pressure

Cleave's more realistic advantage is throughput. There are two distinct scaling
modes:

- **Batch throughput:** many independent polygons or triangulation jobs distributed
  across workers. This is the easiest and most likely near-term win because workers
  do not share a mutable mesh.
- **Large single-mesh throughput/latency:** one large mesh split into spatial chunks.
  This can work if mutations stay local and conflict rates are low, but it requires
  careful transaction design and real contention measurements.

Small fixtures are the wrong place to expect thread-level latency wins. Queueing,
thread wakeup, locking, and barriers can cost more than fast-poly2tri spends on the
entire triangulation.

## 5. SIMD and Prefetching

SIMD and prefetching are useful, but they should be treated as measured experiments,
not guaranteed wins.

SIMD can help the floating-point filter portion of cavity evaluation by testing
several candidate triangles together. It does not remove the scalar exact fallback,
nor does it solve irregular topology traversal. SIMD is most promising when cavity
frontiers can be batched without excessive gather/scatter overhead.

Prefetching can help stochastic walks and corridor traces when memory latency is the
bottleneck. It can also hurt by increasing bandwidth pressure or prefetching the
wrong neighbor. It should be added only around measured cache-miss hot paths and kept
only if perf counters improve.

## 6. Roadmap

The next work should stay measurement-first. Current Cleave-specific benchmark
coverage now includes:

- `zig build bench-batch` for independent-job throughput across worker counts.
- `zig build bench-single` for larger single-mesh latency with insertion versus
  constraint-recovery timing.
- `zig build bench-single -Dinstrument-predicates=true` for predicate call and exact
  fallback counters.

Recent larger-fixture diagnostic measurements show insertion dominates constraint
recovery:

- `dude`: about `43 us/run`, roughly `26 us` insertion and `16 us` constraints.
- `nazca-monkey`: about `771 us/run`, roughly `591 us` insertion and `178 us`
  constraints.
- `nazca-heron`: about `931 us/run`, roughly `729 us` insertion and `199 us`
  constraints.

The instrumented adaptive run showed many predicate calls but very few exact
orientation fallbacks and no exact incircle fallbacks on these fixtures. That means
the immediate scalar bottleneck is mostly regular topology traversal, cavity work,
and memory traffic, not exact-predicate fallback.

1. Add a batch-throughput benchmark.
   Measure many independent triangulations across `1, 2, 4, 8, ...` workers. Reuse
   per-thread engines and arenas. Compare wall time, jobs/sec, and scaling efficiency.

2. Add a larger single-mesh benchmark.
   The current fixtures are too small to judge threaded mesh mutation. Add fixtures
   large enough to expose chunking, conflict rate, memory bandwidth, and predicate
   fallback behavior.

3. Instrument parallel-readiness metrics.
   Track lock attempts, lock failures, retries, deferred points, corridor lengths,
   exact predicate fallback counts, and time spent in insertion versus constraint
   recovery.

4. Prototype coarse job-level parallelism first.
   This validates the runtime, worker setup, per-thread memory reuse, and benchmark
   reporting without adding shared-mesh transaction complexity.

5. Prototype chunked single-mesh insertion after measurement exists.
   Start with Morton chunks, per-thread deferred queues, strict transaction
   revalidation, and serial cleanup for high-conflict leftovers.

6. Treat SIMD and prefetch as opt-in experiments.
   Keep adaptive predicates as the default. Add SIMD or prefetch behind build flags,
   benchmark both robust and fast predicate policies, and remove experiments that do
   not improve measured throughput.

## Conclusion

Cleave should not be sold as a guaranteed scalar replacement for fast-poly2tri. The
engineering case is different: robust CDT construction, data-oriented mutation, and a
path to throughput scaling on workloads large enough to amortize coordination costs.
The next milestone is not another claim of parallelism; it is benchmark evidence
showing where Cleave actually scales.
