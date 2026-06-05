## Correctness-first 2D DeWall Delaunay triangulation prototype.
##
## This is intentionally not wired into the public CDT tessellation path. It
## builds an unconstrained DT over a point set and exists to explore whether
## DeWall's merge-free recursion can become an effective threaded backend.
##
## The recursive traversal is deliberately a static generic. Use
## `dewallTriangulateStatic[false]` for serial codegen and
## `dewallTriangulateStatic[true]` for the threaded specialization.

import std/[algorithm, hashes, math, monotimes, sets, tables, times]

when compileOption("threads"):
  import std/threadpool

import ../types
import ../geometry

const Eps = 1e-12

template trace(msg: string) =
  when defined(p2tDewallTrace):
    echo msg

template hotInc(ctx: untyped, field: untyped, amount: int = 1) =
  when defined(p2tDewallHotStats):
    if not ctx.stats.isNil:
      ctx.stats[].field += amount

type
  DewallOptions* = object
    parallel*: bool
    maxParallelDepth*: int
    minParallelPoints*: int
    gridMinPoints*: int
    gridCellFactor*: float64
    prewallLeafTarget*: int
    prewallMinSplitPoints*: int
    prewallMinLeafPoints*: int

  DewallPrewallEstimate* = object
    pointCount*: int
    workers*: int
    leaves*: int
    walls*: int
    effectiveWorkers*: int
    serialUs*: float64
    wallUs*: float64
    parallelUs*: float64
    overheadUs*: float64
    totalUs*: float64
    speedup*: float64

  DewallProfile* = object
    pointCount*: int
    rawTriangleCount*: int
    dedupedTriangleCount*: int
    duplicatesRemoved*: int
    requestedLeaves*: int
    actualLeaves*: int
    spawnedTasks*: int
    prewallWallCount*: int
    wallTriangleCount*: int
    leafMinPoints*: int
    leafMeanPoints*: float64
    leafMaxPoints*: int
    resolvedPrewallMinSplitPoints*: int
    resolvedPrewallMinLeafPoints*: int
    wallUs*: float64
    wallUsPerSqrtPoint*: float64

when defined(p2tDewallHotStats):
  type
    DewallHotStats* = object
      makeSimplexFastCalls*: int
      makeSimplexBruteCalls*: int
      candidateTests*: int
      acceptedCandidates*: int
      gridBoxScans*: int
      gridCellsVisited*: int
      duplicateCellSkips*: int
      scanUnmarkedCalls*: int
      unmarkedCellsVisited*: int
      wallEdgesProcessed*: int
      wallTrianglesEmitted*: int
      gridsBuilt*: int
      gridCellsAllocated*: int
      splitSorts*: int

    DewallHotStatsResult* = object
      triangles*: seq[array[3, int]]
      stats*: DewallHotStats

    DewallHotProfileResult* = object
      profile*: DewallProfile
      stats*: DewallHotStats
      triangles*: seq[array[3, int]]

type
  EdgeKey = object
    a, b: int

  ActiveEdge = object
    a, b: int

  TriKey = object
    a, b, c: int

  Split = object
    cut: float64
    left, right: seq[int]
    hasSideTies: bool
    side: seq[uint8]

  WallBuild = object
    split: Split
    triangles: seq[array[3, int]]
    afl1, afl2: Table[EdgeKey, ActiveEdge]

  PrewallNode = object
    idx: seq[int]
    inherited: seq[ActiveEdge]
    isRoot: bool
    axis: int
    depth: int

  DewallContext = object
    points: seq[Vec2]
    options: DewallOptions
    when defined(p2tDewallHotStats):
      stats: ptr DewallHotStats

  DewallPreparedWorkspace* = object
    points: seq[Vec2]
    idx: seq[int]

  UniformGrid = object
    enabled: bool
    minX, minY: float64
    side: float64
    nx, ny: int
    cellStarts: seq[int]
    cellPoints: seq[int]
    marks: seq[int]
    epoch: int

  CandidateSearch = object
    best: int
    bestDd: float64
    found: bool

proc defaultDewallOptions*(): DewallOptions =
  DewallOptions(
    parallel: false,
    maxParallelDepth: 4,
    minParallelPoints: 512,
    gridMinPoints: 32,
    gridCellFactor: 1.0,
    prewallLeafTarget: 0,
    prewallMinSplitPoints: 0,
    prewallMinLeafPoints: 0,
  )

proc ceilDiv(a, b: int): int =
  if a <= 0:
    0
  else:
    (a + max(1, b) - 1) div max(1, b)

proc resolvedDewallPrewallMinLeafPoints*(options: DewallOptions): int =
  if options.prewallMinLeafPoints > 0:
    options.prewallMinLeafPoints
  else:
    256

proc autoDewallPrewallLeafTarget*(
    pointCount, workers: int, minLeafPoints = 256, oversubscribe = 2
): int =
  let
    n = max(0, pointCount)
    p = max(1, workers)
    leafFloor = max(1, minLeafPoints)
  if n < 2 * leafFloor:
    return 1
  min(max(2, p * max(1, oversubscribe)), max(1, ceilDiv(n, leafFloor)))

proc autoDewallPrewallMinSplitPoints*(
    pointCount, workers: int, minLeafPoints = 256, oversubscribe = 2
): int =
  let
    leafFloor = max(1, minLeafPoints)
    target = autoDewallPrewallLeafTarget(
      pointCount, workers, leafFloor, oversubscribe
    )
  if target <= 1:
    2 * leafFloor
  else:
    max(2 * leafFloor, max(1, pointCount) div max(1, target))

