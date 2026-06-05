import std/[algorithm, os, random, sets, strutils, unittest]

import p2t/geometry
import p2t/types
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

proc checkTriangulation(points: seq[Vec2], tris: seq[array[3, int]]) =
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

proc checkDewall(points: seq[Vec2]) =
  checkTriangulation(points, dewallTriangulate(points))

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

suite "DeWall unconstrained DT prototype":
  test "prewall timing estimate uses corrected wall spine":
    let estimate = estimateDewallPrewall(
      pointCount = 1024,
      workers = 8,
      leaves = 4,
      serialUsPerPoint = 2.0,
      wallUsPerSqrtPoint = 1.0,
      imbalance = 1.0,
      leafOverheadUs = 0.0,
    )
    check estimate.walls == 3
    check estimate.effectiveWorkers == 4
    check abs(estimate.serialUs - 2048.0) < 1e-9
    check abs(estimate.wallUs - 77.25483399593904) < 1e-9
    check estimate.totalUs < estimate.serialUs
    check estimate.speedup > 1.0

  test "prewall leaf target chooser respects leaf floor":
    let tiny = chooseDewallPrewallLeafTarget(
      pointCount = 128,
      workers = 12,
      serialUsPerPoint = 2.0,
      wallUsPerSqrtPoint = 1.0,
      minLeafPoints = 256,
    )
    check tiny.leaves == 1
    check tiny.walls == 0

    let large = chooseDewallPrewallLeafTarget(
      pointCount = 4096,
      workers = 12,
      serialUsPerPoint = 2.0,
      wallUsPerSqrtPoint = 1.0,
      imbalance = 1.5,
      minLeafPoints = 256,
      maxLeaves = 24,
    )
    check large.leaves > 1
    check large.leaves <= 16
    check large.speedup > 1.0

  test "auto prewall planner resolves cheap split policy":
    check autoDewallPrewallLeafTarget(128, 12) == 1
    check autoDewallPrewallLeafTarget(1036, 12) == 5
    check autoDewallPrewallMinSplitPoints(1036, 12) == 512
    check autoDewallPrewallLeafTarget(100_000, 12) == 24
    check autoDewallPrewallMinSplitPoints(100_000, 12) == 4166

    var tinyOptions = defaultDewallOptions()
    tinyOptions.configureAutoDewallPrewall(128, 12)
    check tinyOptions.prewallLeafTarget == 0
    check tinyOptions.prewallMinSplitPoints == 512

    var options = defaultDewallOptions()
    options.minParallelPoints = 8
    options.configureAutoDewallPrewall(1036, 12)
    check options.prewallLeafTarget == 5
    check options.prewallMinLeafPoints == 256
    check options.prewallMinSplitPoints == 512
    check options.minParallelPoints == 8

  test "root wall profile reports wall cost":
    let pts = readDat("nazca_heron.dat")
    let profile = profileDewallRootWall(pts)
    check profile.pointCount == pts.len
    check profile.prewallWallCount == 1
    check profile.wallTriangleCount > 0
    check profile.rawTriangleCount == profile.wallTriangleCount
    check profile.dedupedTriangleCount <= profile.rawTriangleCount
    check profile.duplicatesRemoved == profile.rawTriangleCount - profile.dedupedTriangleCount
    check profile.duplicatesRemoved == 0
    check profile.wallUsPerSqrtPoint >= 0.0

  test "prewall profile exposes leaf starvation":
    let pts = readDat("nazca_heron.dat")

    var fixed = defaultDewallOptions()
    fixed.parallel = true
    fixed.prewallLeafTarget = 24
    fixed.prewallMinSplitPoints = 512
    let starved = profileDewallPrewall(pts, fixed)

    var lowerFloor = fixed
    lowerFloor.prewallMinSplitPoints = 128
    let exposed = profileDewallPrewall(pts, lowerFloor)

    check starved.actualLeaves < starved.requestedLeaves
    check exposed.actualLeaves > starved.actualLeaves
    check starved.resolvedPrewallMinSplitPoints == 512
    check exposed.resolvedPrewallMinSplitPoints == 128
    check starved.spawnedTasks == max(0, starved.actualLeaves - 1)
    check exposed.dedupedTriangleCount <= exposed.rawTriangleCount
    check exposed.duplicatesRemoved == exposed.rawTriangleCount - exposed.dedupedTriangleCount
    check starved.duplicatesRemoved == 0
    check exposed.duplicatesRemoved == 0

  test "triangle":
    checkDewall(@[vec2(0, 0), vec2(4, 0), vec2(0, 3)])

  test "square":
    checkDewall(@[vec2(0, 0), vec2(1, 0), vec2(1, 1), vec2(0, 1)])

  test "small random point cloud":
    checkDewall(randomPoints(25, 0x5151))

  test "structured nondegenerate grid":
    var rng = initRand(0x517A)
    var pts: seq[Vec2]
    for y in 0 ..< 5:
      for x in 0 ..< 5:
        pts.add vec2(
          x.float64 + rng.rand(0.23),
          y.float64 + rng.rand(0.23),
        )
    checkDewall(pts)

  test "seeded random point cloud":
    checkDewall(randomPoints(40, 0xD00D))

  test "serial and parallel results match":
    let pts = randomPoints(64, 0xDEAA11)
    let serial = dewallTriangulate(pts)
    var options = defaultDewallOptions()
    options.parallel = true
    options.maxParallelDepth = 3
    options.minParallelPoints = 8
    let parallel = dewallTriangulate(pts, options)
    check normalized(serial) == normalized(parallel)

  test "grid and brute search results match":
    let pts = randomPoints(64, 0xBEEF)
    let grid = dewallTriangulate(pts)
    var bruteOptions = defaultDewallOptions()
    bruteOptions.gridMinPoints = int.high
    let brute = dewallTriangulate(pts, bruteOptions)
    check normalized(grid) == normalized(brute)

  test "prewall output matches serial":
    let pts = randomPoints(128, 0xCAFE)
    let serial = dewallTriangulate(pts)
    var options = defaultDewallOptions()
    options.parallel = true
    options.prewallLeafTarget = 8
    options.prewallMinSplitPoints = 8
    let prewall = dewallTriangulate(pts, options)
    check normalized(prewall) == normalized(serial)

  test "forced deep prewall output matches serial":
    let pts = randomPoints(96, 0xF00D)
    let serial = dewallTriangulate(pts)
    var options = defaultDewallOptions()
    options.parallel = true
    options.prewallLeafTarget = 32
    options.prewallMinSplitPoints = 4
    let prewall = dewallTriangulate(pts, options)
    check normalized(prewall) == normalized(serial)

  test "prewall handles nazca heron point set":
    let pts = readDat("nazca_heron.dat")
    var options = defaultDewallOptions()
    options.parallel = true
    options.prewallLeafTarget = 16
    options.prewallMinSplitPoints = 16
    checkTriangulation(pts, dewallTriangulate(pts, options))
