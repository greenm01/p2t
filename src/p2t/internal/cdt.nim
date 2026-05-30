import std/math

import ../types

const
  CdtNil = -1
  Epsilon = 1e-12
  Pi3Div4 = 3.0 * PI / 4.0
  PiDiv2 = PI / 2.0
  Alpha = 0.3

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

proc isNil(id: int): bool {.inline.} =
  id == CdtNil

proc resetCdt(ws: var CdtWorkspace) =
  ws.points.setLen(0)
  ws.edges.setLen(0)
  ws.triangles.setLen(0)
  ws.nodes.setLen(0)
  ws.activePoints.setLen(0)
  ws.interiorTriangles.setLen(0)
  ws.triangleMap.setLen(0)
  ws.front = CdtFront(head: CdtNil, tail: CdtNil, searchNode: CdtNil)
  ws.head = CdtNil
  ws.tail = CdtNil
  ws.afHead = CdtNil
  ws.afMiddle = CdtNil
  ws.afTail = CdtNil
  ws.basin = CdtBasin(leftNode: CdtNil, bottomNode: CdtNil, rightNode: CdtNil)
  ws.edgeEvent = CdtEdgeEvent(constrainedEdge: CdtNil)

proc point(ws: var CdtWorkspace, id: CdtPointId): var CdtPoint {.inline.} =
  ws.points[id]

proc edge(ws: var CdtWorkspace, id: CdtEdgeId): var CdtEdge {.inline.} =
  ws.edges[id]

proc tri(ws: var CdtWorkspace, id: CdtTriangleId): var CdtTriangle {.inline.} =
  ws.triangles[id]

proc node(ws: var CdtWorkspace, id: CdtNodeId): var CdtNode {.inline.} =
  ws.nodes[id]

proc newPoint(ws: var CdtWorkspace, x, y: float64, sourceIndex = -1): CdtPointId =
  result = ws.points.len
  ws.points.add CdtPoint(x: x, y: y, sourceIndex: sourceIndex)

proc orient2d(ws: var CdtWorkspace, pa, pb, pc: CdtPointId): Orientation =
  let
    a = ws.point(pa)
    b = ws.point(pb)
    c = ws.point(pc)
    detleft = (a.x - c.x) * (b.y - c.y)
    detright = (a.y - c.y) * (b.x - c.x)
    val = detleft - detright
  if val > -Epsilon and val < Epsilon:
    collinear
  elif val > 0:
    ccw
  else:
    cw

proc inScanArea(ws: var CdtWorkspace, pa, pb, pc, pd: CdtPointId): bool =
  let
    a = ws.point(pa)
    b = ws.point(pb)
    c = ws.point(pc)
    d = ws.point(pd)
    oadb = (a.x - b.x) * (d.y - b.y) - (d.x - b.x) * (a.y - b.y)
  if oadb >= -Epsilon:
    return false

  let oadc = (a.x - c.x) * (d.y - c.y) - (d.x - c.x) * (a.y - c.y)
  if oadc <= Epsilon:
    return false
  true

proc newEdge(ws: var CdtWorkspace, p1, p2: CdtPointId): CdtEdgeId =
  result = ws.edges.len
  var p = p1
  var q = p2
  let
    a = ws.point(p1)
    b = ws.point(p2)
  if a.y > b.y:
    q = p1
    p = p2
  elif a.y == b.y:
    if a.x > b.x:
      q = p1
      p = p2
    elif a.x == b.x:
      raise newException(ValueError, "repeat points in constrained edge")
  ws.edges.add CdtEdge(p: p, q: q)
  ws.point(q).edgeList.add result

proc newTriangle(ws: var CdtWorkspace, a, b, c: CdtPointId): CdtTriangleId =
  result = ws.triangles.len
  ws.triangles.add CdtTriangle(
    points: [a, b, c],
    neighbors: [CdtNil, CdtNil, CdtNil],
    constrainedEdge: [false, false, false],
    delaunayEdge: [false, false, false],
    interior: false,
  )

proc contains(ws: var CdtWorkspace, t: CdtTriangleId, p: CdtPointId): bool =
  let tr = ws.tri(t)
  tr.points[0] == p or tr.points[1] == p or tr.points[2] == p

proc contains(ws: var CdtWorkspace, t: CdtTriangleId, p, q: CdtPointId): bool =
  ws.contains(t, p) and ws.contains(t, q)

proc markNeighbor(
    ws: var CdtWorkspace, t: CdtTriangleId, p1, p2: CdtPointId, other: CdtTriangleId
) =
  if (p1 == ws.tri(t).points[2] and p2 == ws.tri(t).points[1]) or
      (p1 == ws.tri(t).points[1] and p2 == ws.tri(t).points[2]):
    ws.tri(t).neighbors[0] = other
  elif (p1 == ws.tri(t).points[0] and p2 == ws.tri(t).points[2]) or
      (p1 == ws.tri(t).points[2] and p2 == ws.tri(t).points[0]):
    ws.tri(t).neighbors[1] = other
  elif (p1 == ws.tri(t).points[0] and p2 == ws.tri(t).points[1]) or
      (p1 == ws.tri(t).points[1] and p2 == ws.tri(t).points[0]):
    ws.tri(t).neighbors[2] = other
  else:
    raise newException(ValueError, "triangle neighbor does not share an edge")

