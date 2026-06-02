## Optional C ABI for p2t.
##
## This module is built explicitly by the `buildCAbi` / `testCAbi` nimble tasks.
## It is intentionally separate from `import p2t`.

import ./[triangulate, types]

type
  P2tVec2* {.exportc: "p2t_vec2".} = object
    x*, y*: cdouble

  P2tContour* {.exportc: "p2t_contour".} = object
    id*: cint
    points*: ptr P2tVec2
    count*: cint

  P2tOptions* {.exportc: "p2t_options".} = object
    epsilon*: cdouble
    clean_input*: cint
    keep_boundary_edges*: cint
    validate*: cint

  P2tError* {.exportc: "p2t_error".} = object
    kind*: cint
    contour_id*: cint
    point_index*: cint
    message*: cstring

  P2tTriangle* {.exportc: "p2t_triangle".} = object
    a*, b*, c*: cint

  P2tEdge* {.exportc: "p2t_edge".} = object
    a*, b*: cint

  P2tResult* {.exportc: "p2t_result".} = object
    ok*: cint
    error*: P2tError
    vertices*: ptr P2tVec2
    vertex_count*: cint
    triangles*: ptr P2tTriangle
    triangle_count*: cint
    boundary_edges*: ptr P2tEdge
    boundary_edge_count*: cint

  P2tContextObj = object
    workspace: TessWorkspace
    vertices: seq[P2tVec2]
    triangles: seq[P2tTriangle]
    boundaryEdges: seq[P2tEdge]
    errorKind: cint
    errorContourId: int
    errorPointIndex: int
    message: string

  P2tContext* {.exportc: "p2t_context".} = ptr P2tContextObj

const P2tInvalidInput = cint(100)

proc p2t_version*(): cstring {.exportc, cdecl, dynlib.} =
  "0.1.0"

proc p2t_default_options*(): P2tOptions {.exportc, cdecl, dynlib.} =
  let options = defaultTessOptions()
  P2tOptions(
    epsilon: options.epsilon,
    clean_input: ord(options.cleanInput).cint,
    keep_boundary_edges: ord(options.keepBoundaryEdges).cint,
    validate: ord(options.validate).cint,
  )

proc p2t_create*(): P2tContext {.exportc, cdecl, dynlib.} =
  create(P2tContextObj)

proc p2t_destroy*(ctx: P2tContext) {.exportc, cdecl, dynlib.} =
  if ctx.isNil:
    return
  `=destroy`(ctx[])
  dealloc(ctx)

proc p2t_clear*(ctx: P2tContext) {.exportc, cdecl, dynlib.} =
  if ctx.isNil:
    return
  ctx.workspace.clear()
  ctx.vertices.setLen(0)
  ctx.triangles.setLen(0)
  ctx.boundaryEdges.setLen(0)
  ctx.message.setLen(0)

proc resultPtr[T](items: var seq[T]): ptr T =
  if items.len == 0:
    nil
  else:
    addr items[0]

proc setError(ctx: P2tContext, kind: cint, contourId, pointIndex: int, message: string) =
  ctx.errorKind = kind
  ctx.errorContourId = contourId
  ctx.errorPointIndex = pointIndex
  ctx.message = message

proc makeError(ctx: P2tContext): P2tError =
  P2tError(
    kind: ctx.errorKind,
    contour_id: ctx.errorContourId.cint,
    point_index: ctx.errorPointIndex.cint,
    message: ctx.message.cstring,
  )

proc makeResult(ctx: P2tContext, ok: bool, error: P2tError): P2tResult =
  P2tResult(
    ok: ord(ok).cint,
    error: error,
    vertices: resultPtr(ctx.vertices),
    vertex_count: ctx.vertices.len.cint,
    triangles: resultPtr(ctx.triangles),
    triangle_count: ctx.triangles.len.cint,
    boundary_edges: resultPtr(ctx.boundaryEdges),
    boundary_edge_count: ctx.boundaryEdges.len.cint,
  )

proc staticFailure(kind: cint, message: cstring): P2tResult =
  P2tResult(
    ok: 0,
    error: P2tError(kind: kind, contour_id: -1, point_index: -1, message: message),
  )

proc fail(ctx: P2tContext, kind: cint, contourId, pointIndex: int, message: string): P2tResult =
  ctx.vertices.setLen(0)
  ctx.triangles.setLen(0)
  ctx.boundaryEdges.setLen(0)
  ctx.setError(kind, contourId, pointIndex, message)
  ctx.makeResult(false, ctx.makeError())

proc checkedCount(value: cint, name: string): tuple[ok: bool, count: int, message: string] =
  if value < 0:
    return (false, 0, name & " count is negative")
  (true, value.int, "")

proc fromCPoint(p: P2tVec2): Vec2 =
  Vec2(x: p.x.float64, y: p.y.float64)

proc buildContour(
    ctx: P2tContext, c: P2tContour, name: string, output: var TessContour
): bool =
  let checked = checkedCount(c.count, name)
  if not checked.ok:
    ctx.setError(P2tInvalidInput, c.id.int, -1, checked.message)
    return false
  if checked.count > 0 and c.points.isNil:
    ctx.setError(P2tInvalidInput, c.id.int, -1, name & " points pointer is null")
    return false

  output.id = c.id.int
  output.points.setLen(checked.count)
  let points = cast[ptr UncheckedArray[P2tVec2]](c.points)
  for i in 0 ..< checked.count:
    output.points[i] = fromCPoint(points[i])
  true

