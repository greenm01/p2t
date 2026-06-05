## Experimental Triangle-style D&C DT foundation benchmark.
##
## This measures DeWall feeding the reusable dc_dt topology/flood surface.

import std/[algorithm, monotimes, os, random, strformat, strutils, times]

import p2t/types
import p2t/geometry
import p2t/internal/dc_dt

const BenchRounds = 5

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

proc benchCase(name: string, points: seq[Vec2], iterations: int) =
  var validationWs: DcWorkspace
  let validation = validationWs.triangulateDcDtRaw(points)
  if validation.triangleCount <= 0:
    raise newException(ValueError, "dc_dt validation failed for " & name)

  var times = newSeq[int64](BenchRounds)
  var reportedTriangles = 0
  for round in 0 ..< BenchRounds:
    var ws: DcWorkspace
    ws.reserveDcDt(points.len)
    let start = getMonoTime()
    var triangles = 0
    for _ in 0 ..< iterations:
      let raw = ws.triangulateDcDtRaw(points)
      triangles += raw.triangleCount
    times[round] = inMicroseconds(getMonoTime() - start)
    reportedTriangles = triangles

  times.sort()
  echo &"{name}: {iterations} runs, {reportedTriangles} triangles, " &
    &"best {times[0]} us, median {times[BenchRounds div 2]} us"

proc benchCdtCase(
    name: string,
    points: seq[Vec2],
    segments: seq[array[2, int]],
    iterations: int,
) =
  var validationWs: DcWorkspace
  let validation = validationWs.triangulateDcCdtRaw(points, segments)
  if validation.segments.missing != 0:
    raise newException(ValueError, "dc_dt CDT validation has missing segments for " & name)

  var times = newSeq[int64](BenchRounds)
  var reportedTriangles = 0
  for round in 0 ..< BenchRounds:
    var ws: DcWorkspace
    ws.reserveDcDt(points.len)
    let start = getMonoTime()
    var triangles = 0
    for _ in 0 ..< iterations:
      let raw = ws.triangulateDcCdtRaw(points, segments)
      triangles += raw.raw.triangleCount
    times[round] = inMicroseconds(getMonoTime() - start)
    reportedTriangles = triangles

  times.sort()
  echo &"{name}: {iterations} runs, {reportedTriangles} triangles, " &
    &"best {times[0]} us, median {times[BenchRounds div 2]} us"

proc reportRecoveryCase(
    name: string, points: seq[Vec2], segments: seq[array[2, int]]
) =
  var ws: DcWorkspace
  let raw = ws.triangulateDcCdtRaw(points, segments)
  echo &"{name}: marked {raw.segments.marked}, missing {raw.segments.missing}, " &
    &"recovered {raw.segments.recovered}, recoveryWork {raw.recoveryWork}"

echo "config,backend,dc_dt-foundation"
echo "config,kernel,dewall-to-dc-topology-foundation"
benchCase("small-random", randomPoints(32, 0xDC32), 200)
benchCase("mid-random", randomPoints(64, 0xDC64), 100)
benchCase("large-random", randomPoints(128, 0xDC128), 30)
benchCase("nazca-heron", readDat("nazca_heron.dat"), 1)

benchCdtCase(
  "convex-square-cdt",
  @[vec2(0, 0), vec2(10, 0), vec2(10, 10), vec2(0, 10), vec2(5, 4)],
  @[[0, 1], [1, 2], [2, 3], [3, 0]],
  1000,
)

reportRecoveryCase(
  "convex-square-missing-diagonal",
  @[vec2(0, 0), vec2(10, 0), vec2(10, 10), vec2(0, 10), vec2(5, 4)],
  @[[0, 2]],
)

reportRecoveryCase(
  "multi-edge-segment-recovery",
  @[
    vec2(0, 0),
    vec2(10, 0),
    vec2(10, 10),
    vec2(0, 10),
    vec2(4, 3),
    vec2(6, 7),
    vec2(5, 5),
    vec2(3, 8),
    vec2(8, 4),
  ],
  @[[3, 8]],
)

reportRecoveryCase(
  "through-vertex-segment-chain",
  @[
    vec2(0, 0),
    vec2(10, 0),
    vec2(10, 10),
    vec2(0, 10),
    vec2(4, 3),
    vec2(6, 7),
    vec2(5, 5),
  ],
  @[[0, 2]],
)

reportRecoveryCase(
  "conflicting-diagonals",
  @[vec2(0, 0), vec2(10, 0), vec2(10, 10), vec2(0, 10), vec2(5, 4)],
  @[[0, 1], [1, 2], [2, 3], [3, 0], [0, 2], [1, 3]],
)
