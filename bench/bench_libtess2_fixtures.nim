import std/[algorithm, math, monotimes, os, strutils, times]

import p2t

const
  BenchRounds = 5
  libtess2Dir {.strdefine.} = ""

{.passC: "-I" & libtess2Dir & "/Include".}
{.compile: libtess2Dir & "/Source/bucketalloc.c".}
{.compile: libtess2Dir & "/Source/dict.c".}
{.compile: libtess2Dir & "/Source/geom.c".}
{.compile: libtess2Dir & "/Source/mesh.c".}
{.compile: libtess2Dir & "/Source/priorityq.c".}
{.compile: libtess2Dir & "/Source/sweep.c".}
{.compile: libtess2Dir & "/Source/tess.c".}

type
  TESStesselator {.importc, header: "tesselator.h", incompleteStruct.} = object
  TESSreal = cfloat

proc tessNewTess(alloc: pointer): ptr TESStesselator {.importc, header: "tesselator.h".}
proc tessDeleteTess(tess: ptr TESStesselator) {.importc, header: "tesselator.h".}
proc tessAddContour(
  tess: ptr TESStesselator, size: cint, pointer: pointer, stride: cint, count: cint
) {.importc, header: "tesselator.h".}

proc tessSetOption(
  tess: ptr TESStesselator, option, value: cint
) {.importc, header: "tesselator.h".}

proc tessTesselate(
  tess: ptr TESStesselator,
  windingRule, elementType, polySize, vertexSize: cint,
  normal: ptr TESSreal,
): cint {.importc, header: "tesselator.h".}

proc tessGetElementCount(
  tess: ptr TESStesselator
): cint {.importc, header: "tesselator.h".}

proc tessGetStatus(tess: ptr TESStesselator): cint {.importc, header: "tesselator.h".}

const
  TESS_WINDING_ODD = 0.cint
  TESS_POLYGONS = 0.cint
  TESS_CONSTRAINED_DELAUNAY_TRIANGULATION = 0.cint
  TESS_STATUS_OK = 0.cint

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

proc contourBuffer(points: openArray[Vec2]): seq[TESSreal] =
  result.setLen(points.len * 2)
  for i, point in points:
    result[i * 2] = point.x.TESSreal
    result[i * 2 + 1] = point.y.TESSreal

template benchLine(caseName: string, iterations: int, input: TessInput) =
  var buffers: seq[seq[TESSreal]]
  buffers.add contourBuffer(input.outer.points)
  for hole in input.holes:
    buffers.add contourBuffer(hole.points)

  var times = newSeq[int64](BenchRounds)
  var reportedTriangles = 0
  for round in 0 ..< BenchRounds:
    var triangles = 0
    let start = getMonoTime()
    for _ in 0 ..< iterations:
      let tess = tessNewTess(nil)
      if tess == nil:
        raise newException(ValueError, "libtess2 failed to allocate tesselator")
      try:
        for buffer in buffers:
          tessAddContour(
            tess,
            2,
            unsafeAddr buffer[0],
            (2 * sizeof(TESSreal)).cint,
            (buffer.len div 2).cint,
          )
        tessSetOption(tess, TESS_CONSTRAINED_DELAUNAY_TRIANGULATION, 1)
        if tessTesselate(tess, TESS_WINDING_ODD, TESS_POLYGONS, 3, 2, nil) != 1 or
            tessGetStatus(tess) != TESS_STATUS_OK:
          raise newException(ValueError, "libtess2 failed")
        triangles += tessGetElementCount(tess).int
      finally:
        tessDeleteTess(tess)
    times[round] = inMicroseconds(getMonoTime() - start)
    reportedTriangles = triangles
  times.sort()
  echo caseName & ": " & $iterations & " runs, " & $reportedTriangles &
    " triangles, best " & $times[0] & " us, median " & $times[BenchRounds div 2] & " us"

echo "libtess2"
echo "config,buildFlags,Tier 1 host-tuned Nim/C wrapper"
benchLine(
  "small-ui-quad",
  10000,
  TessInput(outer: contour(1, @[vec2(0, 0), vec2(100, 0), vec2(100, 40), vec2(0, 40)])),
)
benchLine("medium-icon", 2000, TessInput(outer: contour(2, regularPolygon(48, 50))))
benchLine("large-shape", 500, TessInput(outer: contour(3, regularPolygon(512, 100))))
benchLine("fixture-test", 10000, TessInput(outer: contour(8, readDat("test.dat"))))
benchLine("diamond", 10000, TessInput(outer: contour(9, readDat("diamond.dat"))))
benchLine("star", 10000, TessInput(outer: contour(10, readDat("star.dat"))))
benchLine(
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
benchLine(
  "nazca-monkey", 100, TessInput(outer: contour(7, readDat("nazca_monkey.dat")))
)
benchLine("nazca-heron", 100, TessInput(outer: contour(11, readDat("nazca_heron.dat"))))
benchLine("organic-large", 100, readDatRings("organic/cdt_organic_large.dat"))
