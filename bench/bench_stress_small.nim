import std/[os, strformat, strutils]

when not defined(p2tCdtStats):
  import std/[algorithm, monotimes, times]

import p2t

when defined(p2tCdtStats):
  when not defined(p2tArenaCdt):
    {.fatal: "bench_stress_small stats require -d:p2tArenaCdt".}
  import p2t/internal/arena_cdt as arena_cdt

when not defined(p2tCdtStats):
  const
    BenchRounds = 11
    StressIterations {.intdefine.} = 5000

const
  StressFixture {.strdefine.} = "cdt_stress.dat"
  StressName {.strdefine.} = "stress-small"

proc cdtBackend(): string =
  when defined(p2tIdxCdt):
    "idx"
  elif defined(p2tArenaCdt):
    "arena"
  else:
    "classic"

proc sortBackend(): string =
  when defined(p2tQuickSort):
    "quicksort"
  elif defined(p2tMergeSort):
    "mergesort"
  elif defined(p2tArenaCdt):
    "pdqsort"
  elif defined(p2tIdxCdt):
    "mergesort"
  else:
    "classic"

proc frontHashConfig(): string =
  when not defined(p2tArenaCdt) and not defined(p2tIdxCdt):
    "not-applicable"
  elif defined(p2tNoFrontHash):
    "off"
  else:
    "on-default-min512"

proc fastRawConfig(): string =
  when defined(p2tFastRawCdt):
    "on"
  else:
    "off"

proc unsafeCdtConfig(): string =
  when defined(p2tUnsafeCdt):
    "on"
  else:
    "off"

proc emitConfig() =
  echo "config,cdtBackend," & cdtBackend()
  echo "config,sortBackend," & sortBackend()
  echo "config,frontHash," & frontHashConfig()
  echo "config,fastRaw," & fastRawConfig()
  echo "config,unsafeCdt," & unsafeCdtConfig()
  echo "config,stressFixture," & StressFixture
  echo "config,stressName," & StressName
  when defined(p2tCdtStats):
    echo "config,cdtStats,on"
  else:
    echo "config,cdtStats,off"
  when defined(p2tFrontHashStats):
    echo "config,frontHashStats,on"
  else:
    echo "config,frontHashStats,off"
  when not defined(p2tCdtStats):
    echo "config,stressIterations," & $StressIterations

proc contour(id: int, points: sink seq[Vec2]): TessContour =
  TessContour(id: id, points: points)

proc readStressDat(name: string): TessInput =
  let path =
    currentSourcePath().parentDir.parentDir / "tests" / "fixtures" / "stress" / name
  var
    rings: seq[seq[Vec2]]
    current: seq[Vec2]

  for line in lines(path):
    let trimmed = line.strip()
    if trimmed.len == 0:
      if current.len > 0:
        rings.add current
        current.setLen(0)
      continue
    let parts = trimmed.splitWhitespace()
    current.add vec2(parseFloat(parts[0]), parseFloat(parts[1]))

  if current.len > 0:
    rings.add current
  if rings.len == 0:
    raise newException(ValueError, "empty stress fixture: " & path)

  result.outer = contour(1, rings[0])
  for i in 1 ..< rings.len:
    result.holes.add contour(i + 1, rings[i])

proc oriented(input: TessInput): TessInput =
  result = input
  result.outer.points.ensureOrientation(ccw = true)
  for hole in result.holes.mitems:
    hole.points.ensureOrientation(ccw = false)

proc areaOf(tess: TessResult): float64 =
  for tri in tess.triangles:
    result +=
      triangleArea(tess.vertices[tri[0]], tess.vertices[tri[1]], tess.vertices[tri[2]])

proc validateStressInput(name: string, input: TessInput) =
  let result = tessellate(input)
  if not result.ok:
    raise newException(ValueError, name & " failed validation: " & result.error.message)

  var expectedArea = polygonArea(input.outer.points)
  var ringVertices = input.outer.points.len
  for hole in input.holes:
    expectedArea -= polygonArea(hole.points)
    ringVertices += hole.points.len

  let areaError = abs(result.areaOf() - expectedArea)
  if areaError >= 1e-5:
    raise newException(
      ValueError, &"{name} area mismatch: error={areaError:.6f}"
    )

  let expectedTriangles = ringVertices + 2 * input.holes.len - 2
  if result.triangles.len != expectedTriangles:
    raise newException(
      ValueError,
      &"{name} triangle-count mismatch: got={result.triangles.len} expected={expectedTriangles}",
    )

  echo &"fixture,{name},points,{ringVertices},holes,{input.holes.len},triangles,{result.triangles.len},areaError,{areaError:.6f}"

