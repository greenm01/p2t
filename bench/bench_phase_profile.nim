import std/[math, monotimes, os, strformat, strutils, times]

import p2t
import p2t/internal/arena_cdt as arena_cdt

when not defined(p2tArenaCdt):
  {.fatal: "bench_phase_profile requires -d:p2tArenaCdt".}

when not defined(p2tPhaseProf):
  {.fatal: "bench_phase_profile requires -d:p2tPhaseProf".}

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

proc pct(part, whole: int64): string =
  if whole == 0:
    "  -  "
  else:
    &"{(part.float64 / whole.float64 * 100.0):5.1f}%"

proc phaseLabel(phase: ArenaCdtPhase): string =
  case phase
  of phSetup:
    "setup"
  of phSort:
    "sort"
  of phLocate:
    "locate"
  of phPointEvent:
    "point"
  of phFill:
    "fill"
  of phLegalize:
    "legal"
  of phEdgeEvent:
    "edge"
  of phFinalize:
    "final"

proc report(name: string, iterations: int, input: TessInput) =
  let trustedInput = input.oriented()
  var workspace: TessWorkspace

  # Warm the reusable workspace so the table describes steady-state small-polygon
  # cost, not one-time seq growth on the first iteration.
  discard workspace.tessellateTrustedRaw(trustedInput)

  var
    bestTotalNs = int64.high
    sumTotalNs = 0'i64
    phaseNs: array[ArenaCdtPhase, int64]
    phaseHits: array[ArenaCdtPhase, int64]
    triangles = 0

  for _ in 0 ..< iterations:
    arena_cdt.resetArenaCdtPhaseProf()
    let t0 = getMonoTime()
    let raw = workspace.tessellateTrustedRaw(trustedInput)
    let totalNs = (getMonoTime() - t0).inNanoseconds
    bestTotalNs = min(bestTotalNs, totalNs)
    sumTotalNs += totalNs
    triangles = p2t.rawTriangleCount(raw)

    let snapshot = arena_cdt.arenaCdtPhaseProfSnapshot()
    for phase in ArenaCdtPhase:
      phaseNs[phase] += snapshot.ns[phase]
      phaseHits[phase] += snapshot.hits[phase]

  var attributed = 0'i64
  for phase in ArenaCdtPhase:
    attributed += phaseNs[phase]
  let unattr = max(0'i64, sumTotalNs - attributed)

  echo &"{name},{trustedInput.pointCount},{triangles},{iterations},{bestTotalNs.float64 / 1000.0:.3f},{sumTotalNs.float64 / iterations.float64 / 1000.0:.3f}," &
    &"{pct(phaseNs[phSetup], sumTotalNs)},{pct(phaseNs[phSort], sumTotalNs)},{pct(phaseNs[phLocate], sumTotalNs)}," &
    &"{pct(phaseNs[phPointEvent], sumTotalNs)},{pct(phaseNs[phFill], sumTotalNs)},{pct(phaseNs[phLegalize], sumTotalNs)}," &
    &"{pct(phaseNs[phEdgeEvent], sumTotalNs)},{pct(phaseNs[phFinalize], sumTotalNs)},{pct(unattr, sumTotalNs)}"

  for phase in ArenaCdtPhase:
    echo &"phaseHits,{name},{phaseLabel(phase)},{phaseHits[phase]}"

echo "case,points,triangles,iterations,best_us,mean_us,setup,sort,locate,point,fill,legalize,edge,finalize,unattr"

report(
  "small-ui-quad",
  20000,
  TessInput(outer: contour(1, @[vec2(0, 0), vec2(100, 0), vec2(100, 40), vec2(0, 40)])),
)
report("fixture-test", 20000, TessInput(outer: contour(2, readDat("test.dat"))))
report("diamond", 20000, TessInput(outer: contour(3, readDat("diamond.dat"))))
report("star", 20000, TessInput(outer: contour(4, readDat("star.dat"))))
report("medium-icon", 10000, TessInput(outer: contour(5, regularPolygon(48, 50))))
report(
  "dude-with-holes",
  5000,
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
report("large-shape", 1000, TessInput(outer: contour(9, regularPolygon(512, 100))))
report("stress-small", 1000, readDatRings("stress/cdt_stress.dat"))
