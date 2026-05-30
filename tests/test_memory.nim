import std/[os, strutils, unittest]

import p2t

proc readDat(name: string): seq[Vec2] =
  let path = currentSourcePath().parentDir / "fixtures" / name
  for line in lines(path):
    let trimmed = line.strip()
    if trimmed.len == 0:
      break
    let parts = trimmed.splitWhitespace()
    result.add vec2(parseFloat(parts[0]), parseFloat(parts[1]))

suite "p2t memory":
  test "repeated large tessellation keeps allocator use bounded":
    let input =
      TessInput(outer: TessContour(id: 1, points: readDat("nazca_monkey.dat")))
    var workspace: TessWorkspace

    for _ in 0 ..< 10:
      let result = workspace.tessellate(input)
      check result.ok

    when declared(getOccupiedMem):
      let baseline = getOccupiedMem()
      for _ in 0 ..< 30:
        let result = workspace.tessellate(input)
        check result.ok
      let after = getOccupiedMem()
      check after <= baseline + 2 * 1024 * 1024
    else:
      for _ in 0 ..< 30:
        let result = workspace.tessellate(input)
        check result.ok
