## Pointer-arena sweep-line constrained Delaunay triangulation (CDT).
##
## This preserves the Poly2Tri advancing-front algorithm used by cdt.nim, but
## stores the hot mesh/front objects as direct pointers into reusable arena
## buffers. It is selected with -d:p2tArenaCdt.

import ../types

when defined(p2tPhaseProf):
  import std/[monotimes, times]

when defined(p2tFrontHashStats) and not defined(p2tCdtStats):
  {.fatal: "p2tFrontHashStats requires -d:p2tCdtStats".}

when defined(p2tIncircleProf) and not defined(p2tCdtStats):
  {.fatal: "p2tIncircleProf requires -d:p2tCdtStats".}

when defined(p2tUnsafeCdt):
  {.push checks: off.}

const
  Epsilon = ArenaReal(1e-12)
  Alpha = ArenaReal(0.3)
  DelaunayEdge0 = 1'u32 shl 0
  ConstrainedEdge0 = 1'u32 shl 3
  InteriorFlag = 1'u32 shl 30
  DelaunayEdgeMask = DelaunayEdge0 or (DelaunayEdge0 shl 1) or (DelaunayEdge0 shl 2)
  NextEdgeIndex = [1, 2, 0]
  PrevEdgeIndex = [2, 0, 1]

when defined(p2tSlotCdt):
  const NilNeighborSlot = 255'u8

when FrontHashOn:
  const
    FrontHashMinPoints {.intdefine.} = 512
    # 0 = uncapped. The hash is a pure accelerator for locateNode (the linear
    # front walk still corrects from the bucket node), so capping it only
    # forced the largest fronts back onto the slow O(n) walk. Uncapped it gives
    # ~2.1x on large-shape and beats fast-poly2tri on the nazca fixtures.
    FrontHashMaxPoints {.intdefine.} = 0
    FrontHashBucketFactor {.intdefine.} = 2
    FrontHashScanRadius {.intdefine.} = 8

  template frontHashPointCountEnabled(pointCount: int): bool =
    pointCount >= FrontHashMinPoints and
      (FrontHashMaxPoints <= 0 or pointCount <= FrontHashMaxPoints)

when defined(p2tFrontHashStats):
  type FrontHashHint = enum
    fhDirect
    fhScan
    fhFallback

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

when defined(p2tPhaseProf):
  type
    ArenaCdtPhase* = enum
      phSetup
      phSort
      phLocate
      phPointEvent
      phFill
      phLegalize
      phEdgeEvent
      phFinalize

    ArenaCdtPhaseProf* = object
      ns*: array[ArenaCdtPhase, int64]
      hits*: array[ArenaCdtPhase, int64]
      stack: array[64, tuple[phase: ArenaCdtPhase, start: MonoTime]]
      sp: int

  var arenaCdtPhaseProf*: ArenaCdtPhaseProf

  proc resetArenaCdtPhaseProf*() =
    for phase in ArenaCdtPhase:
      arenaCdtPhaseProf.ns[phase] = 0
      arenaCdtPhaseProf.hits[phase] = 0
    arenaCdtPhaseProf.sp = 0

  proc arenaCdtPhaseProfSnapshot*(): ArenaCdtPhaseProf =
    arenaCdtPhaseProf

  proc enterPhase(phase: ArenaCdtPhase) {.inline.} =
    let now = getMonoTime()
    if arenaCdtPhaseProf.sp > 0:
      let parent = arenaCdtPhaseProf.stack[arenaCdtPhaseProf.sp - 1]
      arenaCdtPhaseProf.ns[parent.phase] += (now - parent.start).inNanoseconds
      arenaCdtPhaseProf.stack[arenaCdtPhaseProf.sp - 1].start = now
    arenaCdtPhaseProf.stack[arenaCdtPhaseProf.sp] = (phase, now)
    inc arenaCdtPhaseProf.sp

  proc exitPhase() {.inline.} =
    let now = getMonoTime()
    dec arenaCdtPhaseProf.sp
    let current = arenaCdtPhaseProf.stack[arenaCdtPhaseProf.sp]
    arenaCdtPhaseProf.ns[current.phase] += (now - current.start).inNanoseconds
    inc arenaCdtPhaseProf.hits[current.phase]
    if arenaCdtPhaseProf.sp > 0:
      arenaCdtPhaseProf.stack[arenaCdtPhaseProf.sp - 1].start = now

  template phase(p: ArenaCdtPhase, body: untyped) =
    enterPhase(p)
    try:
      body
    finally:
      exitPhase()
else:
  template phase(p: untyped, body: untyped) =
    body

when defined(p2tCdtStats):
  var arenaCdtStats*: ArenaCdtStats

  proc arenaCdtStatsSnapshot*(): ArenaCdtStats =
    arenaCdtStats

  template statIncGlobal(field: untyped) =
    inc arenaCdtStats.field

  template statInc(ws: var ArenaWorkspace, field: untyped) =
    inc arenaCdtStats.field

  template statInc(t: ptr ArenaTriangle, field: untyped) =
    inc arenaCdtStats.field

  when defined(p2tFrontHashStats):
    proc frontHashWalkBin(steps: uint64): int {.inline.} =
      if steps == 0:
        0
      elif steps == 1:
        1
      elif steps == 2:
        2
      elif steps <= 4:
        3
      elif steps <= 8:
        4
      elif steps <= 16:
        5
      elif steps <= 32:
        6
      elif steps <= 64:
        7
      elif steps <= 128:
        8
      elif steps <= 256:
        9
      else:
        10

    proc recordFrontHashWalk(
        bucket: var FrontHashWalkStats, steps: uint64, direction: int
    ) {.inline.} =
      inc bucket.count
      bucket.sum += steps
      if steps > bucket.max:
        bucket.max = steps
      inc bucket.bins[frontHashWalkBin(steps)]
      if direction < 0:
        inc bucket.leftWalks
      elif direction > 0:
        inc bucket.rightWalks

    proc recordFrontHashWalk(
        hint: FrontHashHint, steps: uint64, direction: int
    ) {.inline.} =
      case hint
      of fhDirect:
        recordFrontHashWalk(arenaCdtStats.frontHashDirect, steps, direction)
      of fhScan:
        recordFrontHashWalk(arenaCdtStats.frontHashScan, steps, direction)
      of fhFallback:
        recordFrontHashWalk(arenaCdtStats.frontHashFallback, steps, direction)

    proc recordFrontHashScanRadius(radius: int) {.inline.} =
      if radius >= 1 and radius <= FrontHashScanRadiusCount:
        inc arenaCdtStats.frontHashScanRadius[radius - 1]

else:
  template statIncGlobal(field: untyped) =
    discard

  template statInc(ws: var ArenaWorkspace, field: untyped) =
    discard

  template statInc(t: ptr ArenaTriangle, field: untyped) =
    discard

