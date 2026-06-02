# Žalik sweep-line CDT

This is the high-level shape of the sweep-line part of Poly2Tri. It is not the
whole constrained triangulation story. The sweep builds and maintains the mesh.
FlipScan recovers constraint edges that the sweep cannot simply create on the
spot.

The sweep is useful because it keeps the problem local. Points are sorted from
bottom to top. At any step, the region below the current point has been
triangulated. The region above it has not. The boundary between those two regions
is the advancing front.

## State

The front is a linked list of nodes. Each node has a point, links to the previous
and next front nodes, and usually a triangle that touches the open side of the
front.

```nim
type FrontNode = object
  point: Point
  prev, next: FrontNode
  triangle: Triangle
```

The front is ordered by X. That makes point insertion cheap. Given a new point,
find the front node just to its left, form one triangle, then fix the small
mess that triangle creates.

```nim
type SweepState = object
  points: seq[Point]       # sorted by y, then x
  front: Front             # live lower boundary
  triangles: seq[Triangle]
  constrainedEdges: seq[Edge]
```

## Whole pass

The engine begins by collecting contour points and constrained edges. Each edge
is stored on its upper endpoint. That matters. The edge is only recovered after
both endpoints have entered the triangulation.

```nim
proc triangulate(input: CdtInput): Mesh =
  var ws = newSweepState(input)

  ws.sortPointsByYThenX()
  ws.createSeedTriangle()

  for p in ws.points[1 .. ^1]:
    let node = ws.insertPoint(p)
    ws.fillFrontAround(node)

    for edge in p.edgesEndingHere:
      ws.recoverConstrainedEdge(edge)

  result = ws.collectInteriorTriangles()
```

That is the sweep in one page. Locate. Insert. Fill. Legalize. Recover any
constraint that becomes possible.

## Seed triangle

The first real point cannot make a triangulation by itself. The engine creates
two artificial points below the input bounds and forms one large seed triangle.
Those artificial points are outside the final mesh.

```nim
proc createSeedTriangle(ws: var SweepState) =
  let bounds = ws.bounds()

  let tail = Point(
    x: bounds.minX - padding(bounds),
    y: bounds.minY - padding(bounds),
  )
  let head = Point(
    x: bounds.maxX + padding(bounds),
    y: bounds.minY - padding(bounds),
  )

  let first = ws.points[0]
  let tri = Triangle(first, tail, head)

  ws.front = linkedFront([tail, first, head], tri)
```

Now the front is a shallow V. Every later point is inserted above it.

## Locate

For a point `p`, the sweep finds the front interval under `p.x`. In plain terms:
walk left or right until `node.point.x <= p.x < node.next.point.x`.

```nim
proc locateNode(front: var Front, x: float): FrontNode =
  var node = front.searchNode

  if x < node.point.x:
    while x < node.point.x:
      node = node.prev
  else:
    while node.next != nil and x >= node.next.point.x:
      node = node.next

  front.searchNode = node
  result = node
```

The optimized engine may start from a front hash bucket instead of the last
search node. The concept is the same. The hash only gives a better first guess.

## Insert

Once the interval is found, the new point forms a triangle with the two front
points below it.

```nim
proc insertPoint(ws: var SweepState, p: Point): FrontNode =
  let n = ws.front.locateNode(p.x)

  let tri = Triangle(p, n.point, n.next.point)
  tri.linkNeighbor(n.triangle)
  ws.triangles.add tri

  let newNode = FrontNode(point: p, triangle: tri)
  ws.front.insertAfter(n, newNode)

  ws.legalize(tri)
  result = newNode
```

The front changes from this:

```text
n ----- n.next
```

to this:

```text
n ----- p ----- n.next
```

and the new triangle hangs below `p`.

## Fill

Insertion can leave dents in the front. A dent is a small cavity bounded by
three consecutive front nodes. If the local angle says the dent is safe to close,
the engine creates a triangle and removes the middle node from the front.

