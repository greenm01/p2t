import std/[math, os, strformat, strutils]

import p2t
import p2t/internal/arena_cdt as arena_cdt

when not defined(p2tArenaCdt):
  {.fatal: "bench_incircle_profile requires -d:p2tArenaCdt".}

when not defined(p2tCdtStats):
  {.fatal: "bench_incircle_profile requires -d:p2tCdtStats".}

when not defined(p2tIncircleProf):
  {.fatal: "bench_incircle_profile requires -d:p2tIncircleProf".}

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

proc readDatRings(name: string): TessInput =
  let path = currentSourcePath().parentDir.parentDir / "tests" / "fixtures" / name
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
    raise newException(ValueError, "empty fixture: " & path)

  result.outer = contour(1, rings[0])
  for i in 1 ..< rings.len:
    result.holes.add contour(i + 1, rings[i])

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

proc percent(numer, denom: uint64): float64 =
  numer.ratio(denom) * 100.0

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
    skipped =
      stats.legalizeNilNeighbors + stats.legalizeSkipDelaunay +
      stats.legalizeSkipConstrained + stats.legalizeSkipOppositeDelaunay
    unclassified =
      if stats.legalizeEdges >= stats.incircleCalls + skipped:
        stats.legalizeEdges - stats.incircleCalls - skipped
      else:
        0'u64

  echo &"{name},{points},{triangles},{stats.legalizeCalls},{stats.legalizeEdges},{stats.incircleCalls},{stats.incircleSuccesses},{stats.rotations},{stats.incircleCalls.ratio(stats.pointEvents):.3f},{stats.incircleCalls.ratio(stats.incircleSuccesses):.3f},{stats.incircleSuccesses.percent(stats.incircleCalls):.2f},{stats.legalizeNilNeighbors.percent(stats.legalizeEdges):.2f},{stats.legalizeSkipDelaunay.percent(stats.legalizeEdges):.2f},{stats.legalizeSkipConstrained.percent(stats.legalizeEdges):.2f},{stats.legalizeSkipOppositeDelaunay.percent(stats.legalizeEdges):.2f},{unclassified.percent(stats.legalizeEdges):.2f}"

echo "case,points,triangles,legalizeCalls,legalizeEdges,incircleTests,incircleSuccesses,rotations,testsPerPoint,testsPerSuccess,successPct,nilNeighborPct,skipDelaunayPct,skipConstrainedPct,skipOppositeDelaunayPct,unclassifiedSkipPct"

report(
  "small-ui-quad",
  TessInput(outer: contour(1, @[vec2(0, 0), vec2(100, 0), vec2(100, 40), vec2(0, 40)])),
)
report("fixture-test", TessInput(outer: contour(2, readDat("test.dat"))))
report("diamond", TessInput(outer: contour(3, readDat("diamond.dat"))))
report("star", TessInput(outer: contour(4, readDat("star.dat"))))
report("medium-icon", TessInput(outer: contour(5, regularPolygon(48, 50))))
report(
  "dude-with-holes",
  TessInput(
    outer: contour(6, readDat("dude.dat")),
    holes:
      @[
        contour(7, @[vec2(325, 437), vec2(320, 423), vec2(329, 413), vec2(332, 423)]),
        contour(
          8,
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
report("large-shape", TessInput(outer: contour(9, regularPolygon(512, 100))))
report("stress-small", readDatRings("stress/cdt_stress.dat"))
