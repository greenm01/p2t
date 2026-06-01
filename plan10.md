Let's add `eps` to the incircle check!
In `delaunay-cpp`:
```cpp
      if ((dist - tri.circle.radius) <= eps) {
```
This is equivalent to `incircle > -eps`.
Wait, `incircle` computes `area * distance`. The scale of `incircle` depends on the coordinates.
If coordinates are ~1000, `incircle` could be $1000^4 \approx 10^{12}$.
An absolute epsilon like `1e-4` on a $10^{12}$ scale is nothing.
We should use an epsilon relative to the scale, or just a small absolute epsilon if the scale is small.

Actually, the easiest way to avoid pinches without exact predicates is to use a robust BFS boundary extraction.
Wait! If we just build the triangles, and we get `NonManifoldEdge`, what if we just DEDUPLICATE the generated triangles?
No, if we generate 3 triangles that share edge `(8,3)`, which one do we keep? We can't just delete triangles, it leaves a hole in the mesh.

Let's rethink. If vertex 3 is a pinch point, the boundary touches vertex 3 multiple times.
When we connect the new point 8 to the boundary, we create a fan of triangles around 8.
If the boundary touches vertex 3 twice, we create TWO triangles that connect 8 to 3.
`(8, 3, 7)` and `(8, 4, 3)`.
Wait, if the boundary edges are `(3,7)` and `(4,3)`, the generated triangles are `(8,3,7)` and `(8,4,3)`.
Do `(8,3,7)` and `(8,4,3)` share the edge `(8,3)`?
Yes!
Wait. If they share the edge `(8,3)`, why is that non-manifold?
In a valid mesh, an internal edge CAN be shared by two triangles!
`NonManifoldEdge` means the edge is shared by MORE THAN TWO triangles!
Ah!
Tri 13 is `(8,3,7)`.
Tri 3 is `(1,3,8)`.
Tri 8 is `(3,4,8)`.
There are THREE triangles sharing edge `(8,3)`!
This means vertex 3 appears THREE times in the boundary!
`(3,7)`, `(1,3)`, `(3,4)`.
Is it possible for a simple polygon to visit a vertex 3 times? No.
Is it possible for a pinched polygon to visit a vertex 3 times? No, a single pinch means it visits it TWICE (like a figure-8).
To visit a vertex THREE times, there must be a triple pinch (like a cloverleaf)!
Why would there be a triple pinch?
Because `f128` incircle is completely breaking down, or there is a bug in the BFS.
