import std/[monotimes, os, strformat, strutils, times]

import p2t

const libtess2Dir {.strdefine.} = ""

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
  TESSindex = cint

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

proc tessGetVertices(
  tess: ptr TESStesselator
): ptr TESSreal {.importc, header: "tesselator.h".}

proc tessGetElementCount(
  tess: ptr TESStesselator
): cint {.importc, header: "tesselator.h".}

proc tessGetElements(
  tess: ptr TESStesselator
): ptr TESSindex {.importc, header: "tesselator.h".}

proc tessGetStatus(tess: ptr TESStesselator): cint {.importc, header: "tesselator.h".}

const
  TESS_WINDING_ODD = 0.cint
  TESS_POLYGONS = 0.cint
  TESS_CONSTRAINED_DELAUNAY_TRIANGULATION = 0.cint
  TESS_UNDEF = -1.cint
  TESS_STATUS_OK = 0.cint

proc contour(id: int, points: sink seq[Vec2]): TessContour =
  TessContour(id: id, points: points)

proc readDat(name: string): seq[Vec2] =
  let path = currentSourcePath().parentDir.parentDir / "tests" / "fixtures" / name
  for line in lines(path):
    let trimmed = line.strip()
    if trimmed.len == 0:
      break
    let parts = trimmed.splitWhitespace()
    result.add vec2(parseFloat(parts[0]), parseFloat(parts[1]))

proc dudeInput(): TessInput =
  TessInput(
    outer: contour(1, readDat("dude.dat")),
    holes:
      @[
        contour(2, @[vec2(325, 437), vec2(320, 423), vec2(329, 413), vec2(332, 423)]),
        contour(
          3,
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
  )

proc tessArea(tess: TessResult): float64 =
  for tri in tess.triangles:
    result +=
      triangleArea(tess.vertices[tri[0]], tess.vertices[tri[1]], tess.vertices[tri[2]])

proc contourBuffer(points: openArray[Vec2]): seq[TESSreal] =
  result.setLen(points.len * 2)
  for i, point in points:
    result[i * 2] = point.x.TESSreal
    result[i * 2 + 1] = point.y.TESSreal

proc libtess2Area(tess: ptr TESStesselator): float64 =
  let vertices = cast[ptr UncheckedArray[TESSreal]](tessGetVertices(tess))
  let elements = cast[ptr UncheckedArray[TESSindex]](tessGetElements(tess))
  for i in 0 ..< tessGetElementCount(tess).int:
    let
      a = elements[i * 3]
      b = elements[i * 3 + 1]
      c = elements[i * 3 + 2]
    if a == TESS_UNDEF or b == TESS_UNDEF or c == TESS_UNDEF:
      continue
    result +=
      triangleArea(
        vec2(vertices[a.int * 2].float64, vertices[a.int * 2 + 1].float64),
        vec2(vertices[b.int * 2].float64, vertices[b.int * 2 + 1].float64),
        vec2(vertices[c.int * 2].float64, vertices[c.int * 2 + 1].float64),
      )

proc printBench(
    name: string, iterations, triangles: int, micros: int64, area: float64
) =
  let perRun = micros.float64 / iterations.float64
  echo &"{name}: {iterations} runs, {triangles} triangles, {micros} us, {perRun:.2f} us/run, area={area:.6f}"

proc benchP2tWorkspace(input: TessInput, iterations: int) =
  var workspace: TessWorkspace
  var triangles = 0
  var area = 0.0
  let start = getMonoTime()
  for i in 0 ..< iterations:
    let result = workspace.tessellate(input)
    if not result.ok:
      raise newException(ValueError, result.error.message)
    triangles += result.triangles.len
    if i == 0:
      area = tessArea(result)
  printBench(
    "p2t workspace", iterations, triangles, inMicroseconds(getMonoTime() - start), area
  )

proc benchP2tOneShot(input: TessInput, iterations: int) =
  var triangles = 0
  var area = 0.0
  let start = getMonoTime()
  for i in 0 ..< iterations:
    let result = tessellate(input)
    if not result.ok:
      raise newException(ValueError, result.error.message)
    triangles += result.triangles.len
    if i == 0:
      area = tessArea(result)
  printBench(
    "p2t one-shot", iterations, triangles, inMicroseconds(getMonoTime() - start), area
  )

proc benchLibtess2(input: TessInput, iterations: int) =
  var buffers: seq[seq[TESSreal]]
  buffers.add contourBuffer(input.outer.points)
  for hole in input.holes:
    buffers.add contourBuffer(hole.points)

  var triangles = 0
  var area = 0.0
  let start = getMonoTime()
  for i in 0 ..< iterations:
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
      if i == 0:
        area = libtess2Area(tess)
    finally:
      tessDeleteTess(tess)
  printBench(
    "libtess2", iterations, triangles, inMicroseconds(getMonoTime() - start), area
  )

let
  input = dudeInput()
  iterations = 1000

echo "dude.dat with two holes"
benchP2tWorkspace(input, iterations)
benchP2tOneShot(input, iterations)
benchLibtess2(input, iterations)
