import std/unittest

import p2t

when declared(CdtWorkspace) or declared(ArenaWorkspace) or declared(IdxWorkspace):
  {.fatal: "backend workspaces must not be exported by import p2t".}

when declared(tessellateStatic):
  {.fatal: "tessellateStatic must not be exported by import p2t".}

suite "public p2t API":
  test "root module exposes stable tessellation surface":
    var workspace: TessWorkspace
    let input =
      TessInput(outer: contour(1, [vec2(0, 0), vec2(4, 0), vec2(4, 4), vec2(0, 4)]))
    let result = workspace.tessellate(input)
    check result.ok
    check result.vertices.len == 4
    check result.triangles.len == 2

  test "trusted raw access uses accessor procs":
    var workspace: TessWorkspace
    let input =
      TessInput(outer: contour(1, [vec2(0, 0), vec2(4, 0), vec2(4, 4), vec2(0, 4)]))
    let raw = workspace.tessellateTrustedRaw(input)
    check raw.ok
    check raw.rawTriangleCount == 2
    discard raw.rawTrianglePoints(0)
    discard raw.rawTriangleVertices(0)

  test "normalized trusted API is exported":
    var workspace: TessWorkspace
    let input = TessInput(
      outer:
        contour(
          1,
          [
            vec2(0, 0),
            vec2(2, 0),
            vec2(4, 0),
            vec2(4, 4),
            vec2(0, 4),
            vec2(0, 0),
          ],
        )
    )

    let result = workspace.tessellateNormalizedTrusted(input)
    check result.ok
    check result.vertices.len == 4
    check result.triangles.len == 2

    let oneShot = tessellateNormalizedTrusted(input)
    check oneShot.ok

    let raw = workspace.tessellateNormalizedTrustedRaw(input)
    check raw.ok
    check raw.rawTriangleCount == 2