proc buildInput(
    ctx: P2tContext,
    outer: P2tContour,
    holes: ptr P2tContour,
    holeCount: cint,
    steiner: ptr P2tVec2,
    steinerCount: cint,
    input: var TessInput,
): bool =
  if not buildContour(ctx, outer, "outer", input.outer):
    return false

  let checkedHoles = checkedCount(holeCount, "hole")
  if not checkedHoles.ok:
    ctx.setError(P2tInvalidInput, -1, -1, checkedHoles.message)
    return false
  if checkedHoles.count > 0 and holes.isNil:
    ctx.setError(P2tInvalidInput, -1, -1, "holes pointer is null")
    return false

  input.holes.setLen(checkedHoles.count)
  let holeArray = cast[ptr UncheckedArray[P2tContour]](holes)
  for i in 0 ..< checkedHoles.count:
    if not buildContour(ctx, holeArray[i], "hole", input.holes[i]):
      return false

  let checkedSteiner = checkedCount(steinerCount, "steiner")
  if not checkedSteiner.ok:
    ctx.setError(P2tInvalidInput, -1, -1, checkedSteiner.message)
    return false
  if checkedSteiner.count > 0 and steiner.isNil:
    ctx.setError(P2tInvalidInput, -1, -1, "steiner pointer is null")
    return false

  input.steiner.setLen(checkedSteiner.count)
  let steinerArray = cast[ptr UncheckedArray[P2tVec2]](steiner)
  for i in 0 ..< checkedSteiner.count:
    input.steiner[i] = fromCPoint(steinerArray[i])
  true

proc fromCOptions(options: ptr P2tOptions): TessOptions =
  if options.isNil:
    return defaultTessOptions()
  TessOptions(
    epsilon: options.epsilon.float64,
    cleanInput: options.clean_input != 0,
    keepBoundaryEdges: options.keep_boundary_edges != 0,
    validate: options.validate != 0,
  )

proc copyResult(ctx: P2tContext, tess: TessResult): P2tResult =
  ctx.vertices.setLen(tess.vertices.len)
  for i, vertex in tess.vertices:
    ctx.vertices[i] = P2tVec2(x: vertex.x, y: vertex.y)

  ctx.triangles.setLen(tess.triangles.len)
  for i, tri in tess.triangles:
    for idx in tri:
      if idx < 0 or idx > high(cint).int:
        return ctx.fail(P2tInvalidInput, -1, -1, "triangle index exceeds int32 range")
    ctx.triangles[i] = P2tTriangle(a: tri[0].cint, b: tri[1].cint, c: tri[2].cint)

  ctx.boundaryEdges.setLen(tess.boundaryEdges.len)
  for i, edge in tess.boundaryEdges:
    for idx in edge:
      if idx < 0 or idx > high(cint).int:
        return ctx.fail(P2tInvalidInput, -1, -1, "boundary edge index exceeds int32 range")
    ctx.boundaryEdges[i] = P2tEdge(a: edge[0].cint, b: edge[1].cint)

  ctx.message = tess.error.message
  let err = P2tError(
    kind: ord(tess.error.kind).cint,
    contour_id: tess.error.contourId.cint,
    point_index: tess.error.pointIndex.cint,
    message: ctx.message.cstring,
  )
  ctx.makeResult(tess.ok, err)

proc p2t_tessellate*(
    ctx: P2tContext,
    outer: P2tContour,
    holes: ptr P2tContour,
    hole_count: cint,
    steiner: ptr P2tVec2,
    steiner_count: cint,
    options: ptr P2tOptions,
): P2tResult {.exportc, cdecl, dynlib.} =
  if ctx.isNil:
    return staticFailure(P2tInvalidInput, "context pointer is null")

  try:
    var input: TessInput
    if not buildInput(ctx, outer, holes, hole_count, steiner, steiner_count, input):
      return ctx.makeResult(false, ctx.makeError())
    ctx.copyResult(ctx.workspace.tessellate(input, fromCOptions(options)))
  except CatchableError as err:
    ctx.fail(cint(tekTriangulationFailed), -1, -1, err.msg)

proc p2t_tessellate_trusted*(
    ctx: P2tContext,
    outer: P2tContour,
    holes: ptr P2tContour,
    hole_count: cint,
    steiner: ptr P2tVec2,
    steiner_count: cint,
    epsilon: cdouble,
): P2tResult {.exportc, cdecl, dynlib.} =
  if ctx.isNil:
    return staticFailure(P2tInvalidInput, "context pointer is null")

  try:
    var input: TessInput
    if not buildInput(ctx, outer, holes, hole_count, steiner, steiner_count, input):
      return ctx.makeResult(false, ctx.makeError())
    ctx.copyResult(ctx.workspace.tessellateTrusted(input, epsilon.float64))
  except CatchableError as err:
    ctx.fail(cint(tekTriangulationFailed), -1, -1, err.msg)

proc p2t_tessellate_normalized_trusted*(
    ctx: P2tContext,
    outer: P2tContour,
    holes: ptr P2tContour,
    hole_count: cint,
    steiner: ptr P2tVec2,
    steiner_count: cint,
    epsilon: cdouble,
): P2tResult {.exportc, cdecl, dynlib.} =
  if ctx.isNil:
    return staticFailure(P2tInvalidInput, "context pointer is null")

  try:
    var input: TessInput
    if not buildInput(ctx, outer, holes, hole_count, steiner, steiner_count, input):
      return ctx.makeResult(false, ctx.makeError())
    ctx.copyResult(ctx.workspace.tessellateNormalizedTrusted(input, epsilon.float64))
  except CatchableError as err:
    ctx.fail(cint(tekTriangulationFailed), -1, -1, err.msg)
