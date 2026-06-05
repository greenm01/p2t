## Focused timing for the experimental DeWall -> dc_dt CDT path on heron.
##
## This is intentionally separate from the production p2t raw benchmark. It
## measures the current experimental pipeline that uses DeWall as the DT
## producer and dc_dt for segment recovery plus flood cleanup.

import std/[algorithm, monotimes, os, strformat, strutils, times]

import p2t/geometry
import p2t/internal/dc_dt
import p2t/types

const
  BenchRounds = 5
  Iterations = 100

proc readDat(name: string): seq[Vec2] =
  let path = currentSourcePath().parentDir.parentDir / "tests" / "fixtures" / name
  for line in lines(path):
    let trimmed = line.strip()
    if trimmed.len == 0:
      break
    let parts = trimmed.splitWhitespace()
    result.add vec2(parseFloat(parts[0]), parseFloat(parts[1]))

proc boundarySegments(count: int): seq[array[2, int]] =
  for i in 0 ..< count:
    result.add [i, (i + 1) mod count]

proc benchHeron() =
  let
    points = readDat("nazca_heron.dat")
    segments = boundarySegments(points.len)

  var validateWs: DcWorkspace
  let validation = validateWs.triangulateDcCdtRaw(points, segments)
  doAssert validation.raw.triangleCount == 1034
  doAssert validation.segments.missing == 0
  doAssert validation.recoveryWork == 0

  var elapsed = newSeq[int64](BenchRounds)
  var reportedTriangles = 0
  for round in 0 ..< BenchRounds:
    var ws: DcWorkspace
    ws.reserveDcDt(points.len)
    var triangles = 0
    let start = getMonoTime()
    for _ in 0 ..< Iterations:
      let raw = ws.triangulateDcCdtRaw(points, segments)
      triangles += raw.raw.triangleCount
    elapsed[round] = inMicroseconds(getMonoTime() - start)
    reportedTriangles = triangles

  elapsed.sort()
  echo &"dewall-dc_dt-cdt-heron: {Iterations} runs, {reportedTriangles} " &
    &"triangles, best {elapsed[0]} us, median {elapsed[BenchRounds div 2]} us"

echo "config,backend,dewall-dc_dt-cdt"
echo "config,kernel,dewall-raw-dt-plus-dc_dt-segment-recovery-flood"
benchHeron()