proc resetCdt(ws: var ArenaWorkspace) =
  ws.pointCount = 0
  ws.edgeCount = 0
  ws.triangleCount = 0
  ws.nodeCount = 0
  ws.rawInteriorCount = 0
  ws.activePoints.setLen(0)
  # sortTemp is merge-sort scratch (fully overwritten per sort); keep its length
  # across reuse so the sort grows it at most once instead of every iteration.
  # meshStack and interiorTriangles are scratch/output buffers owned entirely by
  # meshClean; never reset their length so we avoid a per-call grow that
  # zero-fills triangles.len pointer slots. rawInteriorCount is the real count.
  when FrontHashOn:
    ws.frontBuckets.setLen(0)
    ws.frontBucketMin = 0
    ws.frontBucketScale = 0
  ws.front = ArenaFront()
  ws.head = nil
  ws.tail = nil
  ws.afHead = nil
  ws.afMiddle = nil
  ws.afTail = nil
  ws.basin = ArenaBasin()
  ws.edgeEvent = ArenaEdgeEvent()
  when defined(p2tCdtStats):
    arenaCdtStats = ArenaCdtStats()

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
  when FrontHashOn:
    if frontHashPointCountEnabled(pointCount):
      workspace.arena.frontBuckets.reserveSeq(max(16, pointCount div 4))
  workspace.arena.activePoints.reserveSeq(pointCount + 2)
  when defined(p2tMergeSort):
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

proc asArenaReal(x: float64): ArenaReal {.inline.} =
  ArenaReal(x)

proc newPoint(
    ws: var ArenaWorkspace, x, y: float64, sourceIndex = -1
): ptr ArenaPoint {.inline.} =
  result = addr ws.points[ws.pointCount]
  result.firstEdge = nil
  result.node = nil
  result.x = x.asArenaReal
  result.y = y.asArenaReal
  result.sourceIndex = sourceIndex.int32
  result.id = ws.pointCount.int32
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
  statIncGlobal(inScanAreaCalls)
  let oadb = (pa.x - pb.x) * (pd.y - pb.y) - (pd.x - pb.x) * (pa.y - pb.y)
  if oadb >= -Epsilon:
    return false

  let oadc = (pa.x - pc.x) * (pd.y - pc.y) - (pd.x - pc.x) * (pa.y - pc.y)
  if oadc <= Epsilon:
    return false
  true

proc newEdge(ws: var ArenaWorkspace, p1, p2: ptr ArenaPoint): ptr ArenaEdge {.inline.} =
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
  result.p = p
  result.q = q
  result.next = nil
  if q.firstEdge.isNil:
    q.firstEdge = result
  else:
    var last = q.firstEdge
    while not last.next.isNil:
      last = last.next
    last.next = result

proc newTriangle(
    ws: var ArenaWorkspace, a, b, c: ptr ArenaPoint
): ptr ArenaTriangle {.inline.} =
  result = addr ws.triangles[ws.triangleCount]
  result.points[0] = a
  result.points[1] = b
  result.points[2] = c
  result.neighbors[0] = nil
  result.neighbors[1] = nil
  result.neighbors[2] = nil
  when defined(p2tSlotCdt):
    result.neighborSlots[0] = NilNeighborSlot
    result.neighborSlots[1] = NilNeighborSlot
    result.neighborSlots[2] = NilNeighborSlot
  result.flags = 0
  inc ws.triangleCount

proc contains(t: ptr ArenaTriangle, p: ptr ArenaPoint): bool {.inline.} =
  t.points[0] == p or t.points[1] == p or t.points[2] == p

proc contains(t: ptr ArenaTriangle, p, q: ptr ArenaPoint): bool {.inline.} =
  t.contains(p) and t.contains(q)

proc edgeIndexPlain(t: ptr ArenaTriangle, p1, p2: ptr ArenaPoint): int {.inline.} =
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

proc markNeighbor(
    t: ptr ArenaTriangle, p1, p2: ptr ArenaPoint, other: ptr ArenaTriangle
) {.inline.} =
  statIncGlobal(markNeighborCalls)
  if (p1 == t.points[2] and p2 == t.points[1]) or
      (p1 == t.points[1] and p2 == t.points[2]):
    t.neighbors[0] = other
    when defined(p2tSlotCdt):
      t.neighborSlots[0] = other.edgeIndexPlain(p1, p2).uint8
  elif (p1 == t.points[0] and p2 == t.points[2]) or
      (p1 == t.points[2] and p2 == t.points[0]):
    t.neighbors[1] = other
    when defined(p2tSlotCdt):
      t.neighborSlots[1] = other.edgeIndexPlain(p1, p2).uint8
  elif (p1 == t.points[0] and p2 == t.points[1]) or
      (p1 == t.points[1] and p2 == t.points[0]):
    t.neighbors[2] = other
    when defined(p2tSlotCdt):
      t.neighborSlots[2] = other.edgeIndexPlain(p1, p2).uint8

proc swapNeighbor(
    t: ptr ArenaTriangle, oldNeighbor, newNeighbor: ptr ArenaTriangle
) {.inline, used.} =
  for i in 0 .. 2:
    statIncGlobal(swapNeighborScans)
    if t.neighbors[i] == oldNeighbor:
      t.neighbors[i] = newNeighbor
      when defined(p2tSlotCdt):
        let oldSide = t.neighborSlots[i].int
        if oldSide >= 0 and oldSide < 3:
          t.neighborSlots[i] = newNeighbor.neighborSlots[oldSide]
      return

proc neighborIndexPlain(
    t: ptr ArenaTriangle, neighbor: ptr ArenaTriangle
): int {.inline, used.} =
  for i in 0 .. 2:
    if t.neighbors[i] == neighbor:
      return i
  -1

proc clearDelaunayEdges(t: ptr ArenaTriangle) {.inline.} =
  t.flags = t.flags and not DelaunayEdgeMask

proc neighborCW(
    t: ptr ArenaTriangle, p: ptr ArenaPoint
): ptr ArenaTriangle {.inline, used.} =
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

proc getConstrainedEdgeCCW(
    t: ptr ArenaTriangle, p: ptr ArenaPoint
): bool {.inline, used.} =
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

proc getDelaunayEdgeCCW(
    t: ptr ArenaTriangle, p: ptr ArenaPoint
): bool {.inline, used.} =
  if p == t.points[0]:
    t.hasFlag(delaunayFlag(2))
  elif p == t.points[1]:
    t.hasFlag(delaunayFlag(0))
  else:
    t.hasFlag(delaunayFlag(1))

proc getDelaunayEdgeCW(t: ptr ArenaTriangle, p: ptr ArenaPoint): bool {.inline, used.} =
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