proc configureAutoDewallPrewall*(
    options: var DewallOptions,
    pointCount, workers: int,
    minLeafPoints = 256,
    oversubscribe = 2,
) =
  let
    leafFloor = max(1, minLeafPoints)
    target = autoDewallPrewallLeafTarget(
      pointCount, workers, leafFloor, oversubscribe
    )
  options.prewallMinLeafPoints = leafFloor
  options.prewallMinSplitPoints = autoDewallPrewallMinSplitPoints(
    pointCount, workers, leafFloor, oversubscribe
  )
  options.prewallLeafTarget = if target > 1: target else: 0

proc resolvedDewallPrewallMinSplitPoints*(
    options: DewallOptions, pointCount, leafTarget: int
): int =
  if options.prewallMinSplitPoints > 0:
    options.prewallMinSplitPoints
  else:
    let leafFloor = resolvedDewallPrewallMinLeafPoints(options)
    if leafTarget <= 1:
      2 * leafFloor
    else:
      max(2 * leafFloor, max(1, pointCount) div max(1, leafTarget))

proc estimateDewallPrewall*(
    pointCount, workers, leaves: int,
    serialUsPerPoint, wallUsPerSqrtPoint: float64,
    imbalance = 1.5,
    leafOverheadUs = 0.0,
): DewallPrewallEstimate =
  ## Estimate binary-prewall runtime with the corrected wall-spine model:
  ## S(L) = w * sqrt(n) * (sqrt(L) - 1) / (sqrt(2) - 1).
  let
    n = max(0, pointCount)
    l = max(1, leaves)
    p = max(1, workers)
    q = min(p, l)
    serial = max(0.0, serialUsPerPoint) * n.float64
    wallCoeff = max(0.0, wallUsPerSqrtPoint)
    wall = if l <= 1 or n == 0:
      0.0
    else:
      wallCoeff * sqrt(n.float64) * (sqrt(l.float64) - 1.0) / (sqrt(2.0) - 1.0)
    remaining = max(0.0, serial - wall)
    parallel = max(1.0, imbalance) * remaining / q.float64
    overhead = max(0.0, leafOverheadUs) * l.float64
    total = wall + parallel + overhead

  DewallPrewallEstimate(
    pointCount: n,
    workers: p,
    leaves: l,
    walls: max(0, l - 1),
    effectiveWorkers: q,
    serialUs: serial,
    wallUs: wall,
    parallelUs: parallel,
    overheadUs: overhead,
    totalUs: total,
    speedup: if total > 0.0: serial / total else: 0.0,
  )

proc chooseDewallPrewallLeafTarget*(
    pointCount, workers: int,
    serialUsPerPoint, wallUsPerSqrtPoint: float64,
    imbalance = 1.5,
    leafOverheadUs = 0.0,
    minLeafPoints = 256,
    maxLeaves = 0,
): DewallPrewallEstimate =
  ## Pick the best modeled prewall leaf count. `minLeafPoints` is a hard
  ## floor for useful leaf work; pass `maxLeaves` to cap overpartitioning.
  let n = max(0, pointCount)
  if n == 0:
    return estimateDewallPrewall(
      0, workers, 1, serialUsPerPoint, wallUsPerSqrtPoint, imbalance, leafOverheadUs
    )

  let leafFloor = max(1, minLeafPoints)
  var feasible = max(1, n div leafFloor)
  if maxLeaves > 0:
    feasible = min(feasible, maxLeaves)

  result = estimateDewallPrewall(
    n, workers, 1, serialUsPerPoint, wallUsPerSqrtPoint, imbalance, leafOverheadUs
  )
  if feasible >= 2:
    for leaves in 2 .. feasible:
      let candidate = estimateDewallPrewall(
        n, workers, leaves, serialUsPerPoint, wallUsPerSqrtPoint, imbalance, leafOverheadUs
      )
      if candidate.speedup > result.speedup:
        result = candidate

proc edgeKey(a, b: int): EdgeKey =
  if a < b:
    EdgeKey(a: a, b: b)
  else:
    EdgeKey(a: b, b: a)

proc key(e: ActiveEdge): EdgeKey =
  edgeKey(e.a, e.b)

template coord(points: seq[Vec2], i: int, Axis: static[int]): float64 =
  when Axis == 0:
    points[i].x
  else:
    points[i].y

proc hash(e: EdgeKey): Hash =
  var h: Hash = 0
  h = h !& hash(e.a)
  h = h !& hash(e.b)
  !$h

proc hash(t: TriKey): Hash =
  var h: Hash = 0
  h = h !& hash(t.a)
  h = h !& hash(t.b)
  h = h !& hash(t.c)
  !$h

proc triKey(a, b, c: int): TriKey =
  var values = [a, b, c]
  values.sort()
  TriKey(a: values[0], b: values[1], c: values[2])

proc circumRadius2(points: openArray[Vec2], a, b, c: int): float64 =
  let
    pa = points[a]
    pb = points[b]
    pc = points[c]
    ab = dist2(pa, pb)
    bc = dist2(pb, pc)
    ca = dist2(pc, pa)
    area2 = abs(orient(pa, pb, pc))
  if area2 <= Eps:
    Inf
  else:
    (ab * bc * ca) / (4.0 * area2 * area2)

