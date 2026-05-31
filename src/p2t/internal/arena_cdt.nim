## Pointer-arena sweep-line constrained Delaunay triangulation (CDT).
##
## This preserves the Poly2Tri advancing-front algorithm used by cdt.nim, but
## stores the hot mesh/front objects as direct pointers into reusable arena
## buffers. It is selected with -d:p2tArenaCdt.

import std/math

import ../types

when defined(p2tUnsafeCdt):
  {.push checks: off.}

const
  Epsilon = 1e-12
  Pi3Div4 = 3.0 * PI / 4.0
  Alpha = 0.3
  DelaunayEdge0 = 1'u32 shl 0
  ConstrainedEdge0 = 1'u32 shl 3
  InteriorFlag = 1'u32 shl 30
  DelaunayEdgeMask = DelaunayEdge0 or (DelaunayEdge0 shl 1) or (DelaunayEdge0 shl 2)

type
  Orientation = enum
    cw
    ccw
    collinear

  CdtInput* = object
    outer*: seq[Vec2]
    holes*: seq[seq[Vec2]]
    steiner*: seq[Vec2]

  CdtResult* = object
    vertices*: seq[Vec2]
    triangles*: seq[array[3, int]]

  CdtRawResult* = object
    vertices*: ptr seq[Vec2]
    arena*: ptr ArenaWorkspace

proc resetCdt(ws: var ArenaWorkspace) =
  ws.pointCount = 0
  ws.edgeCount = 0
  ws.triangleCount = 0
  ws.nodeCount = 0
  ws.activePoints.setLen(0)
  ws.sortTemp.setLen(0)
  ws.meshStack.setLen(0)
  ws.interiorTriangles.setLen(0)
  ws.front = ArenaFront()
  ws.head = nil
  ws.tail = nil
  ws.afHead = nil
  ws.afMiddle = nil
  ws.afTail = nil
  ws.basin = ArenaBasin()
  ws.edgeEvent = ArenaEdgeEvent()

proc ensureCapacity[T](s: var seq[T], n: int) =
  if s.len < n:
    s.setLen(n)

proc reserveSeq[T](s: var seq[T], n: int) =
  if s.len < n:
    s.setLen(n)
    s.setLen(0)

proc reserveArena(
    workspace: var TessWorkspace, pointCount: int, keepVertices: static bool
) =
  workspace.arena.points.ensureCapacity(pointCount + 2)
  workspace.arena.edges.ensureCapacity(pointCount)
  workspace.arena.nodes.ensureCapacity(pointCount + 4)
  workspace.arena.triangles.ensureCapacity(2 * pointCount + 4)
  workspace.arena.meshStack.reserveSeq(2 * pointCount + 4)
  workspace.arena.interiorTriangles.reserveSeq(2 * pointCount + 4)
  workspace.arena.activePoints.reserveSeq(pointCount + 2)
  when not defined(p2tQuickSort):
    workspace.arena.sortTemp.reserveSeq(pointCount + 2)
  when keepVertices:
    workspace.vertices.reserveSeq(pointCount)

proc edgeFlag(base: uint32, index: int): uint32 {.inline.} =
  base shl index

proc hasFlag(tr: ptr ArenaTriangle, flag: uint32): bool {.inline.} =
  (tr.flags and flag) != 0

proc setFlag(tr: ptr ArenaTriangle, flag: uint32, value: bool) {.inline.} =
  if value:
    tr.flags = tr.flags or flag
  else:
    tr.flags = tr.flags and not flag

proc constrainedFlag(index: int): uint32 {.inline.} =
  edgeFlag(ConstrainedEdge0, index)

proc delaunayFlag(index: int): uint32 {.inline.} =
  edgeFlag(DelaunayEdge0, index)

proc newPoint(ws: var ArenaWorkspace, x, y: float64, sourceIndex = -1): ptr ArenaPoint =
  result = addr ws.points[ws.pointCount]
  result[] = ArenaPoint(
    firstEdge: nil, x: x, y: y, sourceIndex: sourceIndex.int32, id: ws.pointCount.int32
  )
  inc ws.pointCount

proc orient2d(pa, pb, pc: ptr ArenaPoint): Orientation {.inline.} =
  let
    detleft = (pa.x - pc.x) * (pb.y - pc.y)
    detright = (pa.y - pc.y) * (pb.x - pc.x)
    val = detleft - detright
  if val > -Epsilon and val < Epsilon:
    collinear
  elif val > 0:
    ccw
  else:
    cw

proc inScanArea(pa, pb, pc, pd: ptr ArenaPoint): bool {.inline.} =
  let oadb = (pa.x - pb.x) * (pd.y - pb.y) - (pd.x - pb.x) * (pa.y - pb.y)
  if oadb >= -Epsilon:
    return false

  let oadc = (pa.x - pc.x) * (pd.y - pc.y) - (pd.x - pc.x) * (pa.y - pc.y)
  if oadc <= Epsilon:
    return false
  true

proc newEdge(ws: var ArenaWorkspace, p1, p2: ptr ArenaPoint): ptr ArenaEdge =
  result = addr ws.edges[ws.edgeCount]
  inc ws.edgeCount
  var p = p1
  var q = p2
  if p1.y > p2.y:
    q = p1
    p = p2
  elif p1.y == p2.y:
    if p1.x > p2.x:
      q = p1
      p = p2
    elif p1.x == p2.x:
      raise newException(ValueError, "repeat points in constrained edge")
  result[] = ArenaEdge(p: p, q: q, next: nil)
  if q.firstEdge.isNil:
    q.firstEdge = result
  else:
    var last = q.firstEdge
    while not last.next.isNil:
      last = last.next
    last.next = result

proc newTriangle(ws: var ArenaWorkspace, a, b, c: ptr ArenaPoint): ptr ArenaTriangle =
  result = addr ws.triangles[ws.triangleCount]
  result[] = ArenaTriangle(points: [a, b, c], neighbors: [nil, nil, nil], flags: 0)
  inc ws.triangleCount

