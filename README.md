# p2t

![p2t triangulation mesh](tests/fixtures/dude-with-holes.png)

![p2t nazca monkey triangulation mesh](tests/fixtures/nazca_monkey.png)

[Fixture screenshots](tests/fixtures) show champion-path triangulation meshes for
the root fixtures.

`p2t` is a constrained Delaunay tessellation library for Nim.

## About

I wrote the original Poly2Tri in fits and starts from 2008 to 2009. It began as
a small project on Google Code, which soon drew the attention of Thomas Åhlén.
Thomas contributed the FlipScan constrained-edge insertion idea, the part of the
algorithm that made the advancing-front sweep useful for real constrained
polygons. I ported the library to a few languages, lost interest, and moved on.

In 2026 I found myself back in hobby coding and back on GitHub. I was surprised
to see how many Poly2Tri descendants were still around. The one that caught my
attention was `fast-poly2tri`, because it is exactly what its name says: fast,
hard-optimized C, with arena pointers and tuned sorting.

These days Nim is my favorite language, so I wanted to see how far a Nim version
could be pushed on a single CPU thread. This repository is the result: the
Poly2Tri sweep-line CDT, rebuilt around a pointer arena, pdqsort, a large-input
front hash, and release-codegen tuning.

This level of optimization would have been hard for me to do alone now. I used
AI assistance for code reading, instrumentation, benchmark bookkeeping, and
working through the data. The code and the final engineering decisions remain my
responsibility.

## Final Head-to-Head

The final comparison uses the Nim champion path against `fast-poly2tri` and
libtess2. Times are best/median microseconds per triangulation.

Champion Nim configuration:

- pointer arena CDT
- pdqsort active-point sort
- front hash default-on at `FrontHashMinPoints = 512`
- trusted raw path
- Tier 1 tuned release flags

Fixture stats:

| Fixture | Points | Holes | Champion triangles | Notes |
| --- | ---: | ---: | ---: | --- |
| fixture-test | 6 | 0 | 4 | tiny smoke fixture |
| diamond | 10 | 0 | 8 | convex baseline |
| star | 10 | 0 | 8 | concave baseline |
| dude-with-holes | 104 | 2 | 106 | sub-512 hole fixture |
| nazca-monkey | 1,204 | 0 | 1,202 | large organic outline |
| nazca-heron | 1,036 | 0 | 1,034 | large organic outline |
| organic-large | 3,340 | 287 | 3,912 | matched organic control |

Performance results:

| Fixture | Nim champion raw | fast-poly2tri f32 | fast-poly2tri f64 | libtess2 |
| --- | ---: | ---: | ---: | ---: |
| fixture-test | 0.148 / 0.152 | 0.241 / 0.264 | 0.257 / 0.260 | 2.139 / 2.205 |
| diamond | 0.286 / 0.295 | 0.419 / 0.440 | 0.404 / 0.429 | 2.575 / 2.621 |
| star | 0.228 / 0.232 | 0.305 / 0.314 | 0.313 / 0.320 | 2.733 / 2.737 |
| dude-with-holes | 4.318 / 4.428 | 4.888 / 4.942 | 4.489 / 4.845 | 14.640 / 14.975 |
| nazca-monkey | 65.180 / 67.750 | 75.510 / 76.410 | 72.200 / 77.790 | 235.920 / 237.400 |
| nazca-heron | 52.870 / 55.130 | 66.210 / 66.920 | 65.910 / 67.450 | 203.630 / 205.810 |
| organic-large | 230.100 / 238.250 | failed | failed | 1188.930 / 1194.890 |

`fast-poly2tri` asserts in `MPE_EdgeEventPoints` on `organic-large`, so there is
no valid timing for that fixture. The Nim implementation and libtess2 both
complete it.

The short version: the optimized Nim path is ahead of the reference C
implementation on every fixture where `fast-poly2tri` completes, and much faster
than libtess2 on this benchmark set. The large-input front hash is a real win on
organic large inputs; the sub-512 path is already close to the useful limit, with
legalization work dominating what remains.

The `cleave` branch contains my sandbox experiments toward beating the
single-threaded CPU sweep-line CDT with more ambitious approaches, including
threaded ideas. I made a mess of it, and I did not beat the single-threaded path.
Poly2Tri is small, direct, and efficient enough that parallelizing a challenger
is not the easy win I hoped it might be. Maybe someone else will sort out the
hard parts someday. Or not. This is a hobby project.

## Commands

```sh
nimble test
nimble testLibtess2
nimble bench
nimble benchCompareAll
nimble benchLibtess2
nimble benchParallel
nimble tidy
```

## References

The triangulation algorithm is the Poly2Tri advancing-front sweep-line CDT,
combining the sweep-line Delaunay base algorithm with Thomas Åhlén's "FlipScan"
constrained-edge insertion.

- Žalik, B. (2005). *An efficient sweep-line Delaunay triangulation algorithm.*
  Computer-Aided Design, 37(10), pp. 1027–1038.
  doi:[10.1016/j.cad.2004.10.004](https://doi.org/10.1016/j.cad.2004.10.004)
- Domiter, V. and Žalik, B. (2008). *Sweep-line algorithm for constrained
  Delaunay triangulation.* International Journal of Geographical Information
  Science, 22(4), pp. 449–462.
  doi:[10.1080/13658810701492241](https://doi.org/10.1080/13658810701492241)
- Shewchuk, J. R. (1996). *Triangle: Engineering a 2D Quality Mesh Generator and
  Delaunay Triangulator.* WACG 1996, LNCS 1148, Springer.
  [PDF](https://people.eecs.berkeley.edu/~jrs/papers/triangle.pdf)

## License

BSD 2-Clause License. Copyright (c) 2009-2026 Mason Austin Green.