proc applyRotatedFlags(
    t: ptr ArenaTriangle, ea, eb: int, deA, ceA, deB, ceB: bool
) {.inline.} =
  ## Write back the two rotated edges of `t` in a single masked store, with no
  ## point search. After a rotate the touched edge indices `ea`/`eb` are pure
  ## functions of the rotate amounts (already computed by the caller), so the
  ## constrained+delaunay bits fold into one flags update. Edge `ea` receives
  ## (deA, ceA); edge `eb` receives (deB, ceB). Constrained bits sit 3 above the
  ## matching delaunay bit (see DelaunayEdge0/ConstrainedEdge0).
  const pair = DelaunayEdge0 or ConstrainedEdge0
  let mask = (pair shl ea) or (pair shl eb)
  let bits =
    (uint32(ord(deA)) shl ea) or (uint32(ord(ceA)) shl (ea + 3)) or
    (uint32(ord(deB)) shl eb) or (uint32(ord(ceB)) shl (eb + 3))
  t.flags = (t.flags and not mask) or bits

proc oppositePointAcross(
    t: ptr ArenaTriangle, a, b: ptr ArenaPoint
): tuple[point: ptr ArenaPoint, index: int] {.inline.} =
  if t.points[0] != a and t.points[0] != b:
    (t.points[0], 0)
  elif t.points[1] != a and t.points[1] != b:
    (t.points[1], 1)
  else:
    (t.points[2], 2)

proc pointCW(
    t: ptr ArenaTriangle, p: ptr ArenaPoint
): tuple[point: ptr ArenaPoint, index: int] {.inline.} =
  ## Point clockwise from `p` in `t` (== the apex opposite the shared edge whose
  ## cw endpoint is `p`). Mirrors fast-poly2tri MPE_PointCW: needs only `p`, so
  ## the ccw shared point can be computed lazily after the constrained check.
  if p == t.points[0]:
    (t.points[2], 2)
  elif p == t.points[1]:
    (t.points[0], 0)
  else:
    (t.points[1], 1)

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
  t.statInc(indexCalls)
  if p == t.points[0]:
    0
  elif p == t.points[1]:
    1
  elif p == t.points[2]:
    2
  else:
    -1

proc edgeIndex(t: ptr ArenaTriangle, p1, p2: ptr ArenaPoint): int {.inline.} =
  t.statInc(edgeIndexCalls)
  t.edgeIndexPlain(p1, p2)

proc markConstrainedEdge(t: ptr ArenaTriangle, edgeIndex: int) {.inline.} =
  t.setFlag(constrainedFlag(edgeIndex), true)

proc markConstrainedEdge(t: ptr ArenaTriangle, p, q: ptr ArenaPoint) {.inline.} =
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
): ptr ArenaNode {.inline.} =
  result = addr ws.nodes[ws.nodeCount]
  result.next = nil
  result.prev = nil
  result.point = p
  result.triangle = t
  result.value = p.x
  p.node = result
  inc ws.nodeCount

when FrontHashOn:
  proc frontHashBucketCount(pointCount: int): int =
    var root = 1
    while root * root < pointCount:
      inc root
    max(16, root * FrontHashBucketFactor)

  proc initFrontHash(ws: var ArenaWorkspace, xmin, xmax: ArenaReal, pointCount: int) =
    if not frontHashPointCountEnabled(pointCount):
      ws.frontBuckets.setLen(0)
      ws.frontBucketMin = 0
      ws.frontBucketScale = 0
      return

    let bucketCount = frontHashBucketCount(pointCount)
    ws.frontBuckets.setLen(bucketCount)
    for i in 0 ..< ws.frontBuckets.len:
      ws.frontBuckets[i] = nil
    ws.frontBucketMin = xmin
    let width = xmax - xmin
    ws.frontBucketScale =
      if width > 0:
        ArenaReal(bucketCount - 1) / width
      else:
        0

  proc frontBucketIndex(ws: var ArenaWorkspace, x: ArenaReal): int {.inline.} =
    if ws.frontBuckets.len == 0:
      return 0
    result = ((x - ws.frontBucketMin) * ws.frontBucketScale).int
    if result < 0:
      result = 0
    elif result >= ws.frontBuckets.len:
      result = ws.frontBuckets.high

  proc isLiveFrontNode(n: ptr ArenaNode): bool {.inline.} =
    not n.isNil and not n.point.isNil and n.point.node == n

  proc arenaAbs(x: ArenaReal): ArenaReal {.inline.} =
    if x < 0:
      -x
    else:
      x

  proc updateFrontBucket(ws: var ArenaWorkspace, n: ptr ArenaNode) =
    if ws.frontBuckets.len == 0 or not n.isLiveFrontNode:
      return
    ws.statInc(frontBucketUpdates)
    let
      idx = ws.frontBucketIndex(n.value)
      existing = ws.frontBuckets[idx]
    if not existing.isLiveFrontNode:
      ws.frontBuckets[idx] = n
      return

    let
      bucketX =
        if ws.frontBucketScale > 0:
          ws.frontBucketMin + ArenaReal(idx) / ws.frontBucketScale
        else:
          n.value
      existingDist = arenaAbs(existing.value - bucketX)
      nodeDist = arenaAbs(n.value - bucketX)
    if nodeDist <= existingDist:
      ws.frontBuckets[idx] = n

  when defined(p2tFrontHashStats):
    proc nearestBucketNode(
        ws: var ArenaWorkspace, x: ArenaReal, hint: var FrontHashHint
    ): ptr ArenaNode =
      hint = fhFallback
      if ws.frontBuckets.len == 0:
        ws.statInc(locateNodeHashMisses)
        return nil
      let idx = ws.frontBucketIndex(x)
      let direct = ws.frontBuckets[idx]
      if direct.isLiveFrontNode:
        ws.statInc(locateNodeHashHits)
        hint = fhDirect
        return direct
      ws.frontBuckets[idx] = nil
      when FrontHashScanRadius > 0:
        for offset in 1 .. min(ws.frontBuckets.high, FrontHashScanRadius):
          let left = idx - offset
          if left >= 0:
            let node = ws.frontBuckets[left]
            if node.isLiveFrontNode:
              ws.statInc(locateNodeHashHits)
              hint = fhScan
              recordFrontHashScanRadius(offset)
              return node
            ws.frontBuckets[left] = nil
          let right = idx + offset
          if right < ws.frontBuckets.len:
            let node = ws.frontBuckets[right]
            if node.isLiveFrontNode:
              ws.statInc(locateNodeHashHits)
              hint = fhScan
              recordFrontHashScanRadius(offset)
              return node
            ws.frontBuckets[right] = nil
      ws.statInc(locateNodeHashMisses)
      nil

  else:
    proc nearestBucketNode(ws: var ArenaWorkspace, x: ArenaReal): ptr ArenaNode =
      if ws.frontBuckets.len == 0:
        ws.statInc(locateNodeHashMisses)
        return nil
      let idx = ws.frontBucketIndex(x)
      let direct = ws.frontBuckets[idx]
      if direct.isLiveFrontNode:
        ws.statInc(locateNodeHashHits)
        return direct
      ws.frontBuckets[idx] = nil
      when FrontHashScanRadius > 0:
        for offset in 1 .. min(ws.frontBuckets.high, FrontHashScanRadius):
          let left = idx - offset
          if left >= 0:
            let node = ws.frontBuckets[left]
            if node.isLiveFrontNode:
              ws.statInc(locateNodeHashHits)
              return node
            ws.frontBuckets[left] = nil
          let right = idx + offset
          if right < ws.frontBuckets.len:
            let node = ws.frontBuckets[right]
            if node.isLiveFrontNode:
              ws.statInc(locateNodeHashHits)
              return node
            ws.frontBuckets[right] = nil
      ws.statInc(locateNodeHashMisses)
      nil