proc contains(t: ptr ArenaTriangle, p: ptr ArenaPoint): bool {.inline.} =
  t.points[0] == p or t.points[1] == p or t.points[2] == p

proc contains(t: ptr ArenaTriangle, p, q: ptr ArenaPoint): bool {.inline.} =
  t.contains(p) and t.contains(q)

proc markNeighbor(
    t: ptr ArenaTriangle, p1, p2: ptr ArenaPoint, other: ptr ArenaTriangle
) =
  if (p1 == t.points[2] and p2 == t.points[1]) or
      (p1 == t.points[1] and p2 == t.points[2]):
    t.neighbors[0] = other
  elif (p1 == t.points[0] and p2 == t.points[2]) or
      (p1 == t.points[2] and p2 == t.points[0]):
    t.neighbors[1] = other
  elif (p1 == t.points[0] and p2 == t.points[1]) or
      (p1 == t.points[1] and p2 == t.points[0]):
    t.neighbors[2] = other

proc markNeighbor(t, other: ptr ArenaTriangle) =
  if other.isNil:
    return
  if other.contains(t.points[1], t.points[2]):
    t.neighbors[0] = other
    other.markNeighbor(t.points[1], t.points[2], t)
  elif other.contains(t.points[0], t.points[2]):
    t.neighbors[1] = other
    other.markNeighbor(t.points[0], t.points[2], t)
  elif other.contains(t.points[0], t.points[1]):
    t.neighbors[2] = other
    other.markNeighbor(t.points[0], t.points[1], t)

proc clearNeighbors(t: ptr ArenaTriangle) {.inline.} =
  t.neighbors = [nil, nil, nil]

proc clearDelaunayEdges(t: ptr ArenaTriangle) {.inline.} =
  t.flags = t.flags and not DelaunayEdgeMask

proc pointCW(t: ptr ArenaTriangle, p: ptr ArenaPoint): ptr ArenaPoint {.inline.} =
  if p == t.points[0]:
    t.points[2]
  elif p == t.points[1]:
    t.points[0]
  else:
    t.points[1]

proc pointCCW(t: ptr ArenaTriangle, p: ptr ArenaPoint): ptr ArenaPoint {.inline.} =
  if p == t.points[0]:
    t.points[1]
  elif p == t.points[1]:
    t.points[2]
  else:
    t.points[0]

proc neighborCW(t: ptr ArenaTriangle, p: ptr ArenaPoint): ptr ArenaTriangle {.inline.} =
  if p == t.points[0]:
    t.neighbors[1]
  elif p == t.points[1]:
    t.neighbors[2]
  else:
    t.neighbors[0]

proc neighborCCW(
    t: ptr ArenaTriangle, p: ptr ArenaPoint
): ptr ArenaTriangle {.inline.} =
  if p == t.points[0]:
    t.neighbors[2]
  elif p == t.points[1]:
    t.neighbors[0]
  else:
    t.neighbors[1]

proc getConstrainedEdgeCCW(t: ptr ArenaTriangle, p: ptr ArenaPoint): bool {.inline.} =
  if p == t.points[0]:
    t.hasFlag(constrainedFlag(2))
  elif p == t.points[1]:
    t.hasFlag(constrainedFlag(0))
  else:
    t.hasFlag(constrainedFlag(1))

proc getConstrainedEdgeCW(t: ptr ArenaTriangle, p: ptr ArenaPoint): bool {.inline.} =
  if p == t.points[0]:
    t.hasFlag(constrainedFlag(1))
  elif p == t.points[1]:
    t.hasFlag(constrainedFlag(2))
  else:
    t.hasFlag(constrainedFlag(0))

proc setConstrainedEdgeCCW(t: ptr ArenaTriangle, p: ptr ArenaPoint, ce: bool) =
  if p == t.points[0]:
    t.setFlag(constrainedFlag(2), ce)
  elif p == t.points[1]:
    t.setFlag(constrainedFlag(0), ce)
  else:
    t.setFlag(constrainedFlag(1), ce)

proc setConstrainedEdgeCW(t: ptr ArenaTriangle, p: ptr ArenaPoint, ce: bool) =
  if p == t.points[0]:
    t.setFlag(constrainedFlag(1), ce)
  elif p == t.points[1]:
    t.setFlag(constrainedFlag(2), ce)
  else:
    t.setFlag(constrainedFlag(0), ce)

proc getDelaunayEdgeCCW(t: ptr ArenaTriangle, p: ptr ArenaPoint): bool {.inline.} =
  if p == t.points[0]:
    t.hasFlag(delaunayFlag(2))
  elif p == t.points[1]:
    t.hasFlag(delaunayFlag(0))
  else:
    t.hasFlag(delaunayFlag(1))

proc getDelaunayEdgeCW(t: ptr ArenaTriangle, p: ptr ArenaPoint): bool {.inline.} =
  if p == t.points[0]:
    t.hasFlag(delaunayFlag(1))
  elif p == t.points[1]:
    t.hasFlag(delaunayFlag(2))
  else:
    t.hasFlag(delaunayFlag(0))

proc setDelaunayEdgeCCW(t: ptr ArenaTriangle, p: ptr ArenaPoint, edge: bool) =
  if p == t.points[0]:
    t.setFlag(delaunayFlag(2), edge)
  elif p == t.points[1]:
    t.setFlag(delaunayFlag(0), edge)
  else:
    t.setFlag(delaunayFlag(1), edge)

proc setDelaunayEdgeCW(t: ptr ArenaTriangle, p: ptr ArenaPoint, edge: bool) =
  if p == t.points[0]:
    t.setFlag(delaunayFlag(1), edge)
  elif p == t.points[1]:
    t.setFlag(delaunayFlag(2), edge)
  else:
    t.setFlag(delaunayFlag(0), edge)

proc neighborAcross(
    t: ptr ArenaTriangle, opoint: ptr ArenaPoint
): ptr ArenaTriangle {.inline.} =
  if opoint == t.points[0]:
    t.neighbors[0]
  elif opoint == t.points[1]:
    t.neighbors[1]
  else:
    t.neighbors[2]

