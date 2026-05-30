## Delaunay triangle-quality comparison between p2t and libtess2.
##
## Reports per-triangle angle statistics (min angle is the standard Delaunay
## quality measure: a Delaunay triangulation maximises the minimum angle), the
## fraction of sliver triangles, and the aspect-ratio distribution.

import std/[algorithm, math, os, strformat, strutils]

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

type QualityStats = object
  count: int
  minAngle: float64 ## smallest interior angle anywhere (deg)
  maxAngle: float64 ## largest interior angle anywhere (deg)
  meanMinAngle: float64 ## mean over triangles of each triangle's min angle
  slivers20: int ## triangles with a min angle < 20 deg
  slivers30: int ## triangles with a min angle < 30 deg
  maxAspect: float64 ## worst longest-edge / shortest-edge ratio
  meanAspect: float64
  hist: array[9, int] ## min-angle histogram, 10-deg buckets 0..90

proc triAngles(a, b, c: Vec2): tuple[lo, hi: float64] =
  ## Returns the smallest and largest interior angle (degrees) of triangle abc.
  let
    la = dist2(b, c).sqrt
    lb = dist2(a, c).sqrt
    lc = dist2(a, b).sqrt
  proc ang(opp, s1, s2: float64): float64 =
    let v = (s1 * s1 + s2 * s2 - opp * opp) / (2.0 * s1 * s2)
    arccos(clamp(v, -1.0, 1.0)).radToDeg

  let
    angA = ang(la, lb, lc)
    angB = ang(lb, la, lc)
    angC = 180.0 - angA - angB
  (min(angA, min(angB, angC)), max(angA, max(angB, angC)))

proc accumulate(
    stats: var QualityStats, sumMin, sumAspect: var float64, a, b, c: Vec2
) =
  let area = triangleArea(a, b, c)
  if area <= 0.0:
    return
  inc stats.count
  let (lo, hi) = triAngles(a, b, c)
  stats.minAngle = min(stats.minAngle, lo)
  stats.maxAngle = max(stats.maxAngle, hi)
  sumMin += lo
  if lo < 20.0:
    inc stats.slivers20
  if lo < 30.0:
    inc stats.slivers30
  let bucket = clamp(int(lo / 10.0), 0, 8)
  inc stats.hist[bucket]
  let
    e0 = dist2(a, b).sqrt
    e1 = dist2(b, c).sqrt
    e2 = dist2(c, a).sqrt
    aspect = max(e0, max(e1, e2)) / max(min(e0, min(e1, e2)), 1e-30)
  stats.maxAspect = max(stats.maxAspect, aspect)
  sumAspect += aspect

proc finalize(stats: var QualityStats, sumMin, sumAspect: float64) =
  if stats.count > 0:
    stats.meanMinAngle = sumMin / stats.count.float64
    stats.meanAspect = sumAspect / stats.count.float64

proc p2tQuality(res: TessResult): QualityStats =
  result.minAngle = 180.0
  var sumMin, sumAspect: float64
  for tri in res.triangles:
    result.accumulate(
      sumMin,
      sumAspect,
      res.vertices[tri[0]],
      res.vertices[tri[1]],
      res.vertices[tri[2]],
    )
  result.finalize(sumMin, sumAspect)

proc libtess2Quality(tess: ptr TESStesselator): QualityStats =
  result.minAngle = 180.0
  var sumMin, sumAspect: float64
  let vertices = cast[ptr UncheckedArray[TESSreal]](tessGetVertices(tess))
  let elements = cast[ptr UncheckedArray[TESSindex]](tessGetElements(tess))
  for i in 0 ..< tessGetElementCount(tess).int:
    let
      a = elements[i * 3]
      b = elements[i * 3 + 1]
      c = elements[i * 3 + 2]
    if a == TESS_UNDEF or b == TESS_UNDEF or c == TESS_UNDEF:
      continue
    result.accumulate(
      sumMin,
      sumAspect,
      vec2(vertices[a.int * 2].float64, vertices[a.int * 2 + 1].float64),
      vec2(vertices[b.int * 2].float64, vertices[b.int * 2 + 1].float64),
      vec2(vertices[c.int * 2].float64, vertices[c.int * 2 + 1].float64),
    )
  result.finalize(sumMin, sumAspect)

proc contourBuffer(points: openArray[Vec2]): seq[TESSreal] =
  result.setLen(points.len * 2)
  for i, point in points:
    result[i * 2] = point.x.TESSreal
    result[i * 2 + 1] = point.y.TESSreal

proc report(name: string, stats: QualityStats) =
  echo &"  {name}"
  echo &"    triangles   : {stats.count}"
  echo &"    min angle   : {stats.minAngle:7.3f} deg   (higher is better)"
  echo &"    max angle   : {stats.maxAngle:7.3f} deg   (lower is better)"
  echo &"    mean min ang: {stats.meanMinAngle:7.3f} deg   (higher is better)"
  echo &"    slivers <20 : {stats.slivers20}   <30: {stats.slivers30}"
  echo &"    aspect ratio: max {stats.maxAspect:7.2f}  mean {stats.meanAspect:6.2f}"
  var line = "    min-angle histogram (10deg buckets):"
  echo line
  for b in 0 ..< 9:
    echo &"      [{b*10:2}-{b*10+10:2}) : {stats.hist[b]}"

proc run(label: string, input: TessInput) =
  echo label
  let res = tessellate(input)
  if not res.ok:
    echo "  p2t failed: ", res.error.message
    return
  report("p2t", p2tQuality(res))

  var buffers: seq[seq[TESSreal]]
  buffers.add contourBuffer(input.outer.points)
  for hole in input.holes:
    buffers.add contourBuffer(hole.points)
  let tess = tessNewTess(nil)
  doAssert tess != nil
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
    doAssert tessTesselate(tess, TESS_WINDING_ODD, TESS_POLYGONS, 3, 2, nil) == 1
    doAssert tessGetStatus(tess) == TESS_STATUS_OK
    report("libtess2", libtess2Quality(tess))
  finally:
    tessDeleteTess(tess)

run("dude.dat with two holes", dudeInput())
run("nazca_monkey.dat", TessInput(outer: contour(7, readDat("nazca_monkey.dat"))))
run("nazca_heron.dat", TessInput(outer: contour(8, readDat("nazca_heron.dat"))))