proc markNeighbor(ws: var CdtWorkspace, t, other: CdtTriangleId) =
  let points = ws.tri(t).points
  if ws.contains(other, points[1], points[2]):
    ws.tri(t).neighbors[0] = other
    ws.markNeighbor(other, points[1], points[2], t)
  elif ws.contains(other, points[0], points[2]):
    ws.tri(t).neighbors[1] = other
    ws.markNeighbor(other, points[0], points[2], t)
  elif ws.contains(other, points[0], points[1]):
    ws.tri(t).neighbors[2] = other
    ws.markNeighbor(other, points[0], points[1], t)

proc clearNeighbors(ws: var CdtWorkspace, t: CdtTriangleId) =
  ws.tri(t).neighbors = [CdtNil, CdtNil, CdtNil]

proc clearDelaunayEdges(ws: var CdtWorkspace, t: CdtTriangleId) =
  ws.tri(t).delaunayEdge = [false, false, false]

proc pointCW(ws: var CdtWorkspace, t: CdtTriangleId, p: CdtPointId): CdtPointId =
  let tr = ws.tri(t)
  if p == tr.points[0]:
    tr.points[2]
  elif p == tr.points[1]:
    tr.points[0]
  elif p == tr.points[2]:
    tr.points[1]
  else:
    raise newException(ValueError, "point is not in triangle")

proc pointCCW(ws: var CdtWorkspace, t: CdtTriangleId, p: CdtPointId): CdtPointId =
  let tr = ws.tri(t)
  if p == tr.points[0]:
    tr.points[1]
  elif p == tr.points[1]:
    tr.points[2]
  elif p == tr.points[2]:
    tr.points[0]
  else:
    raise newException(ValueError, "point is not in triangle")

proc neighborCW(ws: var CdtWorkspace, t: CdtTriangleId, p: CdtPointId): CdtTriangleId =
  let tr = ws.tri(t)
  if p == tr.points[0]:
    tr.neighbors[1]
  elif p == tr.points[1]:
    tr.neighbors[2]
  else:
    tr.neighbors[0]

proc neighborCCW(ws: var CdtWorkspace, t: CdtTriangleId, p: CdtPointId): CdtTriangleId =
  let tr = ws.tri(t)
  if p == tr.points[0]:
    tr.neighbors[2]
  elif p == tr.points[1]:
    tr.neighbors[0]
  else:
    tr.neighbors[1]

proc getConstrainedEdgeCCW(
    ws: var CdtWorkspace, t: CdtTriangleId, p: CdtPointId
): bool =
  let tr = ws.tri(t)
  if p == tr.points[0]:
    tr.constrainedEdge[2]
  elif p == tr.points[1]:
    tr.constrainedEdge[0]
  else:
    tr.constrainedEdge[1]

proc getConstrainedEdgeCW(ws: var CdtWorkspace, t: CdtTriangleId, p: CdtPointId): bool =
  let tr = ws.tri(t)
  if p == tr.points[0]:
    tr.constrainedEdge[1]
  elif p == tr.points[1]:
    tr.constrainedEdge[2]
  else:
    tr.constrainedEdge[0]

proc setConstrainedEdgeCCW(
    ws: var CdtWorkspace, t: CdtTriangleId, p: CdtPointId, ce: bool
) =
  let points = ws.tri(t).points
  if p == points[0]:
    ws.tri(t).constrainedEdge[2] = ce
  elif p == points[1]:
    ws.tri(t).constrainedEdge[0] = ce
  else:
    ws.tri(t).constrainedEdge[1] = ce

proc setConstrainedEdgeCW(
    ws: var CdtWorkspace, t: CdtTriangleId, p: CdtPointId, ce: bool
) =
  let points = ws.tri(t).points
  if p == points[0]:
    ws.tri(t).constrainedEdge[1] = ce
  elif p == points[1]:
    ws.tri(t).constrainedEdge[2] = ce
  else:
    ws.tri(t).constrainedEdge[0] = ce

proc getDelaunayEdgeCCW(ws: var CdtWorkspace, t: CdtTriangleId, p: CdtPointId): bool =
  let tr = ws.tri(t)
  if p == tr.points[0]:
    tr.delaunayEdge[2]
  elif p == tr.points[1]:
    tr.delaunayEdge[0]
  else:
    tr.delaunayEdge[1]

proc getDelaunayEdgeCW(ws: var CdtWorkspace, t: CdtTriangleId, p: CdtPointId): bool =
  let tr = ws.tri(t)
  if p == tr.points[0]:
    tr.delaunayEdge[1]
  elif p == tr.points[1]:
    tr.delaunayEdge[2]
  else:
    tr.delaunayEdge[0]

proc setDelaunayEdgeCCW(
    ws: var CdtWorkspace, t: CdtTriangleId, p: CdtPointId, edge: bool
) =
  let points = ws.tri(t).points
  if p == points[0]:
    ws.tri(t).delaunayEdge[2] = edge
  elif p == points[1]:
    ws.tri(t).delaunayEdge[0] = edge
  else:
    ws.tri(t).delaunayEdge[1] = edge

proc setDelaunayEdgeCW(
    ws: var CdtWorkspace, t: CdtTriangleId, p: CdtPointId, edge: bool
) =
  let points = ws.tri(t).points
  if p == points[0]:
    ws.tri(t).delaunayEdge[1] = edge
  elif p == points[1]:
    ws.tri(t).delaunayEdge[2] = edge
  else:
    ws.tri(t).delaunayEdge[0] = edge

proc neighborAcross(
    ws: var CdtWorkspace, t: CdtTriangleId, opoint: CdtPointId
): CdtTriangleId =
  let tr = ws.tri(t)
  if opoint == tr.points[0]:
    tr.neighbors[0]
  elif opoint == tr.points[1]:
    tr.neighbors[1]
  else:
    tr.neighbors[2]