proc oppositePoint(
    t, other: ptr ArenaTriangle, p: ptr ArenaPoint
): ptr ArenaPoint {.inline.} =
  t.pointCW(other.pointCW(p))

proc legalize(t: ptr ArenaTriangle, opoint, npoint: ptr ArenaPoint) =
  if opoint == t.points[0]:
    t.points[1] = t.points[0]
    t.points[0] = t.points[2]
    t.points[2] = npoint
  elif opoint == t.points[1]:
    t.points[2] = t.points[1]
    t.points[1] = t.points[0]
    t.points[0] = npoint
  else:
    t.points[0] = t.points[2]
    t.points[2] = t.points[1]
    t.points[1] = npoint

proc index(t: ptr ArenaTriangle, p: ptr ArenaPoint): int {.inline.} =
  if p == t.points[0]:
    0
  elif p == t.points[1]:
    1
  elif p == t.points[2]:
    2
  else:
    -1

proc edgeIndex(t: ptr ArenaTriangle, p1, p2: ptr ArenaPoint): int =
  if t.points[0] == p1:
    if t.points[1] == p2:
      return 2
    if t.points[2] == p2:
      return 1
  elif t.points[1] == p1:
    if t.points[2] == p2:
      return 0
    if t.points[0] == p2:
      return 2
  elif t.points[2] == p1:
    if t.points[0] == p2:
      return 1
    if t.points[1] == p2:
      return 0
  -1

proc markConstrainedEdge(t: ptr ArenaTriangle, edgeIndex: int) =
  t.setFlag(constrainedFlag(edgeIndex), true)

proc markConstrainedEdge(t: ptr ArenaTriangle, p, q: ptr ArenaPoint) =
  if (q == t.points[0] and p == t.points[1]) or (q == t.points[1] and p == t.points[0]):
    t.setFlag(constrainedFlag(2), true)
  elif (q == t.points[0] and p == t.points[2]) or (
    q == t.points[2] and p == t.points[0]
  ):
    t.setFlag(constrainedFlag(1), true)
  elif (q == t.points[1] and p == t.points[2]) or (
    q == t.points[2] and p == t.points[1]
  ):
    t.setFlag(constrainedFlag(0), true)

proc newNode(
    ws: var ArenaWorkspace, p: ptr ArenaPoint, t: ptr ArenaTriangle = nil
): ptr ArenaNode =
  result = addr ws.nodes[ws.nodeCount]
  result[] = ArenaNode(point: p, triangle: t, value: p.x)
  inc ws.nodeCount

proc locateNode(ws: var ArenaWorkspace, x: float64): ptr ArenaNode =
  var node = ws.front.searchNode
  if x < node.value:
    while not node.isNil:
      node = node.prev
      if not node.isNil and x >= node.value:
        ws.front.searchNode = node
        return node
  else:
    while not node.isNil:
      node = node.next
      if not node.isNil and x < node.value:
        ws.front.searchNode = node.prev
        return node.prev
  nil

proc locatePoint(ws: var ArenaWorkspace, p: ptr ArenaPoint): ptr ArenaNode =
  let px = p.x
  var node = ws.front.searchNode
  let nx = node.point.x

  if px == nx:
    if p == node.point:
      return node
    if not node.prev.isNil and p == node.prev.point:
      ws.front.searchNode = node.prev
      return node.prev
    if not node.next.isNil and p == node.next.point:
      ws.front.searchNode = node.next
      return node.next
  elif px < nx:
    while not node.prev.isNil:
      node = node.prev
      if p == node.point:
        ws.front.searchNode = node
        return node
  else:
    while not node.next.isNil:
      node = node.next
      if p == node.point:
        ws.front.searchNode = node
        return node
  nil

proc addPoint(ws: var ArenaWorkspace, p: ptr ArenaPoint) =
  ws.activePoints.add p

proc pointCmp(a, b: ptr ArenaPoint): int {.inline.} =
  if a.y < b.y:
    -1
  elif a.y > b.y:
    1
  elif a.x < b.x:
    -1
  elif a.x > b.x:
    1
  else:
    0

proc quicksortActivePoints(ws: var ArenaWorkspace) {.used.} =
  proc quicksort(ws: var ArenaWorkspace, lo, hi: int) =
    var i = lo
    var j = hi
    let pivot = ws.activePoints[(lo + hi) shr 1]
    while i <= j:
      while pointCmp(ws.activePoints[i], pivot) < 0:
        inc i
      while pointCmp(ws.activePoints[j], pivot) > 0:
        dec j
      if i <= j:
        swap ws.activePoints[i], ws.activePoints[j]
        inc i
        dec j
    if lo < j:
      ws.quicksort(lo, j)
    if i < hi:
      ws.quicksort(i, hi)

  if ws.activePoints.len > 1:
    ws.quicksort(0, ws.activePoints.high)

proc insertionSortActivePoints(ws: var ArenaWorkspace, lo, hi: int) =
  for i in lo + 1 ..< hi:
    let item = ws.activePoints[i]
    var j = i
    while j > lo and pointCmp(item, ws.activePoints[j - 1]) < 0:
      ws.activePoints[j] = ws.activePoints[j - 1]
      dec j
    ws.activePoints[j] = item

proc mergeSortActivePoints(ws: var ArenaWorkspace) {.used.} =
  const InsertionLimit = 24

  proc sortRange(ws: var ArenaWorkspace, lo, hi: int) =
    if hi - lo <= InsertionLimit:
      ws.insertionSortActivePoints(lo, hi)
      return

    let mid = (lo + hi) shr 1
    ws.sortRange(lo, mid)
    ws.sortRange(mid, hi)
    if pointCmp(ws.activePoints[mid - 1], ws.activePoints[mid]) <= 0:
      return

    var left = lo
    var right = mid
    var outIdx = lo
    while left < mid and right < hi:
      if pointCmp(ws.activePoints[left], ws.activePoints[right]) <= 0:
        ws.sortTemp[outIdx] = ws.activePoints[left]
        inc left
      else:
        ws.sortTemp[outIdx] = ws.activePoints[right]
        inc right
      inc outIdx
    while left < mid:
      ws.sortTemp[outIdx] = ws.activePoints[left]
      inc left
      inc outIdx
    while right < hi:
      ws.sortTemp[outIdx] = ws.activePoints[right]
      inc right
      inc outIdx
    for i in lo ..< hi:
      ws.activePoints[i] = ws.sortTemp[i]

  if ws.activePoints.len > 1:
    ws.sortTemp.setLen(ws.activePoints.len)
    ws.sortRange(0, ws.activePoints.len)

