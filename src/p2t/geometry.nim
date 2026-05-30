import std/[math, strformat]

import ./types

proc vec2*(x, y: float64): Vec2 =
  Vec2(x: x, y: y)

proc `+`*(a, b: Vec2): Vec2 =
  vec2(a.x + b.x, a.y + b.y)

proc `-`*(a, b: Vec2): Vec2 =
  vec2(a.x - b.x, a.y - b.y)

proc `*`*(a: Vec2, s: float64): Vec2 =
  vec2(a.x * s, a.y * s)

proc dot*(a, b: Vec2): float64 =
  a.x * b.x + a.y * b.y

proc cross*(a, b: Vec2): float64 =
  a.x * b.y - a.y * b.x

proc orient*(a, b, c: Vec2): float64 =
  cross(b - a, c - a)

proc dist2*(a, b: Vec2): float64 =
  let d = a - b
  dot(d, d)

proc almostEqual*(a, b: Vec2, eps: float64): bool =
  dist2(a, b) <= eps * eps

proc signedArea*(points: openArray[Vec2]): float64 =
  if points.len < 3:
    return 0
  for i in 0 ..< points.len:
    let j = (i + 1) mod points.len
    result += points[i].x * points[j].y - points[j].x * points[i].y
  result * 0.5

proc triangleArea*(a, b, c: Vec2): float64 =
  abs(orient(a, b, c)) * 0.5

proc polygonArea*(points: openArray[Vec2]): float64 =
  abs(signedArea(points))

proc ensureOrientation*(points: var seq[Vec2], ccw: bool) =
  let area = signedArea(points)
  if (ccw and area < 0) or ((not ccw) and area > 0):
    var i = 0
    var j = points.high
    while i < j:
      swap points[i], points[j]
      inc i
      dec j

proc pointOnSegment*(p, a, b: Vec2, eps: float64): bool =
  abs(orient(a, b, p)) <= eps and p.x >= min(a.x, b.x) - eps and
    p.x <= max(a.x, b.x) + eps and p.y >= min(a.y, b.y) - eps and
    p.y <= max(a.y, b.y) + eps

proc pointInPolygon*(p: Vec2, polygon: openArray[Vec2], eps: float64): bool =
  if polygon.len < 3:
    return false
  var inside = false
  var j = polygon.high
  for i in 0 ..< polygon.len:
    let a = polygon[i]
    let b = polygon[j]
    if pointOnSegment(p, a, b, eps):
      return true
    if ((a.y > p.y) != (b.y > p.y)):
      let x = (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x
      if p.x < x:
        inside = not inside
    j = i
  inside

proc segmentsIntersect*(a, b, c, d: Vec2, eps: float64): bool =
  let
    o1 = orient(a, b, c)
    o2 = orient(a, b, d)
    o3 = orient(c, d, a)
    o4 = orient(c, d, b)

  if pointOnSegment(c, a, b, eps) or pointOnSegment(d, a, b, eps) or
      pointOnSegment(a, c, d, eps) or pointOnSegment(b, c, d, eps):
    return true

  ((o1 > eps and o2 < -eps) or (o1 < -eps and o2 > eps)) and
    ((o3 > eps and o4 < -eps) or (o3 < -eps and o4 > eps))

proc cleanContour*(
    contour: TessContour, eps: float64, cleanInput: bool, error: var TessError
): seq[Vec2] =
  if contour.points.len == 0:
    error = tessError(tekEmptyOuter, contour.id, -1, "contour has no points")
    return @[]

  if not cleanInput:
    result = contour.points
  else:
    for i, p in contour.points:
      if result.len > 0 and almostEqual(result[^1], p, eps):
        continue
      result.add p
    if result.len > 1 and almostEqual(result[0], result[^1], eps):
      result.setLen(result.len - 1)

    var changed = true
    while changed and result.len >= 3:
      changed = false
      var filtered: seq[Vec2] = @[]
      for i in 0 ..< result.len:
        let
          prev = result[(i + result.len - 1) mod result.len]
          curr = result[i]
          next = result[(i + 1) mod result.len]
        if pointOnSegment(curr, prev, next, eps):
          changed = true
        else:
          filtered.add curr
      result = filtered

  if result.len < 3:
    error = tessError(
      tekTooFewVertices, contour.id, result.len, "contour has fewer than 3 vertices"
    )
    return @[]

  for i in 0 ..< result.len:
    if dist2(result[i], result[(i + 1) mod result.len]) <= eps * eps:
      error = tessError(tekDegenerateEdge, contour.id, i, "zero-length contour edge")
      return @[]
    for j in i + 1 ..< result.len:
      if almostEqual(result[i], result[j], eps):
        error =
          tessError(tekDuplicatePoint, contour.id, j, &"point {j} duplicates point {i}")
        return @[]

proc hasSelfIntersection*(
    points: openArray[Vec2], contourId: int, eps: float64, error: var TessError
): bool =
  if points.len < 4:
    return false
  for i in 0 ..< points.len:
    let
      iNext = (i + 1) mod points.len
      a = points[i]
      b = points[iNext]
    for j in i + 1 ..< points.len:
      let jNext = (j + 1) mod points.len
      if i == j or iNext == j or jNext == i:
        continue
      if i == 0 and jNext == 0:
        continue
      if segmentsIntersect(a, b, points[j], points[jNext], eps):
        error =
          tessError(tekSelfIntersection, contourId, i, &"edge {i} intersects edge {j}")
        return true
  false
