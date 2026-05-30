import std/[math, os, strutils, unittest]

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

proc tessGetVertexCount(
  tess: ptr TESStesselator
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

proc contour(id: int, points: openArray[Vec2]): TessContour =
  TessContour(id: id, points: @points)

proc readDat(name: string): seq[Vec2] =
  let path = currentSourcePath().parentDir / "fixtures" / name
  for line in lines(path):
    let trimmed = line.strip()
    if trimmed.len == 0:
      break
    let parts = trimmed.splitWhitespace()
    result.add vec2(parseFloat(parts[0]), parseFloat(parts[1]))

proc headHole(): TessContour =
  contour(100, [vec2(325, 437), vec2(320, 423), vec2(329, 413), vec2(332, 423)])

proc chestHole(): TessContour =
  contour(
    101,
    [
      vec2(320.72342, 480),
      vec2(338.90617, 465.96863),
      vec2(347.99754, 480.61584),
      vec2(329.8148, 510.41534),
      vec2(339.91632, 480.11077),
      vec2(334.86556, 478.09046),
    ],
  )

proc addContour(
    tess: ptr TESStesselator, points: openArray[Vec2], buffers: var seq[seq[TESSreal]]
) =
  var buffer = newSeq[TESSreal](points.len * 2)
  for i, point in points:
    buffer[i * 2] = point.x.TESSreal
    buffer[i * 2 + 1] = point.y.TESSreal
  buffers.add buffer
  tessAddContour(
    tess, 2, unsafeAddr buffers[^1][0], (2 * sizeof(TESSreal)).cint, points.len.cint
  )

proc tessArea(tess: TessResult): float64 =
  for tri in tess.triangles:
    result +=
      triangleArea(tess.vertices[tri[0]], tess.vertices[tri[1]], tess.vertices[tri[2]])

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

suite "libtess2 comparison":
  test "dude fixture with holes matches libtess2 area and triangle count":
    check libtess2Dir.len > 0

    let
      outer = contour(1, readDat("dude.dat"))
      holes = @[headHole(), chestHole()]
      p2tResult = tessellate(TessInput(outer: outer, holes: holes))

    check p2tResult.ok
    check p2tResult.triangles.len == 106

    let tess = tessNewTess(nil)
    check tess != nil
    try:
      var buffers: seq[seq[TESSreal]]
      addContour(tess, outer.points, buffers)
      for hole in holes:
        addContour(tess, hole.points, buffers)

      tessSetOption(tess, TESS_CONSTRAINED_DELAUNAY_TRIANGULATION, 1)
      check tessTesselate(tess, TESS_WINDING_ODD, TESS_POLYGONS, 3, 2, nil) == 1
      check tessGetStatus(tess) == TESS_STATUS_OK
      check tessGetVertexCount(tess) == 104
      check tessGetElementCount(tess) == 106
      check abs(tessArea(p2tResult) - libtess2Area(tess)) < 1e-2
    finally:
      tessDeleteTess(tess)