proc locateNode(ws: var ArenaWorkspace, x: ArenaReal): ptr ArenaNode =
  when FrontHashOn:
    when defined(p2tFrontHashStats):
      var
        hint = fhFallback
        node: ptr ArenaNode
      if ws.frontBuckets.len == 0:
        node = ws.front.searchNode
      else:
        let bucketNode = ws.nearestBucketNode(x, hint)
        node = if bucketNode.isNil: ws.front.searchNode else: bucketNode
    else:
      var node =
        if ws.frontBuckets.len == 0:
          ws.front.searchNode
        else:
          let bucketNode = ws.nearestBucketNode(x)
          if bucketNode.isNil: ws.front.searchNode else: bucketNode
  else:
    when defined(p2tFrontHashStats):
      var hint = fhFallback
    var node = ws.front.searchNode
  if x < node.value:
    when defined(p2tFrontHashStats):
      var correctionSteps = 0'u64
    while not node.isNil:
      ws.statInc(locateNodeSteps)
      node = node.prev
      when defined(p2tFrontHashStats):
        inc correctionSteps
      if not node.isNil and x >= node.value:
        ws.front.searchNode = node
        when FrontHashOn:
          if ws.frontBuckets.len != 0:
            ws.updateFrontBucket(node)
        when defined(p2tFrontHashStats):
          recordFrontHashWalk(hint, correctionSteps, -1)
        return node
  else:
    when defined(p2tFrontHashStats):
      var correctionSteps = 0'u64
    while not node.isNil:
      ws.statInc(locateNodeSteps)
      node = node.next
      if not node.isNil and x < node.value:
        ws.front.searchNode = node.prev
        when FrontHashOn:
          if ws.frontBuckets.len != 0:
            ws.updateFrontBucket(node.prev)
        when defined(p2tFrontHashStats):
          let direction =
            if correctionSteps == 0:
              0
            else:
              1
          recordFrontHashWalk(hint, correctionSteps, direction)
        return node.prev
      when defined(p2tFrontHashStats):
        inc correctionSteps
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
    if ws.sortTemp.len < ws.activePoints.len:
      ws.sortTemp.setLen(ws.activePoints.len)
    ws.sortRange(0, ws.activePoints.len)

when not defined(p2tQuickSort):
  # pdqsort: pattern-defeating quicksort over activePoints, vendored from
  # ~/dev/fastsort-nim (Orson Peters' pdqsort). Comparator splices pointCmp so it
  # inlines to a raw lexicographic (y,x) compare. In-place (no sortTemp traffic),
  # which is why it beats the previous hybrid merge sort on every fixture. This is
  # the default sort; -d:p2tMergeSort / -d:p2tQuickSort select the alternatives.
  const
    PdqInsertionThreshold = 24
    PdqNintherThreshold = 128

  func pdqLog2(n: int): int {.inline.} =
    var v = n
    while v > 1:
      inc result
      v = v shr 1

  template pdqLt(x, y: ptr ArenaPoint): bool =
    pointCmp(x, y) < 0

  proc pdqIns(a: var seq[ptr ArenaPoint], lo, hi: int) =
    var i = lo + 1
    while i <= hi:
      var j = i
      let tmp = a[j]
      while j > lo and pdqLt(tmp, a[j - 1]):
        a[j] = a[j - 1]
        dec j
      a[j] = tmp
      inc i

  proc pdqUnIns(a: var seq[ptr ArenaPoint], lo, hi: int) =
    var i = lo + 1
    while i <= hi:
      var j = i
      let tmp = a[j]
      while pdqLt(tmp, a[j - 1]):
        a[j] = a[j - 1]
        dec j
      a[j] = tmp
      inc i

  proc pdqS3(a: var seq[ptr ArenaPoint], x, y, z: int) =
    if pdqLt(a[y], a[x]):
      swap(a[x], a[y])
    if pdqLt(a[z], a[y]):
      swap(a[y], a[z])
      if pdqLt(a[y], a[x]):
        swap(a[x], a[y])

  proc pdqPartRight(
      a: var seq[ptr ArenaPoint], lo, hi: int
  ): tuple[pos: int, ap: bool] =
    let pivot = a[lo]
    var first = lo
    var last = hi + 1
    inc first
    while pdqLt(a[first], pivot):
      inc first
    if first - 1 == lo:
      while first < last:
        dec last
        if pdqLt(a[last], pivot):
          break
    else:
      while true:
        dec last
        if pdqLt(a[last], pivot):
          break
    let alreadyPartitioned = first >= last
    while first < last:
      swap(a[first], a[last])
      inc first
      while pdqLt(a[first], pivot):
        inc first
      dec last
      while not pdqLt(a[last], pivot):
        dec last
    let pivotPos = first - 1
    a[lo] = a[pivotPos]
    a[pivotPos] = pivot
    result = (pivotPos, alreadyPartitioned)

  proc pdqPartLeft(a: var seq[ptr ArenaPoint], lo, hi: int): int =
    let pivot = a[lo]
    var first = lo
    var last = hi + 1
    while true:
      dec last
      if pdqLt(pivot, a[last]):
        break
    if last == hi:
      while first < last:
        inc first
        if pdqLt(pivot, a[first]):
          break
    else:
      while true:
        inc first
        if pdqLt(pivot, a[first]):
          break
    while first < last:
      swap(a[first], a[last])
      while true:
        dec last
        if pdqLt(pivot, a[last]):
          break
      while true:
        inc first
        if pdqLt(pivot, a[first]):
          break
    result = last
    let pivotPos = last
    a[lo] = a[pivotPos]
    a[pivotPos] = pivot

  proc pdqSift(a: var seq[ptr ArenaPoint], lo, hi, start: int) =
    let n = hi - lo + 1
    var root = start - lo
    while true:
      var child = 2 * root + 1
      if child >= n:
        break
      if child + 1 < n and pdqLt(a[lo + child], a[lo + child + 1]):
        inc child
      if pdqLt(a[lo + root], a[lo + child]):
        swap(a[lo + root], a[lo + child])
        root = child
      else:
        break

  proc pdqHeap(a: var seq[ptr ArenaPoint], lo, hi: int) =
    let n = hi - lo + 1
    var start = lo + (n div 2) - 1
    while start >= lo:
      pdqSift(a, lo, hi, start)
      dec start
    var ed = hi
    while ed > lo:
      swap(a[lo], a[ed])
      pdqSift(a, lo, ed - 1, lo)
      dec ed

  proc pdqLoop(
      a: var seq[ptr ArenaPoint], lo0, hi0, bad0: int, leftmost0: bool
  ) =
    var lo = lo0
    var hi = hi0
    var badAllowed = bad0
    var leftmost = leftmost0
    while true:
      let size = hi - lo + 1
      if size < PdqInsertionThreshold:
        if leftmost:
          pdqIns(a, lo, hi)
        else:
          pdqUnIns(a, lo, hi)
        return
      let half = size div 2
      if size > PdqNintherThreshold:
        pdqS3(a, lo, lo + half, hi)
        pdqS3(a, lo + 1, lo + (half - 1), hi - 1)
        pdqS3(a, lo + 2, lo + (half + 1), hi - 2)
        pdqS3(a, lo + (half - 1), lo + half, lo + (half + 1))
        swap(a[lo], a[lo + half])
      else:
        pdqS3(a, lo + half, lo, hi)
      if not leftmost and not pdqLt(a[lo - 1], a[lo]):
        let p = pdqPartLeft(a, lo, hi)
        lo = p + 1
        continue
      let (pivotPos, _) = pdqPartRight(a, lo, hi)
      let lSize = pivotPos - lo
      let rSize = hi - pivotPos
      let unbalanced = lSize < size div 8 or rSize < size div 8
      if unbalanced:
        dec badAllowed
        if badAllowed <= 0:
          pdqHeap(a, lo, hi)
          return
        if lSize >= PdqInsertionThreshold:
          swap(a[lo], a[lo + lSize div 4])
          swap(a[pivotPos - 1], a[pivotPos - lSize div 4])
        if rSize >= PdqInsertionThreshold:
          swap(a[pivotPos + 1], a[pivotPos + 1 + rSize div 4])
          swap(a[hi], a[hi - rSize div 4])
      if lSize < rSize:
        pdqLoop(a, lo, pivotPos - 1, badAllowed, leftmost)
        lo = pivotPos + 1
        leftmost = false
      else:
        pdqLoop(a, pivotPos + 1, hi, badAllowed, false)
        hi = pivotPos - 1

  proc pdqsortActivePoints(ws: var ArenaWorkspace) {.used.} =
    let hi = ws.activePoints.high
    if hi <= 0:
      return
    let depth = pdqLog2(hi + 1)
    pdqLoop(ws.activePoints, 0, hi, depth, true)

