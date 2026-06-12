## Public point/segment constrained tessellation API.
##
## This module is separate from the contour `p2t` root API so existing
## `TessInput` users do not import the point/segment path unless they opt in.

import ./[geometry, types]
import ./internal/arena_cdt as cdt

when defined(p2tIdxCdt) or defined(p2tLegacyCdt):
  {.fatal: "p2t/pslg requires the default arena CDT backend".}

type
  TessPslgInput* = object
    ## Point buffer referenced by `boundarySegments` and `segments`.
    points*: seq[Vec2]
    ## Domain boundary segments as pairs of indices into `points`.
    boundarySegments*: seq[array[2, int]]
    ## Interior constrained segments as pairs of indices into `points`.
    segments*: seq[array[2, int]]
    ## Optional hole markers. In the production arena path, constrained inner
    ## loops bound holes; markers are accepted so callers can share one PSLG
    ## shape with the C ABI and future backends.
    holes*: seq[Vec2]

  TessPslgWorkspace* = object
    workspace: TessWorkspace

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
  if input.boundarySegments.len < 3:
    error = tessError(
      tekTooFewVertices, -1, input.boundarySegments.len,
      "boundary segment set has fewer than 3 edges"
    )
    return false
  for i, segment in input.boundarySegments:
    if segment[0] < 0 or segment[1] < 0 or
        segment[0] >= input.points.len or segment[1] >= input.points.len:
      error = tessError(
        tekTriangulationFailed, -1, i, "boundary segment index out of range"
      )
      return false
    if segment[0] == segment[1] or
        almostEqual(input.points[segment[0]], input.points[segment[1]], epsilon):
      error = tessError(
        tekDegenerateEdge, -1, i, "zero-length boundary segment"
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

template rawSuccess(raw: untyped): TessRawResult =
  TessRawResult(
    ok: true,
    error: tessError(tekNone),
    vertices: raw.vertices,
    arena: raw.arena
  )

proc tessellatePslgTrustedRaw*(
    workspace: var TessPslgWorkspace,
    input: TessPslgInput,
    epsilon = DefaultTessEpsilon
): TessRawResult =
  ## Trusted point/segment CDT path. This is separate from the contour
  ## `TessInput` path, so existing contour tessellation does not pay for PSLG
  ## checks or branches.
  var error = tessError(tekNone)
  if not validatePslgInput(input, epsilon, error):
    return TessRawResult(ok: false, error: error)
  try:
    let raw = workspace.workspace.triangulatePslgRaw(
      input.points,
      input.boundarySegments,
      input.segments
    )
    rawSuccess(raw)
  except CatchableError as err:
    TessRawResult(
      ok: false,
      error: tessError(tekTriangulationFailed, -1, -1, err.msg)
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

  var triangles = newSeqOfCap[array[3, int]](raw.rawTriangleCount)
  for i in 0 ..< raw.rawTriangleCount:
    let tri = raw.rawTriangleSourcePoints(i)
    if tri[0] >= 0 and tri[1] >= 0 and tri[2] >= 0:
      triangles.add tri

  var vertices = newSeqOfCap[Vec2](raw.vertices[].len)
  for point in raw.vertices[]:
    vertices.add point
  success(vertices, triangles)

proc tessellatePslgTrusted*(
    input: TessPslgInput,
    epsilon = DefaultTessEpsilon
): TessResult =
  ## Trusted point/segment CDT using a temporary PSLG workspace.
  var workspace: TessPslgWorkspace
  workspace.tessellatePslgTrusted(input, epsilon)