proc oppositePoint(
    ws: var CdtWorkspace, t, other: CdtTriangleId, p: CdtPointId
): CdtPointId =
  let cw = ws.pointCW(other, p)
  ws.pointCW(t, cw)

proc legalize(ws: var CdtWorkspace, t: CdtTriangleId, opoint, npoint: CdtPointId) =
  let points = ws.tri(t).points
  if opoint == points[0]:
    ws.tri(t).points[1] = points[0]
    ws.tri(t).points[0] = points[2]
    ws.tri(t).points[2] = npoint
  elif opoint == points[1]:
    ws.tri(t).points[2] = points[1]
    ws.tri(t).points[1] = points[0]
    ws.tri(t).points[0] = npoint
  elif opoint == points[2]:
    ws.tri(t).points[0] = points[2]
    ws.tri(t).points[2] = points[1]
    ws.tri(t).points[1] = npoint
  else:
    raise newException(ValueError, "legalize point is not in triangle")

proc index(ws: var CdtWorkspace, t: CdtTriangleId, p: CdtPointId): int =
  let points = ws.tri(t).points
  if p == points[0]:
    0
  elif p == points[1]:
    1
  elif p == points[2]:
    2
  else:
    raise newException(ValueError, "point is not in triangle")

proc edgeIndex(ws: var CdtWorkspace, t: CdtTriangleId, p1, p2: CdtPointId): int =
  let points = ws.tri(t).points
  if points[0] == p1:
    if points[1] == p2:
      return 2
    elif points[2] == p2:
      return 1
  elif points[1] == p1:
    if points[2] == p2:
      return 0
    elif points[0] == p2:
      return 2
  elif points[2] == p1:
    if points[0] == p2:
      return 1
    elif points[1] == p2:
      return 0
  -1

proc markConstrainedEdge(ws: var CdtWorkspace, t: CdtTriangleId, edgeIndex: int) =
  ws.tri(t).constrainedEdge[edgeIndex] = true

proc markConstrainedEdge(ws: var CdtWorkspace, t: CdtTriangleId, p, q: CdtPointId) =
  let points = ws.tri(t).points
  if (q == points[0] and p == points[1]) or (q == points[1] and p == points[0]):
    ws.tri(t).constrainedEdge[2] = true
  elif (q == points[0] and p == points[2]) or (q == points[2] and p == points[0]):
    ws.tri(t).constrainedEdge[1] = true
  elif (q == points[1] and p == points[2]) or (q == points[2] and p == points[1]):
    ws.tri(t).constrainedEdge[0] = true

proc newNode(
    ws: var CdtWorkspace, p: CdtPointId, t: CdtTriangleId = CdtNil
): CdtNodeId =
  result = ws.nodes.len
  ws.nodes.add CdtNode(
    point: p, triangle: t, next: CdtNil, prev: CdtNil, value: ws.point(p).x
  )

proc locateNode(ws: var CdtWorkspace, x: float64): CdtNodeId =
  var node = ws.front.searchNode
  if x < ws.node(node).value:
    node = ws.node(node).prev
    while not node.isNil:
      if x >= ws.node(node).value:
        ws.front.searchNode = node
        return node
      node = ws.node(node).prev
  else:
    node = ws.node(node).next
    while not node.isNil:
      if x < ws.node(node).value:
        ws.front.searchNode = ws.node(node).prev
        return ws.node(node).prev
      node = ws.node(node).next
  CdtNil

proc locatePoint(ws: var CdtWorkspace, p: CdtPointId): CdtNodeId =
  let px = ws.point(p).x
  var node = ws.front.searchNode
  let nx = ws.point(ws.node(node).point).x

  if px == nx:
    if p != ws.node(node).point:
      if not ws.node(node).prev.isNil and p == ws.node(ws.node(node).prev).point:
        node = ws.node(node).prev
      elif not ws.node(node).next.isNil and p == ws.node(ws.node(node).next).point:
        node = ws.node(node).next
      else:
        raise newException(ValueError, "front point not found")
  elif px < nx:
    node = ws.node(node).prev
    while not node.isNil:
      if p == ws.node(node).point:
        break
      node = ws.node(node).prev
  else:
    node = ws.node(node).next
    while not node.isNil:
      if p == ws.node(node).point:
        break
      node = ws.node(node).next

  if not node.isNil:
    ws.front.searchNode = node
  node

proc initEdges(ws: var CdtWorkspace, polyline: seq[CdtPointId]) =
  for i in 0 ..< polyline.len:
    let j =
      if i < polyline.len - 1:
        i + 1
      else:
        0
    ws.edges.add CdtEdge()
    discard ws.newEdge(polyline[i], polyline[j])

proc addHole(ws: var CdtWorkspace, polyline: seq[CdtPointId]) =
  ws.initEdges(polyline)
  for p in polyline:
    ws.activePoints.add p

proc addPoint(ws: var CdtWorkspace, p: CdtPointId) =
  ws.activePoints.add p

proc pointCmp(ws: var CdtWorkspace, a, b: CdtPointId): int =
  let pa = ws.points[a]
  let pb = ws.points[b]
  if pa.y < pb.y:
    -1
  elif pa.y > pb.y:
    1
  elif pa.x < pb.x:
    -1
  elif pa.x > pb.x:
    1
  else:
    0

proc sortActivePoints(ws: var CdtWorkspace) =
  proc quicksort(ws: var CdtWorkspace, lo, hi: int) =
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