proc sortActivePoints(ws: var ArenaWorkspace) =
  when defined(p2tQuickSort):
    ws.quicksortActivePoints()
  elif defined(p2tMergeSort):
    ws.mergeSortActivePoints()
  else:
    ws.pdqsortActivePoints()

proc initTriangulation(ws: var ArenaWorkspace) =
  phase(phSetup):
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
    when FrontHashOn:
      ws.initFrontHash(ws.tail.x, ws.head.x, ws.activePoints.len)
  phase(phSort):
    ws.sortActivePoints()

proc createAdvancingFront(ws: var ArenaWorkspace) =
  phase(phSetup):
    let t = ws.newTriangle(ws.activePoints[0], ws.tail, ws.head)

    ws.afHead = ws.newNode(t.points[1], t)
    ws.afMiddle = ws.newNode(t.points[0], t)
    ws.afTail = ws.newNode(t.points[2])
    ws.front = ArenaFront(head: ws.afHead, tail: ws.afTail, searchNode: ws.afHead)

    ws.afHead.next = ws.afMiddle
    ws.afMiddle.next = ws.afTail
    ws.afMiddle.prev = ws.afHead
    ws.afTail.prev = ws.afMiddle
  when FrontHashOn:
    ws.updateFrontBucket(ws.afHead)
    ws.updateFrontBucket(ws.afMiddle)
    ws.updateFrontBucket(ws.afTail)

proc mapTriangleToNodes(ws: var ArenaWorkspace, t: ptr ArenaTriangle) {.inline.} =
  ws.statInc(mapTriangleToNodesCalls)
  for i in 0 .. 2:
    if t.neighbors[i].isNil:
      let n = t.points[PrevEdgeIndex[i]].node
      if not n.isNil:
        ws.statInc(mapTriangleNodeUpdates)
        n.triangle = t

proc validRawTriangle(t: ptr ArenaTriangle): bool {.inline.} =
  not t.isNil and not t.points[0].isNil and not t.points[1].isNil and
    not t.points[2].isNil and t.points[0] != t.points[1] and t.points[0] != t.points[2] and
    t.points[1] != t.points[2]

proc meshClean(ws: var ArenaWorkspace, t: ptr ArenaTriangle) =
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
    if not item.isNil and not item.hasFlag(InteriorFlag):
      ws.statInc(meshCleanVisits)
      item.setFlag(InteriorFlag, true)
      if item.validRawTriangle:
        ws.interiorTriangles[ws.rawInteriorCount] = item
        inc ws.rawInteriorCount
      for i in 0 .. 2:
        if not item.hasFlag(constrainedFlag(i)):
          let neighbor = item.neighbors[i]
          if not neighbor.isNil:
             ws.meshStack[stackCount] = neighbor
             inc stackCount

proc incircle(pa, pb, pc, pd: ptr ArenaPoint): bool {.inline.} =
  statIncGlobal(incircleCalls)
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

