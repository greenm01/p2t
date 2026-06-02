# p2t

![p2t triangulation mesh](tests/fixtures/dude-with-holes.png)

![p2t nazca monkey triangulation mesh](tests/fixtures/nazca_monkey.png)

[Fixture screenshots](tests/fixtures) show champion-path triangulation meshes for
the root fixtures.

`p2t` is a constrained Delaunay tessellation library for Nim.

Start here: [Public API guide](docs/public-api.md).

Algorithm guides: [Žalik sweep-line CDT](docs/zalik-sweep.md) and
[FlipScan constrained-edge insertion](docs/flipscan.md).

Nim is the superior code warrior's weapon of choice, but for those who wish to
suffer we provide a C ABI on the backend.

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

The final comparison uses the public `import p2t` API against vendored
`fast-poly2tri` and libtess2. Times are best/median microseconds per
triangulation, derived from five sequential `nimble benchCompareAll` passes.
Each cell uses the pass with the lowest best time for that fixture/engine.

Benchmark machine:

- Mac mini (`Mac16,11`)
- Apple M4 Pro, 12 cores (8 performance, 4 efficiency)
- 24 GB memory
- macOS 26.5 (`25F71`), arm64
- Nim 2.2.10

Comparison dependencies are vendored in this repository:

- `fast-poly2tri` commit `c04c633f6e48fb4e79bd511f2c0bb46279fd5773`
- `libtess2` commit `8dbd6483e920311a58c9af10a10beb278efebc36`

Earcut is intentionally excluded because it is not a constrained Delaunay
triangulation algorithm.

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

Champion public-API results:

| Fixture | no-validate | trusted | raw |
| --- | ---: | ---: | ---: |
| small-ui-quad | 0.214 / 0.223 | 0.116 / 0.119 | 0.079 / 0.081 |
| medium-icon | 3.001 / 3.046 | 2.123 / 2.195 | 1.924 / 2.023 |
| large-shape | 42.238 / 43.006 | 35.382 / 36.308 | 32.136 / 32.816 |
| fixture-test | 0.328 / 0.329 | 0.198 / 0.203 | 0.143 / 0.151 |
| diamond | 0.254 / 0.256 | 0.337 / 0.351 | 0.288 / 0.290 |
| star | 0.495 / 0.502 | 0.287 / 0.294 | 0.228 / 0.232 |
| dude-with-holes | 6.919 / 7.058 | 4.951 / 5.099 | 4.378 / 4.406 |
| nazca-monkey | 94.310 / 96.130 | 70.730 / 72.170 | 65.210 / 65.640 |
| nazca-heron | 76.420 / 79.040 | 58.330 / 58.960 | 53.500 / 53.660 |
| organic-large | 310.390 / 314.660 | 249.770 / 250.840 | 230.390 / 238.390 |

Raw-path head-to-head:

| Case | p2t raw | fast f32 | fast f64 | libtess2 | delta |
| --- | ---: | ---: | ---: | ---: | ---: |
| fixture-test | 0.143 / 0.151 | 0.169 / 0.169 | 0.176 / 0.180 | 2.075 / 2.204 | +15.3% |
| diamond | 0.288 / 0.290 | 0.308 / 0.312 | 0.321 / 0.324 | 2.495 / 2.535 | +6.3% |
| star | 0.228 / 0.232 | 0.273 / 0.277 | 0.264 / 0.274 | 2.655 / 2.691 | +13.6% |
| dude-with-holes | 4.378 / 4.406 | 4.417 / 4.452 | 4.421 / 4.518 | 14.201 / 14.370 | +0.9% |
| nazca-monkey | 65.210 / 65.640 | 72.390 / 75.210 | 73.740 / 76.130 | 232.900 / 238.840 | +9.9% |
| nazca-heron | 53.500 / 53.660 | 65.050 / 66.010 | 65.800 / 68.870 | 198.660 / 199.730 | +17.8% |
| organic-large | 230.390 / 238.390 | failed | failed | 1169.650 / 1181.680 | +80.3% vs libtess2 |

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
nimble benchNormalizedTrusted
nimble benchParallel
nimble tidy
```

Benchmark comparisons use vendored `fast-poly2tri` and `libtess2` sources under
`vendor/` by default. Set `FAST_POLY2TRI_DIR` or `LIBTESS2_DIR` to compare
against external checkouts.

## References

The triangulation algorithm is the Poly2Tri advancing-front sweep-line CDT,
combining the sweep-line Delaunay base algorithm with Thomas Åhlén's "FlipScan"
constrained-edge insertion.

- [Public API guide](docs/public-api.md)
- [Žalik sweep-line CDT guide](docs/zalik-sweep.md)
- [FlipScan constrained-edge insertion spec](docs/flipscan.md)
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

BSD 3-Clause License. Copyright (c) 2009-2026 Mason Austin Green.
