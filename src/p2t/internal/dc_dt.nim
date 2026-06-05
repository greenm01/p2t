## Experimental Triangle-style Delaunay backend foundation.
##
## This module is intentionally separate from the public CDT path and from the
## public CDT path.  It establishes the reusable workspace, arena topology,
## raw-output accessors, protected-edge flags, and flood cleanup surface needed
## to turn DeWall's unconstrained DT output into a Triangle-style CDT pipeline.
##
## The intended flow is:
##   DeWall raw DT triangles -> dc_dt arena topology -> segment recovery ->
##   protected-edge flood cleanup -> CDT output.

import std/algorithm

import ../types
import ./dewall

const
  DcNil* = -1'i32
  Protected0 = 1'u32 shl 0
  ExteriorFlag = 1'u32 shl 8

type
  DcTriangleId* = int32

  EdgeRef = object
    a, b: int32

  EdgeSlot = object
    key: uint64
    tri: DcTriangleId
    edge: int8
    used: bool

  DcTriangle* = object
    vertices*: array[3, int32]
    neighbors*: array[3, DcTriangleId]
    flags*: uint32

  DcWorkspace* = object
    points*: seq[Vec2]
    triangles*: seq[DcTriangle]
    rawTriangles*: seq[DcTriangleId]
    order: seq[int]
    edgeTable: seq[EdgeSlot]
    queue: seq[DcTriangleId]

  DcRawResult* = object
    workspace*: ptr DcWorkspace

  SegmentMarkResult* = object
    marked*, missing*: int

template protectedFlag(edge: int): uint32 =
  Protected0 shl edge

proc resetDcDt*(ws: var DcWorkspace) =
  ws.points.setLen(0)
  ws.triangles.setLen(0)
  ws.rawTriangles.setLen(0)
  ws.order.setLen(0)
  ws.edgeTable.setLen(0)
  ws.queue.setLen(0)

proc reserveDcDt*(ws: var DcWorkspace, pointCount: int) =
  let triCap = max(4, 2 * pointCount + 8)
  if ws.points.len < pointCount:
    ws.points.setLen(pointCount)
    ws.points.setLen(0)
  if ws.triangles.len < triCap:
    ws.triangles.setLen(triCap)
    ws.triangles.setLen(0)
  if ws.rawTriangles.len < triCap:
    ws.rawTriangles.setLen(triCap)
    ws.rawTriangles.setLen(0)
  if ws.order.len < pointCount:
    ws.order.setLen(pointCount)
    ws.order.setLen(0)
  if ws.queue.len < triCap:
    ws.queue.setLen(triCap)
    ws.queue.setLen(0)

proc triangleCount*(raw: DcRawResult): int {.inline.} =
  raw.workspace[].rawTriangles.len

proc rawTriangleId*(raw: DcRawResult, triangleIndex: int): DcTriangleId {.inline.} =
  raw.workspace[].rawTriangles[triangleIndex]

proc rawTrianglePoints*(
    raw: DcRawResult, triangleIndex: int
): array[3, int] {.inline.} =
  let tri = raw.workspace[].triangles[raw.rawTriangleId(triangleIndex)]
  [tri.vertices[0].int, tri.vertices[1].int, tri.vertices[2].int]

proc rawTriangleNeighbors*(
    raw: DcRawResult, triangleIndex: int
): array[3, DcTriangleId] {.inline.} =
  raw.workspace[].triangles[raw.rawTriangleId(triangleIndex)].neighbors

proc edgeKey(a, b: int32): uint64 {.inline.} =
  let
    lo = min(a, b).uint64
    hi = max(a, b).uint64
  (lo shl 32) or hi

proc edgeEndpoints(vertices: array[3, int32], edge: int): EdgeRef {.inline.} =
  case edge
  of 0:
    EdgeRef(a: vertices[1], b: vertices[2])
  of 1:
    EdgeRef(a: vertices[2], b: vertices[0])
  else:
    EdgeRef(a: vertices[0], b: vertices[1])

proc buildInsertionOrder(ws: var DcWorkspace, pointCount: int) =
  ws.order.setLen(pointCount)
  for i in 0 ..< pointCount:
    ws.order[i] = i
  let points = ws.points
  ws.order.sort(
    proc(a, b: int): int =
      let cx = cmp(points[a].x, points[b].x)
      if cx != 0:
        cx
      else:
        cmp(points[a].y, points[b].y)
  )

proc validateNoExactDuplicates(ws: DcWorkspace, pointCount: int) =
  for i in 1 ..< pointCount:
    let
      a = ws.order[i - 1]
      b = ws.order[i]
    if ws.points[a].x == ws.points[b].x and ws.points[a].y == ws.points[b].y:
      raise newException(ValueError, "duplicate points are not supported by dc_dt")