proc initTriangulation(ws: var CdtWorkspace) =
  var
    xmax = ws.point(ws.activePoints[0]).x
    xmin = xmax
    ymax = ws.point(ws.activePoints[0]).y
    ymin = ymax

  for id in ws.activePoints:
    let p = ws.point(id)
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

proc addToMap(ws: var CdtWorkspace, t: CdtTriangleId) =
  ws.triangleMap.add t

proc createAdvancingFront(ws: var CdtWorkspace) =
  let t = ws.newTriangle(ws.activePoints[0], ws.tail, ws.head)
  ws.triangleMap.add t

  ws.afHead = ws.newNode(ws.tri(t).points[1], t)
  ws.afMiddle = ws.newNode(ws.tri(t).points[0], t)
  ws.afTail = ws.newNode(ws.tri(t).points[2])
  ws.front = CdtFront(head: ws.afHead, tail: ws.afTail, searchNode: ws.afHead)

  ws.node(ws.afHead).next = ws.afMiddle
  ws.node(ws.afMiddle).next = ws.afTail
  ws.node(ws.afMiddle).prev = ws.afHead
  ws.node(ws.afTail).prev = ws.afMiddle

proc mapTriangleToNodes(ws: var CdtWorkspace, t: CdtTriangleId) =
  for i in 0 .. 2:
    if ws.tri(t).neighbors[i].isNil:
      let n = ws.locatePoint(ws.pointCW(t, ws.tri(t).points[i]))
      if not n.isNil:
        ws.node(n).triangle = t

proc meshClean(ws: var CdtWorkspace, t: CdtTriangleId) =
  var stack = @[t]
  while stack.len > 0:
    let item = stack.pop()
    if not item.isNil and not ws.tri(item).interior:
      ws.tri(item).interior = true
      ws.interiorTriangles.add item
      for i in 0 .. 2:
        if not ws.tri(item).constrainedEdge[i]:
          stack.add ws.tri(item).neighbors[i]

proc incircle(ws: var CdtWorkspace, pa, pb, pc, pd: CdtPointId): bool =
  let
    a = ws.point(pa)
    b = ws.point(pb)
    c = ws.point(pc)
    d = ws.point(pd)
    adx = a.x - d.x
    ady = a.y - d.y
    bdx = b.x - d.x
    bdy = b.y - d.y
    adxbdy = adx * bdy
    bdxady = bdx * ady
    oabd = adxbdy - bdxady

  if oabd <= 0:
    return false

  let
    cdx = c.x - d.x
    cdy = c.y - d.y
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

proc rotateTrianglePair(
    ws: var CdtWorkspace,
    t: CdtTriangleId,
    p: CdtPointId,
    ot: CdtTriangleId,
    op: CdtPointId,
) =
  let
    n1 = ws.neighborCCW(t, p)
    n2 = ws.neighborCW(t, p)
    n3 = ws.neighborCCW(ot, op)
    n4 = ws.neighborCW(ot, op)
    ce1 = ws.getConstrainedEdgeCCW(t, p)
    ce2 = ws.getConstrainedEdgeCW(t, p)
    ce3 = ws.getConstrainedEdgeCCW(ot, op)
    ce4 = ws.getConstrainedEdgeCW(ot, op)
    de1 = ws.getDelaunayEdgeCCW(t, p)
    de2 = ws.getDelaunayEdgeCW(t, p)
    de3 = ws.getDelaunayEdgeCCW(ot, op)
    de4 = ws.getDelaunayEdgeCW(ot, op)

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

  ws.clearNeighbors(t)
  ws.clearNeighbors(ot)
  if not n1.isNil:
    ws.markNeighbor(ot, n1)
  if not n2.isNil:
    ws.markNeighbor(t, n2)
  if not n3.isNil:
    ws.markNeighbor(t, n3)
  if not n4.isNil:
    ws.markNeighbor(ot, n4)
  ws.markNeighbor(t, ot)

proc legalize(ws: var CdtWorkspace, t: CdtTriangleId): bool =
  for i in 0 .. 2:
    if ws.tri(t).delaunayEdge[i]:
      continue

    let ot = ws.tri(t).neighbors[i]
    if not ot.isNil:
      let
        p = ws.tri(t).points[i]
        op = ws.oppositePoint(ot, t, p)
        oi = ws.index(ot, op)

      if ws.tri(ot).constrainedEdge[oi] or ws.tri(ot).delaunayEdge[oi]:
        ws.tri(t).constrainedEdge[i] = ws.tri(ot).constrainedEdge[oi]
        continue

      if ws.incircle(p, ws.pointCCW(t, p), ws.pointCW(t, p), op):
        ws.tri(t).delaunayEdge[i] = true
        ws.tri(ot).delaunayEdge[oi] = true

        ws.rotateTrianglePair(t, p, ot, op)

        var notLegalized = not ws.legalize(t)
        if notLegalized:
          ws.mapTriangleToNodes(t)

        notLegalized = not ws.legalize(ot)
        if notLegalized:
          ws.mapTriangleToNodes(ot)

        ws.tri(t).delaunayEdge[i] = false
        ws.tri(ot).delaunayEdge[oi] = false
        return true
  false

proc fill(ws: var CdtWorkspace, n: CdtNodeId) =
  let t = ws.newTriangle(
    ws.node(ws.node(n).prev).point, ws.node(n).point, ws.node(ws.node(n).next).point
  )
  ws.markNeighbor(t, ws.node(ws.node(n).prev).triangle)
  ws.markNeighbor(t, ws.node(n).triangle)
  ws.addToMap(t)

  let prev = ws.node(n).prev
  let next = ws.node(n).next
  ws.node(prev).next = next
  ws.node(next).prev = prev

  if not ws.legalize(t):
    ws.mapTriangleToNodes(t)

