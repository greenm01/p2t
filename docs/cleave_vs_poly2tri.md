# Cleave vs. Poly2tri (Zalik CDT): Architecture and Soundness

This document analyzes the fundamental architectural differences between the **Cleave** triangulation algorithm (detailed in `cleave.md`) and the **Poly2tri / Zalik CDT** (sweep-line) algorithm. It outlines why the Cleave hybrid approach is mathematically more sound and details the roadmap for exceeding Poly2tri's performance.

## 1. The Hybrid Approach: Best of Both Worlds

The Cleave architecture is intentionally designed as a hybrid. It synthesizes the strengths of Zalik's sweep-line approach with the mathematical guarantees of Bowyer-Watson:
- **From Zalik CDT (Sweep-line):** We take the concept of **spatial predictability**. By sorting points along a space-filling curve (Morton/Z-order), we achieve the cache-locality and ordered insertion benefits that make Zalik's sweep-line so incredibly fast.
- **From Bowyer-Watson:** We replace the fragile "advancing front" of the sweep-line with **topological localization**. Instead of maintaining a complex, global front, we insert points sequentially into a mathematically guaranteed Delaunay base mesh via local cavities.
- **Corridor Clearing:** We enforce constraints not by flipping edges iteratively, but by locking an isolated corridor and triangulating it in linear time.

## 2. Robustness: Exact Predicates vs. Advancing Fronts

**Poly2tri / Zalik CDT (Sweep-line):**
Sweep-line algorithms are inherently fragile when dealing with floating-point precision and degenerate geometries (e.g., nearly collinear points, co-circular points). They rely on maintaining a complex "advancing front" data structure. If floating-point roundoff errors corrupt the logic of this front, the algorithm can easily crash, hang, or produce invalid, overlapping geometry.

**Cleave (Hybrid Bowyer-Watson):**
Cleave is built purely on exact geometric predicates (such as robust `orient2d` and `incircle` checks). The Bowyer-Watson insertion method guarantees a mathematically perfect Delaunay mesh at every step. Because point insertion only evaluates and mutates its immediate local cavity, the algorithm is virtually immune to the cascading, systemic failures that plague sweep-line approaches.

## 2. The Concurrency Ceiling

**Poly2tri (Sequential Constraint):**
A sweep-line algorithm is unavoidably sequential. The algorithm cannot safely process point $N$ until it knows the exact state of the advancing front after processing point $N-1$. This sequential dependency makes it practically impossible to efficiently multi-thread a single sweep-line instance across a single mesh.

**Cleave (Infinite Horizontal Scaling):**
The Cleave architecture is designed specifically to shatter this concurrency ceiling:
- **Phase 1 (Spatial Chunking):** By calculating Z-order Morton curves, the point cloud is segmented into geographically isolated chunks.
- **Phase 2 (Concurrent Insertion):** Because a Bowyer-Watson insertion only affects a highly localized neighborhood, multiple threads can safely execute insertions simultaneously in different spatial chunks using isolated, fine-grained atomic spin-locks.
- **Phase 3 (Parallel Corridor Clearing):** Enforcing constraint edges is also fully parallelizable. Threads independently grab line segments, march across the mesh, lock the bounding triangles, and execute isolated retriangulations.

## 3. Single-Threaded Performance Analysis: The Tradeoff

It is highly likely that **Cleave will never beat a highly-optimized Poly2tri implementation on a single, scalar thread.**

An optimized sweep-line algorithm (like `fastpoly2tri`) is incredibly lightweight per-point. It simply evaluates the active front, performs a basic orientation check, and links 1 or 2 new triangles.

Cleave fundamentally performs a heavier "tax" of work per point inserted:
1. It must execute a stochastic walk to find the container triangle.
2. It must calculate exact `incircle` determinants to map the cavity boundaries.
3. It must tombstone old triangles and carefully wire up new internal and external adjacencies.

Our pure-Zig benchmark confirms this reality. Cleave is not designed to win a single-threaded scalar race. It explicitly trades this raw single-threaded speed for absolute mathematical robustness and the ability to scale.

## 4. The Roadmap to Beating Poly2tri

To realize the high-throughput performance envisioned in the Cleave blueprint and surpass Poly2tri, the implementation must be advanced to utilize hardware-level concurrency and vectorization:

1. **SIMD Cavity Evaluation:** Instead of checking adjacent triangles sequentially during point insertion, the engine must load the coordinates of 4 or 8 neighbors into vector registers (`@Vector`) and evaluate the `incircle` determinant on all of them simultaneously in a single CPU cycle.
2. **Multi-threading the Pipeline:** The geographically localized chunks (created by Morton sorting) must be distributed to a thread pool for asynchronous point insertion. Similarly, Corridor Clearing must be dispatched to concurrent workers.
3. **Explicit Prefetching:** Using compiler intrinsics (`@prefetch`) during the stochastic walk and line-marching phases to hide main memory latency behind the CPU's orientation math.

**Conclusion:** 
The Cleave architecture trades a slight increase in scalar algorithmic work for absolute mathematical robustness and the ability to scale linearly across modern multi-core, SIMD-capable CPUs.
