type
  CdtPointId* = int
  CdtEdgeId* = int
  CdtTriangleId* = int
  CdtNodeId* = int

  CdtPoint* = object
    x*, y*: float64
    sourceIndex*: int

  CdtEdge* = object
    p*, q*: CdtPointId

  # Triangle-based data structures are known to perform better than quad-edge
  # structures. See: J. Shewchuk, "Triangle: Engineering a 2D Quality Mesh
  # Generator and Delaunay Triangulator".
  CdtTriangle* = object
    points*: array[3, CdtPointId]
    neighbors*: array[3, CdtTriangleId]
    constrainedEdge*: array[3, bool]
    delaunayEdge*: array[3, bool]
    interior*: bool

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
    pointEdges*: seq[seq[CdtEdgeId]]
    edges*: seq[CdtEdge]
    triangles*: seq[CdtTriangle]
    nodes*: seq[CdtNode]
    activePoints*: seq[CdtPointId]
    interiorTriangles*: seq[CdtTriangleId]
    front*: CdtFront
    head*, tail*: CdtPointId
    afHead*, afMiddle*, afTail*: CdtNodeId
    basin*: CdtBasin
    edgeEvent*: CdtEdgeEvent

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

  TessWorkspace* = object
    vertices*: seq[Vec2]
    polygon*: seq[int]
    indexMap*: seq[int]
    scratch*: seq[int]
    cdt*: CdtWorkspace

proc defaultTessOptions*(): TessOptions =
  TessOptions(epsilon: 1e-9, cleanInput: true, keepBoundaryEdges: false, validate: true)

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