proc circumCenter(points: openArray[Vec2], a, b, c: int): Vec2 =
  let
    pa = points[a]
    pb = points[b]
    pc = points[c]
    d = 2.0 * (
      pa.x * (pb.y - pc.y) + pb.x * (pc.y - pa.y) + pc.x * (pa.y - pb.y)
    )
  if abs(d) <= Eps:
    return vec2(Inf, Inf)
  let
    ax2ay2 = pa.x * pa.x + pa.y * pa.y
    bx2by2 = pb.x * pb.x + pb.y * pb.y
    cx2cy2 = pc.x * pc.x + pc.y * pc.y
    ux = (
      ax2ay2 * (pb.y - pc.y) + bx2by2 * (pc.y - pa.y) +
      cx2cy2 * (pa.y - pb.y)
    ) / d
    uy = (
      ax2ay2 * (pc.x - pb.x) + bx2by2 * (pa.x - pc.x) +
      cx2cy2 * (pb.x - pa.x)
    ) / d
  vec2(ux, uy)

proc initSearch(): CandidateSearch =
  CandidateSearch(best: -1, bestDd: Inf, found: false)

proc considerCandidate(
    ctx: DewallContext, h: ActiveEdge, candidate: int, search: var CandidateSearch
) =
  hotInc(ctx, candidateTests)
  if candidate == h.a or candidate == h.b:
    return

  let
    pa = ctx.points[h.a]
    pb = ctx.points[h.b]
    pc = ctx.points[candidate]
  if orient(pa, pb, pc) <= Eps:
    return

  let radius2 = circumRadius2(ctx.points, h.a, h.b, candidate)
  if radius2 == Inf:
    return
  let
    center = circumCenter(ctx.points, h.a, h.b, candidate)
    centerOnOpenSide = orient(pa, pb, center) > 0
    dd = if centerOnOpenSide: radius2 else: -radius2
  if dd < search.bestDd:
    search.bestDd = dd
    search.best = candidate
    search.found = true
    hotInc(ctx, acceptedCandidates)

proc makeSimplexBrute(ctx: DewallContext, idx: openArray[int], h: ActiveEdge): int =
  ## Return the apex on the left/open side of directed edge h, or -1 for a
  ## hull edge. This follows the paper's Delaunay-distance scan, without the
  ## uniform-grid acceleration.
  hotInc(ctx, makeSimplexBruteCalls)
  var search = initSearch()
  for candidate in idx:
    considerCandidate(ctx, h, candidate, search)
  search.best

proc clampCell(value, limit: int): int =
  if value < 0:
    0
  elif value >= limit:
    limit - 1
  else:
    value

proc cellX(g: UniformGrid, x: float64): int =
  clampCell(int(floor((x - g.minX) / g.side)), g.nx)

proc cellY(g: UniformGrid, y: float64): int =
  clampCell(int(floor((y - g.minY) / g.side)), g.ny)

proc cellIndex(g: UniformGrid, x, y: int): int =
  y * g.nx + x

proc buildGrid(ctx: DewallContext, idx: openArray[int]): UniformGrid =
  if idx.len < ctx.options.gridMinPoints:
    return

  var
    minX = Inf
    maxX = -Inf
    minY = Inf
    maxY = -Inf
  for i in idx:
    minX = min(minX, ctx.points[i].x)
    maxX = max(maxX, ctx.points[i].x)
    minY = min(minY, ctx.points[i].y)
    maxY = max(maxY, ctx.points[i].y)

  let
    dx = maxX - minX
    dy = maxY - minY
  if dx <= Eps or dy <= Eps or ctx.options.gridCellFactor <= 0.0:
    return

  let
    targetCells = max(1.0, idx.len.float64 * ctx.options.gridCellFactor)
    side = sqrt((dx * dy) / targetCells)
  if side <= Eps or side == Inf:
    return

  result.enabled = true
  result.minX = minX
  result.minY = minY
  result.side = side
  result.nx = max(1, int(ceil(dx / side)))
  result.ny = max(1, int(ceil(dy / side)))
  let cellCount = result.nx * result.ny
  result.cellStarts = newSeq[int](cellCount + 1)
  result.cellPoints = newSeq[int](idx.len)
  result.marks = newSeq[int](cellCount)
  result.epoch = 1
  hotInc(ctx, gridsBuilt)
  hotInc(ctx, gridCellsAllocated, cellCount)

  for i in idx:
    let c = cellIndex(result, result.cellX(ctx.points[i].x), result.cellY(ctx.points[i].y))
    inc result.cellStarts[c + 1]

  for c in 1 ..< result.cellStarts.len:
    result.cellStarts[c] += result.cellStarts[c - 1]

  var writeAt = result.cellStarts
  for i in idx:
    let c = cellIndex(result, result.cellX(ctx.points[i].x), result.cellY(ctx.points[i].y))
    result.cellPoints[writeAt[c]] = i
    inc writeAt[c]

proc reset(g: var UniformGrid) =
  inc g.epoch
  if g.epoch == int.high:
    for i in 0 ..< g.marks.len:
      g.marks[i] = 0
    g.epoch = 1

proc markCell(g: var UniformGrid, index: int): bool =
  if g.marks[index] == g.epoch:
    return false
  g.marks[index] = g.epoch
  true

