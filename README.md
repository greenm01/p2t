# p2t

![p2t triangulation mesh](tests/fixtures/dude-with-holes.png)

![p2t nazca monkey triangulation mesh](tests/fixtures/nazca_monkey.png)

[Fixture screenshots](tests/fixtures) show champion-path triangulation meshes for
the root fixtures.

`p2t` is a constrained Delaunay tessellation library for Nim.

Start here: [Public API guide](docs/public-api.md).

Algorithm guides: [Žalik sweep-line CDT](docs/zalik-sweep.md) and
[FlipScan constrained-edge insertion](docs/flipscan.md).

Nim is the superior code warrior's weapon of choice, but we provide a C ABI on the backend.

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
`fast-poly2tri` and libtess2, with Shewchuk's Triangle available as an optional
external backend. Times are best/median microseconds per triangulation, from
five sequential `nimble benchCompareAll` passes. Each cell uses the pass with
the lowest best time for that fixture/engine.

Benchmark machine:

- Mac mini (`Mac16,11`)
- Apple M4 Pro, 12 cores (8 performance, 4 efficiency)
- 24 GB memory
- macOS 26.5 (`25F71`), arm64
- Nim 2.2.10

Comparison dependencies are vendored in this repository:

- `fast-poly2tri` commit `c04c633f6e48fb4e79bd511f2c0bb46279fd5773`
- `libtess2` commit `8dbd6483e920311a58c9af10a10beb278efebc36`

Triangle is supported as an optional external benchmark backend via
`TRIANGLE_DIR`, but is not vendored because its license does not belong in this
repository. When present, `benchCompareAll` runs Triangle's supported CDT
construction switches and reports the fastest valid Triangle result per fixture.

Earcut is intentionally excluded because it is not a constrained Delaunay
triangulation algorithm.

Champion Nim configuration:

- pointer arena CDT
- pdqsort active-point sort
- front hash default-on at `FrontHashMinPoints = 512`
- trusted raw path
- Tier 1 tuned release flags

Head-to-head contender builds use equivalent host-tuned release codegen where
their toolchains support it: C/C++ references are built with `-O3 -DNDEBUG
-flto` plus the platform-native CPU flag (`-mcpu=native` on Apple Silicon,
`-march=native` on x86), and Nim benchmark binaries/wrappers receive the
matching C/link flags through the Tier 1 tuned flag bundle. Nim benchmark
binaries also use `--panics:on`; standalone C/C++ references have no direct
analogue for that Nim-specific lowering option.

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
| small-ui-quad | 0.216 / 0.231 | 0.101 / 0.124 | 0.083 / 0.099 |
| medium-icon | 3.525 / 3.712 | 2.504 / 2.726 | 2.264 / 2.401 |
| large-shape | 46.024 / 50.072 | 39.010 / 40.838 | 34.070 / 35.240 |
| fixture-test | 0.357 / 0.360 | 0.196 / 0.196 | 0.157 / 0.159 |
| diamond | 0.286 / 0.287 | 0.345 / 0.363 | 0.300 / 0.309 |
| star | 0.534 / 0.540 | 0.292 / 0.298 | 0.249 / 0.250 |
| dude-with-holes | 7.082 / 7.454 | 4.954 / 5.064 | 4.695 / 4.779 |
| nazca-monkey | 102.180 / 103.710 | 74.540 / 75.630 | 71.030 / 72.340 |
| nazca-heron | 83.240 / 85.880 | 63.270 / 63.760 | 56.860 / 59.530 |
| organic-large | 338.030 / 351.380 | 267.560 / 268.260 | 253.070 / 254.470 |

Raw-path head-to-head:

The faster `fast-poly2tri` float run stays in the table; the slower double
column is replaced by the per-fixture best Triangle configuration.

| Case | p2t raw | fast f32 | Triangle best | libtess2 | delta |
| --- | ---: | ---: | ---: | ---: | ---: |
| fixture-test | 0.157 / 0.159 | 0.242 / 0.255 | 0.725 / 0.771 | 2.709 / 2.758 | +34.9% |
| diamond | 0.300 / 0.309 | 0.402 / 0.427 | 0.938 / 0.979 | 2.872 / 3.527 | +25.3% |
| star | 0.249 / 0.250 | 0.299 / 0.312 | 1.137 / 1.179 | 2.926 / 2.949 | +16.7% |
| dude-with-holes | 4.695 / 4.779 | 4.835 / 4.877 | 10.557 / 12.377 | 14.399 / 14.651 | +2.9% |
| nazca-monkey | 71.030 / 72.340 | 81.000 / 82.070 | 164.640 / 175.610 | 231.900 / 235.760 | +12.3% |
| nazca-heron | 56.860 / 59.530 | 68.730 / 72.250 | 134.870 / 140.060 | 206.570 / 211.700 | +17.3% |
| organic-large | 253.070 / 254.470 | failed | 863.350 / 883.830 | 1148.380 / 1152.980 | +70.7% vs Triangle |

