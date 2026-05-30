import ./[geometry, types]
import ./internal/cdt

type Edge = array[2, int]

proc addBoundaryEdges(edges: var seq[Edge], base, count: int) =
  if count < 2:
    return
  for i in 0 ..< count:
    edges.add [base + i, base + ((i + 1) mod count)]

proc validateContours(
    outer: seq[Vec2], holes: seq[seq[Vec2]], eps: float64, error: var TessError
): bool =
  var err = tessError(tekNone)
  if hasSelfIntersection(outer, -1, eps, err):
    error = err
    return false

  for h, hole in holes:
    if hasSelfIntersection(hole, h, eps, err):
      error = err
      return false
    for p in hole:
      if not pointInPolygon(p, outer, eps):
        error = tessError(tekInvalidHole, h, -1, "hole vertex is outside outer contour")
        return false

  for h, hole in holes:
    for i in 0 ..< hole.len:
      let
        a = hole[i]
        b = hole[(i + 1) mod hole.len]
      for j in 0 ..< outer.len:
        if segmentsIntersect(a, b, outer[j], outer[(j + 1) mod outer.len], eps):
          error = tessError(tekInvalidHole, h, i, "hole intersects outer contour")
          return false

  for h1 in 0 ..< holes.len:
    for h2 in h1 + 1 ..< holes.len:
      for p in holes[h2]:
        if pointInPolygon(p, holes[h1], eps):
          error = tessError(tekInvalidHole, h2, -1, "hole is nested in another hole")
          return false
      for i in 0 ..< holes[h1].len:
        for j in 0 ..< holes[h2].len:
          if segmentsIntersect(
            holes[h1][i],
            holes[h1][(i + 1) mod holes[h1].len],
            holes[h2][j],
            holes[h2][(j + 1) mod holes[h2].len],
            eps,
          ):
            error = tessError(tekInvalidHole, h1, i, "holes intersect")
            return false

  true

proc tessellate*(
    workspace: var TessWorkspace, input: TessInput, options = defaultTessOptions()
): TessResult =
  workspace.clear()

  var error = tessError(tekNone)
  var outer = cleanContour(input.outer, options.epsilon, options.cleanInput, error)
  if error.kind != tekNone:
    return failure(error)
  outer.ensureOrientation(ccw = true)

  var holes: seq[seq[Vec2]] = @[]
  for holeContour in input.holes:
    var hole = cleanContour(holeContour, options.epsilon, options.cleanInput, error)
    if error.kind != tekNone:
      return failure(error)
    hole.ensureOrientation(ccw = false)
    holes.add hole

  if options.validate and not validateContours(outer, holes, options.epsilon, error):
    return failure(error)

  var boundaryEdges: seq[Edge] = @[]
  if options.keepBoundaryEdges:
    boundaryEdges.addBoundaryEdges(0, outer.len)
  var boundaryBase = outer.len
  for hole in holes:
    if options.keepBoundaryEdges:
      boundaryEdges.addBoundaryEdges(boundaryBase, hole.len)
    inc boundaryBase, hole.len

  for p in input.steiner:
    if not pointInPolygon(p, outer, options.epsilon):
      return failure(
        tessError(tekInvalidHole, -1, -1, "Steiner point is outside outer contour")
      )

  try:
    let cdtResult = workspace.triangulateCdt(
      CdtInput(outer: outer, holes: holes, steiner: input.steiner)
    )
    workspace.vertices = cdtResult.vertices
    success(cdtResult.vertices, cdtResult.triangles, boundaryEdges)
  except CatchableError as err:
    failure(tessError(tekTriangulationFailed, -1, -1, err.msg))

proc tessellate*(input: TessInput, options = defaultTessOptions()): TessResult =
  var workspace: TessWorkspace
  workspace.tessellate(input, options)

# A single triangulation is inherently serial (the advancing front is one chain
# of data dependencies), but distinct inputs are independent. tessellateBatch
# triangulates many inputs in parallel, one reused TessWorkspace per thread, so
# throughput scales with cores - the practical way to outrun a single-threaded
# tessellator on batch workloads (e.g. many glyphs/paths in a renderer).

proc tessellateBatchSerial(
    inputs: openArray[TessInput], options: TessOptions
): seq[TessResult] =
  result = newSeq[TessResult](inputs.len)
  var workspace: TessWorkspace
  for i in 0 ..< inputs.len:
    result[i] = workspace.tessellate(inputs[i], options)

when compileOption("threads"):
  import std/cpuinfo

  type BatchChunk = object
    inputs: ptr UncheckedArray[TessInput]
    results: ptr UncheckedArray[TessResult]
    options: TessOptions
    lo, hi: int

  proc batchWorker(chunk: BatchChunk) {.thread.} =
    # Each thread owns its workspace so allocations are reused across its chunk
    # without cross-thread contention. Inputs are read-only; result slots are
    # disjoint, so no synchronization is needed. tessellate touches no global
    # state (only its params and the local workspace), so asserting gcsafe here
    # is sound - the compiler is just conservative about the unannotated chain.
    var workspace: TessWorkspace
    for i in chunk.lo ..< chunk.hi:
      {.gcsafe.}:
        chunk.results[i] = workspace.tessellate(chunk.inputs[i], chunk.options)

  proc tessellateBatch*(
      inputs: openArray[TessInput], options = defaultTessOptions(), threads = 0
  ): seq[TessResult] =
    ## Triangulate `inputs` in parallel. `threads = 0` uses all detected cores.
    ## Results are returned in input order. Each input is independent.
    ##
    ## Worker threads allocate the result buffers that the caller then owns, so
    ## compile multi-threaded callers with `-d:useMalloc` (a global thread-safe
    ## allocator). Without it, Nim's per-thread heap regions make this
    ## cross-thread ownership transfer unsafe.
    let n = inputs.len
    if n == 0:
      return @[]

    var nThreads =
      if threads > 0:
        threads
      else:
        countProcessors()
    nThreads = max(1, min(nThreads, n))
    if nThreads == 1:
      return tessellateBatchSerial(inputs, options)

    result = newSeq[TessResult](n)
    let
      inPtr = cast[ptr UncheckedArray[TessInput]](unsafeAddr inputs[0])
      outPtr = cast[ptr UncheckedArray[TessResult]](addr result[0])
      chunk = (n + nThreads - 1) div nThreads
    var workers = newSeq[Thread[BatchChunk]](nThreads)
    for t in 0 ..< nThreads:
      let lo = t * chunk
      if lo >= n:
        workers.setLen(t)
        break
      createThread(
        workers[t],
        batchWorker,
        BatchChunk(
          inputs: inPtr,
          results: outPtr,
          options: options,
          lo: lo,
          hi: min(lo + chunk, n),
        ),
      )
    for t in 0 ..< workers.len:
      joinThread(workers[t])

else:
  proc tessellateBatch*(
      inputs: openArray[TessInput], options = defaultTessOptions(), threads = 0
  ): seq[TessResult] =
    ## Serial fallback when compiled without `--threads:on`.
    discard threads
    tessellateBatchSerial(inputs, options)