proc sortActivePoints(ws: var ArenaWorkspace) =
  when defined(p2tQuickSort):
    ws.quicksortActivePoints()
  else:
    ws.mergeSortActivePoints()

proc initTriangulation(ws: var ArenaWorkspace) =
  var
    xmax = ws.activePoints[0].x
    xmin = xmax
    ymax = ws.activePoints[0].y
    ymin = ymax

  for p in ws.activePoints:
    xmax = max(xmax, p.x)
    xmin = min(xmin, p.x)
    ymax = max(ymax, p.y)
    ymin = min(ymin, p.y)

  let
    dx = Alpha * (xmax - xmin)
    dy = Alpha * (ymax - ymin)
  ws.head = ws.newPoint(xmax + dx, ymin - dy)
  ws.tail = ws.newPoint(xmin - dx, ymin - dy)
  ws.sortActivePoints()

proc createAdvancingFront(ws: var ArenaWorkspace) =
  let t = ws.newTriangle(ws.activePoints[0], ws.tail, ws.head)

  ws.afHead = ws.newNode(t.points[1], t)
  ws.afMiddle = ws.newNode(t.points[0], t)
  ws.afTail = ws.newNode(t.points[2])
  ws.front = ArenaFront(head: ws.afHead, tail: ws.afTail, searchNode: ws.afHead)

  ws.afHead.next = ws.afMiddle
  ws.afMiddle.next = ws.afTail
  ws.afMiddle.prev = ws.afHead
  ws.afTail.prev = ws.afMiddle

proc mapTriangleToNodes(ws: var ArenaWorkspace, t: ptr ArenaTriangle) =
  for i in 0 .. 2:
    if t.neighbors[i].isNil:
      let n = ws.locatePoint(t.pointCW(t.points[i]))
      if not n.isNil:
        n.triangle = t

proc meshClean(ws: var ArenaWorkspace, t: ptr ArenaTriangle) =
  ws.meshStack.setLen(0)
  ws.meshStack.add t
  while ws.meshStack.len > 0:
    let item = ws.meshStack.pop()
    if not item.isNil and not item.hasFlag(InteriorFlag):
      item.setFlag(InteriorFlag, true)
      ws.interiorTriangles.add item
      for i in 0 .. 2:
        if not item.hasFlag(constrainedFlag(i)):
          ws.meshStack.add item.neighbors[i]

proc incircle(pa, pb, pc, pd: ptr ArenaPoint): bool {.inline.} =
  let
    adx = pa.x - pd.x
    ady = pa.y - pd.y
    bdx = pb.x - pd.x
    bdy = pb.y - pd.y
    adxbdy = adx * bdy
    bdxady = bdx * ady
    oabd = adxbdy - bdxady

  if oabd <= 0:
    return false

  let
    cdx = pc.x - pd.x
    cdy = pc.y - pd.y
    cdxady = cdx * ady
    adxcdy = adx * cdy
    ocad = cdxady - adxcdy

  if ocad <= 0:
    return false

  let
    bdxcdy = bdx * cdy
    cdxbdy = cdx * bdy
    alift = adx * adx + ady * ady
    blift = bdx * bdx + bdy * bdy
    clift = cdx * cdx + cdy * cdy
    det = alift * (bdxcdy - cdxbdy) + blift * ocad + clift * oabd

  det > 0

proc legalize(ws: var ArenaWorkspace, t: ptr ArenaTriangle): bool

proc rotateTrianglePair(
    ws: var ArenaWorkspace,
    t: ptr ArenaTriangle,
    p: ptr ArenaPoint,
    ot: ptr ArenaTriangle,
    op: ptr ArenaPoint,
) =
  let
    n1 = t.neighborCCW(p)
    n2 = t.neighborCW(p)
    n3 = ot.neighborCCW(op)
    n4 = ot.neighborCW(op)
    ce1 = t.getConstrainedEdgeCCW(p)
    ce2 = t.getConstrainedEdgeCW(p)
    ce3 = ot.getConstrainedEdgeCCW(op)
    ce4 = ot.getConstrainedEdgeCW(op)
    de1 = t.getDelaunayEdgeCCW(p)
    de2 = t.getDelaunayEdgeCW(p)
    de3 = ot.getDelaunayEdgeCCW(op)
    de4 = ot.getDelaunayEdgeCW(op)

  t.legalize(p, op)
  ot.legalize(op, p)

  ot.setDelaunayEdgeCCW(p, de1)
  t.setDelaunayEdgeCW(p, de2)
  t.setDelaunayEdgeCCW(op, de3)
  ot.setDelaunayEdgeCW(op, de4)

  ot.setConstrainedEdgeCCW(p, ce1)
  t.setConstrainedEdgeCW(p, ce2)
  t.setConstrainedEdgeCCW(op, ce3)
  ot.setConstrainedEdgeCW(op, ce4)

  t.clearNeighbors()
  ot.clearNeighbors()
  if not n1.isNil:
    ot.markNeighbor(n1)
  if not n2.isNil:
    t.markNeighbor(n2)
  if not n3.isNil:
    t.markNeighbor(n3)
  if not n4.isNil:
    ot.markNeighbor(n4)
  t.markNeighbor(ot)

