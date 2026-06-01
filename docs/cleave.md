This is the complete, unified architectural blueprint for a multi-threaded Constrained Delaunay Triangulation engine. It synthesizes the spatial predictability of a sweep-line front-end, the topological localization of a Bowyer-Watson back-end, and a high-performance Corridor Clearing strategy for constraint recovery—all layered over a highly optimized, data-oriented memory architecture.

The Global Data Layout (Structure of Arrays)
To maximize memory bandwidth and ensure cache lines are never wasted on unused data, the entire triangulation is stored globally in a single flat Structure of Arrays (SoA). All pointers are replaced with 32-bit integer indices (int32_t).

Global Mesh (SoA)
├── Vertices:  [ float* X ] [ float* Y ]
├── Topology:  [ int32_t* T_v0 ]  [ int32_t* T_v1 ]  [ int32_t* T_v2 ]
├── Adjacency: [ int32_t* T_adj0 ] [ int32_t* T_adj1 ] [ int32_t* T_adj2 ]
└── Sync:      [ std::atomic<uint8_t>* T_locks ]
Phase 1: Spatial Sorting (The Sweep Influence)
To eliminate the strict sequential constraints of a physical sweep-line while retaining its cache-locality benefits, we use a 2D spatial sweep via a Space-Filling Curve.

The 1D Map: Calculate the 32-bit or 64-bit Morton code (Z-order curve) for every unconstrained point and constraint endpoint based on their coordinates.

Sequential Sort: Sort the entire vertex array by these codes. This step can be multi-threaded using a parallel radix sort.

Block Chunking: Segment the sorted array into linear blocks (e.g., 8,000 to 16,000 points per block) and assign each block to a thread in a work-stealing pool. Because of the curve's properties, each thread is now automatically localized to a tight geometric cluster in 2D space.

Phase 2: Concurrent Unconstrained Insertion (Localized Bowyer-Watson)
Threads execute asynchronously across their assigned spatial chunks to construct the base Delaunay mesh.

1. Spatial Search & Prefetching
Because points are processed in spatial order, the next point to be inserted is almost always inside or adjacent to the previously created triangle.

The thread executes a localized stochastic walk to locate the containing triangle.

Optimization: Before evaluating the current triangle T, the thread issues a __builtin_prefetch on the vertex and adjacency arrays for the triangles pointed to by T_adj0, T_adj1, and T_adj2. This hides main memory latency behind the orientation math. Search time approaches O(1).

2. SIMD Cavity Evaluation
Once the containing triangle is found, the thread evaluates adjacent triangles to find all circumcircle violations and map the Bowyer-Watson cavity.

Optimization: The thread loads the coordinates of the new point into SIMD broadcast registers. Using AVX2 or AVX-512, it pulls the coordinates of 4 or 8 neighboring triangles from the SoA arrays simultaneously. It runs the floating-point InCircle determinant filter in parallel, returning a bitmask of triangles that must be added to the cavity. (If a result is inside the arithmetic error bound, it falls back to a scalar exact predicate).

3. Thread-Local Tombstoning & Locking
Locking: The thread attempts to acquire atomic spinlocks on the T_locks entries for all triangles in the cavity. If a lock fails (indicating contention at a chunk boundary), the thread backs off, releases all acquired locks, and moves the point to a deferred queue.

Memory Management: To avoid global heap locks, each thread maintains an isolated memory arena. Deleting a triangle does not free memory; it writes the triangle's index to a thread-local freelist stack. New triangles overwrite these tombstoned slots directly in the global SoA.

Phase 3: Concurrent Constraint Recovery (Corridor Clearing)
Once unconstrained insertion is complete, the engine transitions to enforcing fixed edges using a highly parallel, isolated Corridor Clearing strategy.

1. Independent Line-Marching
Constraint segments are distributed via a global thread-safe queue. A thread grabs a segment and traces its path from endpoint A to endpoint B across the mesh by hopping through the T_adj indices.

Optimization: As the thread computes line intersections to step through the mesh, it uses __builtin_prefetch on the next adjacent triangle down the line, ensuring zero CPU stalls during the corridor trace.

2. Static Bounding Locks
Instead of iteratively flipping edges and dynamically expanding the lock footprint, the thread identifies the complete list of triangles pierced by the segment.

It acquires atomic locks on the outer ring of un-pierced triangles that border this corridor.

Once the outer boundary is locked, the thread has established an isolated, secure zone. No topological changes can leak outside this perimeter, completely neutralizing concurrency risks with neighboring threads.

3. Corridor Clearing & Linear Triangulation
Clearing: The thread marks all pierced triangles within the corridor as tombstones and pushes their indices to its local freelist. It extracts the boundary vertices of the left and right walls of the cleared cavity.

Linear Triangulation: The constraint segment splits the cavity into two independent pseudo-polygons (one on the left, one on the right). Because every vertex on these boundaries is strictly visible from the constraint line, they are optimized for a highly specialized, stack-based triangulation loop.

The thread processes the left and right halves entirely within its L1/L2 cache using small local arrays, executing in strict O(n) time (where n is the number of intersected triangles).

4. Coalesced Write-Back
Once the new triangles for both sides of the constraint are computed, the thread performs a burst write-back to the global SoA:

It overwrites the tombstoned indices with the newly generated triangle vertex and adjacency data.

It hooks up the new internal edges to the locked outer boundary triangles.

It releases the static bounding locks.

By isolating the constraint recovery to a fixed bounding box and resolving it via linear-time pseudo-polygon triangulation, the engine eliminates cascading topological dependencies, guarantees thread safety without rolling back edge-flips, and maximizes memory throughput.
