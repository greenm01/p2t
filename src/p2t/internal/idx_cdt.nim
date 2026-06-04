## int32-index sweep-line constrained Delaunay triangulation (CDT).
##
## This is a faithful, line-for-line twin of arena_cdt.nim: same Poly2Tri
## advancing-front algorithm, same control flow, same front-hash accelerator.
## The ONLY difference is the mesh representation - every handle is a 32-bit
## index into reusable workspace seqs (sentinel NilId = -1) accessed through
## explicit `ws` accessors, instead of a raw pointer into an arena buffer.
##
## Keeping both modules lets us A/B the int32-index vs pointer data layout on an
## otherwise identical implementation. Selected with -d:p2tIdxCdt. Slot tracking
## (p2tSlotCdt) and stats (p2tCdtStats) are intentionally omitted here.

import ../types

when defined(p2tUnsafeCdt):
  {.push checks: off.}

const
  Epsilon = IdxReal(1e-12)
  Alpha = IdxReal(0.3)
  DelaunayEdge0 = 1'u32 shl 0
  ConstrainedEdge0 = 1'u32 shl 3
  InteriorFlag = 1'u32 shl 30
  DelaunayEdgeMask = DelaunayEdge0 or (DelaunayEdge0 shl 1) or (DelaunayEdge0 shl 2)
  NextEdgeIndex = [1, 2, 0]
  PrevEdgeIndex = [2, 0, 1]
  NilId = -1'i32

when FrontHashOn:
  const
    FrontHashMinPoints {.intdefine.} = 512
    FrontHashBucketFactor {.intdefine.} = 2
    FrontHashScanRadius {.intdefine.} = 8

  template frontHashPointCountEnabled(pointCount: int): bool =
    pointCount >= FrontHashMinPoints

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
    idx*: ptr IdxWorkspace

# Index accessors. Untyped templates keep lvalue/var-ness so `ws.tri(id).x = y`
# works exactly like a field assignment - no hidden indirection beyond the
# base+index addressing we are measuring.
template pt(ws, id): untyped =
  ws.points[id]

template eg(ws, id): untyped =
  ws.edges[id]

template tri(ws, id): untyped =
  ws.triangles[id]

template nd(ws, id): untyped =
  ws.nodes[id]

proc resetCdt(ws: var IdxWorkspace) =
  ws.pointCount = 0
  ws.edgeCount = 0
  ws.triangleCount = 0
  ws.nodeCount = 0
  ws.rawInteriorCount = 0
  ws.activePoints.setLen(0)
  ws.sortTemp.setLen(0)
  ws.meshStack.setLen(0)
  ws.interiorTriangles.setLen(0)
  when FrontHashOn:
    ws.frontBuckets.setLen(0)
    ws.frontBucketMin = 0
    ws.frontBucketScale = 0
  ws.front = IdxFront()
  ws.head = NilId
  ws.tail = NilId
  ws.afHead = NilId
  ws.afMiddle = NilId
  ws.afTail = NilId
  ws.basin = IdxBasin()
  ws.edgeEvent = IdxEdgeEvent()

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
  workspace.idx.points.ensureCapacity(pointCount + 2)
  workspace.idx.edges.ensureCapacity(pointCount)
  workspace.idx.nodes.ensureCapacity(pointCount + 4)
  workspace.idx.triangles.ensureCapacity(2 * pointCount + 4)
  workspace.idx.meshStack.reserveSeq(2 * pointCount + 4)
  workspace.idx.interiorTriangles.reserveSeq(2 * pointCount + 4)
  when FrontHashOn:
    if frontHashPointCountEnabled(pointCount):
      workspace.idx.frontBuckets.reserveSeq(max(16, pointCount div 4))
  workspace.idx.activePoints.reserveSeq(pointCount + 2)
  when not defined(p2tQuickSort):
    workspace.idx.sortTemp.reserveSeq(pointCount + 2)
  when keepVertices:
    workspace.vertices.reserveSeq(pointCount)

proc edgeFlag(base: uint32, index: int): uint32 {.inline.} =
  base shl index

proc hasFlag(ws: var IdxWorkspace, tr: IdxTriangleId, flag: uint32): bool {.inline.} =
  (ws.tri(tr).flags and flag) != 0

proc setFlag(ws: var IdxWorkspace, tr: IdxTriangleId, flag: uint32, value: bool) {.inline.} =
  if value:
    ws.tri(tr).flags = ws.tri(tr).flags or flag
  else:
    ws.tri(tr).flags = ws.tri(tr).flags and not flag

proc constrainedFlag(index: int): uint32 {.inline.} =
  edgeFlag(ConstrainedEdge0, index)

proc delaunayFlag(index: int): uint32 {.inline.} =
  edgeFlag(DelaunayEdge0, index)

proc asIdxReal(x: float64): IdxReal {.inline.} =
  IdxReal(x)

proc newPoint(
    ws: var IdxWorkspace, x, y: float64, sourceIndex = -1
): IdxPointId {.inline.} =
  result = ws.pointCount.IdxPointId
  ws.pt(result).firstEdge = NilId
  ws.pt(result).node = NilId
  ws.pt(result).x = x.asIdxReal
  ws.pt(result).y = y.asIdxReal
  ws.pt(result).sourceIndex = sourceIndex.int32
  inc ws.pointCount

proc orient2d(ws: var IdxWorkspace, pa, pb, pc: IdxPointId): Orientation {.inline.} =
  let
    detleft = (ws.pt(pa).x - ws.pt(pc).x) * (ws.pt(pb).y - ws.pt(pc).y)
    detright = (ws.pt(pa).y - ws.pt(pc).y) * (ws.pt(pb).x - ws.pt(pc).x)
    val = detleft - detright
  if val > -Epsilon and val < Epsilon:
    collinear
  elif val > 0:
    ccw
  else:
    cw

proc inScanArea(ws: var IdxWorkspace, pa, pb, pc, pd: IdxPointId): bool {.inline.} =
  let oadb = (ws.pt(pa).x - ws.pt(pb).x) * (ws.pt(pd).y - ws.pt(pb).y) -
    (ws.pt(pd).x - ws.pt(pb).x) * (ws.pt(pa).y - ws.pt(pb).y)
  if oadb >= -Epsilon:
    return false

  let oadc = (ws.pt(pa).x - ws.pt(pc).x) * (ws.pt(pd).y - ws.pt(pc).y) -
    (ws.pt(pd).x - ws.pt(pc).x) * (ws.pt(pa).y - ws.pt(pc).y)
  if oadc <= Epsilon:
    return false
  true

proc newEdge(ws: var IdxWorkspace, p1, p2: IdxPointId): IdxEdgeId {.inline.} =
  result = ws.edgeCount.IdxEdgeId
  inc ws.edgeCount
  var p = p1
  var q = p2
  if ws.pt(p1).y > ws.pt(p2).y:
    q = p1
    p = p2
  elif ws.pt(p1).y == ws.pt(p2).y:
    if ws.pt(p1).x > ws.pt(p2).x:
      q = p1
      p = p2
    elif ws.pt(p1).x == ws.pt(p2).x:
      raise newException(ValueError, "repeat points in constrained edge")
  ws.eg(result).p = p
  ws.eg(result).q = q
  ws.eg(result).next = NilId
  if ws.pt(q).firstEdge == NilId:
    ws.pt(q).firstEdge = result
  else:
    var last = ws.pt(q).firstEdge
    while ws.eg(last).next != NilId:
      last = ws.eg(last).next
    ws.eg(last).next = result

proc newTriangle(
    ws: var IdxWorkspace, a, b, c: IdxPointId
): IdxTriangleId {.inline.} =
  result = ws.triangleCount.IdxTriangleId
  ws.tri(result).points[0] = a
  ws.tri(result).points[1] = b
  ws.tri(result).points[2] = c
  ws.tri(result).neighbors[0] = NilId
  ws.tri(result).neighbors[1] = NilId
  ws.tri(result).neighbors[2] = NilId
  ws.tri(result).flags = 0
  inc ws.triangleCount