proc angle(ws: var CdtWorkspace, origin, pa, pb: CdtPointId): float64 =
  let
    o = ws.point(origin)
    a = ws.point(pa)
    b = ws.point(pb)
    ax = a.x - o.x
    ay = a.y - o.y
    bx = b.x - o.x
    by = b.y - o.y
    x = ax * by - ay * bx
    y = ax * bx + ay * by
  arctan2(x, y)

proc angleExceeds90Degrees(ws: var CdtWorkspace, origin, pa, pb: CdtPointId): bool =
  let a = ws.angle(origin, pa, pb)
  a > PiDiv2 or a < -PiDiv2

proc angleIsNegative(ws: var CdtWorkspace, origin, pa, pb: CdtPointId): bool =
  ws.angle(origin, pa, pb) < 0

proc angleExceedsPlus90DegreesOrIsNegative(
    ws: var CdtWorkspace, origin, pa, pb: CdtPointId
): bool =
  let a = ws.angle(origin, pa, pb)
  a > PiDiv2 or a < 0

proc largeHoleDontFill(ws: var CdtWorkspace, n: CdtNodeId): bool =
  let
    nextNode = ws.node(n).next
    prevNode = ws.node(n).prev
  if not ws.angleExceeds90Degrees(
    ws.node(n).point, ws.node(nextNode).point, ws.node(prevNode).point
  ):
    return false
  if ws.angleIsNegative(
    ws.node(n).point, ws.node(nextNode).point, ws.node(prevNode).point
  ):
    return true

  let next2Node = ws.node(nextNode).next
  if not next2Node.isNil and
      not ws.angleExceedsPlus90DegreesOrIsNegative(
        ws.node(n).point, ws.node(next2Node).point, ws.node(prevNode).point
      ):
    return false

  let prev2Node = ws.node(prevNode).prev
  if not prev2Node.isNil and
      not ws.angleExceedsPlus90DegreesOrIsNegative(
        ws.node(n).point, ws.node(nextNode).point, ws.node(prev2Node).point
      ):
    return false

  true

proc basinAngle(ws: var CdtWorkspace, n: CdtNodeId): float64 =
  let
    p = ws.point(ws.node(n).point)
    q = ws.point(ws.node(ws.node(ws.node(n).next).next).point)
  arctan2(p.y - q.y, p.x - q.x)

proc isShallow(ws: var CdtWorkspace, n: CdtNodeId): bool =
  let height =
    if ws.basin.leftHighest:
      ws.point(ws.node(ws.basin.leftNode).point).y - ws.point(ws.node(n).point).y
    else:
      ws.point(ws.node(ws.basin.rightNode).point).y - ws.point(ws.node(n).point).y
  ws.basin.width > height

proc fillBasinReq(ws: var CdtWorkspace, n: CdtNodeId)

proc fillBasin(ws: var CdtWorkspace, n: CdtNodeId) =
  if ws.orient2d(
    ws.node(n).point,
    ws.node(ws.node(n).next).point,
    ws.node(ws.node(ws.node(n).next).next).point,
  ) == ccw:
    ws.basin.leftNode = ws.node(ws.node(n).next).next
  else:
    ws.basin.leftNode = ws.node(n).next

  ws.basin.bottomNode = ws.basin.leftNode
  while not ws.node(ws.basin.bottomNode).next.isNil and
      ws.point(ws.node(ws.basin.bottomNode).point).y >=
      ws.point(ws.node(ws.node(ws.basin.bottomNode).next).point).y
  :
    ws.basin.bottomNode = ws.node(ws.basin.bottomNode).next
  if ws.basin.bottomNode == ws.basin.leftNode:
    return

  ws.basin.rightNode = ws.basin.bottomNode
  while not ws.node(ws.basin.rightNode).next.isNil and
      ws.point(ws.node(ws.basin.rightNode).point).y <
      ws.point(ws.node(ws.node(ws.basin.rightNode).next).point).y
  :
    ws.basin.rightNode = ws.node(ws.basin.rightNode).next
  if ws.basin.rightNode == ws.basin.bottomNode:
    return

  ws.basin.width =
    ws.point(ws.node(ws.basin.rightNode).point).x -
    ws.point(ws.node(ws.basin.leftNode).point).x
  ws.basin.leftHighest =
    ws.point(ws.node(ws.basin.leftNode).point).y >
    ws.point(ws.node(ws.basin.rightNode).point).y
  ws.fillBasinReq(ws.basin.bottomNode)

proc fillBasinReq(ws: var CdtWorkspace, n: CdtNodeId) =
  var n = n
  if ws.isShallow(n):
    return

  ws.fill(n)

  if ws.node(n).prev == ws.basin.leftNode and ws.node(n).next == ws.basin.rightNode:
    return
  elif ws.node(n).prev == ws.basin.leftNode:
    if ws.orient2d(
      ws.node(n).point,
      ws.node(ws.node(n).next).point,
      ws.node(ws.node(ws.node(n).next).next).point,
    ) == cw:
      return
    n = ws.node(n).next
  elif ws.node(n).next == ws.basin.rightNode:
    if ws.orient2d(
      ws.node(n).point,
      ws.node(ws.node(n).prev).point,
      ws.node(ws.node(ws.node(n).prev).prev).point,
    ) == ccw:
      return
    n = ws.node(n).prev
  else:
    if ws.point(ws.node(ws.node(n).prev).point).y <
        ws.point(ws.node(ws.node(n).next).point).y:
      n = ws.node(n).prev
    else:
      n = ws.node(n).next

  ws.fillBasinReq(n)

