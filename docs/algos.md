# GPU Fill Tessellation Findings

  ## Goal

  The tessellator is intended for immediate-mode GPU UI rendering, not as a general-purpose computational-geometry library. The target is:

  - fast CPU front-end path processing,
  - non-overlapping indexed fill triangles,
  - good triangle quality for GPU rasterization,
  - stable bounded work per frame,
  - reusable workspace allocation,
  - optional stricter CDT behavior only where useful.

  Strict CDT is a useful quality reference, but not the default product goal.

  ## Current State

  The Zig implementation now exposes a renderer-facing `GpuFillTess` workspace API. It supports trusted contour input, triangle/quad fast paths, boundary-edge metadata, diagnostics, and raw/balanced quality modes.

  The complex fallback still delegates to the existing earcut-style triangulator plus local Delaunay flips. That is useful as a baseline, but it is not the final algorithm for beating libtess2/NanoVG.

  Observed benchmark shape:

  - NanoVG scratch fill path is very fast, around `1.8 us/run`, but it emits stencil/fan-style fill vertices, not final non-overlapping GPU fill triangles.
  - libtess2 CDT is much faster than the Nim Poly2Tri CDT path on `dude.dat`.
  - Current Zig fallback is competitive as a prototype but does not yet have libtess2-style hot-path data structures.

  ## Paper Findings

  ### Shewchuk/Brown: Fast Segment Insertion

  Useful as the correctness reference for incremental CDT construction.

  Key takeaways:

  - Start from an unconstrained Delaunay triangulation.
  - Insert constraint segments incrementally.
  - Locate crossed triangles, delete them, and retriangulate the two cavities.
  - Randomized segment insertion avoids bad deterministic structural-change patterns.
  - Segment location is not expected to be the bottleneck.

  Use this for a future `.strict_cdt` mode or as a fallback when faster edge-swap insertion fails.

  ### Stanchev/Paraskevov: Constraining Triangulation to Line Segments

  Most relevant to the GPU-first goal.

  Key takeaways:

  - Insert constraint segments by edge swapping only.
  - Avoid deleting crossed edges and rebuilding cavities.
  - Preserve vertex count.
  - Locally improve affected triangles through additional aspect-ratio-driven edge swaps.

  This fits the desired `.balanced` mode: fast, bounded, renderer-oriented triangle improvement without chasing full geometry-library strictness.

  ### Perumal: New Approaches for Delaunay Triangulation and Optimisation

  Mostly FEM/remeshing-oriented, not a hot UI tessellator design.

  Useful later for:

  - quality metrics: aspect ratio and minimum angle/skewness,
  - optional Steiner/refinement mode,
  - midpoint insertion on longest edge for poor boundary-forced triangles.

  Not recommended for the default immediate-mode fill path.

  ### Held / Mapbox / GeoRust Earcut: FIST-style Ear Clipping

  Useful as a raw triangulation seed and benchmark control, not as the final quality path.

  Key takeaways:

  - FIST-style ear clipping with z-order/geometric hashing is extremely fast on large simple contours.
  - The GeoRust `earcut` port tracks Mapbox Earcut 3.0.2 and is a better reference than the older Zig 0.12 port.
  - Raw ear clipping still creates slivers and can drop collinear/degenerate boundary constraints that the balanced refiner wants to preserve.
  - On current fixtures, the experimental Zig FIST/Earcut seed is much faster than the existing raw fallback for large contours, but it is not coverage-equivalent on every degenerate/complex input.
  - Keep it as an experimental benchmark/backend until deviation and constraint diagnostics are clean enough for renderer use.

  Recommended use:

  - `earcut raw` as a speed baseline,
  - `earcut balanced` as `earcut raw` plus bounded local swaps,
  - no production default switch until area error and missing-boundary behavior are resolved.

  ## Recommended Algorithm Direction

  For the next internal implementation, prioritize a mutable triangle adjacency mesh and edge-swap segment insertion.

  Default `.balanced` pipeline:

  1. Build or reuse an initial triangulation for the submitted contours.
  2. Insert contour edges as constraints using edge swaps.
  3. Preserve boundary edges.
  4. Locally improve affected interior edges using bounded quality swaps.
  5. Emit valid indexed triangles and diagnostics even if the quality budget is exhausted.

  Fallback path:

  - If edge-swap constraint insertion fails or exceeds budget, fall back to Shewchuk/Brown-style cavity insertion or the existing triangulator until the strict path is implemented.

  ## Design Principle

  Optimize for GPU UI behavior first:

  - predictable frame-time cost,
  - low allocation pressure,
  - reasonable triangle quality,
  - low triangle count,
  - no invalid/inverted output,
  - diagnostics instead of unbounded convergence.