proc contains(ws: var IdxWorkspace, t: IdxTriangleId, p: IdxPointId): bool {.inline.} =
  ws.tri(t).points[0] == p or ws.tri(t).points[1] == p or ws.tri(t).points[2] == p

proc contains(ws: var IdxWorkspace, t: IdxTriangleId, p, q: IdxPointId): bool {.inline.} =
  ws.contains(t, p) and ws.contains(t, q)

proc edgeIndexPlain(
    ws: var IdxWorkspace, t: IdxTriangleId, p1, p2: IdxPointId
): int {.inline.} =
  if ws.tri(t).points[0] == p1:
    if ws.tri(t).points[1] == p2:
      return 2
    if ws.tri(t).points[2] == p2:
      return 1
  elif ws.tri(t).points[1] == p1:
    if ws.tri(t).points[2] == p2:
      return 0
    if ws.tri(t).points[0] == p2:
      return 2
  elif ws.tri(t).points[2] == p1:
    if ws.tri(t).points[0] == p2:
      return 1
    if ws.tri(t).points[1] == p2:
      return 0
  -1

proc markNeighbor(
    ws: var IdxWorkspace, t: IdxTriangleId, p1, p2: IdxPointId, other: IdxTriangleId
) {.inline.} =
  if (p1 == ws.tri(t).points[2] and p2 == ws.tri(t).points[1]) or
      (p1 == ws.tri(t).points[1] and p2 == ws.tri(t).points[2]):
    ws.tri(t).neighbors[0] = other
  elif (p1 == ws.tri(t).points[0] and p2 == ws.tri(t).points[2]) or
      (p1 == ws.tri(t).points[2] and p2 == ws.tri(t).points[0]):
    ws.tri(t).neighbors[1] = other
  elif (p1 == ws.tri(t).points[0] and p2 == ws.tri(t).points[1]) or
      (p1 == ws.tri(t).points[1] and p2 == ws.tri(t).points[0]):
    ws.tri(t).neighbors[2] = other

proc swapNeighbor(
    ws: var IdxWorkspace, t: IdxTriangleId, oldNeighbor, newNeighbor: IdxTriangleId
) {.inline, used.} =
  for i in 0 .. 2:
    if ws.tri(t).neighbors[i] == oldNeighbor:
      ws.tri(t).neighbors[i] = newNeighbor
      return

proc neighborIndexPlain(
    ws: var IdxWorkspace, t: IdxTriangleId, neighbor: IdxTriangleId
): int {.inline, used.} =
  for i in 0 .. 2:
    if ws.tri(t).neighbors[i] == neighbor:
      return i
  -1

proc clearDelaunayEdges(ws: var IdxWorkspace, t: IdxTriangleId) {.inline.} =
  ws.tri(t).flags = ws.tri(t).flags and not DelaunayEdgeMask

proc neighborCW(
    ws: var IdxWorkspace, t: IdxTriangleId, p: IdxPointId
): IdxTriangleId {.inline, used.} =
  if p == ws.tri(t).points[0]:
    ws.tri(t).neighbors[1]
  elif p == ws.tri(t).points[1]:
    ws.tri(t).neighbors[2]
  else:
    ws.tri(t).neighbors[0]

proc neighborCCW(
    ws: var IdxWorkspace, t: IdxTriangleId, p: IdxPointId
): IdxTriangleId {.inline.} =
  if p == ws.tri(t).points[0]:
    ws.tri(t).neighbors[2]
  elif p == ws.tri(t).points[1]:
    ws.tri(t).neighbors[0]
  else:
    ws.tri(t).neighbors[1]

proc getConstrainedEdgeCCW(
    ws: var IdxWorkspace, t: IdxTriangleId, p: IdxPointId
): bool {.inline, used.} =
  if p == ws.tri(t).points[0]:
    ws.hasFlag(t, constrainedFlag(2))
  elif p == ws.tri(t).points[1]:
    ws.hasFlag(t, constrainedFlag(0))
  else:
    ws.hasFlag(t, constrainedFlag(1))

proc getConstrainedEdgeCW(
    ws: var IdxWorkspace, t: IdxTriangleId, p: IdxPointId
): bool {.inline.} =
  if p == ws.tri(t).points[0]:
    ws.hasFlag(t, constrainedFlag(1))
  elif p == ws.tri(t).points[1]:
    ws.hasFlag(t, constrainedFlag(2))
  else:
    ws.hasFlag(t, constrainedFlag(0))

proc setConstrainedEdgeCCW(
    ws: var IdxWorkspace, t: IdxTriangleId, p: IdxPointId, ce: bool
) =
  if p == ws.tri(t).points[0]:
    ws.setFlag(t, constrainedFlag(2), ce)
  elif p == ws.tri(t).points[1]:
    ws.setFlag(t, constrainedFlag(0), ce)
  else:
    ws.setFlag(t, constrainedFlag(1), ce)

proc setConstrainedEdgeCW(
    ws: var IdxWorkspace, t: IdxTriangleId, p: IdxPointId, ce: bool
) =
  if p == ws.tri(t).points[0]:
    ws.setFlag(t, constrainedFlag(1), ce)
  elif p == ws.tri(t).points[1]:
    ws.setFlag(t, constrainedFlag(2), ce)
  else:
    ws.setFlag(t, constrainedFlag(0), ce)

proc getDelaunayEdgeCCW(
    ws: var IdxWorkspace, t: IdxTriangleId, p: IdxPointId
): bool {.inline, used.} =
  if p == ws.tri(t).points[0]:
    ws.hasFlag(t, delaunayFlag(2))
  elif p == ws.tri(t).points[1]:
    ws.hasFlag(t, delaunayFlag(0))
  else:
    ws.hasFlag(t, delaunayFlag(1))

proc getDelaunayEdgeCW(
    ws: var IdxWorkspace, t: IdxTriangleId, p: IdxPointId
): bool {.inline, used.} =
  if p == ws.tri(t).points[0]:
    ws.hasFlag(t, delaunayFlag(1))
  elif p == ws.tri(t).points[1]:
    ws.hasFlag(t, delaunayFlag(2))
  else:
    ws.hasFlag(t, delaunayFlag(0))

proc setDelaunayEdgeCCW(
    ws: var IdxWorkspace, t: IdxTriangleId, p: IdxPointId, edge: bool
) =
  if p == ws.tri(t).points[0]:
    ws.setFlag(t, delaunayFlag(2), edge)
  elif p == ws.tri(t).points[1]:
    ws.setFlag(t, delaunayFlag(0), edge)
  else:
    ws.setFlag(t, delaunayFlag(1), edge)

proc setDelaunayEdgeCW(
    ws: var IdxWorkspace, t: IdxTriangleId, p: IdxPointId, edge: bool
) =
  if p == ws.tri(t).points[0]:
    ws.setFlag(t, delaunayFlag(1), edge)
  elif p == ws.tri(t).points[1]:
    ws.setFlag(t, delaunayFlag(2), edge)
  else:
    ws.setFlag(t, delaunayFlag(0), edge)

proc oppositePointAcross(
    ws: var IdxWorkspace, t: IdxTriangleId, a, b: IdxPointId
): tuple[point: IdxPointId, index: int] {.inline.} =
  if ws.tri(t).points[0] != a and ws.tri(t).points[0] != b:
    (ws.tri(t).points[0], 0)
  elif ws.tri(t).points[1] != a and ws.tri(t).points[1] != b:
    (ws.tri(t).points[1], 1)
  else:
    (ws.tri(t).points[2], 2)

