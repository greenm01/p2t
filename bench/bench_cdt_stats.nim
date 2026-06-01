import std/[math, os, strformat, strutils]

import p2t

when not defined(p2tArenaCdt):
  {.fatal: "bench_cdt_stats requires -d:p2tArenaCdt".}

when not defined(p2tCdtStats):
  {.fatal: "bench_cdt_stats requires -d:p2tCdtStats".}

import p2t/internal/arena_cdt as arena_cdt

proc contour(id: int, points: sink seq[Vec2]): TessContour =
  TessContour(id: id, points: points)

proc regularPolygon(n: int, radius: float64): seq[Vec2] =
  for i in 0 ..< n:
    let angle = 2.0 * PI * float64(i) / float64(n)
    result.add vec2(cos(angle) * radius, sin(angle) * radius)

proc readDat(name: string): seq[Vec2] =
  let path = currentSourcePath().parentDir.parentDir / "tests" / "fixtures" / name
  for line in lines(path):
    let trimmed = line.strip()
    if trimmed.len == 0:
      break
    let parts = trimmed.splitWhitespace()
    result.add vec2(parseFloat(parts[0]), parseFloat(parts[1]))

proc oriented(input: TessInput): TessInput =
  result = input
  result.outer.points.ensureOrientation(ccw = true)
  for hole in result.holes.mitems:
    hole.points.ensureOrientation(ccw = false)

proc pointCount(input: TessInput): int =
  result = input.outer.points.len + input.steiner.len
  for hole in input.holes:
    result += hole.points.len

proc ratio(numer, denom: uint64): float64 =
  if denom == 0:
    0.0
  else:
    numer.float64 / denom.float64

proc report(name: string, input: TessInput) =
  var workspace: TessWorkspace
  let trustedInput = input.oriented()
  let raw = workspace.tessellateTrustedRaw(trustedInput)
  when not defined(p2tFastRawCdt):
    if not raw.ok:
      raise newException(ValueError, raw.error.message)

  let
    stats = arena_cdt.arenaCdtStatsSnapshot()
    points = trustedInput.pointCount()
    triangles = p2t.rawTriangleCount(raw)
    locatePerPoint = stats.locateNodeSteps.ratio(stats.pointEvents)
    edgeWalkPerEvent = stats.edgeWalkSteps.ratio(stats.edgeEvents)
    flipScanPerEvent = stats.flipScans.ratio(stats.flipEvents)

  echo &"{name},{points},{triangles},{stats.pointEvents},{stats.locateNodeSteps},{locatePerPoint:.3f},{stats.fills},{stats.fillBasins},{stats.legalizeCalls},{stats.legalizeEdges},{stats.rotations},{stats.edgeEvents},{stats.edgeWalkSteps},{edgeWalkPerEvent:.3f},{stats.flipEvents},{stats.flipScans},{flipScanPerEvent:.3f},{stats.incircleCalls},{stats.incircleSuccesses},{stats.inScanAreaCalls},{stats.mapTriangleToNodesCalls},{stats.mapTriangleNodeUpdates},{stats.indexCalls},{stats.edgeIndexCalls},{stats.meshCleanVisits},{stats.markNeighborCalls},{stats.swapNeighborScans},{stats.slotRotations},{stats.slotFallbacks},{stats.locateNodeHashHits},{stats.locateNodeHashMisses},{stats.frontBucketUpdates}"

when defined(p2tFrontHash):
  echo "arena CDT stats with front hash"
else:
  echo "arena CDT stats"

echo "case,points,triangles,pointEvents,locateSteps,locateStepsPerPoint,fills,fillBasins,legalizeCalls,legalizeEdges,rotations,edgeEvents,edgeWalkSteps,edgeWalkStepsPerEvent,flipEvents,flipScans,flipScansPerEvent,incircleCalls,incircleSuccesses,inScanAreaCalls,mapTriangleToNodesCalls,mapTriangleNodeUpdates,indexCalls,edgeIndexCalls,meshCleanVisits,markNeighborCalls,swapNeighborScans,slotRotations,slotFallbacks,hashHits,hashMisses,frontBucketUpdates"

report(
  "small-ui-quad",
  TessInput(outer: contour(1, @[vec2(0, 0), vec2(100, 0), vec2(100, 40), vec2(0, 40)])),
)
report("medium-icon", TessInput(outer: contour(2, regularPolygon(48, 50))))
report("large-shape", TessInput(outer: contour(3, regularPolygon(512, 100))))
report("fixture-test", TessInput(outer: contour(8, readDat("test.dat"))))
report("diamond", TessInput(outer: contour(9, readDat("diamond.dat"))))
report("star", TessInput(outer: contour(10, readDat("star.dat"))))
report(
  "dude-with-holes",
  TessInput(
    outer: contour(4, readDat("dude.dat")),
    holes:
      @[
        contour(5, @[vec2(325, 437), vec2(320, 423), vec2(329, 413), vec2(332, 423)]),
        contour(
          6,
          @[
            vec2(320.72342, 480),
            vec2(338.90617, 465.96863),
            vec2(347.99754, 480.61584),
            vec2(329.8148, 510.41534),
            vec2(339.91632, 480.11077),
            vec2(334.86556, 478.09046),
          ],
        ),
      ],
  ),
)
report("nazca-monkey", TessInput(outer: contour(7, readDat("nazca_monkey.dat"))))
report("nazca-heron", TessInput(outer: contour(11, readDat("nazca_heron.dat"))))
