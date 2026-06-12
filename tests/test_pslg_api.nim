import std/unittest

import p2t
import p2t/pslg

proc totalArea(tess: TessResult): float64 =
  for tri in tess.triangles:
    result += triangleArea(
      tess.vertices[tri[0]],
      tess.vertices[tri[1]],
      tess.vertices[tri[2]]
    )

suite "public p2t PSLG API":
  test "PSLG API is separate from contour workspace":
    var workspace: TessPslgWorkspace
    let input = TessPslgInput(
      points: @[
        vec2(0, 0),
        vec2(4, 0),
        vec2(4, 4),
        vec2(0, 4),
        vec2(2, 2),
      ],
      segments: @[[0, 1], [1, 2], [2, 3], [3, 0], [0, 2]]
    )
    let raw = workspace.tessellatePslgTrustedRaw(input)
    check raw.ok
    check raw.rawTriangleCount > 0
    discard raw.rawTrianglePoints(0)
    discard raw.rawTriangleVertices(0)
    discard raw.rawTriangleNeighborAllocIds(0)

    let result = workspace.tessellatePslgTrusted(input)
    check result.ok
    check result.vertices.len == input.points.len
    check result.triangles.len > 0

    let oneShot = tessellatePslgTrusted(input)
    check oneShot.ok

  test "PSLG API supports hole markers":
    let input = TessPslgInput(
      points: @[
        vec2(0, 0),
        vec2(10, 0),
        vec2(10, 10),
        vec2(0, 10),
        vec2(3, 3),
        vec2(7, 3),
        vec2(7, 7),
        vec2(3, 7),
      ],
      segments: @[
        [0, 1], [1, 2], [2, 3], [3, 0],
        [4, 5], [5, 6], [6, 7], [7, 4],
      ],
      holes: @[vec2(5, 5)]
    )

    let result = tessellatePslgTrusted(input)
    check result.ok
    check abs(result.totalArea - 84.0) <= 1e-9