proc legalize(
    ws: var IdxWorkspace, t: IdxTriangleId, opoint, npoint: IdxPointId
) =
  if opoint == ws.tri(t).points[0]:
    ws.tri(t).points[1] = ws.tri(t).points[0]
    ws.tri(t).points[0] = ws.tri(t).points[2]
    ws.tri(t).points[2] = npoint
  elif opoint == ws.tri(t).points[1]:
    ws.tri(t).points[2] = ws.tri(t).points[1]
    ws.tri(t).points[1] = ws.tri(t).points[0]
    ws.tri(t).points[0] = npoint
  else:
    ws.tri(t).points[0] = ws.tri(t).points[2]
    ws.tri(t).points[2] = ws.tri(t).points[1]
    ws.tri(t).points[1] = npoint

proc index(ws: var IdxWorkspace, t: IdxTriangleId, p: IdxPointId): int {.inline.} =
  if p == ws.tri(t).points[0]:
    0
  elif p == ws.tri(t).points[1]:
    1
  elif p == ws.tri(t).points[2]:
    2
  else:
    -1

proc edgeIndex(
    ws: var IdxWorkspace, t: IdxTriangleId, p1, p2: IdxPointId
): int {.inline.} =
  ws.edgeIndexPlain(t, p1, p2)

proc markConstrainedEdge(ws: var IdxWorkspace, t: IdxTriangleId, edgeIndex: int) {.inline.} =
  ws.setFlag(t, constrainedFlag(edgeIndex), true)

proc markConstrainedEdge(
    ws: var IdxWorkspace, t: IdxTriangleId, p, q: IdxPointId
) {.inline.} =
  if (q == ws.tri(t).points[0] and p == ws.tri(t).points[1]) or
      (q == ws.tri(t).points[1] and p == ws.tri(t).points[0]):
    ws.setFlag(t, constrainedFlag(2), true)
  elif (q == ws.tri(t).points[0] and p == ws.tri(t).points[2]) or (
    q == ws.tri(t).points[2] and p == ws.tri(t).points[0]
  ):
    ws.setFlag(t, constrainedFlag(1), true)
  elif (q == ws.tri(t).points[1] and p == ws.tri(t).points[2]) or (
    q == ws.tri(t).points[2] and p == ws.tri(t).points[1]
  ):
    ws.setFlag(t, constrainedFlag(0), true)

proc newNode(
    ws: var IdxWorkspace, p: IdxPointId, t: IdxTriangleId = NilId
): IdxNodeId {.inline.} =
  result = ws.nodeCount.IdxNodeId
  ws.nd(result).next = NilId
  ws.nd(result).prev = NilId
  ws.nd(result).point = p
  ws.nd(result).triangle = t
  ws.nd(result).value = ws.pt(p).x
  ws.pt(p).node = result
  inc ws.nodeCount

when FrontHashOn:
  proc frontHashBucketCount(pointCount: int): int =
    var root = 1
    while root * root < pointCount:
      inc root
    max(16, root * FrontHashBucketFactor)

  proc initFrontHash(ws: var IdxWorkspace, xmin, xmax: IdxReal, pointCount: int) =
    if not frontHashPointCountEnabled(pointCount):
      ws.frontBuckets.setLen(0)
      ws.frontBucketMin = 0
      ws.frontBucketScale = 0
      return

    let bucketCount = frontHashBucketCount(pointCount)
    ws.frontBuckets.setLen(bucketCount)
    for i in 0 ..< ws.frontBuckets.len:
      ws.frontBuckets[i] = NilId
    ws.frontBucketMin = xmin
    let width = xmax - xmin
    ws.frontBucketScale =
      if width > 0:
        IdxReal(bucketCount - 1) / width
      else:
        0

  proc frontBucketIndex(ws: var IdxWorkspace, x: IdxReal): int {.inline.} =
    if ws.frontBuckets.len == 0:
      return 0
    result = ((x - ws.frontBucketMin) * ws.frontBucketScale).int
    if result < 0:
      result = 0
    elif result >= ws.frontBuckets.len:
      result = ws.frontBuckets.high

  proc isLiveFrontNode(ws: var IdxWorkspace, n: IdxNodeId): bool {.inline.} =
    n != NilId and ws.nd(n).point != NilId and ws.pt(ws.nd(n).point).node == n

  proc idxAbs(x: IdxReal): IdxReal {.inline.} =
    if x < 0:
      -x
    else:
      x

  proc updateFrontBucket(ws: var IdxWorkspace, n: IdxNodeId) =
    if ws.frontBuckets.len == 0 or not ws.isLiveFrontNode(n):
      return
    let
      idx = ws.frontBucketIndex(ws.nd(n).value)
      existing = ws.frontBuckets[idx]
    if not ws.isLiveFrontNode(existing):
      ws.frontBuckets[idx] = n
      return

    let
      bucketX =
        if ws.frontBucketScale > 0:
          ws.frontBucketMin + IdxReal(idx) / ws.frontBucketScale
        else:
          ws.nd(n).value
      existingDist = idxAbs(ws.nd(existing).value - bucketX)
      nodeDist = idxAbs(ws.nd(n).value - bucketX)
    if nodeDist <= existingDist:
      ws.frontBuckets[idx] = n

  proc nearestBucketNode(ws: var IdxWorkspace, x: IdxReal): IdxNodeId =
    if ws.frontBuckets.len == 0:
      return NilId
    let idx = ws.frontBucketIndex(x)
    let direct = ws.frontBuckets[idx]
    if ws.isLiveFrontNode(direct):
      return direct
    ws.frontBuckets[idx] = NilId
    when FrontHashScanRadius > 0:
      for offset in 1 .. min(ws.frontBuckets.high, FrontHashScanRadius):
        let left = idx - offset
        if left >= 0:
          let node = ws.frontBuckets[left]
          if ws.isLiveFrontNode(node):
            return node
          ws.frontBuckets[left] = NilId
        let right = idx + offset
        if right < ws.frontBuckets.len:
          let node = ws.frontBuckets[right]
          if ws.isLiveFrontNode(node):
            return node
          ws.frontBuckets[right] = NilId
    NilId

proc locateNode(ws: var IdxWorkspace, x: IdxReal): IdxNodeId =
  when FrontHashOn:
    var node =
      if ws.frontBuckets.len == 0:
        ws.front.searchNode
      else:
        let bucketNode = ws.nearestBucketNode(x)
        if bucketNode == NilId: ws.front.searchNode else: bucketNode
  else:
    var node = ws.front.searchNode
  if x < ws.nd(node).value:
    while node != NilId:
      node = ws.nd(node).prev
      if node != NilId and x >= ws.nd(node).value:
        ws.front.searchNode = node
        when FrontHashOn:
          if ws.frontBuckets.len != 0:
            ws.updateFrontBucket(node)
        return node
  else:
    while node != NilId:
      node = ws.nd(node).next
      if node != NilId and x < ws.nd(node).value:
        ws.front.searchNode = ws.nd(node).prev
        when FrontHashOn:
          if ws.frontBuckets.len != 0:
            ws.updateFrontBucket(ws.nd(node).prev)
        return ws.nd(node).prev
  NilId

proc addPoint(ws: var IdxWorkspace, p: IdxPointId) =
  ws.activePoints.add p

proc pointCmp(ws: var IdxWorkspace, a, b: IdxPointId): int {.inline.} =
  if ws.pt(a).y < ws.pt(b).y:
    -1
  elif ws.pt(a).y > ws.pt(b).y:
    1
  elif ws.pt(a).x < ws.pt(b).x:
    -1
  elif ws.pt(a).x > ws.pt(b).x:
    1
  else:
    0

