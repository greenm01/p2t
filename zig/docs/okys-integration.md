# okys Integration Contract

`p2t` is designed to stay independent from okys. It should be consumed as a
small Zig package that turns already-classified fill contours into indexed
triangles. It must not depend on okys types, Sokol, Wayland, NanoVG, or a GPU
backend.

## Boundary

okys owns:

- frontend commands and tagged primitive classification,
- path flattening into closed contours,
- deciding when sparse strips, stencil, analytic SDF, text, or triangles are
  the right backend,
- mesh caching and cache invalidation,
- GPU upload and draw batching,
- edge anti-aliasing policy.

p2t owns:

- trusted contour intake,
- triangle/quad fast paths,
- fallback polygon tessellation,
- bounded triangle-quality improvement,
- optional boundary-edge metadata,
- diagnostics about selected strategy, quality flips, area error, and fallback.

## First okys Use

The first okys integration should be opt-in. Do not replace the existing sparse
strip or stencil paths by default.

Recommended initial routing:

```text
okys classifier says "triangles are useful"
  -> convert each closed PathRange into a p2t contour
  -> GpuFillTess.tessellateFill(.{
       .quality = .balanced,
       .strategy = .auto,
       .validation = .trusted,
       .keep_boundary_edges = true only when the caller needs edge metadata,
     })
  -> expand indexed triangles into okys Vertex triangles for v1
  -> later replace expansion with an indexed mesh draw path
```

Use `.strict_cdt` only for comparison/debug paths. Keep `.experimental_fist`
behind explicit benchmark or developer flags until its rejection path is cheap
enough for `.auto`.

## Data Conversion

For each okys `PathRange` selected for p2t:

- require `closed == true`,
- require `point_count >= 3`,
- copy `Point.x` and `Point.y` into `GpuFillTess.Vec`,
- pass outer contours as `.solid`,
- pass known holes as `.hole` after their owning solid,
- leave winding normalization to p2t.

For v1, route only clean/cacheable complex fills to p2t. Dirty, ambiguous, or
self-intersecting paths should remain on stencil/libtess-style fallback paths.

## Package Consumption

During local development, okys can consume p2t as a local Zig package:

```zig
const dep_p2t = b.dependency("p2t", .{
    .target = target,
    .optimize = optimize,
});
okys_mod.addImport("p2t", dep_p2t.module("p2t"));
```

The matching `build.zig.zon` dependency should point at the local
`../p2t/zig` package while the prototype is being proven:

```zig
.dependencies = .{
    .p2t = .{
        .path = "../p2t/zig",
    },
},
```

## Acceptance Criteria

- okys integration must compile without importing p2t private files.
- p2t tests and benchmarks must continue to run outside okys.
- p2t must remain backend-neutral and allocation-explicit.
- okys defaults must not change until the p2t path has fixture coverage,
  visual comparison, and performance data.