proc fillAdvancingFront(ws: var CdtWorkspace, n: CdtNodeId) =
  var node = ws.node(n).next
  while not ws.node(node).next.isNil:
    if ws.largeHoleDontFill(node):
      break
    ws.fill(node)
    node = ws.node(node).next

  node = ws.node(n).prev
  while not ws.node(node).prev.isNil:
    if ws.largeHoleDontFill(node):
      break
    ws.fill(node)
    node = ws.node(node).prev

  if not ws.node(n).next.isNil and not ws.node(ws.node(n).next).next.isNil:
    if ws.basinAngle(n) < Pi3Div4:
      ws.fillBasin(n)

proc isEdgeSideOfTriangle(
    ws: var CdtWorkspace, t: CdtTriangleId, ep, eq: CdtPointId
): bool =
  let idx = ws.edgeIndex(t, ep, eq)
  if idx != -1:
    ws.markConstrainedEdge(t, idx)
    let neighbor = ws.tri(t).neighbors[idx]
    if not neighbor.isNil:
      ws.markConstrainedEdge(neighbor, ep, eq)
    return true
  false

proc newFrontTriangle(ws: var CdtWorkspace, p: CdtPointId, n: CdtNodeId): CdtNodeId =
  let t = ws.newTriangle(p, ws.node(n).point, ws.node(ws.node(n).next).point)
  ws.markNeighbor(t, ws.node(n).triangle)
  ws.addToMap(t)

  result = ws.newNode(p)
  let next = ws.node(n).next
  ws.node(result).next = next
  ws.node(result).prev = n
  ws.node(next).prev = result
  ws.node(n).next = result

  if not ws.legalize(t):
    ws.mapTriangleToNodes(t)

proc pointEvent(ws: var CdtWorkspace, p: CdtPointId): CdtNodeId =
  let n = ws.locateNode(ws.point(p).x)
  if n.isNil:
    raise newException(ValueError, "failed to locate advancing-front node")
  result = ws.newFrontTriangle(p, n)
  if ws.point(p).x <= ws.point(ws.node(n).point).x + Epsilon:
    ws.fill(n)
  ws.fillAdvancingFront(result)

proc fillRightConcaveEdgeEvent(ws: var CdtWorkspace, edge: CdtEdgeId, n: CdtNodeId)
proc fillRightConvexEdgeEvent(ws: var CdtWorkspace, edge: CdtEdgeId, n: CdtNodeId)
proc fillRightBelowEdgeEvent(ws: var CdtWorkspace, edge: CdtEdgeId, n: CdtNodeId)
proc fillLeftBelowEdgeEvent(ws: var CdtWorkspace, edge: CdtEdgeId, n: CdtNodeId)
proc fillLeftConcaveEdgeEvent(ws: var CdtWorkspace, edge: CdtEdgeId, n: CdtNodeId)
proc fillLeftConvexEdgeEvent(ws: var CdtWorkspace, edge: CdtEdgeId, n: CdtNodeId)
proc edgeEvent(
  ws: var CdtWorkspace, ep, eq: CdtPointId, t: CdtTriangleId, p: CdtPointId
)

proc flipEdgeEvent(
  ws: var CdtWorkspace, ep, eq: CdtPointId, t: CdtTriangleId, p: CdtPointId
)

proc fillRightAboveEdgeEvent(ws: var CdtWorkspace, edge: CdtEdgeId, n: CdtNodeId) =
  var n = n
  while ws.point(ws.node(ws.node(n).next).point).x < ws.point(ws.edge(edge).p).x:
    if ws.orient2d(ws.edge(edge).q, ws.node(ws.node(n).next).point, ws.edge(edge).p) ==
        ccw:
      ws.fillRightBelowEdgeEvent(edge, n)
    else:
      n = ws.node(n).next

proc fillRightBelowEdgeEvent(ws: var CdtWorkspace, edge: CdtEdgeId, n: CdtNodeId) =
  if ws.point(ws.node(n).point).x < ws.point(ws.edge(edge).p).x:
    if ws.orient2d(
      ws.node(n).point,
      ws.node(ws.node(n).next).point,
      ws.node(ws.node(ws.node(n).next).next).point,
    ) == ccw:
      ws.fillRightConcaveEdgeEvent(edge, n)
    else:
      ws.fillRightConvexEdgeEvent(edge, n)
      ws.fillRightBelowEdgeEvent(edge, n)

proc fillRightConcaveEdgeEvent(ws: var CdtWorkspace, edge: CdtEdgeId, n: CdtNodeId) =
  ws.fill(ws.node(n).next)
  if ws.node(ws.node(n).next).point != ws.edge(edge).p:
    if ws.orient2d(ws.edge(edge).q, ws.node(ws.node(n).next).point, ws.edge(edge).p) ==
        ccw:
      if ws.orient2d(
        ws.node(n).point,
        ws.node(ws.node(n).next).point,
        ws.node(ws.node(ws.node(n).next).next).point,
      ) == ccw:
        ws.fillRightConcaveEdgeEvent(edge, n)

proc fillRightConvexEdgeEvent(ws: var CdtWorkspace, edge: CdtEdgeId, n: CdtNodeId) =
  if ws.orient2d(
    ws.node(ws.node(n).next).point,
    ws.node(ws.node(ws.node(n).next).next).point,
    ws.node(ws.node(ws.node(ws.node(n).next).next).next).point,
  ) == ccw:
    ws.fillRightConcaveEdgeEvent(edge, ws.node(n).next)
  elif ws.orient2d(
    ws.edge(edge).q, ws.node(ws.node(ws.node(n).next).next).point, ws.edge(edge).p
  ) == ccw:
    ws.fillRightConvexEdgeEvent(edge, ws.node(n).next)

