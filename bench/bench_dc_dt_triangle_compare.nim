## Compare DeWall -> dc_dt CDT output against Triangle's unrefined CDT.
##
## Triangle must be compiled without quality refinement (`pzQ`, no `q30`) for
## this to be apples-to-apples: same input vertices, same boundary segments, no
## Steiner points.

import std/[algorithm, os, osproc, sets, strformat, strutils]

import p2t/geometry
import p2t/internal/dc_dt
import p2t/internal/dewall
import p2t/types

type TriKey = array[3, int]

proc readDat(path: string): seq[Vec2] =
  for line in lines(path):
    let trimmed = line.strip()
    if trimmed.len == 0:
      break
    let parts = trimmed.splitWhitespace()
    result.add vec2(parseFloat(parts[0]), parseFloat(parts[1]))

proc key(tri: array[3, int]): TriKey =
  result = tri
  result.sort()

proc lessTriKey(a, b: TriKey): int =
  for i in 0 ..< 3:
    let c = cmp(a[i], b[i])
    if c != 0:
      return c
  0

proc sortedKeys(tris: openArray[array[3, int]]): seq[TriKey] =
  for tri in tris:
    result.add key(tri)
  result.sort(lessTriKey)

proc readKeys(path: string): seq[TriKey] =
  for line in lines(path):
    let trimmed = line.strip()
    if trimmed.len == 0:
      continue
    let parts = trimmed.splitWhitespace()
    result.add [parseInt(parts[0]), parseInt(parts[1]), parseInt(parts[2])]

proc polygonSignedArea(points: openArray[Vec2]): float64 =
  for i in 0 ..< points.len:
    let j = if i == 0: points.high else: i - 1
    result += points[j].x * points[i].y - points[i].x * points[j].y
  result * 0.5

proc polygonAbsArea(points: openArray[Vec2]): float64 =
  abs(polygonSignedArea(points))

proc totalArea(points: openArray[Vec2], tris: openArray[array[3, int]]): float64 =
  for tri in tris:
    result += triangleArea(points[tri[0]], points[tri[1]], points[tri[2]])

proc countInverted(points: openArray[Vec2], tris: openArray[array[3, int]]): int =
  for tri in tris:
    if orient(points[tri[0]], points[tri[1]], points[tri[2]]) <= 0.0:
      inc result

proc countDuplicates(tris: openArray[array[3, int]]): int =
  var seen = initHashSet[TriKey]()
  for tri in tris:
    let k = key(tri)
    if seen.contains(k):
      inc result
    else:
      seen.incl k

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

proc countDelaunayViolations(
    points: openArray[Vec2], tris: openArray[array[3, int]]
): int =
  for tri in tris:
    for i, p in points:
      if i == tri[0] or i == tri[1] or i == tri[2]:
        continue
      if inCircle(points[tri[0]], points[tri[1]], points[tri[2]], p) > 1e-9:
        inc result

proc rawTriangles(raw: DcRawResult): seq[array[3, int]] =
  for i in 0 ..< raw.triangleCount:
    result.add raw.rawTrianglePoints(i)

proc boundarySegments(count: int): seq[array[2, int]] =
  for i in 0 ..< count:
    result.add [i, (i + 1) mod count]

proc report(name: string, points: seq[Vec2], tris: seq[array[3, int]]) =
  let polyArea = polygonAbsArea(points)
  let triArea = totalArea(points, tris)
  echo &"{name}.points,{points.len}"
  echo &"{name}.triangles,{tris.len}"
  echo &"{name}.polygonArea,{polyArea:.17g}"
  echo &"{name}.triangleArea,{triArea:.17g}"
  echo &"{name}.areaError,{abs(triArea - polyArea):.17g}"
  echo &"{name}.inverted,{countInverted(points, tris)}"
  echo &"{name}.duplicates,{countDuplicates(tris)}"
  echo &"{name}.delaunayViolations,{countDelaunayViolations(points, tris)}"

proc mismatchCount(a, b: openArray[TriKey]): int =
  var i = 0
  var j = 0
  while i < a.len and j < b.len:
    let c = lessTriKey(a[i], b[j])
    if c == 0:
      inc i
      inc j
    elif c < 0:
      inc result
      inc i
    else:
      inc result
      inc j
  result += a.len - i
  result += b.len - j

if paramCount() < 1:
  quit(
    "usage: bench_dc_dt_triangle_compare /path/to/triangle_cdt_compare [fixture.dat]",
    QuitFailure,
  )

let
  triangleExe = paramStr(1)
  fixture =
    if paramCount() >= 2: paramStr(2) else: "tests/fixtures/nazca_heron.dat"
  triangleKeysPath = getTempDir() / "p2t_triangle_cdt_compare.tris"
  points = readDat(fixture)
  segments = boundarySegments(points.len)

let triangleRun = execCmdEx(
  quoteShell(triangleExe) & " " & quoteShell(fixture) & " " &
    quoteShell(triangleKeysPath)
)
stdout.write triangleRun.output
if triangleRun.exitCode != 0:
  quit("Triangle comparison executable failed", QuitFailure)

let rawDeWall = dewallTriangulate(points)
report("dewallRaw", points, rawDeWall)

var ws: DcWorkspace
let cdt = ws.triangulateDcCdtRaw(points, segments)
let cdtTris = cdt.raw.rawTriangles
report("dcDtCdt", points, cdtTris)
echo &"dcDtCdt.marked,{cdt.segments.marked}"
echo &"dcDtCdt.missing,{cdt.segments.missing}"
echo &"dcDtCdt.recovered,{cdt.segments.recovered}"
echo &"dcDtCdt.recoveryWork,{cdt.recoveryWork}"

let
  triangleKeys = readKeys(triangleKeysPath)
  dcKeys = sortedKeys(cdtTris)
  mismatches = mismatchCount(triangleKeys, dcKeys)

echo &"compare.exactTriangleSet,{mismatches == 0}"
echo &"compare.triangleSetMismatches,{mismatches}"

if mismatches != 0:
  quit("dc_dt CDT output differs from Triangle pzQ", QuitFailure)
