import std/[algorithm, os, strutils, unittest]

import p2t/types
import p2t/geometry
import p2t/internal/dewall

when not defined(p2tDewallHotStats):
  {.fatal: "test_dewall_hot_stats requires -d:p2tDewallHotStats".}

type TriKey = array[3, int]

proc key(tri: array[3, int]): TriKey =
  result = tri
  result.sort()

proc normalized(tris: seq[array[3, int]]): seq[TriKey] =
  for tri in tris:
    result.add key(tri)
  result.sort(
    proc(a, b: TriKey): int =
      for i in 0 ..< 3:
        let c = cmp(a[i], b[i])
        if c != 0:
          return c
      0
  )

proc readDat(name: string): seq[Vec2] =
  let path = currentSourcePath().parentDir / "fixtures" / name
  for line in lines(path):
    let trimmed = line.strip()
    if trimmed.len == 0:
      break
    let parts = trimmed.splitWhitespace()
    result.add vec2(parseFloat(parts[0]), parseFloat(parts[1]))

suite "DeWall hot stats":
  test "hot stats build matches normal triangulation":
    let pts = readDat("nazca_heron.dat")
    var options = defaultDewallOptions()
    options.parallel = false
    let hot = dewallTriangulateWithHotStats(pts, options)
    let normal = dewallTriangulateStatic[false](pts, options)

    check normalized(hot.triangles) == normalized(normal)
    check hot.stats.makeSimplexFastCalls > 0
    check hot.stats.candidateTests > 0
    check hot.stats.wallEdgesProcessed > 0
    check hot.stats.wallTrianglesEmitted > 0
