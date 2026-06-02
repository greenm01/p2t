import std/[strutils, times]

import p2t

const
  PointsPerSide = 256
  Iterations = 50_000

proc collinearHeavySquare(): TessInput =
  var pts: seq[Vec2]
  for i in 0 ..< PointsPerSide:
    pts.add vec2(4.0 * float64(i) / float64(PointsPerSide), 0)
  for i in 0 ..< PointsPerSide:
    pts.add vec2(4, 4.0 * float64(i) / float64(PointsPerSide))
  for i in 0 ..< PointsPerSide:
    pts.add vec2(4.0 - 4.0 * float64(i) / float64(PointsPerSide), 4)
  for i in 0 ..< PointsPerSide:
    pts.add vec2(0, 4.0 - 4.0 * float64(i) / float64(PointsPerSide))
  pts.add pts[0]
  TessInput(outer: contour(1, pts))

proc cleanSquare(): TessInput =
  TessInput(outer: contour(1, [vec2(0, 0), vec2(4, 0), vec2(4, 4), vec2(0, 4)]))

template bench(name: string, body: untyped) =
  block:
    let start = cpuTime()
    var checksum = 0
    for _ in 0 ..< Iterations:
      checksum += body
    let elapsed = cpuTime() - start
    let us = elapsed * 1_000_000.0 / float64(Iterations)
    let label = name & repeat(' ', max(1, 28 - name.len))
    echo label & formatFloat(us, ffDecimal, 3).align(10) & " us  checksum=" & $checksum

proc main() =
  let messy = collinearHeavySquare()
  let clean = cleanSquare()
  var workspace: TessWorkspace
  var options = defaultTessOptions()
  options.validate = false

  echo "points,heavy," & $messy.outer.points.len
  echo "points,clean," & $clean.outer.points.len
  echo "iterations," & $Iterations

  bench "checked no-validate":
    let result = workspace.tessellate(messy, options)
    if not result.ok:
      raise newException(ValueError, result.error.message)
    result.triangles.len

  bench "normalized trusted":
    let result = workspace.tessellateNormalizedTrusted(messy)
    if not result.ok:
      raise newException(ValueError, result.error.message)
    result.triangles.len

  bench "normalized trusted raw":
    let raw = workspace.tessellateNormalizedTrustedRaw(messy)
    if not raw.ok:
      raise newException(ValueError, raw.error.message)
    raw.rawTriangleCount

  bench "clean trusted":
    let result = workspace.tessellateTrusted(clean)
    if not result.ok:
      raise newException(ValueError, result.error.message)
    result.triangles.len

  bench "clean trusted raw":
    let raw = workspace.tessellateTrustedRaw(clean)
    if not raw.ok:
      raise newException(ValueError, raw.error.message)
    raw.rawTriangleCount

main()