when defined(p2tCdtStats):
  proc pointCount(input: TessInput): int =
    result = input.outer.points.len + input.steiner.len
    for hole in input.holes:
      result += hole.points.len

  proc ratio(numer, denom: uint64): float64 =
    if denom == 0:
      0.0
    else:
      numer.float64 / denom.float64

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

when defined(p2tCdtStats):
  proc emitStats(name: string, input: TessInput) =
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

    echo "case,points,triangles,pointEvents,locateSteps,locateStepsPerPoint,fills,fillBasins,legalizeCalls,legalizeEdges,rotations,edgeEvents,edgeWalkSteps,edgeWalkStepsPerEvent,flipEvents,flipScans,flipScansPerEvent,incircleCalls,incircleSuccesses,inScanAreaCalls,mapTriangleToNodesCalls,mapTriangleNodeUpdates,indexCalls,edgeIndexCalls,meshCleanVisits,markNeighborCalls,swapNeighborScans,slotRotations,slotFallbacks,hashHits,hashMisses,frontBucketUpdates"
    when defined(p2tFrontHashStats):
      echo "frontHashWalk,case,tag,count,sum,mean,max,p50,p90,p99,left,right,b0,b1,b2,b3_4,b5_8,b9_16,b17_32,b33_64,b65_128,b129_256,b257_plus"
      echo "frontHashScanRadius,case,radius,count"
    echo &"{name},{points},{triangles},{stats.pointEvents},{stats.locateNodeSteps},{locatePerPoint:.3f},{stats.fills},{stats.fillBasins},{stats.legalizeCalls},{stats.legalizeEdges},{stats.rotations},{stats.edgeEvents},{stats.edgeWalkSteps},{edgeWalkPerEvent:.3f},{stats.flipEvents},{stats.flipScans},{flipScanPerEvent:.3f},{stats.incircleCalls},{stats.incircleSuccesses},{stats.inScanAreaCalls},{stats.mapTriangleToNodesCalls},{stats.mapTriangleNodeUpdates},{stats.indexCalls},{stats.edgeIndexCalls},{stats.meshCleanVisits},{stats.markNeighborCalls},{stats.swapNeighborScans},{stats.slotRotations},{stats.slotFallbacks},{stats.locateNodeHashHits},{stats.locateNodeHashMisses},{stats.frontBucketUpdates}"
    when defined(p2tFrontHashStats):
      emitFrontHashStats(name, stats)

when not defined(p2tCdtStats):
  proc benchRaw(name: string, input: TessInput) =
    let trustedInput = input.oriented()
    var benchTimes = newSeq[int64](BenchRounds)
    var reportedTriangles = 0

    for round in 0 ..< BenchRounds:
      var workspace: TessWorkspace
      var triangles = 0
      let start = getMonoTime()
      for _ in 0 ..< StressIterations:
        let raw = workspace.tessellateTrustedRaw(trustedInput)
        when not defined(p2tFastRawCdt):
          if not raw.ok:
            raise newException(ValueError, raw.error.message)
        triangles += p2t.rawTriangleCount(raw)
      benchTimes[round] = inMicroseconds(getMonoTime() - start)
      reportedTriangles = triangles

    benchTimes.sort()
    echo &"{name} raw: {StressIterations} runs, {reportedTriangles} triangles, best {benchTimes[0]} us, median {benchTimes[BenchRounds div 2]} us, per-best {benchTimes[0].float / StressIterations.float:.3f} us, per-median {benchTimes[BenchRounds div 2].float / StressIterations.float:.3f} us"

emitConfig()

let input = readStressDat(StressFixture)
validateStressInput(StressName, input)
when defined(p2tCdtStats):
  emitStats(StressName, input)
else:
  benchRaw(StressName, input)