proc fillLeftAboveEdgeEvent(ws: var CdtWorkspace, edge: CdtEdgeId, n: CdtNodeId) =
  var n = n
  while ws.point(ws.node(ws.node(n).prev).point).x > ws.point(ws.edge(edge).p).x:
    if ws.orient2d(ws.edge(edge).q, ws.node(ws.node(n).prev).point, ws.edge(edge).p) ==
        cw:
      ws.fillLeftBelowEdgeEvent(edge, n)
    else:
      n = ws.node(n).prev

proc fillLeftBelowEdgeEvent(ws: var CdtWorkspace, edge: CdtEdgeId, n: CdtNodeId) =
  if ws.point(ws.node(n).point).x > ws.point(ws.edge(edge).p).x:
    if ws.orient2d(
      ws.node(n).point,
      ws.node(ws.node(n).prev).point,
      ws.node(ws.node(ws.node(n).prev).prev).point,
    ) == cw:
      ws.fillLeftConcaveEdgeEvent(edge, n)
    else:
      ws.fillLeftConvexEdgeEvent(edge, n)
      ws.fillLeftBelowEdgeEvent(edge, n)

proc fillLeftConvexEdgeEvent(ws: var CdtWorkspace, edge: CdtEdgeId, n: CdtNodeId) =
  if ws.orient2d(
    ws.node(ws.node(n).prev).point,
    ws.node(ws.node(ws.node(n).prev).prev).point,
    ws.node(ws.node(ws.node(ws.node(n).prev).prev).prev).point,
  ) == cw:
    ws.fillLeftConcaveEdgeEvent(edge, ws.node(n).prev)
  elif ws.orient2d(
    ws.edge(edge).q, ws.node(ws.node(ws.node(n).prev).prev).point, ws.edge(edge).p
  ) == cw:
    ws.fillLeftConvexEdgeEvent(edge, ws.node(n).prev)

proc fillLeftConcaveEdgeEvent(ws: var CdtWorkspace, edge: CdtEdgeId, n: CdtNodeId) =
  ws.fill(ws.node(n).prev)
  if ws.node(ws.node(n).prev).point != ws.edge(edge).p:
    if ws.orient2d(ws.edge(edge).q, ws.node(ws.node(n).prev).point, ws.edge(edge).p) ==
        cw:
      if ws.orient2d(
        ws.node(n).point,
        ws.node(ws.node(n).prev).point,
        ws.node(ws.node(ws.node(n).prev).prev).point,
      ) == cw:
        ws.fillLeftConcaveEdgeEvent(edge, n)

proc fillEdgeEvent(ws: var CdtWorkspace, edge: CdtEdgeId, n: CdtNodeId) =
  if ws.edgeEvent.right:
    ws.fillRightAboveEdgeEvent(edge, n)
  else:
    ws.fillLeftAboveEdgeEvent(edge, n)

proc nextFlipTriangle(
    ws: var CdtWorkspace, o: Orientation, t, ot: CdtTriangleId, p, op: CdtPointId
): CdtTriangleId =
  if o == ccw:
    let idx = ws.edgeIndex(ot, p, op)
    ws.tri(ot).delaunayEdge[idx] = true
    discard ws.legalize(ot)
    ws.clearDelaunayEdges(ot)
    return t

  let idx = ws.edgeIndex(t, p, op)
  ws.tri(t).delaunayEdge[idx] = true
  discard ws.legalize(t)
  ws.clearDelaunayEdges(t)
  ot

proc nextFlipPoint(
    ws: var CdtWorkspace, ep, eq: CdtPointId, ot: CdtTriangleId, op: CdtPointId
): CdtPointId =
  case ws.orient2d(eq, op, ep)
  of cw:
    ws.pointCCW(ot, op)
  of ccw:
    ws.pointCW(ot, op)
  of collinear:
    raise newException(ValueError, "opposing point on constrained edge")

proc flipScanEdgeEvent(
    ws: var CdtWorkspace,
    ep, eq: CdtPointId,
    flipTriangle, t: CdtTriangleId,
    p: CdtPointId,
) =
  let ot = ws.neighborAcross(t, p)
  if ot.isNil:
    raise newException(ValueError, "flip scan failed due to missing triangle")
  let op = ws.oppositePoint(ot, t, p)

  if ws.inScanArea(eq, ws.pointCCW(flipTriangle, eq), ws.pointCW(flipTriangle, eq), op):
    ws.flipEdgeEvent(eq, op, ot, op)
  else:
    let newP = ws.nextFlipPoint(ep, eq, ot, op)
    ws.flipScanEdgeEvent(ep, eq, flipTriangle, ot, newP)