proc scanBox(
    ctx: DewallContext,
    h: ActiveEdge,
    g: var UniformGrid,
    minX, minY, maxX, maxY: float64,
    search: var CandidateSearch,
): bool =
  if not g.enabled:
    return false
  hotInc(ctx, gridBoxScans)
  let
    x0 = g.cellX(minX)
    y0 = g.cellY(minY)
    x1 = g.cellX(maxX)
    y1 = g.cellY(maxY)
  for y in y0 .. y1:
    for x in x0 .. x1:
      let c = cellIndex(g, x, y)
      if not g.markCell(c):
        hotInc(ctx, duplicateCellSkips)
        continue
      hotInc(ctx, gridCellsVisited)
      for i in g.cellStarts[c] ..< g.cellStarts[c + 1]:
        let candidate = g.cellPoints[i]
        let wasFound = search.found
        considerCandidate(ctx, h, candidate, search)
        result = result or (search.found and not wasFound) or search.found

proc scanUnmarked(
    ctx: DewallContext, h: ActiveEdge, g: var UniformGrid, search: var CandidateSearch
) =
  hotInc(ctx, scanUnmarkedCalls)
  for c in 0 ..< g.marks.len:
    if not g.markCell(c):
      continue
    hotInc(ctx, unmarkedCellsVisited)
    for i in g.cellStarts[c] ..< g.cellStarts[c + 1]:
      let candidate = g.cellPoints[i]
      considerCandidate(ctx, h, candidate, search)

proc scanRadiusBox(
    ctx: DewallContext,
    h: ActiveEdge,
    g: var UniformGrid,
    radius: float64,
    search: var CandidateSearch,
): float64 =
  let
    pa = ctx.points[h.a]
    pb = ctx.points[h.b]
    dx = pb.x - pa.x
    dy = pb.y - pa.y
    len2 = dx * dx + dy * dy
  if len2 <= Eps:
    return Inf

  let
    len = sqrt(len2)
    faceRadius = 0.5 * len
    boxRadius = max(radius, faceRadius)
    offset = sqrt(max(0.0, boxRadius * boxRadius - faceRadius * faceRadius))
    mid = vec2((pa.x + pb.x) * 0.5, (pa.y + pb.y) * 0.5)
    normal = vec2(-dy / len, dx / len)
    center = vec2(mid.x + normal.x * offset, mid.y + normal.y * offset)

  discard scanBox(
    ctx,
    h,
    g,
    center.x - boxRadius,
    center.y - boxRadius,
    center.x + boxRadius,
    center.y + boxRadius,
    search,
  )
  boxRadius * boxRadius

proc makeSimplexFast(
    ctx: DewallContext, idx: openArray[int], h: ActiveEdge, g: var UniformGrid
): int =
  hotInc(ctx, makeSimplexFastCalls)
  if not g.enabled:
    return makeSimplexBrute(ctx, idx, h)

  let
    pa = ctx.points[h.a]
    pb = ctx.points[h.b]
    faceRadius = sqrt(dist2(pa, pb)) * 0.5
  if faceRadius <= Eps:
    return -1

  g.reset()
  var search = initSearch()
  var boxRadius2 = scanRadiusBox(ctx, h, g, faceRadius, search)
  if not search.found:
    var radius = faceRadius
    for _ in 0 ..< 4:
      radius *= 2.0
      boxRadius2 = scanRadiusBox(ctx, h, g, radius, search)
      if search.found:
        break
  if search.found and search.bestDd > boxRadius2 + Eps:
    discard scanRadiusBox(ctx, h, g, sqrt(search.bestDd), search)
  if not search.found:
    scanUnmarked(ctx, h, g, search)
  search.best

template indexLess(ctx: DewallContext, a, b: int, Axis: static[int]): bool =
  let
    ca = coord(ctx.points, a, Axis)
    cb = coord(ctx.points, b, Axis)
  ca < cb or (ca == cb and a < b)

proc insertionSortRange[Axis: static[int]](
    ctx: DewallContext, items: var seq[int], lo, hi: int
) =
  var i = lo + 1
  while i <= hi:
    let value = items[i]
    var j = i
    while j > lo and indexLess(ctx, value, items[j - 1], Axis):
      items[j] = items[j - 1]
      dec j
    items[j] = value
    inc i

proc medianOfThree[Axis: static[int]](
    ctx: DewallContext, items: seq[int], lo, mid, hi: int
): int =
  let
    a = items[lo]
    b = items[mid]
    c = items[hi]
  if indexLess(ctx, a, b, Axis):
    if indexLess(ctx, b, c, Axis):
      mid
    elif indexLess(ctx, a, c, Axis):
      hi
    else:
      lo
  elif indexLess(ctx, a, c, Axis):
    lo
  elif indexLess(ctx, b, c, Axis):
    hi
  else:
    mid

proc partitionAroundPivot[Axis: static[int]](
    ctx: DewallContext, items: var seq[int], lo, hi, pivotAt: int
): int =
  let pivot = items[pivotAt]
  swap(items[pivotAt], items[hi])
  var store = lo
  for i in lo ..< hi:
    if indexLess(ctx, items[i], pivot, Axis):
      swap(items[store], items[i])
      inc store
  swap(items[store], items[hi])
  store

proc partitionAtMedian[Axis: static[int]](
    ctx: DewallContext, items: var seq[int], nth: int
) =
  var
    lo = 0
    hi = items.high
  while hi - lo > 24:
    let pivotAt = medianOfThree[Axis](ctx, items, lo, lo + ((hi - lo) div 2), hi)
    let pivotNew = partitionAroundPivot[Axis](ctx, items, lo, hi, pivotAt)
    if nth == pivotNew:
      return
    if nth < pivotNew:
      hi = pivotNew - 1
    else:
      lo = pivotNew + 1
  insertionSortRange[Axis](ctx, items, lo, hi)