`fast-poly2tri` asserts in `MPE_EdgeEventPoints` on `organic-large`, so there is
no valid timing for that fixture. The Nim implementation, Triangle, and libtess2
all complete it.

External contenders:

This separate table uses `nimble benchExternalContenders`, which is intentionally
not part of the final `benchCompareAll` suite. Delabella and artem-ogre/CDT are
external source checkouts; Fade2D is the public 2.17.3 SDK and runs under its
student/non-commercial research license. The `delta` column is p2t raw's
best-time advantage over the fastest external contender for that case.
Full reproduction commands are in the
[final benchmark notes](docs/final-head-to-head.md).

| Case | p2t raw | Delabella | CDT | Fade2D | delta |
| --- | ---: | ---: | ---: | ---: | ---: |
| small-ui-quad | 0.083 / 0.099 | 0.241 / 0.255 | 1.605 / 1.749 | 2.580 / 2.911 | +65.4% vs Delabella |
| medium-icon | 2.264 / 2.401 | 67.174 / 67.445 | 30.555 / 31.165 | 290.432 / 291.244 | +92.6% vs CDT |
| large-shape | 34.070 / 35.240 | 510.266 / 579.064 | 403.342 / 429.738 | 2686.892 / 2687.568 | +91.6% vs CDT |
| fixture-test | 0.157 / 0.159 | 0.329 / 0.335 | 2.078 / 2.118 | 3.816 / 3.839 | +52.2% vs Delabella |
| diamond | 0.300 / 0.309 | 0.745 / 0.754 | 3.276 / 3.381 | 8.650 / 8.761 | +59.7% vs Delabella |
| star | 0.249 / 0.250 | 0.653 / 0.688 | 3.082 / 3.119 | 7.794 / 7.844 | +61.9% vs Delabella |
| dude-with-holes | 4.695 / 4.779 | 9.594 / 9.801 | 32.693 / 33.028 | 66.638 / 66.977 | +51.1% vs Delabella |
| nazca-monkey | 71.030 / 72.340 | 153.880 / 155.260 | 491.780 / 507.860 | 1190.120 / 1227.680 | +53.8% vs Delabella |
| nazca-heron | 56.860 / 59.530 | 118.770 / 120.610 | 409.030 / 417.270 | 943.200 / 983.560 | +52.1% vs Delabella |
| organic-large | 253.070 / 254.470 | 1125.050 / 1133.560 | 1784.250 / 1859.380 | 33969.460 / 34354.250 | +77.5% vs Delabella |

For the public fast path that materializes `TessResult.triangles`, see the
[`tessellateTrusted` benchmark](docs/final-head-to-head.md#trusted-public-api-check).

The short version: the optimized Nim path is ahead of the reference C
implementation on every fixture where `fast-poly2tri` completes, ahead of
Triangle, and much faster than libtess2 on this benchmark set. The large-input
front hash is a real win on organic large inputs; the sub-512 path is already
close to the useful limit, with legalization work dominating what remains.

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
nimble benchTrusted
nimble benchNormalizedTrusted
nimble benchExternalContenders
nimble benchParallel
nimble tidy
```

Benchmark comparisons use vendored `fast-poly2tri` and `libtess2` sources under
`vendor/` by default. Set `FAST_POLY2TRI_DIR`, `LIBTESS2_DIR`, or
`TRIANGLE_DIR` to compare against external checkouts. Triangle must contain
`triangle.c` and `triangle.h`; it is intentionally external-only.

The external contenders task also stays external-only. Set `DELABELLA_DIR`,
`CDT_DIR`, and `FADE2D_DIR` before running `nimble benchExternalContenders`.
Use `CC`/`CXX` to override the C/C++ compilers. Use `P2T_FLAGS` for
platform-specific include, library, and runtime-linker paths needed by local
SDKs, for example `-I/opt/foo/include -L/opt/foo/lib -Wl,-rpath,/opt/foo/lib`.
The harness also checks `getTempDir()/p2t-contenders`; on Unix/macOS it checks
`/tmp/p2t-contenders` and `/private/tmp/p2t-contenders` as convenience
fallbacks for local benchmark checkouts.

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
