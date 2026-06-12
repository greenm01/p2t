## Public point/segment constrained tessellation API.
##
## This module is separate from the contour `p2t` root API so existing
## `TessInput` users do not import the point/segment CDT path unless they opt in.

import ./[geometry, types]
import ./internal/dc_dt as dc

type
  TessPslgInput* = object
    ## Point buffer referenced by `segments`.
    points*: seq[Vec2]
    ## Constrained segments as pairs of indices into `points`.
    segments*: seq[array[2, int]]
    ## Optional hole markers. Triangles reachable from each marker across
    ## unconstrained edges are removed from the domain.
    holes*: seq[Vec2]

  TessPslgWorkspace* = object
    dc: dc.DcWorkspace

  TessPslgRawResult* = object
    ok*: bool
    error*: TessError
    vertices*: ptr seq[Vec2]
    raw: dc.DcRawResult

proc validatePslgInput(
    input: TessPslgInput,
    epsilon: float64,
    error: var TessError
): bool =
  if input.points.len < 3:
    error = tessError(
      tekTooFewVertices, -1, input.points.len,
      "point set has fewer than 3 vertices"
    )
    return false
  for i, segment in input.segments:
    if segment[0] < 0 or segment[1] < 0 or
        segment[0] >= input.points.len or segment[1] >= input.points.len:
      error = tessError(
        tekTriangulationFailed, -1, i, "segment index out of range"
      )
      return false
    if segment[0] == segment[1] or
        almostEqual(input.points[segment[0]], input.points[segment[1]], epsilon):
      error = tessError(
        tekDegenerateEdge, -1, i, "zero-length segment"
      )
      return false
  true

proc tessellatePslgTrustedRaw*(
    workspace: var TessPslgWorkspace,
    input: TessPslgInput,
    epsilon = DefaultTessEpsilon
): TessPslgRawResult =
  ## Trusted point/segment CDT path. This is separate from the contour
  ## `TessInput` path, so existing contour tessellation does not pay for PSLG
  ## checks or branches.
  var error = tessError(tekNone)
  if not validatePslgInput(input, epsilon, error):
    return TessPslgRawResult(ok: false, error: error)
  try:
    let cdt = workspace.dc.triangulateDcCdtRaw(input.points, input.segments)
    if cdt.recoveryWork > 0 or cdt.segments.missing > 0:
      return TessPslgRawResult(
        ok: false,
        error: tessError(
          tekTriangulationFailed, -1, -1,
          "constrained point-set CDT has unrecovered segments"
        )
      )
    if input.holes.len > 0:
      workspace.dc.markHoles(input.holes, epsilon)
    TessPslgRawResult(
      ok: true,
      error: tessError(tekNone),
      vertices: addr workspace.dc.points,
      raw: cdt.raw
    )
  except CatchableError as err:
    TessPslgRawResult(
      ok: false, error: tessError(tekTriangulationFailed, -1, -1, err.msg)
    )

proc tessellatePslgTrusted*(
    workspace: var TessPslgWorkspace,
    input: TessPslgInput,
    epsilon = DefaultTessEpsilon
): TessResult =
  ## Materialized trusted point/segment CDT path.
  let raw = workspace.tessellatePslgTrustedRaw(input, epsilon)
  if not raw.ok:
    return failure(raw.error)

  var triangles = newSeqOfCap[array[3, int]](raw.raw.triangleCount)
  for i in 0 ..< raw.raw.triangleCount:
    triangles.add raw.raw.rawTrianglePoints(i)
  var vertices = newSeqOfCap[Vec2](raw.vertices[].len)
  for point in raw.vertices[]:
    vertices.add point
  success(vertices, triangles)

proc rawTriangleCount*(raw: TessPslgRawResult): int {.inline.} =
  ## Return the number of triangles available through a PSLG raw result.
  if not raw.ok:
    return 0
  raw.raw.triangleCount

proc rawTrianglePoints*(
    raw: TessPslgRawResult, triangleIndex: int
): array[3, int] {.inline.} =
  ## Return point ids for one PSLG raw triangle.
  raw.raw.rawTrianglePoints(triangleIndex)

proc rawTriangleAllocId*(
    raw: TessPslgRawResult, triangleIndex: int
): int {.inline.} =
  ## Return the backend allocation id for one PSLG raw triangle.
  raw.raw.rawTriangleId(triangleIndex).int

proc rawTriangleNeighborAllocIds*(
    raw: TessPslgRawResult, triangleIndex: int
): array[3, int] {.inline.} =
  ## Return backend allocation ids for the three PSLG triangle neighbors.
  let neighbors = raw.raw.rawTriangleNeighbors(triangleIndex)
  [neighbors[0].int, neighbors[1].int, neighbors[2].int]

proc rawTriangleVertices*(
    raw: TessPslgRawResult, triangleIndex: int
): array[3, Vec2] {.inline.} =
  ## Return the three vertex coordinates for one PSLG raw triangle.
  let points = raw.rawTrianglePoints(triangleIndex)
  [
    raw.vertices[][points[0]],
    raw.vertices[][points[1]],
    raw.vertices[][points[2]]
  ]

proc tessellatePslgTrusted*(
    input: TessPslgInput,
    epsilon = DefaultTessEpsilon
): TessResult =
  ## Trusted point/segment CDT using a temporary PSLG workspace.
  var workspace: TessPslgWorkspace
  workspace.tessellatePslgTrusted(input, epsilon)