proc quicksortActivePoints(ws: var IdxWorkspace) {.used.} =
  proc quicksort(ws: var IdxWorkspace, lo, hi: int) =
    var i = lo
    var j = hi
    let pivot = ws.activePoints[(lo + hi) shr 1]
    while i <= j:
      while ws.pointCmp(ws.activePoints[i], pivot) < 0:
        inc i
      while ws.pointCmp(ws.activePoints[j], pivot) > 0:
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

proc insertionSortActivePoints(ws: var IdxWorkspace, lo, hi: int) =
  for i in lo + 1 ..< hi:
    let item = ws.activePoints[i]
    var j = i
    while j > lo and ws.pointCmp(item, ws.activePoints[j - 1]) < 0:
      ws.activePoints[j] = ws.activePoints[j - 1]
      dec j
    ws.activePoints[j] = item

proc mergeSortActivePoints(ws: var IdxWorkspace) {.used.} =
  const InsertionLimit = 24

  proc sortRange(ws: var IdxWorkspace, lo, hi: int) =
    if hi - lo <= InsertionLimit:
      ws.insertionSortActivePoints(lo, hi)
      return

    let mid = (lo + hi) shr 1
    ws.sortRange(lo, mid)
    ws.sortRange(mid, hi)
    if ws.pointCmp(ws.activePoints[mid - 1], ws.activePoints[mid]) <= 0:
      return

    var left = lo
    var right = mid
    var outIdx = lo
    while left < mid and right < hi:
      if ws.pointCmp(ws.activePoints[left], ws.activePoints[right]) <= 0:
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

proc sortActivePoints(ws: var IdxWorkspace) =
  when defined(p2tQuickSort):
    ws.quicksortActivePoints()
  else:
    ws.mergeSortActivePoints()

proc initTriangulation(ws: var IdxWorkspace) =
  var
    xmax = ws.pt(ws.activePoints[0]).x
    xmin = xmax
    ymax = ws.pt(ws.activePoints[0]).y
    ymin = ymax

  for p in ws.activePoints:
    xmax = max(xmax, ws.pt(p).x)
    xmin = min(xmin, ws.pt(p).x)
    ymax = max(ymax, ws.pt(p).y)
    ymin = min(ymin, ws.pt(p).y)

  let
    dx = Alpha * (xmax - xmin)
    dy = Alpha * (ymax - ymin)
  ws.head = ws.newPoint(xmax + dx, ymin - dy)
  ws.tail = ws.newPoint(xmin - dx, ymin - dy)
  when FrontHashOn:
    ws.initFrontHash(ws.pt(ws.tail).x, ws.pt(ws.head).x, ws.activePoints.len)
  ws.sortActivePoints()

proc createAdvancingFront(ws: var IdxWorkspace) =
  let t = ws.newTriangle(ws.activePoints[0], ws.tail, ws.head)

  ws.afHead = ws.newNode(ws.tri(t).points[1], t)
  ws.afMiddle = ws.newNode(ws.tri(t).points[0], t)
  ws.afTail = ws.newNode(ws.tri(t).points[2])
  ws.front = IdxFront(head: ws.afHead, tail: ws.afTail, searchNode: ws.afHead)

  ws.nd(ws.afHead).next = ws.afMiddle
  ws.nd(ws.afMiddle).next = ws.afTail
  ws.nd(ws.afMiddle).prev = ws.afHead
  ws.nd(ws.afTail).prev = ws.afMiddle
  when FrontHashOn:
    ws.updateFrontBucket(ws.afHead)
    ws.updateFrontBucket(ws.afMiddle)
    ws.updateFrontBucket(ws.afTail)

proc mapTriangleToNodes(ws: var IdxWorkspace, t: IdxTriangleId) {.inline.} =
  for i in 0 .. 2:
    if ws.tri(t).neighbors[i] == NilId:
      let n = ws.pt(ws.tri(t).points[PrevEdgeIndex[i]]).node
      if n != NilId:
        ws.nd(n).triangle = t

proc validRawTriangle(ws: var IdxWorkspace, t: IdxTriangleId): bool {.inline.} =
  t != NilId and ws.tri(t).points[0] != NilId and ws.tri(t).points[1] != NilId and
    ws.tri(t).points[2] != NilId and ws.tri(t).points[0] != ws.tri(t).points[1] and
    ws.tri(t).points[0] != ws.tri(t).points[2] and
    ws.tri(t).points[1] != ws.tri(t).points[2]

proc meshClean(ws: var IdxWorkspace, t: IdxTriangleId) =
  if ws.meshStack.len < ws.triangles.len:
    ws.meshStack.setLen(ws.triangles.len)
  if ws.interiorTriangles.len < ws.triangles.len:
    ws.interiorTriangles.setLen(ws.triangles.len)

  ws.rawInteriorCount = 0
  var stackCount = 1
  ws.meshStack[0] = t
  while stackCount > 0:
    dec stackCount
    let item = ws.meshStack[stackCount]
    if item != NilId and not ws.hasFlag(item, InteriorFlag):
      ws.setFlag(item, InteriorFlag, true)
      if ws.validRawTriangle(item):
        ws.interiorTriangles[ws.rawInteriorCount] = item
        inc ws.rawInteriorCount
      for i in 0 .. 2:
        if not ws.hasFlag(item, constrainedFlag(i)):
          let neighbor = ws.tri(item).neighbors[i]
          if neighbor != NilId:
            ws.meshStack[stackCount] = neighbor
            inc stackCount

  ws.meshStack.setLen(0)
  ws.interiorTriangles.setLen(ws.rawInteriorCount)

proc incircle(ws: var IdxWorkspace, pa, pb, pc, pd: IdxPointId): bool {.inline.} =
  let
    adx = ws.pt(pa).x - ws.pt(pd).x
    ady = ws.pt(pa).y - ws.pt(pd).y
    bdx = ws.pt(pb).x - ws.pt(pd).x
    bdy = ws.pt(pb).y - ws.pt(pd).y
    adxbdy = adx * bdy
    bdxady = bdx * ady
    oabd = adxbdy - bdxady

  if oabd <= 0:
    return false

  let
    cdx = ws.pt(pc).x - ws.pt(pd).x
    cdy = ws.pt(pc).y - ws.pt(pd).y
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

proc legalize(ws: var IdxWorkspace, t: IdxTriangleId): bool

proc rotateTrianglePairIndexed(
    ws: var IdxWorkspace,
    t: IdxTriangleId,
    p: IdxPointId,
    pIdx: int,
    ot: IdxTriangleId,
    op: IdxPointId,
    opIdx: int,
) {.inline.} =
  let
    rotateAmount = NextEdgeIndex[pIdx]
    otherRotateAmount = NextEdgeIndex[opIdx]
    tPrev = PrevEdgeIndex[pIdx]
    tNext = NextEdgeIndex[pIdx]
    otPrev = PrevEdgeIndex[opIdx]
    otNext = NextEdgeIndex[opIdx]
    n1 = ws.tri(t).neighbors[tPrev]
    n2 = ws.tri(t).neighbors[tNext]
    n3 = ws.tri(ot).neighbors[otPrev]
    n4 = ws.tri(ot).neighbors[otNext]
    ce1 = ws.hasFlag(t, constrainedFlag(tPrev))
    ce2 = ws.hasFlag(t, constrainedFlag(tNext))
    ce3 = ws.hasFlag(ot, constrainedFlag(otPrev))
    ce4 = ws.hasFlag(ot, constrainedFlag(otNext))
    de1 = ws.hasFlag(t, delaunayFlag(tPrev))
    de2 = ws.hasFlag(t, delaunayFlag(tNext))
    de3 = ws.hasFlag(ot, delaunayFlag(otPrev))
    de4 = ws.hasFlag(ot, delaunayFlag(otNext))

  ws.tri(t).neighbors[rotateAmount] = n3
  ws.tri(t).neighbors[NextEdgeIndex[rotateAmount]] = n2
  ws.tri(t).neighbors[PrevEdgeIndex[rotateAmount]] = ot
  ws.tri(ot).neighbors[otherRotateAmount] = n1
  ws.tri(ot).neighbors[NextEdgeIndex[otherRotateAmount]] = n4
  ws.tri(ot).neighbors[PrevEdgeIndex[otherRotateAmount]] = t

  if n1 != NilId:
    ws.swapNeighbor(n1, t, ot)
  if n3 != NilId:
    ws.swapNeighbor(n3, ot, t)

  ws.legalize(t, p, op)
  ws.legalize(ot, op, p)

  ws.setDelaunayEdgeCCW(ot, p, de1)
  ws.setDelaunayEdgeCW(t, p, de2)
  ws.setDelaunayEdgeCCW(t, op, de3)
  ws.setDelaunayEdgeCW(ot, op, de4)

  ws.setConstrainedEdgeCCW(ot, p, ce1)
  ws.setConstrainedEdgeCW(t, p, ce2)
  ws.setConstrainedEdgeCCW(t, op, ce3)
  ws.setConstrainedEdgeCW(ot, op, ce4)

