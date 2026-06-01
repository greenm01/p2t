import std/[math, monotimes, times]
import p2t

proc regularPolygon(n: int, radius: float64): seq[Vec2] =
  for i in 0 ..< n:
    let angle = 2.0 * PI * float64(i) / float64(n)
    result.add vec2(cos(angle) * radius, sin(angle) * radius)

var input = TessInput(outer: TessContour(id: 3, points: regularPolygon(512, 100)))
input.outer.points.ensureOrientation(ccw = true)

var workspace: TessWorkspace
var triangles = 0
let start = getMonoTime()
# Long enough for `sample` to collect a few thousand stacks.
for _ in 0 ..< 200000:
  let result = workspace.tessellateTrustedRaw(input)
  triangles += result.rawTriangleCount
echo "done ", triangles, " in ", inMilliseconds(getMonoTime() - start), " ms"
