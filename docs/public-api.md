# Public API guide

This is the guide for using `p2t` from application code. The short version is:
use `tessellate` until you know enough about your input to choose a faster path.

## Basic use

```nim
import p2t

let input = TessInput(
  outer: contour(1, [vec2(0, 0), vec2(4, 0), vec2(4, 4), vec2(0, 4)])
)

let result = tessellate(input)
if not result.ok:
  raise newException(ValueError, result.error.message)

for tri in result.triangles:
  let
    a = result.vertices[tri[0]]
    b = result.vertices[tri[1]]
    c = result.vertices[tri[2]]
  discard (a, b, c)
```

`vertices` is the vertex buffer. `triangles` is a list of three indices into
that buffer.

Contours are closed by the library. Do not repeat the first point at the end
unless you are using a path that says it will remove that point.

## Input shape

`TessInput` has one outer contour, zero or more holes, and optional Steiner
points.

```nim
let input = TessInput(
  outer: contour(10, [vec2(0, 0), vec2(8, 0), vec2(8, 8), vec2(0, 8)]),
  holes: @[
    contour(20, [vec2(1, 1), vec2(1, 2), vec2(2, 2), vec2(2, 1)])
  ],
  steiner: @[vec2(4, 4)]
)
```

Contour ids are for error reporting. They are not used by the triangulator.

The checked path fixes winding. The trusted paths do not. For trusted calls the
outer contour must be counterclockwise and holes must be clockwise.

## Checked path

Use this first:

```nim
let result = tessellate(input)
```

This path removes simple contour noise, fixes winding, validates self
intersections and holes, and returns a `TessResult`.

For repeated calls, keep a workspace:

```nim
var workspace: TessWorkspace
let a = workspace.tessellate(inputA)
let b = workspace.tessellate(inputB)
```

A workspace reuses storage. Do not use the same workspace from multiple threads
at once.

## Options

```nim
var options = defaultTessOptions()
options.validate = false
options.keepBoundaryEdges = true

let result = tessellate(input, options)
```

`cleanInput` removes adjacent duplicate points, a repeated closing point, and
collinear contour points. It does not make invalid geometry valid.

`validate` checks self intersections, hole placement, hole intersections, nested
holes, and Steiner point containment. Turning it off is useful when the input has
already been checked somewhere else.

`keepBoundaryEdges` fills `result.boundaryEdges` with outer and hole edges in
`result.vertices` index space.

## Trusted path

Use `tessellateTrusted` when the input is already clean, valid, and correctly
oriented.

```nim
let result = workspace.tessellateTrusted(input)
```

The contract is strict:

- outer contour is counterclockwise
- holes are clockwise
- no duplicate or degenerate contour points
- no collinear cleanup needed
- contours are simple
- holes are valid
- Steiner points are inside the outer contour

This path skips cleanup and validation. That is why it is faster.

## Normalized trusted path

Use `tessellateNormalizedTrusted` for simple, valid, correctly oriented input
that still has cheap boundary noise.

```nim
let result = workspace.tessellateNormalizedTrusted(input)
```

It removes:

- adjacent duplicate points
- one repeated closing point
- collinear points along contour edges

It does not check self intersections. It does not check holes. It does not fix
winding. It does not remove non-adjacent duplicate points.

This path exists for generated or imported outlines that are valid but verbose.
If the input is already clean, `tessellateTrusted` is still faster.

## Raw path

Use raw results when you need the fastest trusted result and can work with the
workspace-owned mesh.

```nim
var workspace: TessWorkspace
let raw = workspace.tessellateTrustedRaw(input)
if not raw.ok:
  raise newException(ValueError, raw.error.message)

for i in 0 ..< raw.rawTriangleCount:
  let tri = raw.rawTriangleVertices(i)
  discard tri
```

Raw result data is valid only until the workspace is cleared or reused.

There is also a normalized raw path:

```nim
let raw = workspace.tessellateNormalizedTrustedRaw(input)
```

It has the same normalization behavior and the same trusted contract as
`tessellateNormalizedTrusted`.

## Point/Segment Input

Use `p2t/pslg` when your input is already a point buffer with constrained
segments:

```nim
import p2t
import p2t/pslg

let input = TessPslgInput(
  points: @[
    vec2(0, 0), vec2(4, 0), vec2(4, 4), vec2(0, 4),
    vec2(0, 1), vec2(4, 3)
  ],
  boundarySegments: @[[0, 1], [1, 2], [2, 3], [3, 0]],
  segments: @[[4, 5]]
)

var workspace: TessPslgWorkspace
let result = workspace.tessellatePslgTrusted(input)
```

This is the PSLG path: a planar straight-line graph, not a contour object. The
boundary segment set must include a closed outer boundary. Add holes as
constrained inner boundary loops. Put extra constrained edges, such as internal
creases or repair candidates, in `segments`. Hole markers are accepted so
callers can keep the usual PSLG shape, but the current arena backend gets the
hole boundary from the constrained loop itself.

The PSLG API lives in its own module on purpose. Existing contour callers do not
import it, and the ordinary contour hot path does not branch for it.

## Batch use

Use `tessellateBatch` when you have many independent inputs.

```nim
let results = tessellateBatch(inputs)
```

With `--threads:on`, this uses worker threads. Compile threaded callers with
`-d:useMalloc` so result buffers allocated by workers can be owned safely by the
caller.

## C ABI

The C ABI is optional. Build it with:

```sh
nimble buildCAbi
```

A context owns the result arrays:

```c
p2t_context *ctx = p2t_create();
p2t_options options = p2t_default_options();

p2t_result result =
  p2t_tessellate(ctx, outer, holes, hole_count, steiner, steiner_count, &options);

p2t_destroy(ctx);
```

Result pointers stay valid until the next call using that context, `p2t_clear`,
or `p2t_destroy`.

The C ABI also exposes:

- `p2t_tessellate_trusted`
- `p2t_tessellate_normalized_trusted`
- `p2t_tessellate_pslg`

They use the same contracts as the Nim trusted paths. For
`p2t_tessellate_pslg`, pass a flat point array, boundary segment index pairs,
and any extra interior constrained segment pairs. The result arrays have the
same context-owned lifetime as the contour entry points.

## Picking a path

Use this as the default rule:

| Input state | API |
| --- | --- |
| Unknown or user-provided | `tessellate` |
| Valid but you still want boundary cleanup | `tessellate` with `validate = false` |
| Valid, oriented, but has adjacent duplicates or collinear runs | `tessellateNormalizedTrusted` |
| Valid, oriented, and already clean | `tessellateTrusted` |
| Valid, oriented, already clean, and you want minimum materialization | `tessellateTrustedRaw` |
| Valid point/segment PSLG with constrained boundaries | `tessellatePslgTrusted` |

If a trusted path fails, treat that as a broken input contract first. The checked
path is the diagnostic path.
