import std/[algorithm, os, random, sets, strutils, unittest]

import p2t/geometry
import p2t/types
import p2t/internal/dc_dt
import p2t/internal/dewall

type TriKey = array[3, int]

proc key(tri: array[3, int]): TriKey =
  result = tri
  result.sort()

proc inCircle(a, b, c, d: Vec2): float64 =
  let
    ax = a.x - d.x
    ay = a.y - d.y
    bx = b.x - d.x
    by = b.y - d.y
    cx = c.x - d.x
    cy = c.y - d.y
    d1 = (ax * ax + ay * ay) * (bx * cy - cx * by)
    d2 = (bx * bx + by * by) * (ax * cy - cx * ay)
    d3 = (cx * cx + cy * cy) * (ax * by - bx * ay)
  d1 - d2 + d3

proc convexHullCount(points: openArray[Vec2]): int =
  let pts = @points
  if pts.len <= 1:
    return pts.len
  var order = newSeq[int](points.len)
  for i in 0 ..< points.len:
    order[i] = i
  order.sort(
    proc(a, b: int): int =
      let cx = cmp(pts[a].x, pts[b].x)
      if cx != 0:
        cx
      else:
        cmp(pts[a].y, pts[b].y)
  )

  var lower: seq[int]
  for id in order:
    while lower.len >= 2 and
        orient(pts[lower[^2]], pts[lower[^1]], pts[id]) <= 1e-12:
      discard lower.pop()
    lower.add id

  var upper: seq[int]
  for i in countdown(order.high, 0):
    let id = order[i]
    while upper.len >= 2 and
        orient(pts[upper[^2]], pts[upper[^1]], pts[id]) <= 1e-12:
      discard upper.pop()
    upper.add id

  lower.len + upper.len - 2

proc randomPoints(count: int, seed: int64): seq[Vec2] =
  var rng = initRand(seed)
  for _ in 0 ..< count:
    result.add vec2(rng.rand(1000.0), rng.rand(1000.0))

proc readDat(name: string): seq[Vec2] =
  let path = currentSourcePath().parentDir / "fixtures" / name
  for line in lines(path):
    let trimmed = line.strip()
    if trimmed.len == 0:
      break
    let parts = trimmed.splitWhitespace()
    result.add vec2(parseFloat(parts[0]), parseFloat(parts[1]))

proc normalized(tris: seq[array[3, int]]): seq[TriKey] =
  for tri in tris:
    result.add key(tri)
  result.sort(
    proc(a, b: TriKey): int =
      for i in 0 ..< 3:
        let c = cmp(a[i], b[i])
        if c != 0:
          return c
      0
  )

proc checkDelaunay(points: seq[Vec2], tris: seq[array[3, int]]) =
  let expected = 2 * points.len - 2 - convexHullCount(points)
  check tris.len == expected

  var seen = initHashSet[TriKey]()
  for tri in tris:
    check tri[0] >= 0 and tri[0] < points.len
    check tri[1] >= 0 and tri[1] < points.len
    check tri[2] >= 0 and tri[2] < points.len
    check orient(points[tri[0]], points[tri[1]], points[tri[2]]) > 0
    check not seen.contains(key(tri))
    seen.incl key(tri)

    for i, p in points:
      if i == tri[0] or i == tri[1] or i == tri[2]:
        continue
      check inCircle(points[tri[0]], points[tri[1]], points[tri[2]], p) <= 1e-9

proc rawTriangles(raw: DcRawResult): seq[array[3, int]] =
  for i in 0 ..< raw.triangleCount:
    result.add raw.rawTrianglePoints(i)

proc checkNeighborSymmetry(raw: DcRawResult) =
  let ws = raw.workspace[]
  for triIndex in 0 ..< raw.triangleCount:
    let triId = raw.rawTriangleId(triIndex)
    let tri = ws.triangles[triId]
    for edge in 0 ..< 3:
      let neighbor = tri.neighbors[edge]
      if neighbor == DcNil:
        continue
      var foundBack = false
      for otherEdge in 0 ..< 3:
        if ws.triangles[neighbor].neighbors[otherEdge] == triId:
          foundBack = true
      check foundBack

proc totalArea(points: seq[Vec2], raw: DcRawResult): float64 =
  for tri in raw.rawTriangles:
    result += triangleArea(
      points[tri[0]],
      points[tri[1]],
      points[tri[2]],
    )

suite "experimental Triangle-style D&C DT foundation":
  test "raw point cloud DT is Delaunay":
    let pts = randomPoints(32, 0xDCD7)
    checkDelaunay(pts, triangulateDcDt(pts))

  test "dc_dt topology preserves DeWall triangle set":
    let pts = randomPoints(40, 0xD00D)
    let dewallTris = dewallTriangulate(pts)
    var ws: DcWorkspace
    let raw = ws.loadDcDtTriangles(pts, dewallTris)
    check normalized(raw.rawTriangles) == normalized(dewallTris)
    checkNeighborSymmetry(raw)

  test "raw arena topology wires symmetric neighbors":
    let pts = randomPoints(40, 0xD00D)
    var ws: DcWorkspace
    let raw = ws.triangulateDcDtRaw(pts)
    checkDelaunay(pts, raw.rawTriangles)
    checkNeighborSymmetry(raw)

  test "raw heron point cloud is Delaunay":
    let pts = readDat("nazca_heron.dat")
    checkDelaunay(pts, triangulateDcDt(pts))

  test "workspace can be reused across sizes":
    let
      small = randomPoints(16, 0x5151)
      large = randomPoints(64, 0x6161)
    var ws: DcWorkspace
    let first = normalized(ws.triangulateDcDtRaw(small).rawTriangles)
    let second = normalized(ws.triangulateDcDtRaw(large).rawTriangles)
    let third = normalized(ws.triangulateDcDtRaw(small).rawTriangles)
    check first == third
    check second.len > first.len

  test "protected convex hull blocks exterior flood":
    let pts = @[
      vec2(0, 0),
      vec2(10, 0),
      vec2(10, 10),
      vec2(0, 10),
      vec2(5, 4),
    ]
    var ws: DcWorkspace
    let raw = ws.triangulateDcDtRaw(pts)
    let before = raw.triangleCount
    let marked = ws.markProtectedSegments(
      @[[0, 1], [1, 2], [2, 3], [3, 0]]
    )
    check marked.missing == 0
    ws.markExterior()
    check ws.rawTriangles.len == before

  test "DeWall-to-dc CDT raw keeps protected convex boundary interior":
    let pts = @[
      vec2(0, 0),
      vec2(10, 0),
      vec2(10, 10),
      vec2(0, 10),
      vec2(5, 4),
    ]
    let segments = @[[0, 1], [1, 2], [2, 3], [3, 0]]
    var ws: DcWorkspace
    let cdt = ws.triangulateDcCdtRaw(pts, segments)
    check cdt.segments.marked == segments.len
    check cdt.segments.missing == 0
    check abs(totalArea(pts, cdt.raw) - 100.0) <= 1e-9

  test "DeWall-to-dc CDT raw reports unrecovered missing segments":
    let pts = @[
      vec2(0, 0),
      vec2(10, 0),
      vec2(10, 10),
      vec2(0, 10),
      vec2(5, 4),
    ]
    var ws: DcWorkspace
    let cdt = ws.triangulateDcCdtRaw(pts, @[[0, 2]])
    check cdt.segments.missing == 1

  test "unprotected hull flood removes everything":
    let pts = randomPoints(20, 0xABCD)
    var ws: DcWorkspace
    discard ws.triangulateDcDtRaw(pts)
    ws.markExterior()
    check ws.rawTriangles.len == 0
