import std/[math, os, strformat, strutils]

import p2t

when defined(p2tIdxCdt) or defined(p2tLegacyCdt):
  {.fatal: "bench_cdt_stats requires the arena CDT backend".}

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

proc sortBackend(): string =
  when defined(p2tQuickSort):
    "quicksort"
  elif defined(p2tMergeSort):
    "mergesort"
  else:
    "pdqsort"

proc frontHashConfig(): string =
  when defined(p2tNoFrontHash):
    "off"
  else:
    "on-default-min512"

proc frontHashStatsConfig(): string =
  when defined(p2tFrontHashStats):
    "on"
  else:
    "off"

proc emitConfig() =
  echo "config,cdtBackend,arena"
  echo "config,sortBackend," & sortBackend()
  echo "config,frontHash," & frontHashConfig()
  echo "config,frontHashStats," & frontHashStatsConfig()
  echo "config,fastRaw,on"
  echo "config,unsafeCdt,on"

when defined(p2tFrontHashStats):
  const FrontHashWalkBinUpper = [
    0'u64, 1'u64, 2'u64, 4'u64, 8'u64, 16'u64, 32'u64, 64'u64, 128'u64, 256'u64,
    257'u64,
  ]

  proc percentile(stats: FrontHashWalkStats, pct: uint64): uint64 =
    if stats.count == 0:
      return 0
    let rank = (stats.count * pct + 99) div 100
    var cumulative = 0'u64
    for i, count in stats.bins:
      cumulative += count
      if cumulative >= rank:
        return FrontHashWalkBinUpper[i]
    FrontHashWalkBinUpper[^1]

  proc emitFrontHashWalk(name, tag: string, stats: FrontHashWalkStats) =
    var line =
      &"frontHashWalk,{name},{tag},{stats.count},{stats.sum},{stats.sum.ratio(stats.count):.3f},{stats.max},{stats.percentile(50)},{stats.percentile(90)},{stats.percentile(99)},{stats.leftWalks},{stats.rightWalks}"
    for count in stats.bins:
      line.add "," & $count
    echo line

  proc emitFrontHashStats(name: string, stats: ArenaCdtStats) =
    emitFrontHashWalk(name, "direct", stats.frontHashDirect)
    emitFrontHashWalk(name, "scan", stats.frontHashScan)
    emitFrontHashWalk(name, "fallback", stats.frontHashFallback)
    for i, count in stats.frontHashScanRadius:
      echo &"frontHashScanRadius,{name},{i + 1},{count}"

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
  when defined(p2tFrontHashStats):
    emitFrontHashStats(name, stats)

when defined(p2tNoFrontHash):
  echo "arena CDT stats without front hash"
elif defined(p2tFrontHashStats):
  echo "arena CDT stats with front hash quality stats"
else:
  echo "arena CDT stats"

emitConfig()

echo "case,points,triangles,pointEvents,locateSteps,locateStepsPerPoint,fills,fillBasins,legalizeCalls,legalizeEdges,rotations,edgeEvents,edgeWalkSteps,edgeWalkStepsPerEvent,flipEvents,flipScans,flipScansPerEvent,incircleCalls,incircleSuccesses,inScanAreaCalls,mapTriangleToNodesCalls,mapTriangleNodeUpdates,indexCalls,edgeIndexCalls,meshCleanVisits,markNeighborCalls,swapNeighborScans,slotRotations,slotFallbacks,hashHits,hashMisses,frontBucketUpdates"
when defined(p2tFrontHashStats):
  echo "frontHashWalk,case,tag,count,sum,mean,max,p50,p90,p99,left,right,b0,b1,b2,b3_4,b5_8,b9_16,b17_32,b33_64,b65_128,b129_256,b257_plus"
  echo "frontHashScanRadius,case,radius,count"

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