proc legalize(ws: var ArenaWorkspace, t: ptr ArenaTriangle): bool =
  for i in 0 .. 2:
    if t.hasFlag(delaunayFlag(i)):
      continue

    let ot = t.neighbors[i]
    if not ot.isNil:
      let
        p = t.points[i]
        op = ot.oppositePoint(t, p)
        oi = ot.index(op)

      if ot.hasFlag(constrainedFlag(oi)) or ot.hasFlag(delaunayFlag(oi)):
        t.setFlag(constrainedFlag(i), ot.hasFlag(constrainedFlag(oi)))
        continue

      if incircle(p, t.pointCCW(p), t.pointCW(p), op):
        t.setFlag(delaunayFlag(i), true)
        ot.setFlag(delaunayFlag(oi), true)

        ws.rotateTrianglePair(t, p, ot, op)

        var notLegalized = not ws.legalize(t)
        if notLegalized:
          ws.mapTriangleToNodes(t)

        notLegalized = not ws.legalize(ot)
        if notLegalized:
          ws.mapTriangleToNodes(ot)

        t.setFlag(delaunayFlag(i), false)
        ot.setFlag(delaunayFlag(oi), false)
        return true
  false

proc fill(ws: var ArenaWorkspace, n: ptr ArenaNode) =
  let t = ws.newTriangle(n.prev.point, n.point, n.next.point)
  t.markNeighbor(n.prev.triangle)
  t.markNeighbor(n.triangle)

  let prev = n.prev
  let next = n.next
  prev.next = next
  next.prev = prev

  if not ws.legalize(t):
    ws.mapTriangleToNodes(t)

proc angleParts(origin, pa, pb: ptr ArenaPoint): tuple[cross, dot: float64] {.inline.} =
  let
    ax = pa.x - origin.x
    ay = pa.y - origin.y
    bx = pb.x - origin.x
    by = pb.y - origin.y
  (cross: ax * by - ay * bx, dot: ax * bx + ay * by)

proc angleExceeds90Degrees(origin, pa, pb: ptr ArenaPoint): bool {.inline.} =
  angleParts(origin, pa, pb).dot < 0

proc angleIsNegative(origin, pa, pb: ptr ArenaPoint): bool {.inline.} =
  angleParts(origin, pa, pb).cross < 0

proc angleExceedsPlus90DegreesOrIsNegative(
    origin, pa, pb: ptr ArenaPoint
): bool {.inline.} =
  let parts = angleParts(origin, pa, pb)
  parts.cross < 0 or parts.dot < 0

proc largeHoleDontFill(n: ptr ArenaNode): bool =
  let
    nextNode = n.next
    prevNode = n.prev
  if not angleExceeds90Degrees(n.point, nextNode.point, prevNode.point):
    return false
  if angleIsNegative(n.point, nextNode.point, prevNode.point):
    return true
  let next2Node = nextNode.next
  if not next2Node.isNil and
      not angleExceedsPlus90DegreesOrIsNegative(
        n.point, next2Node.point, prevNode.point
      ):
    return false
  let prev2Node = prevNode.prev
  if not prev2Node.isNil and
      not angleExceedsPlus90DegreesOrIsNegative(
        n.point, nextNode.point, prev2Node.point
      ):
    return false
  true

proc basinAngle(n: ptr ArenaNode): float64 {.inline.} =
  let
    ax = n.point.x - n.next.next.point.x
    ay = n.point.y - n.next.next.point.y
  arctan2(ay, ax)

proc isShallow(ws: var ArenaWorkspace, n: ptr ArenaNode): bool =
  let height =
    if ws.basin.leftHighest:
      ws.basin.leftNode.point.y - n.point.y
    else:
      ws.basin.rightNode.point.y - n.point.y
  ws.basin.width > height

proc fillBasinReq(ws: var ArenaWorkspace, n: ptr ArenaNode)

proc fillBasin(ws: var ArenaWorkspace, n: ptr ArenaNode) =
  if orient2d(n.point, n.next.point, n.next.next.point) == ccw:
    ws.basin.leftNode = n.next.next
  else:
    ws.basin.leftNode = n.next

  ws.basin.bottomNode = ws.basin.leftNode
  while not ws.basin.bottomNode.next.isNil and
      ws.basin.bottomNode.point.y >= ws.basin.bottomNode.next.point.y:
    ws.basin.bottomNode = ws.basin.bottomNode.next
  if ws.basin.bottomNode == ws.basin.leftNode:
    return

  ws.basin.rightNode = ws.basin.bottomNode
  while not ws.basin.rightNode.next.isNil and
      ws.basin.rightNode.point.y < ws.basin.rightNode.next.point.y:
    ws.basin.rightNode = ws.basin.rightNode.next
  if ws.basin.rightNode == ws.basin.bottomNode:
    return

  ws.basin.width = ws.basin.rightNode.point.x - ws.basin.leftNode.point.x
  ws.basin.leftHighest = ws.basin.leftNode.point.y > ws.basin.rightNode.point.y
  ws.fillBasinReq(ws.basin.bottomNode)

proc fillBasinReq(ws: var ArenaWorkspace, n: ptr ArenaNode) =
  if ws.isShallow(n):
    return

  ws.fill(n)
  if n.prev == ws.basin.leftNode and n.next == ws.basin.rightNode:
    return
  elif n.prev == ws.basin.leftNode:
    if orient2d(n.point, n.next.point, n.next.next.point) == cw:
      return
    ws.fillBasinReq(n.next)
  elif n.next == ws.basin.rightNode:
    if orient2d(n.point, n.prev.point, n.prev.prev.point) == ccw:
      return
    ws.fillBasinReq(n.prev)
  else:
    if n.prev.point.y < n.next.point.y:
      ws.fillBasinReq(n.prev)
    else:
      ws.fillBasinReq(n.next)

proc fillAdvancingFront(ws: var ArenaWorkspace, n: ptr ArenaNode) =
  var nextNode = n.next
  while not nextNode.next.isNil:
    if largeHoleDontFill(nextNode):
      break
    ws.fill(nextNode)
    nextNode = nextNode.next

  var prevNode = n.prev
  while not prevNode.prev.isNil:
    if largeHoleDontFill(prevNode):
      break
    ws.fill(prevNode)
    prevNode = prevNode.prev

  if not n.next.isNil and not n.next.next.isNil and n.basinAngle < Pi3Div4:
    ws.fillBasin(n)