when defined(p2tSlotCdt):
  proc setNeighborSlot(
      t: ptr ArenaTriangle, side: int, other: ptr ArenaTriangle, otherSide: int
  ) {.inline.} =
    t.neighbors[side] = other
    t.neighborSlots[side] =
      if other.isNil or otherSide < 0: NilNeighborSlot else: otherSide.uint8

  proc neighborSlot(t: ptr ArenaTriangle, side: int): int {.inline.} =
    let neighbor = t.neighbors[side]
    if neighbor.isNil:
      return -1
    let slot = t.neighborSlots[side].int
    if slot >= 0 and slot < 3 and neighbor.neighbors[slot] == t:
      return slot
    statIncGlobal(slotFallbacks)
    result = neighbor.neighborIndexPlain(t)
    if result >= 0:
      t.neighborSlots[side] = result.uint8

  proc rotateTrianglePairIndexed(
      ws: var ArenaWorkspace,
      t: ptr ArenaTriangle,
      p: ptr ArenaPoint,
      pIdx: int,
      ot: ptr ArenaTriangle,
      op: ptr ArenaPoint,
      opIdx: int,
  ) {.inline.} =
    ws.statInc(rotations)
    ws.statInc(slotRotations)
    let
      rotateAmount = NextEdgeIndex[pIdx]
      otherRotateAmount = NextEdgeIndex[opIdx]
      tPrev = PrevEdgeIndex[pIdx]
      tNext = NextEdgeIndex[pIdx]
      otPrev = PrevEdgeIndex[opIdx]
      otNext = NextEdgeIndex[opIdx]
      n1 = t.neighbors[tPrev]
      n2 = t.neighbors[tNext]
      n3 = ot.neighbors[otPrev]
      n4 = ot.neighbors[otNext]
      ce1 = t.hasFlag(constrainedFlag(tPrev))
      ce2 = t.hasFlag(constrainedFlag(tNext))
      ce3 = ot.hasFlag(constrainedFlag(otPrev))
      ce4 = ot.hasFlag(constrainedFlag(otNext))
      de1 = t.hasFlag(delaunayFlag(tPrev))
      de2 = t.hasFlag(delaunayFlag(tNext))
      de3 = ot.hasFlag(delaunayFlag(otPrev))
      de4 = ot.hasFlag(delaunayFlag(otNext))
      n1Side = t.neighborSlot(tPrev)
      n2Side = t.neighborSlot(tNext)
      n3Side = ot.neighborSlot(otPrev)
      n4Side = ot.neighborSlot(otNext)

    t.setNeighborSlot(rotateAmount, n3, n3Side)
    t.setNeighborSlot(NextEdgeIndex[rotateAmount], n2, n2Side)
    t.setNeighborSlot(PrevEdgeIndex[rotateAmount], ot, PrevEdgeIndex[otherRotateAmount])
    ot.setNeighborSlot(otherRotateAmount, n1, n1Side)
    ot.setNeighborSlot(NextEdgeIndex[otherRotateAmount], n4, n4Side)
    ot.setNeighborSlot(PrevEdgeIndex[otherRotateAmount], t, PrevEdgeIndex[rotateAmount])

    if not n1.isNil and n1Side >= 0:
      n1.setNeighborSlot(n1Side, ot, otherRotateAmount)
    if not n2.isNil and n2Side >= 0:
      n2.neighborSlots[n2Side] = NextEdgeIndex[rotateAmount].uint8
    if not n3.isNil and n3Side >= 0:
      n3.setNeighborSlot(n3Side, t, rotateAmount)
    if not n4.isNil and n4Side >= 0:
      n4.neighborSlots[n4Side] = NextEdgeIndex[otherRotateAmount].uint8

    t.legalize(p, op)
    ot.legalize(op, p)

    applyRotatedFlags(t, rotateAmount, NextEdgeIndex[rotateAmount], de3, ce3, de2, ce2)
    applyRotatedFlags(
      ot, otherRotateAmount, NextEdgeIndex[otherRotateAmount], de1, ce1, de4, ce4
    )

when not defined(p2tSlotCdt):
  proc rotateTrianglePairIndexed(
      ws: var ArenaWorkspace,
      t: ptr ArenaTriangle,
      p: ptr ArenaPoint,
      pIdx: int,
      ot: ptr ArenaTriangle,
      op: ptr ArenaPoint,
      opIdx: int,
  ) {.inline.} =
    ws.statInc(rotations)
    let
      rotateAmount = NextEdgeIndex[pIdx]
      otherRotateAmount = NextEdgeIndex[opIdx]
      tPrev = PrevEdgeIndex[pIdx]
      tNext = NextEdgeIndex[pIdx]
      otPrev = PrevEdgeIndex[opIdx]
      otNext = NextEdgeIndex[opIdx]
      n1 = t.neighbors[tPrev]
      n2 = t.neighbors[tNext]
      n3 = ot.neighbors[otPrev]
      n4 = ot.neighbors[otNext]
      ce1 = t.hasFlag(constrainedFlag(tPrev))
      ce2 = t.hasFlag(constrainedFlag(tNext))
      ce3 = ot.hasFlag(constrainedFlag(otPrev))
      ce4 = ot.hasFlag(constrainedFlag(otNext))
      de1 = t.hasFlag(delaunayFlag(tPrev))
      de2 = t.hasFlag(delaunayFlag(tNext))
      de3 = ot.hasFlag(delaunayFlag(otPrev))
      de4 = ot.hasFlag(delaunayFlag(otNext))

    t.neighbors[rotateAmount] = n3
    t.neighbors[NextEdgeIndex[rotateAmount]] = n2
    t.neighbors[PrevEdgeIndex[rotateAmount]] = ot
    ot.neighbors[otherRotateAmount] = n1
    ot.neighbors[NextEdgeIndex[otherRotateAmount]] = n4
    ot.neighbors[PrevEdgeIndex[otherRotateAmount]] = t

    if not n1.isNil:
      n1.swapNeighbor(t, ot)
    if not n3.isNil:
      n3.swapNeighbor(ot, t)

    t.legalize(p, op)
    ot.legalize(op, p)

    applyRotatedFlags(t, rotateAmount, NextEdgeIndex[rotateAmount], de3, ce3, de2, ce2)
    applyRotatedFlags(
      ot, otherRotateAmount, NextEdgeIndex[otherRotateAmount], de1, ce1, de4, ce4
    )

