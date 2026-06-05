## Diagnostic DeWall profile runner.
##
## This is intentionally separate from bench_dewall.nim so profile counters and
## coarse timing never contaminate the pure timing benchmark.

import std/[cpuinfo, monotimes, os, random, strformat, strutils, times]

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

proc timeSerial(points: seq[Vec2]): tuple[us: float64, triangles: int] =
  let start = getMonoTime()
  let tris = dewallTriangulateStatic[false](points)
  result.us = inMicroseconds(getMonoTime() - start).float64
  result.triangles = tris.len

proc profileFor(points: seq[Vec2], workers, floor: int): DewallProfile =
  var options = defaultDewallOptions()
  options.parallel = true
  options.prewallLeafTarget = max(2, workers * 2)
  options.prewallMinSplitPoints = floor
  profileDewallPrewall(points, options)

proc autoProfileFor(points: seq[Vec2], workers: int): DewallProfile =
  var options = defaultDewallOptions()
  options.parallel = true
  options.configureAutoDewallPrewall(points.len, workers)
  profileDewallPrewall(points, options)

proc echoProfile(label: string, profile: DewallProfile) =
  echo &"  {label:<11} leaves={profile.actualLeaves:>3}/{profile.requestedLeaves:<3} " &
    &"spawn={profile.spawnedTasks:<3} walls={profile.prewallWallCount:<3} " &
    &"split={profile.resolvedPrewallMinSplitPoints:<5} " &
    &"wallTris={profile.wallTriangleCount:<6} wallUs={profile.wallUs:>9.2f} " &
    &"leafPts={profile.leafMinPoints}/{profile.leafMeanPoints:.1f}/{profile.leafMaxPoints} " &
    &"raw={profile.rawTriangleCount:<7} dedup={profile.dedupedTriangleCount:<7} " &
    &"dups={profile.duplicatesRemoved}"

proc echoEstimate(label: string, estimate: DewallPrewallEstimate) =
  echo &"  model {label:<8} leaves={estimate.leaves:<3} walls={estimate.walls:<3} " &
    &"time={estimate.totalUs:>10.2f}us speedup={estimate.speedup:>5.2f}x"

proc runCase(name: string, points: seq[Vec2]) =
  let
    workers = countProcessors()
    serial = timeSerial(points)
    c = if points.len > 0: serial.us / points.len.float64 else: 0.0
    rootWall = profileDewallRootWall(points)
    w = rootWall.wallUsPerSqrtPoint
    maxLeaves = max(2, workers * 2)
    fixed512 = profileFor(points, workers, 512)
    fixed256 = profileFor(points, workers, 256)
    fixed128 = profileFor(points, workers, 128)
    autoProfile = autoProfileFor(points, workers)

  echo &"{name}: {points.len} points, {serial.triangles} triangles, workers={workers}"
  echo &"  serial       {serial.us:10.2f}us  c={c:.4f}us/point"
  echo &"  root wall    {rootWall.wallUs:10.2f}us  w={w:.4f}us/sqrt(point) " &
    &"wallTris={rootWall.wallTriangleCount}"

  echoEstimate(
    "512",
    chooseDewallPrewallLeafTarget(
      points.len, workers, c, w, minLeafPoints = 512, maxLeaves = maxLeaves
    ),
  )
  echoEstimate(
    "256",
    chooseDewallPrewallLeafTarget(
      points.len, workers, c, w, minLeafPoints = 256, maxLeaves = maxLeaves
    ),
  )
  echoEstimate(
    "128",
    chooseDewallPrewallLeafTarget(
      points.len, workers, c, w, minLeafPoints = 128, maxLeaves = maxLeaves
    ),
  )
  echoEstimate(
    "auto",
    chooseDewallPrewallLeafTarget(
      points.len,
      workers,
      c,
      w,
      minLeafPoints = autoProfile.resolvedPrewallMinLeafPoints,
      maxLeaves = maxLeaves,
    ),
  )

  echoProfile("fixed512", fixed512)
  echoProfile("fixed256", fixed256)
  echoProfile("fixed128", fixed128)
  echoProfile("auto", autoProfile)
  echo ""

runCase("uniform-1k", randomPoints(1_000, 0xD311A11))
runCase("nazca-heron", readDat("nazca_heron.dat"))
runCase("uniform-10k", randomPoints(10_000, 0xD311A12))
runCase("uniform-50k", randomPoints(50_000, 0xD311A13))
runCase("uniform-100k", randomPoints(100_000, 0xD311A14))