proc isEdgeSideOfTriangle(t: ptr ArenaTriangle, ep, eq: ptr ArenaPoint): bool =
  let idx = t.edgeIndex(ep, eq)
  if idx != -1:
    t.markConstrainedEdge(idx)
    let neighbor = t.neighbors[idx]
    if not neighbor.isNil:
      neighbor.markConstrainedEdge(ep, eq)
    return true
  false

proc newFrontTriangle(
    ws: var ArenaWorkspace, p: ptr ArenaPoint, n: ptr ArenaNode
): ptr ArenaNode =
  let t = ws.newTriangle(p, n.point, n.next.point)
  t.markNeighbor(n.triangle)

  result = ws.newNode(p)
  result.next = n.next
  result.prev = n
  n.next.prev = result
  n.next = result

  if not ws.legalize(t):
    ws.mapTriangleToNodes(t)
  result.triangle = t

proc pointEvent(ws: var ArenaWorkspace, p: ptr ArenaPoint): ptr ArenaNode =
  let n = ws.locateNode(p.x)
  if n.isNil:
    raise newException(ValueError, "failed to locate advancing-front node")
  result = ws.newFrontTriangle(p, n)
  if p.x <= n.point.x + Epsilon:
    ws.fill(n)
  ws.fillAdvancingFront(result)

proc fillRightConcaveEdgeEvent(
  ws: var ArenaWorkspace, edge: ptr ArenaEdge, n: ptr ArenaNode
)

proc fillRightConvexEdgeEvent(
  ws: var ArenaWorkspace, edge: ptr ArenaEdge, n: ptr ArenaNode
)

proc fillRightBelowEdgeEvent(
  ws: var ArenaWorkspace, edge: ptr ArenaEdge, n: ptr ArenaNode
)

proc fillLeftBelowEdgeEvent(
  ws: var ArenaWorkspace, edge: ptr ArenaEdge, n: ptr ArenaNode
)

proc fillLeftConcaveEdgeEvent(
  ws: var ArenaWorkspace, edge: ptr ArenaEdge, n: ptr ArenaNode
)

proc fillLeftConvexEdgeEvent(
  ws: var ArenaWorkspace, edge: ptr ArenaEdge, n: ptr ArenaNode
)

proc edgeEvent(
  ws: var ArenaWorkspace,
  ep, eq: ptr ArenaPoint,
  t: ptr ArenaTriangle,
  p: ptr ArenaPoint,
)

proc flipEdgeEvent(
  ws: var ArenaWorkspace,
  ep, eq: ptr ArenaPoint,
  t: ptr ArenaTriangle,
  p: ptr ArenaPoint,
)

proc fillRightAboveEdgeEvent(
    ws: var ArenaWorkspace, edge: ptr ArenaEdge, n: ptr ArenaNode
) =
  var n = n
  while n.next.point.x < edge.p.x:
    if orient2d(edge.q, n.next.point, edge.p) == ccw:
      ws.fillRightBelowEdgeEvent(edge, n)
    else:
      n = n.next

proc fillRightBelowEdgeEvent(
    ws: var ArenaWorkspace, edge: ptr ArenaEdge, n: ptr ArenaNode
) =
  if n.point.x < edge.p.x:
    if orient2d(n.point, n.next.point, n.next.next.point) == ccw:
      ws.fillRightConcaveEdgeEvent(edge, n)
    else:
      ws.fillRightConvexEdgeEvent(edge, n)
      ws.fillRightBelowEdgeEvent(edge, n)

proc fillRightConcaveEdgeEvent(
    ws: var ArenaWorkspace, edge: ptr ArenaEdge, n: ptr ArenaNode
) =
  ws.fill(n.next)
  if n.next.point != edge.p:
    if orient2d(edge.q, n.next.point, edge.p) == ccw:
      if orient2d(n.point, n.next.point, n.next.next.point) == ccw:
        ws.fillRightConcaveEdgeEvent(edge, n)

proc fillRightConvexEdgeEvent(
    ws: var ArenaWorkspace, edge: ptr ArenaEdge, n: ptr ArenaNode
) =
  if orient2d(n.next.point, n.next.next.point, n.next.next.next.point) == ccw:
    ws.fillRightConcaveEdgeEvent(edge, n.next)
  elif orient2d(edge.q, n.next.next.point, edge.p) == ccw:
    ws.fillRightConvexEdgeEvent(edge, n.next)

proc fillLeftAboveEdgeEvent(
    ws: var ArenaWorkspace, edge: ptr ArenaEdge, n: ptr ArenaNode
) =
  var n = n
  while n.prev.point.x > edge.p.x:
    if orient2d(edge.q, n.prev.point, edge.p) == cw:
      ws.fillLeftBelowEdgeEvent(edge, n)
    else:
      n = n.prev

proc fillLeftBelowEdgeEvent(
    ws: var ArenaWorkspace, edge: ptr ArenaEdge, n: ptr ArenaNode
) =
  if n.point.x > edge.p.x:
    if orient2d(n.point, n.prev.point, n.prev.prev.point) == cw:
      ws.fillLeftConcaveEdgeEvent(edge, n)
    else:
      ws.fillLeftConvexEdgeEvent(edge, n)
      ws.fillLeftBelowEdgeEvent(edge, n)

proc fillLeftConvexEdgeEvent(
    ws: var ArenaWorkspace, edge: ptr ArenaEdge, n: ptr ArenaNode
) =
  if orient2d(n.prev.point, n.prev.prev.point, n.prev.prev.prev.point) == cw:
    ws.fillLeftConcaveEdgeEvent(edge, n.prev)
  elif orient2d(edge.q, n.prev.prev.point, edge.p) == cw:
    ws.fillLeftConvexEdgeEvent(edge, n.prev)

