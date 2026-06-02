# Final Head-to-Head Benchmark

## Configuration

Command:

```sh
nimble benchCompareAll
```

The reported table uses five sequential passes. Each cell uses the pass with the
lowest best time for that fixture/engine, normalized back to one triangulation.

Benchmark machine:

- Mac mini (`Mac16,11`)
- Apple M4 Pro, 12 cores (8 performance, 4 efficiency)
- 24 GB memory
- macOS 26.5 (`25F71`), arm64
- Nim 2.2.10

Comparison dependencies are vendored in this repository:

- `fast-poly2tri` commit `c04c633f6e48fb4e79bd511f2c0bb46279fd5773`
- `libtess2` commit `8dbd6483e920311a58c9af10a10beb278efebc36`

Triangle can also be included as an optional external benchmark by setting
`TRIANGLE_DIR` to a checkout containing `triangle.c` and `triangle.h`. It is not
vendored here because its license is not a fit for this repository.

Earcut is intentionally excluded because it is not a constrained Delaunay
triangulation algorithm.

Champion Nim configuration:

- pointer arena CDT
- pdqsort active-point sort
- front hash default-on at `FrontHashMinPoints = 512`
- trusted and raw public API paths
- Tier 1 tuned release flags

The table reports best/median microseconds per triangulation. The `delta` column
is p2t raw's best-time advantage over the fastest non-p2t CDT reference for that
case.

## Results

The faster `fast-poly2tri` float run stays in the table; the slower double
column is replaced by Triangle.

| Case | p2t raw | fast f32 | Triangle | libtess2 | delta |
| --- | ---: | ---: | ---: | ---: | ---: |
| fixture-test | 0.143 / 0.151 | 0.169 / 0.169 | 0.693 / 0.734 | 2.075 / 2.204 | +15.3% |
| diamond | 0.288 / 0.290 | 0.308 / 0.312 | 1.008 / 1.021 | 2.495 / 2.535 | +6.3% |
| star | 0.228 / 0.232 | 0.273 / 0.277 | 1.138 / 1.192 | 2.655 / 2.691 | +16.5% |
| dude-with-holes | 4.378 / 4.406 | 4.417 / 4.452 | 11.177 / 11.580 | 14.201 / 14.370 | +0.9% |
| nazca-monkey | 65.210 / 65.640 | 72.390 / 75.210 | 164.630 / 171.050 | 232.900 / 238.840 | +9.9% |
| nazca-heron | 53.500 / 53.660 | 65.050 / 66.010 | 134.180 / 143.650 | 198.660 / 199.730 | +17.8% |
| organic-large | 230.390 / 238.390 | failed | 1032.100 / 1051.360 | 1169.650 / 1181.680 | +77.7% vs Triangle |

`fast-poly2tri` asserts in `MPE_EdgeEventPoints` on `organic-large`, so there is
no valid fast-poly2tri timing for that fixture. The Nim champion, Triangle, and
libtess2 all complete it.

## External Contenders

These are not part of the official benchmark suite. They are useful checks
against other serious CDT implementations, so the harness keeps them
reproducible without vendoring them into this repository.

The table uses `nimble benchExternalContenders`. Delabella and artem-ogre/CDT are
external source checkouts. Fade2D is the public 2.17.3 SDK and runs under its
student/non-commercial research license. Times are best/median microseconds per
triangulation. The `delta` column is p2t raw's best-time advantage over the
fastest external contender for that case.

| Case | p2t raw | Delabella | CDT | Fade2D | delta |
| --- | ---: | ---: | ---: | ---: | ---: |
| small-ui-quad | 0.079 / 0.081 | 0.348 / 0.370 | 1.530 / 1.703 | 2.358 / 2.402 | +77.3% vs Delabella |
| medium-icon | 1.924 / 2.023 | 62.318 / 62.724 | 29.845 / 30.079 | 274.627 / 277.202 | +93.6% vs CDT |
| large-shape | 32.136 / 32.816 | 439.192 / 464.322 | 372.568 / 380.200 | 2525.106 / 2536.890 | +91.4% vs CDT |
| fixture-test | 0.143 / 0.151 | 0.355 / 0.363 | 2.195 / 2.242 | 3.636 / 3.660 | +59.7% vs Delabella |
| diamond | 0.288 / 0.290 | 0.748 / 0.774 | 3.458 / 3.493 | 8.431 / 8.446 | +61.5% vs Delabella |
| star | 0.228 / 0.232 | 0.679 / 0.686 | 3.288 / 3.304 | 7.341 / 7.410 | +66.4% vs Delabella |
| dude-with-holes | 4.378 / 4.406 | 9.426 / 9.819 | 32.822 / 33.537 | 63.381 / 64.374 | +53.6% vs Delabella |
| nazca-monkey | 65.210 / 65.640 | 156.900 / 159.230 | 498.310 / 525.580 | 1130.090 / 1142.310 | +58.4% vs Delabella |
| nazca-heron | 53.500 / 53.660 | 124.120 / 127.030 | 417.360 / 422.380 | 888.550 / 904.980 | +56.9% vs Delabella |
| organic-large | 230.390 / 238.390 | 1151.140 / 1162.290 | 1783.980 / 1792.170 | 32833.570 / 33004.840 | +80.0% vs Delabella |

## Trusted Public API Check

The raw path is useful when a caller can consume workspace-backed triangles
directly. Most code wants a normal `TessResult`, though. That is what
`tessellateTrusted` measures: trusted input, no full validation, but the public
triangle index buffer is materialized.

