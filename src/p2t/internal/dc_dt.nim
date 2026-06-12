## Experimental Triangle-style Delaunay backend foundation.
##
## This module is intentionally separate from the public CDT path.  It
## establishes the reusable workspace, arena topology,
## raw-output accessors, protected-edge flags, and flood cleanup surface needed
## to turn DeWall's unconstrained DT output into a Triangle-style CDT pipeline.
##
## The intended flow is:
##   DeWall raw DT triangles -> dc_dt arena topology -> segment recovery ->
##   protected-edge flood cleanup -> CDT output.

import std/algorithm

import ../geometry
import ../types
import ./dewall

const
  DcNil* = -1'i32
  Protected0 = 1'u32 shl 0
  ExteriorFlag = 1'u32 shl 8
  MaxRecoveryFlipFactor = 3

type
  DcTriangleId* = int32

  EdgeRef = object
    a, b: int32

  EdgeSlot = object
    key: uint64
    tri: DcTriangleId
    edge: int8
    used: bool

  SegmentRecoveryWork* = object
    segment*: array[2, int]
    crossedEdges*: seq[array[2, int]]

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
    recoveryWork*: seq[SegmentRecoveryWork]
    queue: seq[DcTriangleId]

  DcRawResult* = object
    workspace*: ptr DcWorkspace

  SegmentMarkResult* = object
    marked*, missing*, recovered*: int

  DcCdtRawResult* = object
    raw*: DcRawResult
    segments*: SegmentMarkResult
    recoveryWork*: int

template protectedFlag(edge: int): uint32 =
  Protected0 shl edge

proc resetDcDt*(ws: var DcWorkspace) =
  ws.points.setLen(0)
  ws.triangles.setLen(0)
  ws.rawTriangles.setLen(0)
  ws.order.setLen(0)
  ws.edgeTable.setLen(0)
  ws.recoveryWork.setLen(0)
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
  if ws.recoveryWork.len < pointCount:
    ws.recoveryWork.setLen(pointCount)
    ws.recoveryWork.setLen(0)

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

proc edgePair(e: EdgeRef): array[2, int] {.inline.} =
  [e.a.int, e.b.int]

proc segmentProperlyCrossesEdge(
    points: openArray[Vec2], segment, edge: array[2, int]
): bool =
  if segment[0] == edge[0] or segment[0] == edge[1] or
      segment[1] == edge[0] or segment[1] == edge[1]:
    return false

  let
    a = points[segment[0]]
    b = points[segment[1]]
    c = points[edge[0]]
    d = points[edge[1]]
    o1 = orient(a, b, c)
    o2 = orient(a, b, d)
    o3 = orient(c, d, a)
    o4 = orient(c, d, b)
  ((o1 > 0.0 and o2 < 0.0) or (o1 < 0.0 and o2 > 0.0)) and
    ((o3 > 0.0 and o4 < 0.0) or (o3 < 0.0 and o4 > 0.0))

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

proc setTriangle(
    ws: var DcWorkspace, triId: DcTriangleId, a, b, c: int32
): bool =
  if a == b or b == c or a == c:
    return false
  if orient(ws.points[a.int], ws.points[b.int], ws.points[c.int]) > 0.0:
    ws.triangles[triId].vertices = [a, b, c]
  else:
    ws.triangles[triId].vertices = [a, c, b]
  ws.triangles[triId].neighbors = [DcNil, DcNil, DcNil]
  ws.triangles[triId].flags = 0
  true

proc pairEquals(a, b: array[2, int]): bool {.inline.} =
  (a[0] == b[0] and a[1] == b[1]) or (a[0] == b[1] and a[1] == b[0])

proc canonicalEdgePair(e: EdgeRef): array[2, int] {.inline.} =
  result = e.edgePair
  if result[0] > result[1]:
    swap(result[0], result[1])

proc containsPair(edges: openArray[array[2, int]], needle: array[2, int]): bool =
  for edge in edges:
    if edge.pairEquals(needle):
      return true

proc findNeighborEdge(
    ws: DcWorkspace, triId, neighbor: DcTriangleId
): int {.inline.} =
  for edge in 0 ..< 3:
    if ws.triangles[triId].neighbors[edge] == neighbor:
      return edge
  -1

proc isProtected(tri: DcTriangle, edge: int): bool {.inline.} =
  (tri.flags and protectedFlag(edge)) != 0

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