proc maxPartitionLeft[Axis: static[int]](
    ctx: DewallContext, items: openArray[int], len: int
): int =
  result = items[0]
  for i in 1 ..< len:
    if indexLess(ctx, result, items[i], Axis):
      result = items[i]

proc classifySplit[Axis: static[int]](ctx: DewallContext, idx: seq[int]): Split =
  result.left = idx
  hotInc(ctx, splitSorts)
  let mid = result.left.len div 2
  partitionAtMedian[Axis](ctx, result.left, mid)
  let
    leftMax = maxPartitionLeft[Axis](ctx, result.left, mid)
    rightMin = result.left[mid]
    leftCoord = coord(ctx.points, leftMax, Axis)
    rightCoord = coord(ctx.points, rightMin, Axis)
  result.cut = (leftCoord + rightCoord) * 0.5
  result.right = result.left[mid ..< result.left.len]
  result.left.setLen(mid)
  result.hasSideTies = leftCoord == rightCoord
  if result.hasSideTies:
    result.side = newSeq[uint8](ctx.points.len)

    for i in result.left:
      result.side[i] = 1'u8
    for i in result.right:
      result.side[i] = 2'u8

proc straddles[Axis: static[int]](points: seq[Vec2], h: ActiveEdge, split: Split): bool =
  let
    ca = coord(points, h.a, Axis)
    cb = coord(points, h.b, Axis)
  (ca < split.cut) != (cb < split.cut)

proc bothIn[Axis: static[int]](
    points: seq[Vec2], h: ActiveEdge, split: Split, which: int
): bool =
  if split.hasSideTies:
    let marker = uint8(which)
    return split.side[h.a] == marker and split.side[h.b] == marker

  let
    aLeft = coord(points, h.a, Axis) < split.cut
    bLeft = coord(points, h.b, Axis) < split.cut
  if which == 1:
    aLeft and bLeft
  else:
    not aLeft and not bLeft

proc update(list: var Table[EdgeKey, ActiveEdge], closed: HashSet[EdgeKey], h: ActiveEdge) =
  let k = key(h)
  if closed.contains(k):
    return
  if list.hasKey(k):
    list.del(k)
  else:
    list[k] = h

proc insert(list: var Table[EdgeKey, ActiveEdge], closed: HashSet[EdgeKey], h: ActiveEdge) =
  let k = key(h)
  if not closed.contains(k):
    list[k] = h

proc addTriangle(
    ctx: DewallContext,
    outTriangles: var seq[array[3, int]],
    localSeen: var HashSet[TriKey],
    a, b, c: int,
) =
  if a < 0 or b < 0 or c < 0 or a == b or b == c or a == c:
    return
  let key = triKey(a, b, c)
  if localSeen.contains(key):
    return
  localSeen.incl key
  let o = orient(ctx.points[a], ctx.points[b], ctx.points[c])
  if abs(o) <= Eps:
    return
  if o > 0:
    outTriangles.add [a, b, c]
  else:
    outTriangles.add [a, c, b]

proc routeInsert[Axis: static[int]](
    ctx: DewallContext,
    split: Split,
    closed: HashSet[EdgeKey],
    wall, afl1, afl2: var Table[EdgeKey, ActiveEdge],
    h: ActiveEdge,
) =
  if closed.contains(key(h)):
    return
  if straddles[Axis](ctx.points, h, split):
    insert(wall, closed, h)
  elif bothIn[Axis](ctx.points, h, split, 1):
    insert(afl1, closed, h)
  elif bothIn[Axis](ctx.points, h, split, 2):
    insert(afl2, closed, h)

proc routeUpdate[Axis: static[int]](
    ctx: DewallContext,
    split: Split,
    closed: HashSet[EdgeKey],
    wall, afl1, afl2: var Table[EdgeKey, ActiveEdge],
    h: ActiveEdge,
) =
  if closed.contains(key(h)):
    return
  if straddles[Axis](ctx.points, h, split):
    update(wall, closed, h)
  elif bothIn[Axis](ctx.points, h, split, 1):
    update(afl1, closed, h)
  elif bothIn[Axis](ctx.points, h, split, 2):
    update(afl2, closed, h)

template emitUpdated(
    Axis: static[int],
    ctx: DewallContext,
    split: Split,
    closed: HashSet[EdgeKey],
    wall, afl1, afl2: var Table[EdgeKey, ActiveEdge],
    fromVertex, toVertex: int,
) =
  routeUpdate[Axis](
    ctx,
    split,
    closed,
    wall,
    afl1,
    afl2,
    ActiveEdge(a: fromVertex, b: toVertex),
  )

template emitTriangleExterior(
    Axis: static[int],
    ctx: DewallContext,
    split: Split,
    closed: HashSet[EdgeKey],
    wall, afl1, afl2: var Table[EdgeKey, ActiveEdge],
    a, b, c: int,
) =
  ## A CCW triangle has its interior on the left of a->b, b->c, c->a. Active
  ## requests point to the opposite side, so exterior requests are reversed.
  emitUpdated(Axis, ctx, split, closed, wall, afl1, afl2, b, a)
  emitUpdated(Axis, ctx, split, closed, wall, afl1, afl2, c, b)
  emitUpdated(Axis, ctx, split, closed, wall, afl1, afl2, a, c)