proc buildTopology(ws: var DcWorkspace) =
  for tri in ws.triangles.mitems:
    tri.neighbors = [DcNil, DcNil, DcNil]

  var cap = 1
  while cap < max(8, ws.triangles.len * 8):
    cap = cap shl 1
  ws.edgeTable.setLen(cap)
  for slot in ws.edgeTable.mitems:
    slot.used = false

  let mask = cap - 1
  for triId, tri in ws.triangles:
    for edge in 0 ..< 3:
      let e = edgeEndpoints(tri.vertices, edge)
      let key = edgeKey(e.a, e.b)
      var pos = (key and mask.uint64).int
      while true:
        if not ws.edgeTable[pos].used:
          ws.edgeTable[pos] = EdgeSlot(
            key: key, tri: triId.DcTriangleId, edge: edge.int8, used: true
          )
          break
        if ws.edgeTable[pos].key == key:
          let other = ws.edgeTable[pos]
          ws.triangles[triId].neighbors[edge] = other.tri
          ws.triangles[other.tri].neighbors[other.edge.int] = triId.DcTriangleId
          break
        pos = (pos + 1) and mask

proc loadDcDtTriangles*(
    ws: var DcWorkspace,
    points: openArray[Vec2],
    triangles: openArray[array[3, int]],
): DcRawResult =
  ## Load externally produced DT triangles, currently DeWall output, into the
  ## arena topology used by the CDT/flood-cleanup path.
  ws.resetDcDt()
  ws.reserveDcDt(points.len)
  ws.points.add points
  result.workspace = addr ws
  if points.len < 3:
    return

  ws.buildInsertionOrder(points.len)
  ws.validateNoExactDuplicates(points.len)
  ws.triangles.setLen(triangles.len)
  for i, tri in triangles:
    ws.triangles[i] = DcTriangle(
      vertices: [tri[0].int32, tri[1].int32, tri[2].int32],
      neighbors: [DcNil, DcNil, DcNil],
      flags: 0,
    )
  ws.buildTopology()
  ws.rawTriangles.setLen(triangles.len)
  for i in 0 ..< triangles.len:
    ws.rawTriangles[i] = i.DcTriangleId

proc triangulateDcDtRaw*(ws: var DcWorkspace, points: openArray[Vec2]): DcRawResult =
  ws.loadDcDtTriangles(points, dewallTriangulate(points))

proc triangulateDcDt*(points: openArray[Vec2]): seq[array[3, int]] =
  var ws: DcWorkspace
  let raw = ws.triangulateDcDtRaw(points)
  result.setLen(raw.triangleCount)
  for i in 0 ..< raw.triangleCount:
    result[i] = raw.rawTrianglePoints(i)

proc findTriangleEdge(ws: DcWorkspace, a, b: int32): tuple[tri: DcTriangleId, edge: int] =
  let key = edgeKey(a, b)
  if ws.edgeTable.len == 0:
    return (DcNil, -1)
  let mask = ws.edgeTable.len - 1
  var pos = (key and mask.uint64).int
  while ws.edgeTable[pos].used:
    if ws.edgeTable[pos].key == key:
      return (ws.edgeTable[pos].tri, ws.edgeTable[pos].edge.int)
    pos = (pos + 1) and mask
  (DcNil, -1)

proc markProtectedEdge*(ws: var DcWorkspace, a, b: int): bool =
  let found = ws.findTriangleEdge(a.int32, b.int32)
  if found.tri == DcNil:
    return false
  ws.triangles[found.tri].flags =
    ws.triangles[found.tri].flags or protectedFlag(found.edge)
  let neighbor = ws.triangles[found.tri].neighbors[found.edge]
  if neighbor != DcNil:
    for edge in 0 ..< 3:
      if ws.triangles[neighbor].neighbors[edge] == found.tri:
        ws.triangles[neighbor].flags =
          ws.triangles[neighbor].flags or protectedFlag(edge)
        break
  true

proc markProtectedSegments*(
    ws: var DcWorkspace, segments: openArray[array[2, int]]
): SegmentMarkResult =
  for seg in segments:
    if ws.markProtectedEdge(seg[0], seg[1]):
      inc result.marked
    else:
      inc result.missing

proc isProtected(tri: DcTriangle, edge: int): bool {.inline.} =
  (tri.flags and protectedFlag(edge)) != 0

proc markExterior*(ws: var DcWorkspace) =
  ws.queue.setLen(0)
  for triId, tri in ws.triangles.mpairs:
    tri.flags = tri.flags and not ExteriorFlag
    for edge in 0 ..< 3:
      if tri.neighbors[edge] == DcNil and not tri.isProtected(edge):
        tri.flags = tri.flags or ExteriorFlag
        ws.queue.add triId.DcTriangleId
        break

  var head = 0
  while head < ws.queue.len:
    let triId = ws.queue[head]
    inc head
    let tri = ws.triangles[triId]
    for edge in 0 ..< 3:
      if tri.isProtected(edge):
        continue
      let neighbor = tri.neighbors[edge]
      if neighbor == DcNil:
        continue
      if (ws.triangles[neighbor].flags and ExteriorFlag) == 0:
        ws.triangles[neighbor].flags = ws.triangles[neighbor].flags or ExteriorFlag
        ws.queue.add neighbor

  ws.rawTriangles.setLen(0)
  for triId, tri in ws.triangles:
    if (tri.flags and ExteriorFlag) == 0:
      ws.rawTriangles.add triId.DcTriangleId

proc isExterior*(ws: DcWorkspace, tri: DcTriangleId): bool {.inline.} =
  (ws.triangles[tri].flags and ExteriorFlag) != 0