proc flipEdgeEvent(
    ws: var CdtWorkspace, ep, eq: CdtPointId, t: CdtTriangleId, p: CdtPointId
) =
  let ot = ws.neighborAcross(t, p)
  if ot.isNil:
    raise newException(ValueError, "flip failed due to missing triangle")
  let op = ws.oppositePoint(ot, t, p)

  if ws.inScanArea(p, ws.pointCCW(t, p), ws.pointCW(t, p), op):
    ws.rotateTrianglePair(t, p, ot, op)
    ws.mapTriangleToNodes(t)
    ws.mapTriangleToNodes(ot)

    if p == eq and op == ep:
      if eq == ws.edge(ws.edgeEvent.constrainedEdge).q and
          ep == ws.edge(ws.edgeEvent.constrainedEdge).p:
        ws.markConstrainedEdge(t, ep, eq)
        ws.markConstrainedEdge(ot, ep, eq)
        discard ws.legalize(t)
        discard ws.legalize(ot)
    else:
      let o = ws.orient2d(eq, op, ep)
      let nextT = ws.nextFlipTriangle(o, t, ot, p, op)
      ws.flipEdgeEvent(ep, eq, nextT, p)
  else:
    let newP = ws.nextFlipPoint(ep, eq, ot, op)
    ws.flipScanEdgeEvent(ep, eq, t, ot, newP)
    ws.edgeEvent(ep, eq, t, p)

proc edgeEvent(
    ws: var CdtWorkspace, ep, eq: CdtPointId, t: CdtTriangleId, p: CdtPointId
) =
  var t = t
  if ws.isEdgeSideOfTriangle(t, ep, eq):
    return

  let p1 = ws.pointCCW(t, p)
  let o1 = ws.orient2d(eq, p1, ep)
  if o1 == collinear:
    if ws.contains(t, eq, p1):
      ws.markConstrainedEdge(t, eq, p1)
      ws.edge(ws.edgeEvent.constrainedEdge).q = p1
      ws.edgeEvent(ep, p1, ws.neighborAcross(t, p), p1)
    else:
      raise
        newException(ValueError, "collinear constrained edge points are not supported")
    return

  let p2 = ws.pointCW(t, p)
  let o2 = ws.orient2d(eq, p2, ep)
  if o2 == collinear:
    if ws.contains(t, eq, p2):
      ws.markConstrainedEdge(t, eq, p2)
      ws.edge(ws.edgeEvent.constrainedEdge).q = p2
      ws.edgeEvent(ep, p2, ws.neighborAcross(t, p), p2)
    else:
      raise
        newException(ValueError, "collinear constrained edge points are not supported")
    return

  if o1 == o2:
    if o1 == cw:
      t = ws.neighborCCW(t, p)
    else:
      t = ws.neighborCW(t, p)
    if t.isNil:
      raise newException(ValueError, "missing neighbor while walking constrained edge")
    ws.edgeEvent(ep, eq, t, p)
  else:
    ws.flipEdgeEvent(ep, eq, t, p)

proc edgeEvent(ws: var CdtWorkspace, edgeId: CdtEdgeId, n: CdtNodeId) =
  ws.edgeEvent.constrainedEdge = edgeId
  ws.edgeEvent.right = ws.point(ws.edge(edgeId).p).x > ws.point(ws.edge(edgeId).q).x
  if ws.isEdgeSideOfTriangle(ws.node(n).triangle, ws.edge(edgeId).p, ws.edge(edgeId).q):
    return
  ws.fillEdgeEvent(edgeId, n)
  ws.edgeEvent(
    ws.edge(edgeId).p, ws.edge(edgeId).q, ws.node(n).triangle, ws.edge(edgeId).q
  )

proc sweepPoints(ws: var CdtWorkspace) =
  for i in 1 ..< ws.activePoints.len:
    let p = ws.activePoints[i]
    let n = ws.pointEvent(p)
    let edges = ws.point(p).edgeList
    for edgeId in edges:
      ws.edgeEvent(edgeId, n)

proc finalizationPolygon(ws: var CdtWorkspace) =
  var t = ws.node(ws.node(ws.front.head).next).triangle
  let p = ws.node(ws.node(ws.front.head).next).point
  while not ws.getConstrainedEdgeCW(t, p):
    t = ws.neighborCCW(t, p)
    if t.isNil:
      raise newException(ValueError, "failed to find finalization triangle")
  ws.meshClean(t)

proc triangulate(ws: var CdtWorkspace) =
  ws.initTriangulation()
  ws.createAdvancingFront()
  ws.sweepPoints()
  ws.finalizationPolygon()

proc buildPoints(
    ws: var CdtWorkspace, contour: seq[Vec2], vertices: var seq[Vec2]
): seq[CdtPointId] =
  for p in contour:
    vertices.add p
    result.add ws.newPoint(p.x, p.y, vertices.high)

proc triangulateCdt*(workspace: var TessWorkspace, input: CdtInput): CdtResult =
  if input.outer.len < 3:
    raise newException(ValueError, "outer contour has fewer than 3 points")

  workspace.cdt.resetCdt()
  workspace.vertices.setLen(0)

  let outer = workspace.cdt.buildPoints(input.outer, workspace.vertices)
  workspace.cdt.activePoints = outer
  workspace.cdt.initEdges(outer)

  for hole in input.holes:
    workspace.cdt.addHole(workspace.cdt.buildPoints(hole, workspace.vertices))

  for p in input.steiner:
    workspace.vertices.add p
    workspace.cdt.addPoint(workspace.cdt.newPoint(p.x, p.y, workspace.vertices.high))

  workspace.cdt.triangulate()

  result.vertices = workspace.vertices
  for t in workspace.cdt.interiorTriangles:
    let tri = [
      workspace.cdt.point(workspace.cdt.tri(t).points[0]).sourceIndex,
      workspace.cdt.point(workspace.cdt.tri(t).points[1]).sourceIndex,
      workspace.cdt.point(workspace.cdt.tri(t).points[2]).sourceIndex,
    ]
    if tri[0] < 0 or tri[1] < 0 or tri[2] < 0:
      continue
    result.triangles.add tri