proc makeFirstSimplex[Axis: static[int]](
    ctx: DewallContext, idx: openArray[int], split: Split
): array[3, int] =
  result = [-1, -1, -1]
  if split.left.len == 0 or split.right.len == 0:
    return

  let p1 = split.left[^1]
  var
    p2 = -1
    bestDist = Inf
  for candidate in split.right:
    let d = dist2(ctx.points[p1], ctx.points[candidate])
    if d < bestDist:
      bestDist = d
      p2 = candidate
  if p2 < 0:
    return

  var
    p3 = -1
    bestRadius = Inf
  for candidate in idx:
    if candidate == p1 or candidate == p2:
      continue
    let radius = circumRadius2(ctx.points, p1, p2, candidate)
    if radius < bestRadius:
      bestRadius = radius
      p3 = candidate
  if p3 >= 0:
    result = [p1, p2, p3]

proc tableValues(t: Table[EdgeKey, ActiveEdge]): seq[ActiveEdge] =
  for edge in t.values:
    result.add edge

proc dewallRec[Parallel: static[bool], Axis: static[int]](
    ctx: DewallContext,
    idx: seq[int],
    inherited: seq[ActiveEdge],
    isRoot: bool,
    depth: int,
): seq[array[3, int]] {.gcsafe.}

proc buildWall[Axis: static[int]](
    ctx: DewallContext,
    idx: seq[int],
    inherited: seq[ActiveEdge],
    isRoot: bool,
    depth: int,
): WallBuild {.gcsafe.} =
  result.split = classifySplit[Axis](ctx, idx)
  result.afl1 = initTable[EdgeKey, ActiveEdge]()
  result.afl2 = initTable[EdgeKey, ActiveEdge]()

  var
    localSeen = initHashSet[TriKey]()
    wall = initTable[EdgeKey, ActiveEdge]()
    closed = initHashSet[EdgeKey]()
    grid = buildGrid(ctx, idx)

  for h in inherited:
    routeInsert[Axis](ctx, result.split, closed, wall, result.afl1, result.afl2, h)
  trace(
    "dewall depth=" & $depth & " n=" & $idx.len & " inherited=" &
      $inherited.len & " wall=" & $wall.len & " afl1=" & $result.afl1.len &
      " afl2=" & $result.afl2.len
  )

  if isRoot and wall.len == 0:
    let first = makeFirstSimplex[Axis](ctx, idx, result.split)
    if first[0] >= 0:
      let before = result.triangles.len
      addTriangle(ctx, result.triangles, localSeen, first[0], first[1], first[2])
      if result.triangles.len > before:
        hotInc(ctx, wallTrianglesEmitted)
        let a = result.triangles[^1][0]
        let b = result.triangles[^1][1]
        let c = result.triangles[^1][2]
        emitTriangleExterior(
          Axis, ctx, result.split, closed, wall, result.afl1, result.afl2, a, b, c
        )

  while wall.len > 0:
    var h: ActiveEdge
    var hKey: EdgeKey
    for k, edge in wall.pairs:
      hKey = k
      h = edge
      break
    wall.del(hKey)
    if closed.contains(hKey):
      continue
    hotInc(ctx, wallEdgesProcessed)
    let apex = makeSimplexFast(ctx, idx, h, grid)
    closed.incl hKey
    if apex < 0:
      trace(
        "dewall hull depth=" & $depth & " edge=(" & $h.a & "," & $h.b &
          ") n=" & $idx.len
      )
      continue

    addTriangle(ctx, result.triangles, localSeen, h.a, h.b, apex)
    hotInc(ctx, wallTrianglesEmitted)
    emitUpdated(Axis, ctx, result.split, closed, wall, result.afl1, result.afl2, apex, h.b)
    emitUpdated(Axis, ctx, result.split, closed, wall, result.afl1, result.afl2, h.a, apex)

proc dewallChildren[Parallel: static[bool], Axis: static[int]](
    ctx: DewallContext,
    split: Split,
    afl1, afl2: Table[EdgeKey, ActiveEdge],
    depth: int,
): seq[array[3, int]] {.gcsafe.} =
  let
    leftAfl = tableValues(afl1)
    rightAfl = tableValues(afl2)

  when Parallel and compileOption("threads"):
    let canFork = ctx.options.parallel and depth < ctx.options.maxParallelDepth and
      split.left.len >= ctx.options.minParallelPoints and
      split.right.len >= ctx.options.minParallelPoints and
      leftAfl.len > 0 and rightAfl.len > 0
    if canFork:
      let leftFlow = spawn dewallRec[Parallel, 1 - Axis](ctx, split.left, leftAfl, false, depth + 1)
      let right = dewallRec[Parallel, 1 - Axis](ctx, split.right, rightAfl, false, depth + 1)
      result.add ^leftFlow
      result.add right
      return

  if split.left.len >= 3 and leftAfl.len > 0:
    result.add dewallRec[Parallel, 1 - Axis](ctx, split.left, leftAfl, false, depth + 1)
  if split.right.len >= 3 and rightAfl.len > 0:
    result.add dewallRec[Parallel, 1 - Axis](ctx, split.right, rightAfl, false, depth + 1)

proc dewallRec[Parallel: static[bool], Axis: static[int]](
    ctx: DewallContext,
    idx: seq[int],
    inherited: seq[ActiveEdge],
    isRoot: bool,
    depth: int,
): seq[array[3, int]] {.gcsafe.} =
  if idx.len < 3:
    return

  var localSeen = initHashSet[TriKey]()
  if idx.len == 3:
    addTriangle(ctx, result, localSeen, idx[0], idx[1], idx[2])
    return

  let wall = buildWall[Axis](ctx, idx, inherited, isRoot, depth)
  result.add wall.triangles
  result.add dewallChildren[Parallel, Axis](ctx, wall.split, wall.afl1, wall.afl2, depth)