proc pointOnSegment(points: openArray[Vec2], segment: array[2, int], point: int): bool =
  if point == segment[0] or point == segment[1]:
    return true

  let
    a = points[segment[0]]
    b = points[segment[1]]
    p = points[point]
  if abs(orient(a, b, p)) > 1e-12:
    return false

  p.x >= min(a.x, b.x) - 1e-12 and p.x <= max(a.x, b.x) + 1e-12 and
    p.y >= min(a.y, b.y) - 1e-12 and p.y <= max(a.y, b.y) + 1e-12

proc markProtectedSegment*(ws: var DcWorkspace, segment: array[2, int]): bool =
  if ws.markProtectedEdge(segment[0], segment[1]):
    return true

  var chain: seq[int]
  for point in 0 ..< ws.points.len:
    if pointOnSegment(ws.points, segment, point):
      chain.add point
  if chain.len < 2:
    return false

  let points = ws.points
  let useX =
    abs(points[segment[1]].x - points[segment[0]].x) >=
    abs(points[segment[1]].y - points[segment[0]].y)
  chain.sort(
    proc(a, b: int): int =
      if useX:
        cmp(points[a].x, points[b].x)
      else:
        cmp(points[a].y, points[b].y)
  )

  for i in 1 ..< chain.len:
    if ws.findTriangleEdge(chain[i - 1].int32, chain[i].int32).tri == DcNil:
      return false

  for i in 1 ..< chain.len:
    discard ws.markProtectedEdge(chain[i - 1], chain[i])
  true

proc markProtectedSegments*(
    ws: var DcWorkspace, segments: openArray[array[2, int]]
): SegmentMarkResult =
  for seg in segments:
    if ws.markProtectedSegment(seg):
      inc result.marked
    else:
      inc result.missing

proc crossedEdgesForSegment(
    ws: DcWorkspace, segment: array[2, int]
): seq[array[2, int]] =
  for tri in ws.triangles:
    for edge in 0 ..< 3:
      let e = edgeEndpoints(tri.vertices, edge).canonicalEdgePair
      if result.containsPair(e):
        continue
      if segmentProperlyCrossesEdge(ws.points, segment, e):
        result.add e

proc collectSegmentRecoveryWork*(
    ws: var DcWorkspace, segments: openArray[array[2, int]]
) =
  ## Record the DT edges each unrecovered segment crosses. Multi-edge recovery
  ## still uses this as the explicit handoff to the next CDT phase.
  ws.recoveryWork.setLen(0)
  for seg in segments:
    if ws.findTriangleEdge(seg[0].int32, seg[1].int32).tri != DcNil:
      continue

    ws.recoveryWork.add SegmentRecoveryWork(
      segment: seg, crossedEdges: ws.crossedEdgesForSegment(seg)
    )

proc recoverSingleCrossingSegment(
    ws: var DcWorkspace, work: SegmentRecoveryWork
): bool =
  if work.crossedEdges.len != 1:
    return false

  let
    segment = work.segment
    crossed = work.crossedEdges[0]
    found = ws.findTriangleEdge(crossed[0].int32, crossed[1].int32)
  if found.tri == DcNil:
    return false

  let neighbor = ws.triangles[found.tri].neighbors[found.edge]
  if neighbor == DcNil:
    return false

  let neighborEdge = ws.findNeighborEdge(neighbor, found.tri)
  if neighborEdge < 0:
    return false

  let
    oppositeA = ws.triangles[found.tri].vertices[found.edge].int
    oppositeB = ws.triangles[neighbor].vertices[neighborEdge].int
  if not [oppositeA, oppositeB].pairEquals(segment):
    return false

  let
    a = segment[0].int32
    b = segment[1].int32
    u = crossed[0].int32
    v = crossed[1].int32
  if not ws.setTriangle(found.tri, a, b, u):
    return false
  if not ws.setTriangle(neighbor, b, a, v):
    return false

  ws.buildTopology()
  discard ws.markProtectedEdge(segment[0], segment[1])
  true

proc flipInteriorEdge(ws: var DcWorkspace, crossed: array[2, int]): bool =
  let found = ws.findTriangleEdge(crossed[0].int32, crossed[1].int32)
  if found.tri == DcNil or ws.triangles[found.tri].isProtected(found.edge):
    return false

  let neighbor = ws.triangles[found.tri].neighbors[found.edge]
  if neighbor == DcNil:
    return false

  let neighborEdge = ws.findNeighborEdge(neighbor, found.tri)
  if neighborEdge < 0 or ws.triangles[neighbor].isProtected(neighborEdge):
    return false

  let
    p = ws.triangles[found.tri].vertices[found.edge].int
    q = ws.triangles[neighbor].vertices[neighborEdge].int
  if ws.findTriangleEdge(p.int32, q.int32).tri != DcNil:
    return false
  if not segmentProperlyCrossesEdge(ws.points, [p, q], crossed):
    return false

  let
    u = crossed[0].int32
    v = crossed[1].int32
  if not ws.setTriangle(found.tri, p.int32, q.int32, u):
    return false
  if not ws.setTriangle(neighbor, q.int32, p.int32, v):
    return false

  ws.buildTopology()
  true

