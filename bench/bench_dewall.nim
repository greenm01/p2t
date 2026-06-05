## Experimental DeWall DT benchmark.
##
## This measures only the prototype unconstrained point-set triangulator. It is
## intentionally separate from the public CDT benchmarks.

import std/[algorithm, cpuinfo, monotimes, os, random, strformat, strutils, times]

import p2t/types
import p2t/geometry
import p2t/internal/dewall

proc randomPoints(count: int, seed: int64): seq[Vec2] =
  var rng = initRand(seed)
  for _ in 0 ..< count:
    result.add vec2(rng.rand(1000.0), rng.rand(1000.0))

proc readDat(name: string): seq[Vec2] =
  let path = currentSourcePath().parentDir.parentDir / "tests" / "fixtures" / name
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
      if cx != 0: cx else: cmp(pts[a].y, pts[b].y)
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
    doAssert orient(points[tri[0]], points[tri[1]], points[tri[2]]) > 0

proc benchOne[Parallel: static[bool]](
    label: string, points: seq[Vec2], iterations: int, options: DewallOptions
) =
  let warm = dewallTriangulateStatic[Parallel](points, options)
  validate(points, warm)

  var best = int64.high
  var totalTriangles = 0
  for _ in 0 ..< 3:
    let start = getMonoTime()
    var triangles = 0
    for _ in 0 ..< iterations:
      let tris = dewallTriangulateStatic[Parallel](points, options)
      triangles += tris.len
    let elapsed = inMicroseconds(getMonoTime() - start)
    if elapsed < best:
      best = elapsed
      totalTriangles = triangles

  let
    usPerRun = best.float64 / iterations.float64
    trisPerSec = totalTriangles.float64 / (best.float64 / 1_000_000.0)
  echo &"  {label:<9} {usPerRun:10.2f} us/run  {trisPerSec:12.0f} tris/s"

proc runCase(name: string, points: seq[Vec2], iterations: int) =
  let workers = countProcessors()
  var serialOptions = defaultDewallOptions()
  serialOptions.parallel = false

  var parallelOptions = defaultDewallOptions()
  parallelOptions.parallel = true
  parallelOptions.maxParallelDepth = 4
  parallelOptions.minParallelPoints = 8

  var fixedPrewallOptions = parallelOptions
  fixedPrewallOptions.prewallLeafTarget = max(2, workers * 2)
  fixedPrewallOptions.prewallMinSplitPoints = 512

  var autoPrewallOptions = parallelOptions
  autoPrewallOptions.configureAutoDewallPrewall(points.len, workers)
  if autoPrewallOptions.prewallLeafTarget <= 1:
    autoPrewallOptions.parallel = false

  let tris = dewallTriangulateStatic[false](points, serialOptions)
  echo &"{name}: {points.len} points, {tris.len} triangles, {iterations} iterations"
  benchOne[false]("serial", points, iterations, serialOptions)
  benchOne[true]("parallel", points, iterations, parallelOptions)
  benchOne[true]("fixed512", points, iterations, fixedPrewallOptions)
  if autoPrewallOptions.parallel:
    benchOne[true]("auto", points, iterations, autoPrewallOptions)
  else:
    benchOne[false]("auto", points, iterations, autoPrewallOptions)
  echo ""

proc runCase(name: string, count, iterations: int) =
  runCase(name, randomPoints(count, count.int64 * 7919 + 17), iterations)

runCase("small-random", 32, 200)
runCase("mid-random", 64, 100)
runCase("large-random", 128, 30)
runCase("nazca-heron", readDat("nazca_heron.dat"), 1)