proc legalize(ws: var IdxWorkspace, t: IdxTriangleId): bool =
  for i in 0 .. 2:
    if ws.hasFlag(t, delaunayFlag(i)):
      continue

    let ot = ws.tri(t).neighbors[i]
    if ot != NilId:
      let
        p = ws.tri(t).points[i]
        pccw = ws.tri(t).points[NextEdgeIndex[i]]
        pcw = ws.tri(t).points[PrevEdgeIndex[i]]
        opposite = ws.oppositePointAcross(ot, pccw, pcw)
        op = opposite.point
        oi = opposite.index

      if ws.hasFlag(ot, constrainedFlag(oi)) or ws.hasFlag(ot, delaunayFlag(oi)):
        ws.setFlag(t, constrainedFlag(i), ws.hasFlag(ot, constrainedFlag(oi)))
        continue

      if ws.incircle(p, pccw, pcw, op):
        ws.setFlag(t, delaunayFlag(i), true)
        ws.setFlag(ot, delaunayFlag(oi), true)

        ws.rotateTrianglePairIndexed(t, p, i, ot, op, oi)

        var notLegalized = not ws.legalize(t)
        if notLegalized:
          ws.mapTriangleToNodes(t)

        notLegalized = not ws.legalize(ot)
        if notLegalized:
          ws.mapTriangleToNodes(ot)

        ws.setFlag(t, delaunayFlag(i), false)
        ws.setFlag(ot, delaunayFlag(oi), false)
        return true
  false

proc fill(ws: var IdxWorkspace, n: IdxNodeId) {.inline.} =
  let prev = ws.nd(n).prev
  let next = ws.nd(n).next
  let t = ws.newTriangle(ws.nd(prev).point, ws.nd(n).point, ws.nd(next).point)
  ws.tri(t).neighbors[2] = ws.nd(prev).triangle
  if ws.nd(prev).triangle != NilId:
    ws.markNeighbor(ws.nd(prev).triangle, ws.nd(prev).point, ws.nd(n).point, t)
  ws.tri(t).neighbors[0] = ws.nd(n).triangle
  if ws.nd(n).triangle != NilId:
    ws.markNeighbor(ws.nd(n).triangle, ws.nd(n).point, ws.nd(next).point, t)

  if ws.front.searchNode == n:
    ws.front.searchNode = prev
  ws.pt(ws.nd(n).point).node = NilId
  ws.nd(prev).next = next
  ws.nd(next).prev = prev

  if not ws.legalize(t):
    ws.mapTriangleToNodes(t)

proc angleParts(
    ws: var IdxWorkspace, origin, pa, pb: IdxPointId
): tuple[cross, dot: IdxReal] {.inline.} =
  let
    ax = ws.pt(pa).x - ws.pt(origin).x
    ay = ws.pt(pa).y - ws.pt(origin).y
    bx = ws.pt(pb).x - ws.pt(origin).x
    by = ws.pt(pb).y - ws.pt(origin).y
  (cross: ax * by - ay * bx, dot: ax * bx + ay * by)

proc angleExceeds90Degrees(ws: var IdxWorkspace, origin, pa, pb: IdxPointId): bool {.inline.} =
  ws.angleParts(origin, pa, pb).dot < 0

proc angleIsNegative(ws: var IdxWorkspace, origin, pa, pb: IdxPointId): bool {.inline.} =
  ws.angleParts(origin, pa, pb).cross < 0

proc angleExceedsPlus90DegreesOrIsNegative(
    ws: var IdxWorkspace, origin, pa, pb: IdxPointId
): bool {.inline.} =
  let parts = ws.angleParts(origin, pa, pb)
  parts.cross < 0 or parts.dot < 0

proc largeHoleDontFill(ws: var IdxWorkspace, n: IdxNodeId): bool =
  let
    nextNode = ws.nd(n).next
    prevNode = ws.nd(n).prev
  if not ws.angleExceeds90Degrees(ws.nd(n).point, ws.nd(nextNode).point, ws.nd(prevNode).point):
    return false
  if ws.angleIsNegative(ws.nd(n).point, ws.nd(nextNode).point, ws.nd(prevNode).point):
    return true
  let next2Node = ws.nd(nextNode).next
  if next2Node != NilId and
      not ws.angleExceedsPlus90DegreesOrIsNegative(
        ws.nd(n).point, ws.nd(next2Node).point, ws.nd(prevNode).point
      ):
    return false
  let prev2Node = ws.nd(prevNode).prev
  if prev2Node != NilId and
      not ws.angleExceedsPlus90DegreesOrIsNegative(
        ws.nd(n).point, ws.nd(nextNode).point, ws.nd(prev2Node).point
      ):
    return false
  true

proc shouldFillBasin(ws: var IdxWorkspace, n: IdxNodeId): bool {.inline.} =
  let
    nn = ws.nd(ws.nd(n).next).next
    ax = ws.pt(ws.nd(n).point).x - ws.pt(ws.nd(nn).point).x
    ay = ws.pt(ws.nd(n).point).y - ws.pt(ws.nd(nn).point).y
  ax >= 0 or ay < -ax

proc isShallow(ws: var IdxWorkspace, n: IdxNodeId): bool {.inline.} =
  let height =
    if ws.basin.leftHighest:
      ws.pt(ws.nd(ws.basin.leftNode).point).y - ws.pt(ws.nd(n).point).y
    else:
      ws.pt(ws.nd(ws.basin.rightNode).point).y - ws.pt(ws.nd(n).point).y
  ws.basin.width > height

proc fillBasinReq(ws: var IdxWorkspace, n: IdxNodeId)

proc fillBasin(ws: var IdxWorkspace, n: IdxNodeId) =
  let next = ws.nd(n).next
  if ws.orient2d(ws.nd(n).point, ws.nd(next).point, ws.nd(ws.nd(next).next).point) == ccw:
    ws.basin.leftNode = ws.nd(next).next
  else:
    ws.basin.leftNode = next

  ws.basin.bottomNode = ws.basin.leftNode
  while ws.nd(ws.basin.bottomNode).next != NilId and
      ws.pt(ws.nd(ws.basin.bottomNode).point).y >=
        ws.pt(ws.nd(ws.nd(ws.basin.bottomNode).next).point).y:
    ws.basin.bottomNode = ws.nd(ws.basin.bottomNode).next
  if ws.basin.bottomNode == ws.basin.leftNode:
    return

  ws.basin.rightNode = ws.basin.bottomNode
  while ws.nd(ws.basin.rightNode).next != NilId and
      ws.pt(ws.nd(ws.basin.rightNode).point).y <
        ws.pt(ws.nd(ws.nd(ws.basin.rightNode).next).point).y:
    ws.basin.rightNode = ws.nd(ws.basin.rightNode).next
  if ws.basin.rightNode == ws.basin.bottomNode:
    return

  ws.basin.width =
    ws.pt(ws.nd(ws.basin.rightNode).point).x - ws.pt(ws.nd(ws.basin.leftNode).point).x
  ws.basin.leftHighest =
    ws.pt(ws.nd(ws.basin.leftNode).point).y > ws.pt(ws.nd(ws.basin.rightNode).point).y
  ws.fillBasinReq(ws.basin.bottomNode)

