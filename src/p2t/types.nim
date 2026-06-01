const
  ## The front-hash locate-node accelerator is on by default for arena builds
  ## (it wins on every large fixture). Opt out with -d:p2tNoFrontHash.
  FrontHashOn* = not defined(p2tNoFrontHash)

type
  # 32-bit ids keep CdtTriangle/CdtNode compact (better cache behavior during
  # the sweep). 2^31 points/triangles is far beyond any realistic input.
  CdtPointId* = int32
  CdtEdgeId* = int32
  CdtTriangleId* = int32
  CdtNodeId* = int32

  CdtPoint* = object
    x*, y*: float64
    sourceIndex*: int32
    firstEdge*: CdtEdgeId

  CdtEdge* = object
    p*, q*: CdtPointId
    next*: CdtEdgeId

  # Triangle-based data structures are known to perform better than quad-edge
  # structures. See: J. Shewchuk, "Triangle: Engineering a 2D Quality Mesh
  # Generator and Delaunay Triangulator".
  CdtTriangle* = object
    points*: array[3, CdtPointId]
    neighbors*: array[3, CdtTriangleId]
    flags*: uint32

  CdtNode* = object
    point*: CdtPointId
    triangle*: CdtTriangleId
    next*, prev*: CdtNodeId
    value*: float64

  CdtFront* = object
    head*, tail*, searchNode*: CdtNodeId

  CdtBasin* = object
    leftNode*, bottomNode*, rightNode*: CdtNodeId
    width*: float64
    leftHighest*: bool

  CdtEdgeEvent* = object
    constrainedEdge*: CdtEdgeId
    right*: bool

  CdtWorkspace* = object
    points*: seq[CdtPoint]
    edges*: seq[CdtEdge]
    triangles*: seq[CdtTriangle]
    nodes*: seq[CdtNode]
    activePoints*: seq[CdtPointId]
    sortTemp*: seq[CdtPointId]
    meshStack*: seq[CdtTriangleId]
    interiorTriangles*: seq[CdtTriangleId]
    front*: CdtFront
    head*, tail*: CdtPointId
    afHead*, afMiddle*, afTail*: CdtNodeId
    basin*: CdtBasin
    edgeEvent*: CdtEdgeEvent

when defined(p2tArenaCdt):
  when defined(p2tCdtStats):
    type ArenaCdtStats* = object
      pointEvents*, fills*, fillBasins*, legalizeCalls*, rotations*: uint64
      edgeEvents*, edgeWalkSteps*, flipEvents*, flipScans*: uint64
      indexCalls*, edgeIndexCalls*, mapTriangleToNodesCalls*: uint64
      incircleCalls*, inScanAreaCalls*, meshCleanVisits*: uint64
      locateNodeSteps*, swapNeighborScans*, slotRotations*, slotFallbacks*: uint64
      legalizeEdges*, incircleSuccesses*, markNeighborCalls*: uint64
      mapTriangleNodeUpdates*: uint64
      locateNodeHashHits*, locateNodeHashMisses*, frontBucketUpdates*: uint64

  when defined(p2tFloat32Cdt):
    type ArenaReal* = float32
  else:
    type ArenaReal* = float64

  type
    ArenaPoint* = object
      firstEdge*: ptr ArenaEdge
      node*: ptr ArenaNode
      x*, y*: ArenaReal
      sourceIndex*, id*: int32

    ArenaEdge* = object
      p*, q*: ptr ArenaPoint
      next*: ptr ArenaEdge

    ArenaTriangle* = object
      neighbors*: array[3, ptr ArenaTriangle]
      points*: array[3, ptr ArenaPoint]
      when defined(p2tSlotCdt):
        neighborSlots*: array[3, uint8]
      flags*: uint32

    ArenaNode* = object
      next*, prev*: ptr ArenaNode
      point*: ptr ArenaPoint
      triangle*: ptr ArenaTriangle
      value*: ArenaReal

    ArenaFront* = object
      head*, tail*, searchNode*: ptr ArenaNode

    ArenaBasin* = object
      leftNode*, bottomNode*, rightNode*: ptr ArenaNode
      width*: ArenaReal
      leftHighest*: bool

    ArenaEdgeEvent* = object
      constrainedEdge*: ptr ArenaEdge
      right*: bool

    ArenaWorkspace* = object
      points*: seq[ArenaPoint]
      edges*: seq[ArenaEdge]
      triangles*: seq[ArenaTriangle]
      nodes*: seq[ArenaNode]
      activePoints*: seq[ptr ArenaPoint]
      sortTemp*: seq[ptr ArenaPoint]
      meshStack*: seq[ptr ArenaTriangle]
      interiorTriangles*: seq[ptr ArenaTriangle]
      pointCount*, edgeCount*, triangleCount*, nodeCount*, rawInteriorCount*: int
      when FrontHashOn:
        frontBuckets*: seq[ptr ArenaNode]
        frontBucketMin*, frontBucketScale*: ArenaReal
      front*: ArenaFront
      head*, tail*: ptr ArenaPoint
      afHead*, afMiddle*, afTail*: ptr ArenaNode
      basin*: ArenaBasin
      edgeEvent*: ArenaEdgeEvent

