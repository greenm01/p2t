import std/[os, strutils]

import p2t

proc contour(id: int, points: sink seq[Vec2]): TessContour =
  TessContour(id: id, points: points)

proc readDatPath(path: string): seq[seq[Vec2]] =
  var current: seq[Vec2]
  for line in lines(path):
    let trimmed = line.strip()
    if trimmed.len == 0:
      if current.len > 0:
        result.add current
        current.setLen(0)
      continue
    let parts = trimmed.splitWhitespace()
    current.add vec2(parseFloat(parts[0]), parseFloat(parts[1]))
  if current.len > 0:
    result.add current

proc oriented(input: TessInput): TessInput =
  result = input
  result.outer.points.ensureOrientation(ccw = true)
  for hole in result.holes.mitems:
    hole.points.ensureOrientation(ccw = false)

proc dudeWithHoles(): TessInput =
  let dudePath = currentSourcePath().parentDir.parentDir / "tests" / "fixtures" / "dude.dat"
  result.outer = contour(4, readDatPath(dudePath)[0])
  result.holes =
    @[
      contour(5, @[vec2(325, 437), vec2(320, 423), vec2(329, 413), vec2(332, 423)]),
      contour(
        6,
        @[
          vec2(320.72342, 480),
          vec2(338.90617, 465.96863),
          vec2(347.99754, 480.61584),
          vec2(329.8148, 510.41534),
          vec2(339.91632, 480.11077),
          vec2(334.86556, 478.09046),
        ],
      ),
    ]

proc inputFor(name: string): TessInput =
  if name == "dude-with-holes":
    return dudeWithHoles()

  let path =
    if name.isAbsolute:
      name
    else:
      currentSourcePath().parentDir.parentDir / "tests" / "fixtures" / name
  let rings = readDatPath(path)
  if rings.len == 0:
    quit("empty fixture: " & path, QuitFailure)

  result.outer = contour(1, rings[0])
  for i in 1 ..< rings.len:
    result.holes.add contour(i + 2, rings[i])

let args = commandLineParams()
if args.len != 1:
  quit("usage: dump_fixture_mesh <fixture.dat|dude-with-holes>", QuitFailure)

let input = inputFor(args[0])
var workspace: TessWorkspace
let raw = workspace.tessellateTrustedRaw(input.oriented())
when not defined(p2tFastRawCdt):
  if not raw.ok:
    quit(raw.error.message, QuitFailure)

echo "outer"
for p in input.outer.points:
  echo p.x, " ", p.y
echo ""

for hole in input.holes:
  echo "hole"
  for p in hole.points:
    echo p.x, " ", p.y
  echo ""

echo "triangles"
for i in 0 ..< raw.rawTriangleCount:
  let tri = raw.rawTriangleVertices(i)
  let
    a = tri[0]
    b = tri[1]
    c = tri[2]
  echo a.x, " ", a.y, " ", b.x, " ", b.y, " ", c.x, " ", c.y