proc fillBasinReq(ws: var IdxWorkspace, n: IdxNodeId) =
  var n = n
  while true:
    if ws.isShallow(n):
      return

    ws.fill(n)
    if ws.nd(n).prev == ws.basin.leftNode and ws.nd(n).next == ws.basin.rightNode:
      return
    elif ws.nd(n).prev == ws.basin.leftNode:
      if ws.orient2d(ws.nd(n).point, ws.nd(ws.nd(n).next).point,
          ws.nd(ws.nd(ws.nd(n).next).next).point) == cw:
        return
      n = ws.nd(n).next
    elif ws.nd(n).next == ws.basin.rightNode:
      if ws.orient2d(ws.nd(n).point, ws.nd(ws.nd(n).prev).point,
          ws.nd(ws.nd(ws.nd(n).prev).prev).point) == ccw:
        return
      n = ws.nd(n).prev
    elif ws.pt(ws.nd(ws.nd(n).prev).point).y < ws.pt(ws.nd(ws.nd(n).next).point).y:
      n = ws.nd(n).prev
    else:
      n = ws.nd(n).next

proc fillAdvancingFront(ws: var IdxWorkspace, n: IdxNodeId) =
  var nextNode = ws.nd(n).next
  while ws.nd(nextNode).next != NilId:
    if ws.largeHoleDontFill(nextNode):
      break
    ws.fill(nextNode)
    nextNode = ws.nd(nextNode).next

  var prevNode = ws.nd(n).prev
  while ws.nd(prevNode).prev != NilId:
    if ws.largeHoleDontFill(prevNode):
      break
    ws.fill(prevNode)
    prevNode = ws.nd(prevNode).prev

  if ws.nd(n).next != NilId and ws.nd(ws.nd(n).next).next != NilId and
      ws.shouldFillBasin(n):
    ws.fillBasin(n)

proc isEdgeSideOfTriangle(
    ws: var IdxWorkspace, t: IdxTriangleId, ep, eq: IdxPointId
): bool {.inline.} =
  let idx = ws.edgeIndex(t, ep, eq)
  if idx != -1:
    ws.markConstrainedEdge(t, idx)
    let neighbor = ws.tri(t).neighbors[idx]
    if neighbor != NilId:
      ws.markConstrainedEdge(neighbor, ep, eq)
    return true
  false

proc newFrontTriangle(
    ws: var IdxWorkspace, p: IdxPointId, n: IdxNodeId
): IdxNodeId {.inline.} =
  let t = ws.newTriangle(p, ws.nd(n).point, ws.nd(ws.nd(n).next).point)
  ws.tri(t).neighbors[0] = ws.nd(n).triangle
  if ws.nd(n).triangle != NilId:
    ws.markNeighbor(ws.nd(n).triangle, ws.nd(n).point, ws.nd(ws.nd(n).next).point, t)

  result = ws.newNode(p)
  ws.nd(result).next = ws.nd(n).next
  ws.nd(result).prev = n
  ws.nd(ws.nd(n).next).prev = result
  ws.nd(n).next = result
  when FrontHashOn:
    ws.updateFrontBucket(result)

  if not ws.legalize(t):
    ws.mapTriangleToNodes(t)
  ws.nd(result).triangle = t

proc pointEvent(ws: var IdxWorkspace, p: IdxPointId): IdxNodeId {.inline.} =
  let n = ws.locateNode(ws.pt(p).x)
  if n == NilId:
    raise newException(ValueError, "failed to locate advancing-front node")
  result = ws.newFrontTriangle(p, n)
  if ws.pt(p).x <= ws.pt(ws.nd(n).point).x + Epsilon:
    ws.fill(n)
  ws.fillAdvancingFront(result)

proc fillRightConcaveEdgeEvent(ws: var IdxWorkspace, edge: IdxEdgeId, n: IdxNodeId)
proc fillRightConvexEdgeEvent(ws: var IdxWorkspace, edge: IdxEdgeId, n: IdxNodeId)
proc fillRightBelowEdgeEvent(ws: var IdxWorkspace, edge: IdxEdgeId, n: IdxNodeId)
proc fillLeftBelowEdgeEvent(ws: var IdxWorkspace, edge: IdxEdgeId, n: IdxNodeId)
proc fillLeftConcaveEdgeEvent(ws: var IdxWorkspace, edge: IdxEdgeId, n: IdxNodeId)
proc fillLeftConvexEdgeEvent(ws: var IdxWorkspace, edge: IdxEdgeId, n: IdxNodeId)

proc edgeEvent(
  ws: var IdxWorkspace, ep, eq: IdxPointId, t: IdxTriangleId, p: IdxPointId, pIdx: int
)

proc flipEdgeEvent(
  ws: var IdxWorkspace, ep, eq: IdxPointId, t: IdxTriangleId, p: IdxPointId, pIdx: int
)

proc fillRightAboveEdgeEvent(ws: var IdxWorkspace, edge: IdxEdgeId, n: IdxNodeId) =
  var n = n
  while ws.pt(ws.nd(ws.nd(n).next).point).x < ws.pt(ws.eg(edge).p).x:
    if ws.orient2d(ws.eg(edge).q, ws.nd(ws.nd(n).next).point, ws.eg(edge).p) == ccw:
      ws.fillRightBelowEdgeEvent(edge, n)
    else:
      n = ws.nd(n).next

proc fillRightBelowEdgeEvent(ws: var IdxWorkspace, edge: IdxEdgeId, n: IdxNodeId) =
  if ws.pt(ws.nd(n).point).x < ws.pt(ws.eg(edge).p).x:
    if ws.orient2d(ws.nd(n).point, ws.nd(ws.nd(n).next).point,
        ws.nd(ws.nd(ws.nd(n).next).next).point) == ccw:
      ws.fillRightConcaveEdgeEvent(edge, n)
    else:
      ws.fillRightConvexEdgeEvent(edge, n)
      ws.fillRightBelowEdgeEvent(edge, n)

proc fillRightConcaveEdgeEvent(ws: var IdxWorkspace, edge: IdxEdgeId, n: IdxNodeId) =
  ws.fill(ws.nd(n).next)
  if ws.nd(ws.nd(n).next).point != ws.eg(edge).p:
    if ws.orient2d(ws.eg(edge).q, ws.nd(ws.nd(n).next).point, ws.eg(edge).p) == ccw:
      if ws.orient2d(ws.nd(n).point, ws.nd(ws.nd(n).next).point,
          ws.nd(ws.nd(ws.nd(n).next).next).point) == ccw:
        ws.fillRightConcaveEdgeEvent(edge, n)

proc fillRightConvexEdgeEvent(ws: var IdxWorkspace, edge: IdxEdgeId, n: IdxNodeId) =
  let next = ws.nd(n).next
  if ws.orient2d(ws.nd(next).point, ws.nd(ws.nd(next).next).point,
      ws.nd(ws.nd(ws.nd(next).next).next).point) == ccw:
    ws.fillRightConcaveEdgeEvent(edge, next)
  elif ws.orient2d(ws.eg(edge).q, ws.nd(ws.nd(next).next).point, ws.eg(edge).p) == ccw:
    ws.fillRightConvexEdgeEvent(edge, next)