proc dewallLeaf(ctx: DewallContext, node: PrewallNode): seq[array[3, int]] {.gcsafe.} =
  if node.axis == 0:
    dewallRec[false, 0](ctx, node.idx, node.inherited, node.isRoot, node.depth)
  else:
    dewallRec[false, 1](ctx, node.idx, node.inherited, node.isRoot, node.depth)

proc buildWallFor(ctx: DewallContext, node: PrewallNode): WallBuild =
  if node.axis == 0:
    buildWall[0](ctx, node.idx, node.inherited, node.isRoot, node.depth)
  else:
    buildWall[1](ctx, node.idx, node.inherited, node.isRoot, node.depth)

proc childNode(parent: PrewallNode, idx: seq[int], inherited: seq[ActiveEdge]): PrewallNode =
  PrewallNode(
    idx: idx,
    inherited: inherited,
    isRoot: false,
    axis: 1 - parent.axis,
    depth: parent.depth + 1,
  )

proc largestSplittableNode(nodes: openArray[PrewallNode], minPoints: int): int =
  result = -1
  var bestLen = 0
  for i, node in nodes:
    if node.idx.len > minPoints and node.idx.len > 3 and node.idx.len > bestLen:
      bestLen = node.idx.len
      result = i

proc dewallPrewall[Parallel: static[bool]](
    ctx: DewallContext, rootIdx: seq[int]
): seq[array[3, int]] =
  var pending =
    @[
      PrewallNode(
        idx: rootIdx,
        inherited: @[],
        isRoot: true,
        axis: 0,
        depth: 0,
      )
    ]
  let target = max(1, ctx.options.prewallLeafTarget)
  let minSplitPoints = resolvedDewallPrewallMinSplitPoints(
    ctx.options, rootIdx.len, target
  )

  while pending.len < target:
    let splitAt = largestSplittableNode(pending, minSplitPoints)
    if splitAt < 0:
      break

    let node = pending[splitAt]
    pending.delete(splitAt)
    let wall = buildWallFor(ctx, node)
    result.add wall.triangles

    let leftAfl = tableValues(wall.afl1)
    if wall.split.left.len >= 3 and leftAfl.len > 0:
      pending.add childNode(node, wall.split.left, leftAfl)

    let rightAfl = tableValues(wall.afl2)
    if wall.split.right.len >= 3 and rightAfl.len > 0:
      pending.add childNode(node, wall.split.right, rightAfl)

    if pending.len == 0:
      return

  when Parallel and compileOption("threads"):
    if ctx.options.parallel and pending.len > 1:
      var flows: seq[FlowVar[seq[array[3, int]]]]
      for i in 0 ..< pending.high:
        flows.add spawn dewallLeaf(ctx, pending[i])
      result.add dewallLeaf(ctx, pending[^1])
      for flow in flows.mitems:
        result.add ^flow
      return

  for node in pending:
    result.add dewallLeaf(ctx, node)

when defined(p2tDewallHotStats):
  proc dedupeTriangles(
      points: openArray[Vec2], triangles: openArray[array[3, int]]
  ): seq[array[3, int]] =
    var seen = initHashSet[TriKey]()
    for tri in triangles:
      let key = triKey(tri[0], tri[1], tri[2])
      if seen.contains(key):
        continue
      seen.incl key
      if orient(points[tri[0]], points[tri[1]], points[tri[2]]) > 0:
        result.add tri
      else:
        result.add [tri[0], tri[2], tri[1]]

proc duplicateTriangleCount(triangles: openArray[array[3, int]]): int =
  var seen = initHashSet[TriKey]()
  for tri in triangles:
    let key = triKey(tri[0], tri[1], tri[2])
    if seen.contains(key):
      inc result
    else:
      seen.incl key

proc pointIndexSeq(count: int): seq[int] =
  result = newSeq[int](count)
  for i in 0 ..< count:
    result[i] = i

proc prepareDewallWorkspace*(
    ws: var DewallPreparedWorkspace, points: openArray[Vec2]
) =
  ws.points.setLen(points.len)
  ws.idx.setLen(points.len)
  for i in 0 ..< points.len:
    ws.points[i] = points[i]
    ws.idx[i] = i

proc finishProfileTriangles(
    triangles: openArray[array[3, int]], profile: var DewallProfile
) =
  profile.rawTriangleCount = triangles.len
  profile.duplicatesRemoved = duplicateTriangleCount(triangles)
  profile.dedupedTriangleCount = profile.rawTriangleCount - profile.duplicatesRemoved

proc setLeafStats(profile: var DewallProfile, leaves: openArray[PrewallNode]) =
  profile.actualLeaves = leaves.len
  if leaves.len == 0:
    return

  profile.leafMinPoints = int.high
  var total = 0
  for leaf in leaves:
    profile.leafMinPoints = min(profile.leafMinPoints, leaf.idx.len)
    profile.leafMaxPoints = max(profile.leafMaxPoints, leaf.idx.len)
    total += leaf.idx.len
  profile.leafMeanPoints = total.float64 / leaves.len.float64

