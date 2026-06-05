## Diagnostic DeWall hot-path counters.
##
## Build only with -d:p2tDewallHotStats. This intentionally prioritizes
## counter visibility over benchmark purity.

import std/[cpuinfo, monotimes, os, random, strformat, strutils, times]

import p2t/types
import p2t/geometry
import p2t/internal/dewall

when not defined(p2tDewallHotStats):
  {.fatal: "bench_dewall_hot_stats requires -d:p2tDewallHotStats".}

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

proc runHot(name, mode: string, points: seq[Vec2], options: DewallOptions) =
  let start = getMonoTime()
  let hot = dewallTriangulateWithHotStats(points, options)
  let elapsed = inMicroseconds(getMonoTime() - start)
  let s = hot.stats
  echo &"hot,{name},{mode},points,{points.len},triangles,{hot.triangles.len}," &
    &"us,{elapsed},makeSimplexFast,{s.makeSimplexFastCalls}," &
    &"makeSimplexBrute,{s.makeSimplexBruteCalls},candidateTests,{s.candidateTests}," &
    &"acceptedCandidates,{s.acceptedCandidates},gridBoxScans,{s.gridBoxScans}," &
    &"gridCellsVisited,{s.gridCellsVisited},duplicateCellSkips,{s.duplicateCellSkips}," &
    &"scanUnmarkedCalls,{s.scanUnmarkedCalls},unmarkedCellsVisited,{s.unmarkedCellsVisited}," &
    &"wallEdgesProcessed,{s.wallEdgesProcessed},wallTrianglesEmitted,{s.wallTrianglesEmitted}," &
    &"gridsBuilt,{s.gridsBuilt},gridCellsAllocated,{s.gridCellsAllocated}," &
    &"splitSorts,{s.splitSorts}"

proc runCase(name: string, points: seq[Vec2]) =
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

  runHot(name, "serial", points, serialOptions)
  runHot(name, "parallel", points, parallelOptions)
  runHot(name, "fixed512", points, fixedPrewallOptions)
  runHot(name, "auto", points, autoPrewallOptions)

runCase("uniform-1k", randomPoints(1_000, 0xD311A11))
runCase("nazca-heron", readDat("nazca_heron.dat"))
runCase("uniform-10k", randomPoints(10_000, 0xD311A12))
runCase("uniform-50k", randomPoints(50_000, 0xD311A13))
runCase("uniform-100k", randomPoints(100_000, 0xD311A14))