proc legalize(ws: var ArenaWorkspace, t: ptr ArenaTriangle): bool =
  phase(phLegalize):
    ws.statInc(legalizeCalls)
    for i in 0 .. 2:
      ws.statInc(legalizeEdges)
      if t.hasFlag(delaunayFlag(i)):
        when defined(p2tIncircleProf):
          ws.statInc(legalizeSkipDelaunay)
        continue

      let ot = t.neighbors[i]
      if not ot.isNil:
        let
          pcw = t.points[PrevEdgeIndex[i]]
          opposite = ot.pointCW(pcw)
          op = opposite.point
          oi = opposite.index

        let
          oppositeConstrained = ot.hasFlag(constrainedFlag(oi))
          oppositeDelaunay = ot.hasFlag(delaunayFlag(oi))
        if oppositeConstrained or oppositeDelaunay:
          when defined(p2tIncircleProf):
            if oppositeConstrained:
              ws.statInc(legalizeSkipConstrained)
            if oppositeDelaunay:
              ws.statInc(legalizeSkipOppositeDelaunay)
          t.setFlag(constrainedFlag(i), oppositeConstrained)
          continue

        let
          p = t.points[i]
          pccw = t.points[NextEdgeIndex[i]]
        if incircle(p, pccw, pcw, op):
          ws.statInc(incircleSuccesses)
          t.setFlag(delaunayFlag(i), true)
          ot.setFlag(delaunayFlag(oi), true)

          ws.rotateTrianglePairIndexed(t, p, i, ot, op, oi)

          var notLegalized = not ws.legalize(t)
          if notLegalized:
            ws.mapTriangleToNodes(t)

          notLegalized = not ws.legalize(ot)
          if notLegalized:
            ws.mapTriangleToNodes(ot)

          t.setFlag(delaunayFlag(i), false)
          ot.setFlag(delaunayFlag(oi), false)
          result = true
          return
      else:
        when defined(p2tIncircleProf):
          ws.statInc(legalizeNilNeighbors)
    result = false

proc fill(ws: var ArenaWorkspace, n: ptr ArenaNode) {.inline.} =
  ws.statInc(fills)
  let t = ws.newTriangle(n.prev.point, n.point, n.next.point)
  t.neighbors[2] = n.prev.triangle
  when defined(p2tSlotCdt):
    if not n.prev.triangle.isNil:
      t.neighborSlots[2] = n.prev.triangle.edgeIndexPlain(n.prev.point, n.point).uint8
  if not n.prev.triangle.isNil:
    n.prev.triangle.markNeighbor(n.prev.point, n.point, t)
  t.neighbors[0] = n.triangle
  when defined(p2tSlotCdt):
    if not n.triangle.isNil:
      t.neighborSlots[0] = n.triangle.edgeIndexPlain(n.point, n.next.point).uint8
  if not n.triangle.isNil:
    n.triangle.markNeighbor(n.point, n.next.point, t)

  let prev = n.prev
  let next = n.next
  if ws.front.searchNode == n:
    ws.front.searchNode = prev
  n.point.node = nil
  prev.next = next
  next.prev = prev

  if not ws.legalize(t):
    ws.mapTriangleToNodes(t)

proc angleParts(
    origin, pa, pb: ptr ArenaPoint
): tuple[cross, dot: ArenaReal] {.inline.} =
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

proc shouldFillBasin(n: ptr ArenaNode): bool {.inline.} =
  let
    ax = n.point.x - n.next.next.point.x
    ay = n.point.y - n.next.next.point.y
  ax >= 0 or ay < -ax

proc isShallow(ws: var ArenaWorkspace, n: ptr ArenaNode): bool {.inline.} =
  let height =
    if ws.basin.leftHighest:
      ws.basin.leftNode.point.y - n.point.y
    else:
      ws.basin.rightNode.point.y - n.point.y
  ws.basin.width > height

proc fillBasinReq(ws: var ArenaWorkspace, n: ptr ArenaNode)

proc fillBasin(ws: var ArenaWorkspace, n: ptr ArenaNode) =
  ws.statInc(fillBasins)
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
  var n = n
  while true:
    if ws.isShallow(n):
      return

    ws.fill(n)
    if n.prev == ws.basin.leftNode and n.next == ws.basin.rightNode:
      return
    elif n.prev == ws.basin.leftNode:
      if orient2d(n.point, n.next.point, n.next.next.point) == cw:
        return
      n = n.next
    elif n.next == ws.basin.rightNode:
      if orient2d(n.point, n.prev.point, n.prev.prev.point) == ccw:
        return
      n = n.prev
    elif n.prev.point.y < n.next.point.y:
      n = n.prev
    else:
      n = n.next

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

  if not n.next.isNil and not n.next.next.isNil and n.shouldFillBasin:
    ws.fillBasin(n)

proc isEdgeSideOfTriangle(
    t: ptr ArenaTriangle, ep, eq: ptr ArenaPoint
): bool {.inline.} =
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
): ptr ArenaNode {.inline.} =
  let t = ws.newTriangle(p, n.point, n.next.point)
  t.neighbors[0] = n.triangle
  when defined(p2tSlotCdt):
    if not n.triangle.isNil:
      t.neighborSlots[0] = n.triangle.edgeIndexPlain(n.point, n.next.point).uint8
  if not n.triangle.isNil:
    n.triangle.markNeighbor(n.point, n.next.point, t)

  result = ws.newNode(p)
  result.next = n.next
  result.prev = n
  n.next.prev = result
  n.next = result
  when FrontHashOn:
    ws.updateFrontBucket(result)

  if not ws.legalize(t):
    ws.mapTriangleToNodes(t)
  result.triangle = t

proc pointEvent(ws: var ArenaWorkspace, p: ptr ArenaPoint): ptr ArenaNode {.inline.} =
  ws.statInc(pointEvents)
  var n: ptr ArenaNode
  phase(phLocate):
    n = ws.locateNode(p.x)
  if n.isNil:
    raise newException(ValueError, "failed to locate advancing-front node")
  phase(phPointEvent):
    result = ws.newFrontTriangle(p, n)
  phase(phFill):
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
  pIdx: int,
)

proc flipEdgeEvent(
  ws: var ArenaWorkspace,
  ep, eq: ptr ArenaPoint,
  t: ptr ArenaTriangle,
  p: ptr ArenaPoint,
  pIdx: int,
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
    pIdx, opIdx: int,
): tuple[tri: ptr ArenaTriangle, pIndex: int] =
  # The flipped edge index equals the (pre-rotation) index already in hand:
  # the rotate is a pure permutation, so ot.edgeIndex(p, op) == opIdx and
  # t.edgeIndex(p, op) == pIdx. Reuse them to skip the 3-way point search
  # (matches fast-poly2tri's MPE_NextFlipTriangle).
  if o == ccw:
    when defined(p2tVerifyFlipIdx):
      doAssert opIdx == ot.edgeIndex(p, op)
    ot.setFlag(delaunayFlag(opIdx), true)
    discard ws.legalize(ot)
    ot.clearDelaunayEdges()
    return (t, t.index(p))

  when defined(p2tVerifyFlipIdx):
    doAssert pIdx == t.edgeIndex(p, op)
  t.setFlag(delaunayFlag(pIdx), true)
  discard ws.legalize(t)
  t.clearDelaunayEdges()
  (ot, ot.index(p))

proc nextFlipPoint(
    ep, eq: ptr ArenaPoint, ot: ptr ArenaTriangle, op: ptr ArenaPoint, opIdx: int
): tuple[point: ptr ArenaPoint, index: int] =
  case orient2d(eq, op, ep)
  of cw:
    let idx = NextEdgeIndex[opIdx]
    (ot.points[idx], idx)
  of ccw:
    let idx = PrevEdgeIndex[opIdx]
    (ot.points[idx], idx)
  of collinear:
    raise newException(ValueError, "opposing point on constrained edge")

