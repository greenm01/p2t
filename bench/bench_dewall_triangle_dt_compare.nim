## Compare experimental DeWall raw point-set DT against Triangle raw DT.
##
## This benchmark does not pass PSLG segments to Triangle. Triangle is compiled
## with `zQ`: zero-based indices, quiet, no quality refinement, unconstrained
## Delaunay triangulation of the input points.

import std/[algorithm, cpuinfo, monotimes, os, osproc, strformat, strutils, times]

import p2t/geometry
import p2t/internal/dewall
import p2t/types

const
  BenchRounds = 5
  Iterations = 100

proc readDat(path: string): seq[Vec2] =
  for line in lines(path):
    let trimmed = line.strip()
    if trimmed.len == 0:
      break
    let parts = trimmed.splitWhitespace()
    result.add vec2(parseFloat(parts[0]), parseFloat(parts[1]))

proc convexHullCount(points: openArray[Vec2]): int =
  let pts = @points
  if pts.len <= 1:
    return pts.len

  var order = newSeq[int](pts.len)
  for i in 0 ..< pts.len:
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

proc validate(points: seq[Vec2], tris: seq[array[3, int]]) =
  let expected = 2 * points.len - 2 - convexHullCount(points)
  doAssert tris.len == expected, &"triangles={tris.len} expected={expected}"
  for tri in tris:
    doAssert orient(points[tri[0]], points[tri[1]], points[tri[2]]) > 0.0

proc benchDewall[Parallel: static[bool]](
    label: string, points: seq[Vec2], options: DewallOptions
) =
  let warm = dewallTriangulateStatic[Parallel](points, options)
  validate(points, warm)

  var elapsed = newSeq[int64](BenchRounds)
  var reportedTriangles = 0
  for round in 0 ..< BenchRounds:
    var triangles = 0
    let start = getMonoTime()
    for _ in 0 ..< Iterations:
      let tris = dewallTriangulateStatic[Parallel](points, options)
      triangles += tris.len
    elapsed[round] = inMicroseconds(getMonoTime() - start)
    reportedTriangles = triangles

  elapsed.sort()
  echo &"dewall-{label}: {Iterations} runs, {reportedTriangles} triangles, " &
    &"best {elapsed[0]} us, median {elapsed[BenchRounds div 2]} us"

proc benchDewallPrepared[Parallel: static[bool]](
    label: string, points: seq[Vec2], options: DewallOptions
) =
  var ws: DewallPreparedWorkspace
  ws.prepareDewallWorkspace(points)

  let warm = dewallTriangulatePreparedStatic[Parallel](ws, options)
  validate(points, warm)

  var elapsed = newSeq[int64](BenchRounds)
  var reportedTriangles = 0
  for round in 0 ..< BenchRounds:
    var triangles = 0
    let start = getMonoTime()
    for _ in 0 ..< Iterations:
      let tris = dewallTriangulatePreparedStatic[Parallel](ws, options)
      triangles += tris.len
    elapsed[round] = inMicroseconds(getMonoTime() - start)
    reportedTriangles = triangles

  elapsed.sort()
  echo &"dewall-{label}: {Iterations} runs, {reportedTriangles} triangles, " &
    &"best {elapsed[0]} us, median {elapsed[BenchRounds div 2]} us"

if paramCount() < 1:
  quit(
    "usage: bench_dewall_triangle_dt_compare /path/to/triangle_dt [fixture.dat]",
    QuitFailure,
  )

let
  triangleExe = paramStr(1)
  fixture =
    if paramCount() >= 2: paramStr(2) else: "tests/fixtures/nazca_heron.dat"

let triangleRun = execCmdEx(
  quoteShell(triangleExe) & " " & quoteShell(fixture) & " " & $Iterations
)
stdout.write triangleRun.output
if triangleRun.exitCode != 0:
  quit("Triangle DT benchmark failed", QuitFailure)

let points = readDat(fixture)
let workers = cpuinfo.countProcessors()

var serialOptions = defaultDewallOptions()
serialOptions.parallel = false
benchDewall[false]("full-serial-dt", points, serialOptions)
benchDewallPrepared[false]("prepared-serial-dt", points, serialOptions)

var autoOptions = defaultDewallOptions()
autoOptions.parallel = true
autoOptions.configureAutoDewallPrewall(points.len, workers)
if autoOptions.prewallLeafTarget <= 1:
  autoOptions.parallel = false

if autoOptions.parallel:
  benchDewall[true]("full-auto-dt", points, autoOptions)
  benchDewallPrepared[true]("prepared-auto-dt", points, autoOptions)
else:
  benchDewall[false]("full-auto-dt", points, autoOptions)
  benchDewallPrepared[false]("prepared-auto-dt", points, autoOptions)