proc fillLeftAboveEdgeEvent(ws: var IdxWorkspace, edge: IdxEdgeId, n: IdxNodeId) =
  var n = n
  while ws.pt(ws.nd(ws.nd(n).prev).point).x > ws.pt(ws.eg(edge).p).x:
    if ws.orient2d(ws.eg(edge).q, ws.nd(ws.nd(n).prev).point, ws.eg(edge).p) == cw:
      ws.fillLeftBelowEdgeEvent(edge, n)
    else:
      n = ws.nd(n).prev

proc fillLeftBelowEdgeEvent(ws: var IdxWorkspace, edge: IdxEdgeId, n: IdxNodeId) =
  if ws.pt(ws.nd(n).point).x > ws.pt(ws.eg(edge).p).x:
    if ws.orient2d(ws.nd(n).point, ws.nd(ws.nd(n).prev).point,
        ws.nd(ws.nd(ws.nd(n).prev).prev).point) == cw:
      ws.fillLeftConcaveEdgeEvent(edge, n)
    else:
      ws.fillLeftConvexEdgeEvent(edge, n)
      ws.fillLeftBelowEdgeEvent(edge, n)

proc fillLeftConvexEdgeEvent(ws: var IdxWorkspace, edge: IdxEdgeId, n: IdxNodeId) =
  let prev = ws.nd(n).prev
  if ws.orient2d(ws.nd(prev).point, ws.nd(ws.nd(prev).prev).point,
      ws.nd(ws.nd(ws.nd(prev).prev).prev).point) == cw:
    ws.fillLeftConcaveEdgeEvent(edge, prev)
  elif ws.orient2d(ws.eg(edge).q, ws.nd(ws.nd(prev).prev).point, ws.eg(edge).p) == cw:
    ws.fillLeftConvexEdgeEvent(edge, prev)

proc fillLeftConcaveEdgeEvent(ws: var IdxWorkspace, edge: IdxEdgeId, n: IdxNodeId) =
  ws.fill(ws.nd(n).prev)
  if ws.nd(ws.nd(n).prev).point != ws.eg(edge).p:
    if ws.orient2d(ws.eg(edge).q, ws.nd(ws.nd(n).prev).point, ws.eg(edge).p) == cw:
      if ws.orient2d(ws.nd(n).point, ws.nd(ws.nd(n).prev).point,
          ws.nd(ws.nd(ws.nd(n).prev).prev).point) == cw:
        ws.fillLeftConcaveEdgeEvent(edge, n)

proc fillEdgeEvent(ws: var IdxWorkspace, edge: IdxEdgeId, n: IdxNodeId) =
  if ws.edgeEvent.right:
    ws.fillRightAboveEdgeEvent(edge, n)
  else:
    ws.fillLeftAboveEdgeEvent(edge, n)

proc nextFlipTriangle(
    ws: var IdxWorkspace,
    o: Orientation,
    t, ot: IdxTriangleId,
    p, op: IdxPointId,
): tuple[tri: IdxTriangleId, pIndex: int] =
  if o == ccw:
    let idx = ws.edgeIndex(ot, p, op)
    ws.setFlag(ot, delaunayFlag(idx), true)
    discard ws.legalize(ot)
    ws.clearDelaunayEdges(ot)
    return (t, ws.index(t, p))

  let idx = ws.edgeIndex(t, p, op)
  ws.setFlag(t, delaunayFlag(idx), true)
  discard ws.legalize(t)
  ws.clearDelaunayEdges(t)
  (ot, ws.index(ot, p))

proc nextFlipPoint(
    ws: var IdxWorkspace, ep, eq: IdxPointId, ot: IdxTriangleId, op: IdxPointId, opIdx: int
): tuple[point: IdxPointId, index: int] =
  case ws.orient2d(eq, op, ep)
  of cw:
    let idx = NextEdgeIndex[opIdx]
    (ws.tri(ot).points[idx], idx)
  of ccw:
    let idx = PrevEdgeIndex[opIdx]
    (ws.tri(ot).points[idx], idx)
  of collinear:
    raise newException(ValueError, "opposing point on constrained edge")

proc flipScanEdgeEvent(
    ws: var IdxWorkspace,
    ep, eq: IdxPointId,
    flipTriangle, t: IdxTriangleId,
    p: IdxPointId,
    pIdx: int,
) =
  let ot = ws.tri(t).neighbors[pIdx]
  if ot == NilId:
    raise newException(ValueError, "flip scan failed due to missing triangle")
  let
    pccw = ws.tri(t).points[NextEdgeIndex[pIdx]]
    pcw = ws.tri(t).points[PrevEdgeIndex[pIdx]]
    opposite = ws.oppositePointAcross(ot, pccw, pcw)
    op = opposite.point
    opIdx = opposite.index

  let eqIdx = ws.index(flipTriangle, eq)
  if ws.inScanArea(
    eq,
    ws.tri(flipTriangle).points[NextEdgeIndex[eqIdx]],
    ws.tri(flipTriangle).points[PrevEdgeIndex[eqIdx]],
    op,
  ):
    ws.flipEdgeEvent(eq, op, ot, op, opIdx)
  else:
    let newP = ws.nextFlipPoint(ep, eq, ot, op, opIdx)
    ws.flipScanEdgeEvent(ep, eq, flipTriangle, ot, newP.point, newP.index)

proc flipEdgeEvent(
    ws: var IdxWorkspace,
    ep, eq: IdxPointId,
    t: IdxTriangleId,
    p: IdxPointId,
    pIdx: int,
) =
  let ot = ws.tri(t).neighbors[pIdx]
  if ot == NilId:
    raise newException(ValueError, "flip failed due to missing triangle")
  let
    pccw = ws.tri(t).points[NextEdgeIndex[pIdx]]
    pcw = ws.tri(t).points[PrevEdgeIndex[pIdx]]
    opposite = ws.oppositePointAcross(ot, pccw, pcw)
    op = opposite.point
    opIdx = opposite.index

  if ws.inScanArea(p, pccw, pcw, op):
    ws.rotateTrianglePairIndexed(t, p, pIdx, ot, op, opIdx)
    ws.mapTriangleToNodes(t)
    ws.mapTriangleToNodes(ot)

    if p == eq and op == ep:
      if eq == ws.eg(ws.edgeEvent.constrainedEdge).q and
          ep == ws.eg(ws.edgeEvent.constrainedEdge).p:
        ws.markConstrainedEdge(t, ep, eq)
        ws.markConstrainedEdge(ot, ep, eq)
        discard ws.legalize(t)
        discard ws.legalize(ot)
    else:
      let o = ws.orient2d(eq, op, ep)
      let nextT = ws.nextFlipTriangle(o, t, ot, p, op)
      ws.flipEdgeEvent(ep, eq, nextT.tri, p, nextT.pIndex)
  else:
    let newP = ws.nextFlipPoint(ep, eq, ot, op, opIdx)
    ws.flipScanEdgeEvent(ep, eq, t, ot, newP.point, newP.index)
    ws.edgeEvent(ep, eq, t, p, pIdx)