when defined(p2tIdxCdt):
  # int32-index twin of the pointer arena. Every mesh handle is a 32-bit index
  # into the workspace seqs (sentinel -1), so the hot structs are ~half the
  # width of their pointer counterparts. Selected with -d:p2tIdxCdt; used to
  # A/B the int32-index vs pointer-arena data layout on the same algorithm.
  when defined(p2tFloat32Cdt):
    type IdxReal* = float32
  else:
    type IdxReal* = float64

  type
    IdxPointId* = int32
    IdxEdgeId* = int32
    IdxTriangleId* = int32
    IdxNodeId* = int32

    IdxPoint* = object
      x*, y*: IdxReal
      sourceIndex*: int32
      firstEdge*: IdxEdgeId
      node*: IdxNodeId
      when defined(p2tIdxPad):
        pad*: uint32 # pad 28B -> 32B (pow2) to replace imul with shift

    IdxEdge* = object
      p*, q*: IdxPointId
      next*: IdxEdgeId

    IdxTriangle* = object
      neighbors*: array[3, IdxTriangleId]
      points*: array[3, IdxPointId]
      flags*: uint32
      when defined(p2tIdxPad):
        pad*: uint32 # pad 28B -> 32B (pow2) to replace imul with shift

    IdxNode* = object
      point*: IdxPointId
      triangle*: IdxTriangleId
      next*, prev*: IdxNodeId
      value*: IdxReal
      when defined(p2tIdxPad):
        pad*: uint64 # pad 24B -> 32B (pow2) to replace imul with shift

    IdxFront* = object
      head*, tail*, searchNode*: IdxNodeId

    IdxBasin* = object
      leftNode*, bottomNode*, rightNode*: IdxNodeId
      width*: IdxReal
      leftHighest*: bool

    IdxEdgeEvent* = object
      constrainedEdge*: IdxEdgeId
      right*: bool

    IdxWorkspace* = object
      points*: seq[IdxPoint]
      edges*: seq[IdxEdge]
      triangles*: seq[IdxTriangle]
      nodes*: seq[IdxNode]
      activePoints*: seq[IdxPointId]
      sortTemp*: seq[IdxPointId]
      meshStack*: seq[IdxTriangleId]
      interiorTriangles*: seq[IdxTriangleId]
      pointCount*, edgeCount*, triangleCount*, nodeCount*, rawInteriorCount*: int
      when FrontHashOn:
        frontBuckets*: seq[IdxNodeId]
        frontBucketMin*, frontBucketScale*: IdxReal
      front*: IdxFront
      head*, tail*: IdxPointId
      afHead*, afMiddle*, afTail*: IdxNodeId
      basin*: IdxBasin
      edgeEvent*: IdxEdgeEvent

type
  Vec2* = object
    x*, y*: float64

  TessContour* = object
    id*: int
    points*: seq[Vec2]

  TessInput* = object
    outer*: TessContour
    holes*: seq[TessContour]
    steiner*: seq[Vec2]

  TessOptions* = object
    epsilon*: float64
    cleanInput*: bool
    keepBoundaryEdges*: bool
    validate*: bool

  TessErrorKind* = enum
    tekNone
    tekEmptyOuter
    tekTooFewVertices
    tekDuplicatePoint
    tekDegenerateEdge
    tekSelfIntersection
    tekInvalidHole
    tekTriangulationFailed

  TessError* = object
    kind*: TessErrorKind
    contourId*: int
    pointIndex*: int
    message*: string

  TessResult* = object
    ok*: bool
    error*: TessError
    vertices*: seq[Vec2]
    triangles*: seq[array[3, int]]
    boundaryEdges*: seq[array[2, int]]

when defined(p2tIdxCdt):
  type
    TessRawResult* = object
      ok*: bool
      error*: TessError
      vertices*: ptr seq[Vec2]
      idx*: ptr IdxWorkspace

    TessWorkspace* = object
      vertices*: seq[Vec2]
      polygon*: seq[int]
      indexMap*: seq[int]
      scratch*: seq[int]
      cdt*: CdtWorkspace
      idx*: IdxWorkspace

elif defined(p2tArenaCdt):
  type
    TessRawResult* = object
      ok*: bool
      error*: TessError
      vertices*: ptr seq[Vec2]
      arena*: ptr ArenaWorkspace

    TessWorkspace* = object
      vertices*: seq[Vec2]
      polygon*: seq[int]
      indexMap*: seq[int]
      scratch*: seq[int]
      cdt*: CdtWorkspace
      arena*: ArenaWorkspace

else:
  type
    TessRawResult* = object
      ok*: bool
      error*: TessError
      vertices*: ptr seq[Vec2]
      cdt*: ptr CdtWorkspace

    TessWorkspace* = object
      vertices*: seq[Vec2]
      polygon*: seq[int]
      indexMap*: seq[int]
      scratch*: seq[int]
      cdt*: CdtWorkspace

const DefaultTessEpsilon* = 1e-9

proc defaultTessOptions*(): TessOptions =
  TessOptions(
    epsilon: DefaultTessEpsilon,
    cleanInput: true,
    keepBoundaryEdges: false,
    validate: true,
  )

proc tessError*(
    kind: TessErrorKind, contourId = -1, pointIndex = -1, message = ""
): TessError =
  TessError(kind: kind, contourId: contourId, pointIndex: pointIndex, message: message)

proc success*(
    vertices: sink seq[Vec2],
    triangles: sink seq[array[3, int]],
    boundaryEdges: sink seq[array[2, int]] = @[],
): TessResult =
  TessResult(
    ok: true,
    error: tessError(tekNone),
    vertices: vertices,
    triangles: triangles,
    boundaryEdges: boundaryEdges,
  )

proc failure*(error: TessError): TessResult =
  TessResult(ok: false, error: error)

proc clear*(workspace: var TessWorkspace) =
  workspace.vertices.setLen(0)
  workspace.polygon.setLen(0)
  workspace.indexMap.setLen(0)
  workspace.scratch.setLen(0)
