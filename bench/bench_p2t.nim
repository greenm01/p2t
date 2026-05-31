import std/[algorithm, math, monotimes, os, strutils, times]

import p2t

const BenchRounds = 5

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

template benchLine(caseName, modeName: string, iterations: int, body: untyped) =
  var times = newSeq[int64](BenchRounds)
  var reportedTriangles = 0
  for round in 0 ..< BenchRounds:
    var workspace {.inject.}: TessWorkspace
    var triangles {.inject.} = 0
    let start = getMonoTime()
    body
    times[round] = inMicroseconds(getMonoTime() - start)
    reportedTriangles = triangles
  times.sort()
  echo caseName & " " & modeName & ": " & $iterations & " runs, " & $reportedTriangles &
    " triangles, best " & $times[0] & " us, median " & $times[BenchRounds div 2] & " us"

proc benchSafe(name: string, iterations: int, input: TessInput) =
  var options = defaultTessOptions()
  options.validate = false
  benchLine(name, "no-validate", iterations):
    for _ in 0 ..< iterations:
      let result = workspace.tessellate(input, options)
      if not result.ok:
        raise newException(ValueError, result.error.message)
      triangles += result.triangles.len

proc benchTrusted(name: string, iterations: int, input: TessInput) =
  let trustedInput = input.oriented()
  benchLine(name, "trusted", iterations):
    for _ in 0 ..< iterations:
      let result = workspace.tessellateTrusted(trustedInput)
      if not result.ok:
        raise newException(ValueError, result.error.message)
      triangles += result.triangles.len

proc benchRaw(name: string, iterations: int, input: TessInput) =
  let trustedInput = input.oriented()
  benchLine(name, "raw", iterations):
    for _ in 0 ..< iterations:
      let result = workspace.tessellateTrustedRaw(trustedInput)
      if not result.ok:
        raise newException(ValueError, result.error.message)
      triangles += result.rawTriangleCount

proc bench(name: string, iterations: int, input: TessInput) =
  benchSafe(name, iterations, input)
  benchTrusted(name, iterations, input)
  benchRaw(name, iterations, input)

bench(
  "small-ui-quad",
  10000,
  TessInput(outer: contour(1, @[vec2(0, 0), vec2(100, 0), vec2(100, 40), vec2(0, 40)])),
)

bench("medium-icon", 2000, TessInput(outer: contour(2, regularPolygon(48, 50))))

bench("large-shape", 500, TessInput(outer: contour(3, regularPolygon(512, 100))))

bench("fixture-test", 10000, TessInput(outer: contour(8, readDat("test.dat"))))

bench("diamond", 10000, TessInput(outer: contour(9, readDat("diamond.dat"))))

bench("star", 10000, TessInput(outer: contour(10, readDat("star.dat"))))

bench(
  "dude-with-holes",
  1000,
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

bench("nazca-monkey", 100, TessInput(outer: contour(7, readDat("nazca_monkey.dat"))))

bench("nazca-heron", 100, TessInput(outer: contour(11, readDat("nazca_heron.dat"))))