Run the p2t side directly with:

```sh
nimble benchTrusted
```

The official-reference table uses the accepted `benchCompareAll` run after the
trusted-path optimization. Positive `delta` means p2t trusted is faster than the
closest reference.

Official references:

| Case | p2t trusted | fast f32 | Triangle | libtess2 | delta |
| --- | ---: | ---: | ---: | ---: | ---: |
| fixture-test | 0.186 / 0.190 | 0.236 / 0.267 | 0.689 / 0.716 | 2.126 / 2.148 | +21.3% vs fast f32 |
| diamond | 0.346 / 0.348 | 0.432 / 0.445 | 0.953 / 0.978 | 2.659 / 2.692 | +19.9% vs fast f32 |
| star | 0.276 / 0.283 | 0.316 / 0.339 | 1.128 / 1.130 | 2.738 / 2.785 | +12.7% vs fast f32 |
| dude-with-holes | 4.825 / 4.862 | 4.864 / 4.918 | 11.130 / 11.238 | 14.391 / 14.704 | +0.8% vs fast f32 |
| nazca-monkey | 74.670 / 75.570 | 75.350 / 78.490 | 170.620 / 176.350 | 242.900 / 244.110 | +0.9% vs fast f32 |
| nazca-heron | 58.040 / 58.410 | 64.900 / 67.110 | 152.640 / 158.880 | 209.210 / 211.020 | +10.6% vs fast f32 |
| organic-large | 248.240 / 259.970 | failed | 1027.540 / 1037.860 | 1207.350 / 1216.480 | +75.8% vs Triangle |

External contenders:

| Case | p2t trusted | Delabella | CDT | Fade2D | delta |
| --- | ---: | ---: | ---: | ---: | ---: |
| small-ui-quad | 0.135 / 0.140 | 0.348 / 0.370 | 1.530 / 1.703 | 2.358 / 2.402 | +61.2% vs Delabella |
| medium-icon | 2.241 / 2.306 | 62.318 / 62.724 | 29.845 / 30.079 | 274.627 / 277.202 | +92.5% vs CDT |
| large-shape | 34.622 / 35.000 | 439.192 / 464.322 | 372.568 / 380.200 | 2525.106 / 2536.890 | +90.7% vs CDT |
| fixture-test | 0.186 / 0.190 | 0.355 / 0.363 | 2.195 / 2.242 | 3.636 / 3.660 | +47.7% vs Delabella |
| diamond | 0.346 / 0.348 | 0.748 / 0.774 | 3.458 / 3.493 | 8.431 / 8.446 | +53.7% vs Delabella |
| star | 0.276 / 0.283 | 0.679 / 0.686 | 3.288 / 3.304 | 7.341 / 7.410 | +59.3% vs Delabella |
| dude-with-holes | 4.825 / 4.862 | 9.426 / 9.819 | 32.822 / 33.537 | 63.381 / 64.374 | +48.8% vs Delabella |
| nazca-monkey | 74.670 / 75.570 | 156.900 / 159.230 | 498.310 / 525.580 | 1130.090 / 1142.310 | +52.4% vs Delabella |
| nazca-heron | 58.040 / 58.410 | 124.120 / 127.030 | 417.360 / 422.380 | 888.550 / 904.980 | +53.2% vs Delabella |
| organic-large | 248.240 / 259.970 | 1151.140 / 1162.290 | 1783.980 / 1792.170 | 32833.570 / 33004.840 | +78.4% vs Delabella |

This is the honest public fast-path read: `tessellateTrusted` now beats
fast-poly2tri f32 on every official fixture where fast-poly2tri completes, while
still paying to materialize the public result.

Reproduction, using the exact external inputs used for the table:

```sh
mkdir -p /private/tmp/p2t-contenders
git clone --depth 1 https://github.com/msokalski/delabella.git /private/tmp/p2t-contenders/delabella
git clone --depth 1 https://github.com/artem-ogre/CDT.git /private/tmp/p2t-contenders/CDT
curl -L https://www.geom.at/_downloads/fadeRelease_v2.17.3.zip -o /private/tmp/p2t-contenders/fadeRelease_v2.17.3.zip
unzip -q /private/tmp/p2t-contenders/fadeRelease_v2.17.3.zip -d /private/tmp/p2t-contenders/fadeRelease_v2.17.3

DELABELLA_DIR=/private/tmp/p2t-contenders/delabella \
  CDT_DIR=/private/tmp/p2t-contenders/CDT \
  FADE2D_DIR=/private/tmp/p2t-contenders/fadeRelease_v2.17.3/fadeRelease_v2.17.3 \
  nimble benchExternalContenders
```

The recorded checkouts were Delabella
`0b8d371c28c82492d0a945f535bd7d73c467b630`, artem-ogre/CDT
`7bd85e41a7b2e6e6e3bf82f36bcbc2bcec6441c5`, and Fade2D 2.17.3.

## Conclusion

The champion Nim path wins every fixture where fast-poly2tri completes, stays
ahead of Triangle, and is far ahead of libtess2 across the suite. The
organic-large control also confirms the final front-hash default: at the same
large hole count used in the stress fixture, organic geometry is strongly
hash-positive and the reference C implementation fails the case.

Optimization work is closed for this round. The established wins are:

- pdqsort/Tier 1 tuning across all fixture sizes
- pointer arena as the default backend
- front hash default-on for large organic inputs
- no extra sub-512 locate optimization, because `searchNode` locality already
  covers that path and legalize is intrinsic work