```nim
proc fill(ws: var SweepState, n: FrontNode) =
  let tri = Triangle(n.prev.point, n.point, n.next.point)
  tri.linkNeighbor(n.prev.triangle)
  tri.linkNeighbor(n.triangle)
  ws.triangles.add tri

  ws.front.remove(n)
  ws.legalize(tri)
```

Filling is repeated on both sides of the inserted point.

```nim
proc fillFrontAround(ws: var SweepState, n: FrontNode) =
  var right = n.next
  while right.next != nil and smallHoleCanBeFilled(right):
    ws.fill(right)
    right = right.next

  var left = n.prev
  while left.prev != nil and smallHoleCanBeFilled(left):
    ws.fill(left)
    left = left.prev

  if basinStartsAt(n):
    ws.fillBasin(n)
```

A basin is the same idea at a larger scale. The front has a visible low pocket.
The engine walks to the bottom of that pocket and fills upward until the pocket
is shallow enough to leave alone.

```nim
proc fillBasin(ws: var SweepState, n: FrontNode) =
  let basin = findBasinFrom(n)
  var x = basin.bottom

  while not basin.isShallowAt(x):
    ws.fill(x)

    if x.prev == basin.left and x.next == basin.right:
      break
    elif x.prev.point.y < x.next.point.y:
      x = x.prev
    else:
      x = x.next
```

The rule is conservative. Do not fill a large hole just because three nodes make
a triangle. Fill only when the local shape says it will not jump across a real
opening.

## Legalize

Every new triangle may violate the Delaunay condition with its neighbor. The
test is the usual incircle test: if the neighbor's opposite point lies inside the
triangle's circumcircle, flip the shared edge.

```nim
proc legalize(ws: var SweepState, t: Triangle) =
  for edge in t.edges:
    let other = t.neighborAcross(edge)
    if other == nil:
      continue

    if edge.isConstrained:
      continue

    let op = other.oppositePoint(edge)
    if incircle(t.oppositePoint(edge), edge.a, edge.b, op):
      ws.rotateTrianglePair(t, other)
      ws.legalize(t)
      ws.legalize(other)
```

This is local repair. A point insertion creates one triangle and a few filled
triangles. Legalization ripples only as far as needed.

Constrained edges are different. They are not flipped away. Once a polygon edge
or hole edge is marked constrained, it becomes a wall for Delaunay repair and
for final mesh collection.

## Constraints

The plain sweep does not guarantee that a polygon edge appears as a triangle
side. It only guarantees that both endpoints eventually exist in the mesh.

That is why edges are recovered when their upper endpoint is inserted:

```nim
proc afterPointInserted(ws: var SweepState, p: Point, n: FrontNode) =
  for edge in p.edgesEndingHere:
    if not ws.meshHasSide(edge.p, edge.q):
      ws.fillBesideEdge(edge, n)
      ws.flipScan(edge)
```

`fillBesideEdge` clears obvious front cavities beside the edge. `flipScan`
then walks through the triangles crossed by the edge and flips until the edge is
present. The details are in the
[FlipScan constrained-edge insertion note](flipscan.md).

## Finalization

At the end, the seed triangle and all exterior triangles are still present in
the working mesh. The engine starts from an interior triangle and flood-fills
through unconstrained edges. It collects only triangles reachable inside the
outer boundary and outside holes.

```nim
proc collectInteriorTriangles(ws: var SweepState): Mesh =
  var stack = @[ws.findInteriorStartTriangle()]

  while stack.len != 0:
    let t = stack.pop()
    if t.seen:
      continue

    t.seen = true
    result.add t

    for edge in t.edges:
      if not edge.isConstrained:
        stack.add t.neighborAcross(edge)
```

Constrained edges stop the flood. That is how the outer polygon and holes become
the final shape.

## What to remember

The sweep is not magic. It is a disciplined way to keep the active work small.

- Sort points bottom to top.
- Keep one advancing front between finished and unfinished space.
- Insert each point by making one triangle under it.
- Fill local dents in the front.
- Flip local edges until Delaunay is restored.
- Recover constraints after their upper endpoint is present.
- Flood from the inside and stop at constrained edges.

The result is a constrained Delaunay triangulation built mostly from short local
walks, small triangle rotations, and a front that stays easy to search.