proc fillLeftConcaveEdgeEvent(
    ws: var ArenaWorkspace, edge: ptr ArenaEdge, n: ptr ArenaNode
) =
  ws.fill(n.prev)
  if n.prev.point != edge.p:
    if orient2d(edge.q, n.prev.point, edge.p) == cw:
      if orient2d(n.point, n.prev.point, n.prev.prev.point) == cw:
        ws.fillLeftConcaveEdgeEvent(edge, n)

proc fillEdgeEvent(ws: var ArenaWorkspace, edge: ptr ArenaEdge, n: ptr ArenaNode) =
  if ws.edgeEvent.right:
    ws.fillRightAboveEdgeEvent(edge, n)
  else:
    ws.fillLeftAboveEdgeEvent(edge, n)

proc nextFlipTriangle(
    ws: var ArenaWorkspace,
    o: Orientation,
    t, ot: ptr ArenaTriangle,
    p, op: ptr ArenaPoint,
): ptr ArenaTriangle =
  if o == ccw:
    let idx = ot.edgeIndex(p, op)
    ot.setFlag(delaunayFlag(idx), true)
    discard ws.legalize(ot)
    ot.clearDelaunayEdges()
    return t

  let idx = t.edgeIndex(p, op)
  t.setFlag(delaunayFlag(idx), true)
  discard ws.legalize(t)
  t.clearDelaunayEdges()
  ot

proc nextFlipPoint(
    ep, eq: ptr ArenaPoint, ot: ptr ArenaTriangle, op: ptr ArenaPoint
): ptr ArenaPoint =
  case orient2d(eq, op, ep)
  of cw:
    ot.pointCCW(op)
  of ccw:
    ot.pointCW(op)
  of collinear:
    raise newException(ValueError, "opposing point on constrained edge")

proc flipScanEdgeEvent(
    ws: var ArenaWorkspace,
    ep, eq: ptr ArenaPoint,
    flipTriangle, t: ptr ArenaTriangle,
    p: ptr ArenaPoint,
) =
  let ot = t.neighborAcross(p)
  if ot.isNil:
    raise newException(ValueError, "flip scan failed due to missing triangle")
  let op = ot.oppositePoint(t, p)

  if inScanArea(eq, flipTriangle.pointCCW(eq), flipTriangle.pointCW(eq), op):
    ws.flipEdgeEvent(eq, op, ot, op)
  else:
    let newP = nextFlipPoint(ep, eq, ot, op)
    ws.flipScanEdgeEvent(ep, eq, flipTriangle, ot, newP)

proc flipEdgeEvent(
    ws: var ArenaWorkspace,
    ep, eq: ptr ArenaPoint,
    t: ptr ArenaTriangle,
    p: ptr ArenaPoint,
) =
  let ot = t.neighborAcross(p)
  if ot.isNil:
    raise newException(ValueError, "flip failed due to missing triangle")
  let op = ot.oppositePoint(t, p)

  if inScanArea(p, t.pointCCW(p), t.pointCW(p), op):
    ws.rotateTrianglePair(t, p, ot, op)
    ws.mapTriangleToNodes(t)
    ws.mapTriangleToNodes(ot)

    if p == eq and op == ep:
      if eq == ws.edgeEvent.constrainedEdge.q and ep == ws.edgeEvent.constrainedEdge.p:
        t.markConstrainedEdge(ep, eq)
        ot.markConstrainedEdge(ep, eq)
        discard ws.legalize(t)
        discard ws.legalize(ot)
    else:
      let o = orient2d(eq, op, ep)
      let nextT = ws.nextFlipTriangle(o, t, ot, p, op)
      ws.flipEdgeEvent(ep, eq, nextT, p)
  else:
    let newP = nextFlipPoint(ep, eq, ot, op)
    ws.flipScanEdgeEvent(ep, eq, t, ot, newP)
    ws.edgeEvent(ep, eq, t, p)

proc edgeEvent(
    ws: var ArenaWorkspace,
    ep, eq: ptr ArenaPoint,
    t: ptr ArenaTriangle,
    p: ptr ArenaPoint,
) =
  var t = t
  if t.isEdgeSideOfTriangle(ep, eq):
    return

  let p1 = t.pointCCW(p)
  let o1 = orient2d(eq, p1, ep)
  if o1 == collinear:
    if t.contains(eq, p1):
      t.markConstrainedEdge(eq, p1)
      ws.edgeEvent.constrainedEdge.q = p1
      ws.edgeEvent(ep, p1, t.neighborAcross(p), p1)
    else:
      raise
        newException(ValueError, "collinear constrained edge points are not supported")
    return

  let p2 = t.pointCW(p)
  let o2 = orient2d(eq, p2, ep)
  if o2 == collinear:
    if t.contains(eq, p2):
      t.markConstrainedEdge(eq, p2)
      ws.edgeEvent.constrainedEdge.q = p2
      ws.edgeEvent(ep, p2, t.neighborAcross(p), p2)
    else:
      raise
        newException(ValueError, "collinear constrained edge points are not supported")
    return

  if o1 == o2:
    if o1 == cw:
      t = t.neighborCCW(p)
    else:
      t = t.neighborCW(p)
    if t.isNil:
      raise newException(ValueError, "missing neighbor while walking constrained edge")
    ws.edgeEvent(ep, eq, t, p)
  else:
    ws.flipEdgeEvent(ep, eq, t, p)

proc edgeEvent(ws: var ArenaWorkspace, edge: ptr ArenaEdge, n: ptr ArenaNode) =
  ws.edgeEvent.constrainedEdge = edge
  ws.edgeEvent.right = edge.p.x > edge.q.x
  if n.triangle.isEdgeSideOfTriangle(edge.p, edge.q):
    return
  ws.fillEdgeEvent(edge, n)
  ws.edgeEvent(edge.p, edge.q, n.triangle, edge.q)

proc sweepPoints(ws: var ArenaWorkspace) =
  for i in 1 ..< ws.activePoints.len:
    let p = ws.activePoints[i]
    let n = ws.pointEvent(p)
    var edge = p.firstEdge
    while not edge.isNil:
      ws.edgeEvent(edge, n)
      edge = edge.next

