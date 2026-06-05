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

echo "config,backend,dc_dt-foundation"
echo "config,kernel,dewall-to-dc-topology-foundation"
benchCase("small-random", randomPoints(32, 0xDC32), 200)
benchCase("mid-random", randomPoints(64, 0xDC64), 100)
benchCase("large-random", randomPoints(128, 0xDC128), 30)
benchCase("nazca-heron", readDat("nazca_heron.dat"), 1)