proc profileDewallRootWall*(
    points: openArray[Vec2], options = defaultDewallOptions()
): DewallProfile =
  ## Time only the root wall construction. This is diagnostic and deliberately
  ## separate from the benchmark hot path.
  result.pointCount = points.len
  if points.len < 3:
    return

  let ctx = DewallContext(points: @points, options: options)
  let idx = pointIndexSeq(points.len)
  let start = getMonoTime()
  let wall = buildWall[0](ctx, idx, @[], true, 0)
  result.wallUs = inMicroseconds(getMonoTime() - start).float64
  result.prewallWallCount = 1
  result.wallTriangleCount = wall.triangles.len
  result.requestedLeaves = 1
  result.actualLeaves = 1
  result.rawTriangleCount = wall.triangles.len
  result.duplicatesRemoved = duplicateTriangleCount(wall.triangles)
  result.dedupedTriangleCount = result.rawTriangleCount - result.duplicatesRemoved
  if points.len > 0:
    result.wallUsPerSqrtPoint = result.wallUs / sqrt(points.len.float64)

proc profileDewallPrewall*(
    points: openArray[Vec2], options = defaultDewallOptions()
): DewallProfile =
  ## Profile the binary-prewall frontier plus serial leaf completion. The
  ## counters are intentionally coarse so normal triangulation stays clean.
  result.pointCount = points.len
  result.requestedLeaves = max(1, options.prewallLeafTarget)
  result.resolvedPrewallMinLeafPoints = resolvedDewallPrewallMinLeafPoints(options)
  result.resolvedPrewallMinSplitPoints = resolvedDewallPrewallMinSplitPoints(
    options, points.len, result.requestedLeaves
  )
  if points.len < 3:
    return

  let ctx = DewallContext(points: @points, options: options)
  var pending =
    @[
      PrewallNode(
        idx: pointIndexSeq(points.len),
        inherited: @[],
        isRoot: true,
        axis: 0,
        depth: 0,
      )
    ]
  let target = result.requestedLeaves
  var triangles: seq[array[3, int]]

  while pending.len < target:
    let splitAt = largestSplittableNode(pending, result.resolvedPrewallMinSplitPoints)
    if splitAt < 0:
      break

    let node = pending[splitAt]
    pending.delete(splitAt)

    let start = getMonoTime()
    let wall = buildWallFor(ctx, node)
    result.wallUs += inMicroseconds(getMonoTime() - start).float64
    inc result.prewallWallCount
    result.wallTriangleCount += wall.triangles.len
    triangles.add wall.triangles

    let leftAfl = tableValues(wall.afl1)
    if wall.split.left.len >= 3 and leftAfl.len > 0:
      pending.add childNode(node, wall.split.left, leftAfl)

    let rightAfl = tableValues(wall.afl2)
    if wall.split.right.len >= 3 and rightAfl.len > 0:
      pending.add childNode(node, wall.split.right, rightAfl)

    if pending.len == 0:
      break

  result.setLeafStats(pending)
  if options.parallel and result.actualLeaves > 1:
    result.spawnedTasks = result.actualLeaves - 1
  if points.len > 0:
    result.wallUsPerSqrtPoint = result.wallUs / sqrt(points.len.float64)

  for node in pending:
    triangles.add dewallLeaf(ctx, node)
  finishProfileTriangles(triangles, result)

proc dewallTriangulateStatic*[Parallel: static[bool]](
    points: openArray[Vec2], options = defaultDewallOptions()
): seq[array[3, int]] =
  if points.len < 3:
    return @[]

  var ctx = DewallContext(points: @points, options: options)
  var idx = newSeq[int](points.len)
  for i in 0 ..< points.len:
    idx[i] = i

  when Parallel:
    if options.parallel and options.prewallLeafTarget > 1:
      return dewallPrewall[Parallel](ctx, idx)

  dewallRec[Parallel, 0](ctx, idx, @[], true, 0)

proc dewallTriangulatePreparedStatic*[Parallel: static[bool]](
    ws: DewallPreparedWorkspace, options = defaultDewallOptions()
): seq[array[3, int]] =
  if ws.points.len < 3:
    return @[]

  let ctx = DewallContext(points: ws.points, options: options)
  when Parallel:
    if options.parallel and options.prewallLeafTarget > 1:
      return dewallPrewall[Parallel](ctx, ws.idx)

  dewallRec[Parallel, 0](ctx, ws.idx, @[], true, 0)

when defined(p2tDewallHotStats):
  proc dewallTriangulateWithHotStats*(
      points: openArray[Vec2], options = defaultDewallOptions()
  ): DewallHotStatsResult =
    var stats: DewallHotStats
    if points.len < 3:
      result.stats = stats
      return

    var ctx = DewallContext(points: @points, options: options, stats: addr stats)
    let idx = pointIndexSeq(points.len)
    var raw: seq[array[3, int]]

    if options.parallel:
      when compileOption("threads"):
        if options.prewallLeafTarget > 1:
          raw = dewallPrewall[true](ctx, idx)
        else:
          raw = dewallRec[true, 0](ctx, idx, @[], true, 0)
      else:
        raw = dewallRec[false, 0](ctx, idx, @[], true, 0)
    else:
      raw = dewallRec[false, 0](ctx, idx, @[], true, 0)

    result.triangles = dedupeTriangles(ctx.points, raw)
    result.stats = stats

  proc profileDewallPrewallHotStats*(
      points: openArray[Vec2], options = defaultDewallOptions()
  ): DewallHotProfileResult =
    result.profile = profileDewallPrewall(points, options)
    let hot = dewallTriangulateWithHotStats(points, options)
    result.triangles = hot.triangles
    result.stats = hot.stats

proc dewallTriangulate*(
    points: openArray[Vec2], options = defaultDewallOptions()
): seq[array[3, int]] =
  if options.parallel:
    dewallTriangulateStatic[true](points, options)
  else:
    dewallTriangulateStatic[false](points, options)