proc recoverSegmentByFlips(
    ws: var DcWorkspace, segment: array[2, int]
): bool =
  let maxAttempts = max(1, ws.triangles.len * MaxRecoveryFlipFactor)
  for _ in 0 ..< maxAttempts:
    if ws.markProtectedSegment(segment):
      return true

    let crossedEdges = ws.crossedEdgesForSegment(segment)
    if crossedEdges.len == 0:
      return false

    var flipped = false
    for crossed in crossedEdges:
      if ws.flipInteriorEdge(crossed):
        flipped = true
        break
    if not flipped:
      return false

  ws.markProtectedSegment(segment)

proc recoverSimpleSegments*(
    ws: var DcWorkspace, segments: openArray[array[2, int]]
): int =
  for segment in segments:
    if ws.markProtectedSegment(segment):
      continue
    let work = SegmentRecoveryWork(
      segment: segment, crossedEdges: ws.crossedEdgesForSegment(segment)
    )
    if ws.recoverSingleCrossingSegment(work) or ws.recoverSegmentByFlips(segment):
      inc result

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

proc pointInTriangleClosed(
    p, a, b, c: Vec2,
    eps: float64
): bool =
  let
    ab = orient(a, b, p)
    bc = orient(b, c, p)
    ca = orient(c, a, p)
  (ab >= -eps and bc >= -eps and ca >= -eps) or
    (ab <= eps and bc <= eps and ca <= eps)

proc rebuildRawTriangles(ws: var DcWorkspace) =
  ws.rawTriangles.setLen(0)
  for triId, tri in ws.triangles:
    if (tri.flags and ExteriorFlag) == 0:
      ws.rawTriangles.add triId.DcTriangleId

proc markHoleFrom(ws: var DcWorkspace, seed: DcTriangleId) =
  if seed == DcNil or (ws.triangles[seed].flags and ExteriorFlag) != 0:
    return
  ws.queue.setLen(0)
  ws.triangles[seed].flags = ws.triangles[seed].flags or ExteriorFlag
  ws.queue.add seed

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

proc markHoles*(
    ws: var DcWorkspace,
    markers: openArray[Vec2],
    eps = 1.0e-9
) =
  ## Removes triangles inside protected hole loops by flooding from marker
  ## points across unprotected edges. Call after `markExterior`.
  for marker in markers:
    var seed = DcNil
    for triId in ws.rawTriangles:
      let tri = ws.triangles[triId]
      if pointInTriangleClosed(
        marker,
        ws.points[tri.vertices[0]],
        ws.points[tri.vertices[1]],
        ws.points[tri.vertices[2]],
        eps
      ):
        seed = triId
        break
    ws.markHoleFrom(seed)
  ws.rebuildRawTriangles()

proc isExterior*(ws: DcWorkspace, tri: DcTriangleId): bool {.inline.} =
  (ws.triangles[tri].flags and ExteriorFlag) != 0

proc triangulateDcCdtRaw*(
    ws: var DcWorkspace,
    points: openArray[Vec2],
    segments: openArray[array[2, int]],
): DcCdtRawResult =
  ## Build DeWall's unconstrained DT, load it into dc_dt topology, mark the
  ## requested protected segments, recover one-crossing diagonals by a local
  ## edge flip, and flood-delete exterior triangles across unprotected hull
  ## edges.
  ##
  ## `segments.missing` is the explicit handoff to multi-edge segment recovery.
  ## A nonzero value means the current output is not a full CDT for that segment
  ## set.
  result.raw = ws.triangulateDcDtRaw(points)
  result.segments = ws.markProtectedSegments(segments)
  if result.segments.missing > 0:
    let recovered = ws.recoverSimpleSegments(segments)
    result.segments.recovered = recovered
    if recovered > 0:
      result.segments = ws.markProtectedSegments(segments)
      result.segments.recovered = recovered
    if result.segments.missing > 0:
      ws.collectSegmentRecoveryWork(segments)
      result.recoveryWork = ws.recoveryWork.len
    else:
      ws.recoveryWork.setLen(0)
      result.recoveryWork = 0
  ws.markExterior()
