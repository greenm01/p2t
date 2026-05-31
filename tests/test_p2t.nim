import std/[math, os, sequtils, strutils, unittest]

import p2t

proc contour(id: int, points: openArray[Vec2]): TessContour =
  TessContour(id: id, points: @points)

proc areaOf(tess: TessResult): float64 =
  for tri in tess.triangles:
    result +=
      triangleArea(tess.vertices[tri[0]], tess.vertices[tri[1]], tess.vertices[tri[2]])

proc checkArea(result: TessResult, expected: float64) =
  check result.ok
  check abs(areaOf(result) - expected) < 1e-6

proc readDat(name: string): seq[Vec2] =
  let path = currentSourcePath().parentDir / "fixtures" / name
  for line in lines(path):
    let trimmed = line.strip()
    if trimmed.len == 0:
      break
    let parts = trimmed.splitWhitespace()
    result.add vec2(parseFloat(parts[0]), parseFloat(parts[1]))

proc headHole(): TessContour =
  contour(100, [vec2(325, 437), vec2(320, 423), vec2(329, 413), vec2(332, 423)])

proc chestHole(): TessContour =
  contour(
    101,
    [
      vec2(320.72342, 480),
      vec2(338.90617, 465.96863),
      vec2(347.99754, 480.61584),
      vec2(329.8148, 510.41534),
      vec2(339.91632, 480.11077),
      vec2(334.86556, 478.09046),
    ],
  )

proc stalactiteHole(): TessContour =
  contour(
    102,
    [
      vec2(980, 1636),
      vec2(950, 1600),
      vec2(650, 1230),
      vec2(625, 1247),
      vec2(600, 1250),
      vec2(591, 1350),
      vec2(550, 2050),
    ],
  )

proc fixtureCase(name: string, holes: seq[TessContour] = @[]) =
  let outer = contour(1, readDat(name))
  let input = TessInput(outer: outer, holes: holes)
  let result = tessellate(input)
  let expectedArea = polygonArea(outer.points) - holes.mapIt(polygonArea(it.points)).sum
  check result.ok
  check result.triangles.len > 0
  for tri in result.triangles:
    check tri[0] >= 0 and tri[0] < result.vertices.len
    check tri[1] >= 0 and tri[1] < result.vertices.len
    check tri[2] >= 0 and tri[2] < result.vertices.len
  check abs(areaOf(result) - expectedArea) < 1e-5

suite "p2t tessellation":
  test "triangle":
    let input = TessInput(outer: contour(1, [vec2(0, 0), vec2(4, 0), vec2(0, 3)]))
    let result = tessellate(input)
    check result.triangles.len == 1
    checkArea(result, 6)

  test "quad":
    let input =
      TessInput(outer: contour(1, [vec2(0, 0), vec2(4, 0), vec2(4, 4), vec2(0, 4)]))
    let result = tessellate(input)
    check result.triangles.len == 2
    checkArea(result, 16)

  test "concave polygon":
    let input = TessInput(
      outer: contour(1, [vec2(0, 0), vec2(4, 0), vec2(4, 4), vec2(2, 2), vec2(0, 4)])
    )
    let result = tessellate(input)
    check result.triangles.len == 3
    checkArea(result, 12)

  test "polygon with a hole":
    let input = TessInput(
      outer: contour(1, [vec2(0, 0), vec2(5, 0), vec2(5, 5), vec2(0, 5)]),
      holes: @[contour(2, [vec2(1, 1), vec2(1, 2), vec2(2, 2), vec2(2, 1)])],
    )
    let result = tessellate(input)
    checkArea(result, 24)

  test "multiple holes":
    let input = TessInput(
      outer: contour(1, [vec2(0, 0), vec2(8, 0), vec2(8, 8), vec2(0, 8)]),
      holes:
        @[
          contour(2, [vec2(1, 1), vec2(1, 2), vec2(2, 2), vec2(2, 1)]),
          contour(3, [vec2(5, 5), vec2(5, 6), vec2(6, 6), vec2(6, 5)]),
        ],
    )
    let result = tessellate(input)
    checkArea(result, 62)

  test "Steiner points are accepted and retained":
    let input = TessInput(
      outer: contour(1, [vec2(0, 0), vec2(4, 0), vec2(4, 4), vec2(0, 4)]),
      steiner: @[vec2(2, 2)],
    )
    let result = tessellate(input)
    check result.ok
    check result.vertices.len == 5

  test "boundary metadata":
    var options = defaultTessOptions()
    options.keepBoundaryEdges = true
    let input =
      TessInput(outer: contour(1, [vec2(0, 0), vec2(4, 0), vec2(4, 4), vec2(0, 4)]))
    let result = tessellate(input, options)
    check result.ok
    check result.boundaryEdges.len == 4

  test "trusted path matches default for clean oriented input":
    let input = TessInput(
      outer: contour(1, [vec2(0, 0), vec2(5, 0), vec2(5, 5), vec2(0, 5)]),
      holes: @[contour(2, [vec2(1, 1), vec2(1, 2), vec2(2, 2), vec2(2, 1)])],
    )
    let safe = tessellate(input)
    let trusted = tessellateTrusted(input)
    check safe.ok
    check trusted.ok
    check trusted.vertices == safe.vertices
    check trusted.triangles == safe.triangles
    checkArea(trusted, 24)

  test "trusted raw path exposes workspace triangles":
    var workspace: TessWorkspace
    let input =
      TessInput(outer: contour(1, [vec2(0, 0), vec2(4, 0), vec2(4, 4), vec2(0, 4)]))
    let raw = workspace.tessellateTrustedRaw(input)
    check raw.ok
    check raw.rawTriangleCount == 2
    let tri = raw.rawTriangleVertices(0)
    check triangleArea(tri[0], tri[1], tri[2]) > 0

suite "original poly2tri fixtures":
  test "small fixture polygons":
    for name in ["test.dat", "diamond.dat", "star.dat", "strange.dat"]:
      fixtureCase(name)

  test "dude fixture with holes":
    fixtureCase("dude.dat", @[headHole(), chestHole()])

  test "stalactite fixture with hole":
    fixtureCase("stalactite.dat", @[stalactiteHole()])

  test "large nazca fixtures":
    fixtureCase("nazca_monkey.dat")
    fixtureCase("nazca_heron.dat")

suite "p2t validation":
  test "duplicate point":
    let input =
      TessInput(outer: contour(1, [vec2(0, 0), vec2(4, 0), vec2(0, 4), vec2(4, 0)]))
    let result = tessellate(input)
    check not result.ok
    check result.error.kind in {tekDuplicatePoint, tekTooFewVertices}

  test "too few vertices":
    let input = TessInput(outer: contour(1, [vec2(0, 0), vec2(4, 0)]))
    let result = tessellate(input)
    check not result.ok
    check result.error.kind == tekTooFewVertices

  test "self intersection":
    let input =
      TessInput(outer: contour(1, [vec2(0, 0), vec2(4, 4), vec2(0, 4), vec2(4, 0)]))
    let result = tessellate(input)
    check not result.ok
    check result.error.kind == tekSelfIntersection

  test "hole outside outer":
    let input = TessInput(
      outer: contour(1, [vec2(0, 0), vec2(4, 0), vec2(4, 4), vec2(0, 4)]),
      holes: @[contour(2, [vec2(5, 5), vec2(6, 5), vec2(6, 6), vec2(5, 6)])],
    )
    let result = tessellate(input)
    check not result.ok
    check result.error.kind == tekInvalidHole