proc finalizationPolygon(ws: var ArenaWorkspace) =
  var t = ws.front.head.next.triangle
  let p = ws.front.head.next.point
  while not t.getConstrainedEdgeCW(p):
    t = t.neighborCCW(p)
    if t.isNil:
      raise newException(ValueError, "failed to find finalization triangle")
  ws.meshClean(t)

proc triangulate(ws: var ArenaWorkspace) =
  ws.initTriangulation()
  ws.createAdvancingFront()
  ws.sweepPoints()
  ws.finalizationPolygon()

proc sourceTriangle(t: ptr ArenaTriangle): array[3, int] =
  if t.isNil or t.points[0].isNil or t.points[1].isNil or t.points[2].isNil or
      t.points[0] == t.points[1] or t.points[0] == t.points[2] or
      t.points[1] == t.points[2]:
    return [-1, -1, -1]
  let
    a = t.points[0].sourceIndex.int
    b = t.points[1].sourceIndex.int
    c = t.points[2].sourceIndex.int
  if a == b or a == c or b == c:
    return [-1, -1, -1]
  [a, b, c]

proc validRawTriangle(t: ptr ArenaTriangle): bool {.inline.} =
  not t.isNil and not t.points[0].isNil and not t.points[1].isNil and
    not t.points[2].isNil and t.points[0] != t.points[1] and t.points[0] != t.points[2] and
    t.points[1] != t.points[2]

proc rawTriangle(raw: TessRawResult, triangleIndex: int): ptr ArenaTriangle =
  var seen = 0
  for tri in raw.arena[].interiorTriangles:
    if tri.validRawTriangle:
      if seen == triangleIndex:
        return tri
      inc seen
  nil

proc rawTrianglePoints*(raw: TessRawResult, triangleIndex: int): array[3, CdtPointId] =
  let tri = raw.rawTriangle(triangleIndex)
  [
    tri.points[0].id.CdtPointId,
    tri.points[1].id.CdtPointId,
    tri.points[2].id.CdtPointId,
  ]

proc rawTriangleVertices*(raw: TessRawResult, triangleIndex: int): array[3, Vec2] =
  let tri = raw.rawTriangle(triangleIndex)
  [
    Vec2(x: tri.points[0].x, y: tri.points[0].y),
    Vec2(x: tri.points[1].x, y: tri.points[1].y),
    Vec2(x: tri.points[2].x, y: tri.points[2].y),
  ]

proc rawTriangleCount*(raw: TessRawResult): int =
  if raw.ok and not raw.arena.isNil:
    for tri in raw.arena[].interiorTriangles:
      if tri.validRawTriangle:
        inc result

proc addContour(ws: var ArenaWorkspace, contour: seq[Vec2], vertices: var seq[Vec2]) =
  if contour.len == 0:
    return

  vertices.add contour[0]
  let first = ws.newPoint(contour[0].x, contour[0].y, vertices.high)
  ws.activePoints.add first
  var prev = first

  for i in 1 ..< contour.len:
    vertices.add contour[i]
    let point = ws.newPoint(contour[i].x, contour[i].y, vertices.high)
    ws.activePoints.add point
    discard ws.newEdge(prev, point)
    prev = point

  discard ws.newEdge(prev, first)

proc addContourRaw(ws: var ArenaWorkspace, contour: openArray[Vec2]) =
  if contour.len == 0:
    return

  let first = ws.newPoint(contour[0].x, contour[0].y)
  ws.activePoints.add first
  var prev = first

  for i in 1 ..< contour.len:
    let point = ws.newPoint(contour[i].x, contour[i].y)
    ws.activePoints.add point
    discard ws.newEdge(prev, point)
    prev = point

  discard ws.newEdge(prev, first)

proc triangulateCdtInPlace(workspace: var TessWorkspace, input: CdtInput) =
  if input.outer.len < 3:
    raise newException(ValueError, "outer contour has fewer than 3 points")

  workspace.arena.resetCdt()
  workspace.vertices.setLen(0)

  var pointCount = input.outer.len + input.steiner.len
  for hole in input.holes:
    pointCount += hole.len
  workspace.reserveArena(pointCount, keepVertices = true)

  workspace.arena.addContour(input.outer, workspace.vertices)

  for hole in input.holes:
    workspace.arena.addContour(hole, workspace.vertices)

  for p in input.steiner:
    workspace.vertices.add p
    workspace.arena.addPoint(
      workspace.arena.newPoint(p.x, p.y, workspace.vertices.high)
    )

  workspace.arena.triangulate()

proc triangulateCdt*(workspace: var TessWorkspace, input: CdtInput): CdtResult =
  workspace.triangulateCdtInPlace(input)

  result.vertices = workspace.vertices
  result.triangles.reserveSeq(workspace.arena.interiorTriangles.len)
  for t in workspace.arena.interiorTriangles:
    let tri = t.sourceTriangle()
    if tri[0] < 0 or tri[1] < 0 or tri[2] < 0:
      continue
    result.triangles.add tri

proc triangulateCdtRaw*(workspace: var TessWorkspace, input: CdtInput): CdtRawResult =
  workspace.triangulateCdtInPlace(input)
  CdtRawResult(vertices: addr workspace.vertices, arena: addr workspace.arena)

proc triangulateCdtRaw*(workspace: var TessWorkspace, input: TessInput): CdtRawResult =
  if input.outer.points.len < 3:
    raise newException(ValueError, "outer contour has fewer than 3 points")

  workspace.arena.resetCdt()
  workspace.vertices.setLen(0)

  var pointCount = input.outer.points.len + input.steiner.len
  for hole in input.holes:
    pointCount += hole.points.len
  workspace.reserveArena(pointCount, keepVertices = false)

  workspace.arena.addContourRaw(input.outer.points)

  for hole in input.holes:
    workspace.arena.addContourRaw(hole.points)

  for p in input.steiner:
    workspace.arena.addPoint(workspace.arena.newPoint(p.x, p.y))

  workspace.arena.triangulate()
  CdtRawResult(vertices: addr workspace.vertices, arena: addr workspace.arena)

when defined(p2tUnsafeCdt):
  {.pop.}