proc edgeEvent(
    ws: var IdxWorkspace,
    ep, eq: IdxPointId,
    t: IdxTriangleId,
    p: IdxPointId,
    pIdx: int,
) =
  var t = t
  var pIdx = pIdx
  while true:
    if ws.isEdgeSideOfTriangle(t, ep, eq):
      return

    let p1 = ws.tri(t).points[NextEdgeIndex[pIdx]]
    let o1 = ws.orient2d(eq, p1, ep)
    if o1 == collinear:
      if ws.contains(t, eq, p1):
        ws.markConstrainedEdge(t, eq, p1)
        ws.eg(ws.edgeEvent.constrainedEdge).q = p1
        let nt = ws.tri(t).neighbors[pIdx]
        ws.edgeEvent(ep, p1, nt, p1, ws.index(nt, p1))
      else:
        raise newException(
          ValueError, "collinear constrained edge points are not supported"
        )
      return

    let p2 = ws.tri(t).points[PrevEdgeIndex[pIdx]]
    let o2 = ws.orient2d(eq, p2, ep)
    if o2 == collinear:
      if ws.contains(t, eq, p2):
        ws.markConstrainedEdge(t, eq, p2)
        ws.eg(ws.edgeEvent.constrainedEdge).q = p2
        let nt = ws.tri(t).neighbors[pIdx]
        ws.edgeEvent(ep, p2, nt, p2, ws.index(nt, p2))
      else:
        raise newException(
          ValueError, "collinear constrained edge points are not supported"
        )
      return

    if o1 != o2:
      ws.flipEdgeEvent(ep, eq, t, p, pIdx)
      return

    t =
      if o1 == cw:
        ws.tri(t).neighbors[PrevEdgeIndex[pIdx]]
      else:
        ws.tri(t).neighbors[NextEdgeIndex[pIdx]]
    if t == NilId:
      raise newException(ValueError, "missing neighbor while walking constrained edge")
    pIdx = ws.index(t, p)

proc edgeEvent(ws: var IdxWorkspace, edge: IdxEdgeId, n: IdxNodeId) =
  ws.edgeEvent.constrainedEdge = edge
  ws.edgeEvent.right = ws.pt(ws.eg(edge).p).x > ws.pt(ws.eg(edge).q).x
  if ws.isEdgeSideOfTriangle(ws.nd(n).triangle, ws.eg(edge).p, ws.eg(edge).q):
    return
  ws.fillEdgeEvent(edge, n)
  ws.edgeEvent(
    ws.eg(edge).p, ws.eg(edge).q, ws.nd(n).triangle, ws.eg(edge).q,
    ws.index(ws.nd(n).triangle, ws.eg(edge).q),
  )

proc sweepPoints(ws: var IdxWorkspace) =
  for i in 1 ..< ws.activePoints.len:
    let p = ws.activePoints[i]
    let n = ws.pointEvent(p)
    var edge = ws.pt(p).firstEdge
    while edge != NilId:
      ws.edgeEvent(edge, n)
      edge = ws.eg(edge).next

proc finalizationPolygon(ws: var IdxWorkspace) =
  var t = ws.nd(ws.nd(ws.front.head).next).triangle
  let p = ws.nd(ws.nd(ws.front.head).next).point
  while not ws.getConstrainedEdgeCW(t, p):
    t = ws.neighborCCW(t, p)
    if t == NilId:
      raise newException(ValueError, "failed to find finalization triangle")
  ws.meshClean(t)

proc triangulate(ws: var IdxWorkspace) =
  ws.initTriangulation()
  ws.createAdvancingFront()
  ws.sweepPoints()
  ws.finalizationPolygon()

proc sourceTriangle(ws: var IdxWorkspace, t: IdxTriangleId): array[3, int] =
  if t == NilId or ws.tri(t).points[0] == NilId or ws.tri(t).points[1] == NilId or
      ws.tri(t).points[2] == NilId or ws.tri(t).points[0] == ws.tri(t).points[1] or
      ws.tri(t).points[0] == ws.tri(t).points[2] or
      ws.tri(t).points[1] == ws.tri(t).points[2]:
    return [-1, -1, -1]
  let
    a = ws.pt(ws.tri(t).points[0]).sourceIndex.int
    b = ws.pt(ws.tri(t).points[1]).sourceIndex.int
    c = ws.pt(ws.tri(t).points[2]).sourceIndex.int
  if a == b or a == c or b == c:
    return [-1, -1, -1]
  [a, b, c]

proc rawTrianglePoints*(
    raw: TessRawResult, triangleIndex: int
): array[3, CdtPointId] {.inline.} =
  let ws = raw.idx
  let t = ws[].interiorTriangles[triangleIndex]
  # The point id is the array index, which equals the arena's per-point id.
  [
    ws[].triangles[t].points[0].CdtPointId,
    ws[].triangles[t].points[1].CdtPointId,
    ws[].triangles[t].points[2].CdtPointId,
  ]

proc rawTriangleAllocId*(
    raw: TessRawResult, triangleIndex: int
): int {.inline.} =
  raw.idx[].interiorTriangles[triangleIndex].int

proc rawTriangleNeighborAllocIds*(
    raw: TessRawResult, triangleIndex: int
): array[3, int] {.inline.} =
  let
    ws = raw.idx
    t = ws[].interiorTriangles[triangleIndex]
  for side in 0 .. 2:
    result[side] = ws[].triangles[t].neighbors[side].int

proc rawTriangleVertices*(
    raw: TessRawResult, triangleIndex: int
): array[3, Vec2] {.inline.} =
  let ws = raw.idx
  let t = ws[].interiorTriangles[triangleIndex]
  template p(k: int): untyped =
    ws[].points[ws[].triangles[t].points[k]]

  [
    Vec2(x: p(0).x.float64, y: p(0).y.float64),
    Vec2(x: p(1).x.float64, y: p(1).y.float64),
    Vec2(x: p(2).x.float64, y: p(2).y.float64),
  ]

proc rawTriangleCount*(raw: TessRawResult): int {.inline.} =
  if raw.ok and raw.idx != nil:
    result = raw.idx[].rawInteriorCount

proc addContour(ws: var IdxWorkspace, contour: seq[Vec2], vertices: var seq[Vec2]) =
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

proc addContourRaw(ws: var IdxWorkspace, contour: openArray[Vec2]) =
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

  workspace.idx.resetCdt()
  workspace.vertices.setLen(0)

  var pointCount = input.outer.len + input.steiner.len
  for hole in input.holes:
    pointCount += hole.len
  workspace.reserveArena(pointCount, keepVertices = true)

  workspace.idx.addContour(input.outer, workspace.vertices)

  for hole in input.holes:
    workspace.idx.addContour(hole, workspace.vertices)

  for p in input.steiner:
    workspace.vertices.add p
    workspace.idx.addPoint(
      workspace.idx.newPoint(p.x, p.y, workspace.vertices.high)
    )

  workspace.idx.triangulate()

proc triangulateCdt*(workspace: var TessWorkspace, input: CdtInput): CdtResult =
  workspace.triangulateCdtInPlace(input)

  result.vertices = workspace.vertices
  result.triangles.reserveSeq(workspace.idx.interiorTriangles.len)
  for t in workspace.idx.interiorTriangles:
    let tri = workspace.idx.sourceTriangle(t)
    if tri[0] < 0 or tri[1] < 0 or tri[2] < 0:
      continue
    result.triangles.add tri

proc triangulateCdtRaw*(workspace: var TessWorkspace, input: CdtInput): CdtRawResult =
  workspace.triangulateCdtInPlace(input)
  CdtRawResult(vertices: addr workspace.vertices, idx: addr workspace.idx)

proc triangulateCdtRaw*(workspace: var TessWorkspace, input: TessInput): CdtRawResult =
  if input.outer.points.len < 3:
    raise newException(ValueError, "outer contour has fewer than 3 points")

  workspace.idx.resetCdt()
  workspace.vertices.setLen(0)

  var pointCount = input.outer.points.len + input.steiner.len
  for hole in input.holes:
    pointCount += hole.points.len
  workspace.reserveArena(pointCount, keepVertices = false)

  workspace.idx.addContourRaw(input.outer.points)

  for hole in input.holes:
    workspace.idx.addContourRaw(hole.points)

  for p in input.steiner:
    workspace.idx.addPoint(workspace.idx.newPoint(p.x, p.y))

  workspace.idx.triangulate()
  CdtRawResult(vertices: addr workspace.vertices, idx: addr workspace.idx)

when defined(p2tUnsafeCdt):
  {.pop.}