proc flipScanEdgeEvent(
    ws: var ArenaWorkspace,
    ep, eq: ptr ArenaPoint,
    flipTriangle, t: ptr ArenaTriangle,
    p: ptr ArenaPoint,
    pIdx: int,
) =
  ws.statInc(flipScans)
  let ot = t.neighbors[pIdx]
  if ot.isNil:
    raise newException(ValueError, "flip scan failed due to missing triangle")
  let
    pccw = t.points[NextEdgeIndex[pIdx]]
    pcw = t.points[PrevEdgeIndex[pIdx]]
    opposite = ot.oppositePointAcross(pccw, pcw)
    op = opposite.point
    opIdx = opposite.index

  let eqIdx = flipTriangle.index(eq)
  if inScanArea(
    eq,
    flipTriangle.points[NextEdgeIndex[eqIdx]],
    flipTriangle.points[PrevEdgeIndex[eqIdx]],
    op,
  ):
    ws.flipEdgeEvent(eq, op, ot, op, opIdx)
  else:
    let newP = nextFlipPoint(ep, eq, ot, op, opIdx)
    ws.flipScanEdgeEvent(ep, eq, flipTriangle, ot, newP.point, newP.index)

proc flipEdgeEvent(
    ws: var ArenaWorkspace,
    ep, eq: ptr ArenaPoint,
    t: ptr ArenaTriangle,
    p: ptr ArenaPoint,
    pIdx: int,
) =
  ws.statInc(flipEvents)
  let ot = t.neighbors[pIdx]
  if ot.isNil:
    raise newException(ValueError, "flip failed due to missing triangle")
  let
    pccw = t.points[NextEdgeIndex[pIdx]]
    pcw = t.points[PrevEdgeIndex[pIdx]]
    opposite = ot.oppositePointAcross(pccw, pcw)
    op = opposite.point
    opIdx = opposite.index

  if inScanArea(p, pccw, pcw, op):
    ws.rotateTrianglePairIndexed(t, p, pIdx, ot, op, opIdx)
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
      let nextT = ws.nextFlipTriangle(o, t, ot, p, op, pIdx, opIdx)
      ws.flipEdgeEvent(ep, eq, nextT.tri, p, nextT.pIndex)
  else:
    let newP = nextFlipPoint(ep, eq, ot, op, opIdx)
    ws.flipScanEdgeEvent(ep, eq, t, ot, newP.point, newP.index)
    ws.edgeEvent(ep, eq, t, p, pIdx)

proc edgeEvent(
    ws: var ArenaWorkspace,
    ep, eq: ptr ArenaPoint,
    t: ptr ArenaTriangle,
    p: ptr ArenaPoint,
    pIdx: int,
) =
  ws.statInc(edgeEvents)
  var t = t
  var pIdx = pIdx
  while true:
    ws.statInc(edgeWalkSteps)
    if t.isEdgeSideOfTriangle(ep, eq):
      return

    let p1 = t.points[NextEdgeIndex[pIdx]]
    let o1 = orient2d(eq, p1, ep)
    if o1 == collinear:
      if t.contains(eq, p1):
        t.markConstrainedEdge(eq, p1)
        ws.edgeEvent.constrainedEdge.q = p1
        let nt = t.neighbors[pIdx]
        ws.edgeEvent(ep, p1, nt, p1, nt.index(p1))
      else:
        raise newException(
          ValueError, "collinear constrained edge points are not supported"
        )
      return

    let p2 = t.points[PrevEdgeIndex[pIdx]]
    let o2 = orient2d(eq, p2, ep)
    if o2 == collinear:
      if t.contains(eq, p2):
        t.markConstrainedEdge(eq, p2)
        ws.edgeEvent.constrainedEdge.q = p2
        let nt = t.neighbors[pIdx]
        ws.edgeEvent(ep, p2, nt, p2, nt.index(p2))
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
        t.neighbors[PrevEdgeIndex[pIdx]]
      else:
        t.neighbors[NextEdgeIndex[pIdx]]
    if t.isNil:
      raise newException(ValueError, "missing neighbor while walking constrained edge")
    pIdx = t.index(p)

proc edgeEvent(ws: var ArenaWorkspace, edge: ptr ArenaEdge, n: ptr ArenaNode) =
  ws.edgeEvent.constrainedEdge = edge
  ws.edgeEvent.right = edge.p.x > edge.q.x
  if n.triangle.isEdgeSideOfTriangle(edge.p, edge.q):
    return
  ws.fillEdgeEvent(edge, n)
  ws.edgeEvent(edge.p, edge.q, n.triangle, edge.q, n.triangle.index(edge.q))

proc sweepPoints(ws: var ArenaWorkspace) =
  for i in 1 ..< ws.activePoints.len:
    let p = ws.activePoints[i]
    let n = ws.pointEvent(p)
    var edge = p.firstEdge
    while not edge.isNil:
      phase(phEdgeEvent):
        ws.edgeEvent(edge, n)
      edge = edge.next

proc finalizationPolygon(ws: var ArenaWorkspace) =
  phase(phFinalize):
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

proc rawTriangle(raw: TessRawResult, triangleIndex: int): ptr ArenaTriangle {.inline.} =
  raw.arena[].interiorTriangles[triangleIndex]

proc rawTrianglePoints*(
    raw: TessRawResult, triangleIndex: int
): array[3, CdtPointId] {.inline.} =
  let tri = raw.rawTriangle(triangleIndex)
  [
    tri.points[0].id.CdtPointId,
    tri.points[1].id.CdtPointId,
    tri.points[2].id.CdtPointId,
  ]

proc rawTriangleVertices*(
    raw: TessRawResult, triangleIndex: int
): array[3, Vec2] {.inline.} =
  let tri = raw.rawTriangle(triangleIndex)
  [
    Vec2(x: tri.points[0].x.float64, y: tri.points[0].y.float64),
    Vec2(x: tri.points[1].x.float64, y: tri.points[1].y.float64),
    Vec2(x: tri.points[2].x.float64, y: tri.points[2].y.float64),
  ]

proc rawTriangleCount*(raw: TessRawResult): int {.inline.} =
  if raw.ok and not raw.arena.isNil:
    result = raw.arena[].rawInteriorCount

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

  phase(phSetup):
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
  result.triangles.reserveSeq(workspace.arena.rawInteriorCount)
  for i in 0 ..< workspace.arena.rawInteriorCount:
    let t = workspace.arena.interiorTriangles[i]
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

  phase(phSetup):
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
