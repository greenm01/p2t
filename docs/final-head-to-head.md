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
vendored here because its license is not a fit for this repository. When it is
available, `benchCompareAll` runs Triangle's supported CDT construction switches
and reports the fastest valid Triangle result per fixture. The detailed tables
also show the fastest no-exact-arithmetic Triangle result as an explicitly
unsafe reference.

Earcut is intentionally excluded because it is not a constrained Delaunay
triangulation algorithm.

Champion Nim configuration:

- pointer arena CDT
- pdqsort active-point sort
- front hash default-on at `FrontHashMinPoints = 512`
- trusted and raw public API paths
- Tier 1 tuned release flags

The reference builds use the same release-codegen policy wherever it applies.
p2t's Nim builds use `--mm:arc --threads:off -d:release --opt:speed` plus Tier 1
tuning. C and C++ contenders are built with `-O3 -DNDEBUG -flto` plus the
platform-native CPU flag (`-mcpu=native` on Apple Silicon, `-march=native` on
x86) and linked with the same native/LTO flags; Nim wrappers that compile
reference C code also receive the Tier 1 C/link flags. Nim benchmark binaries
use `--panics:on`; standalone C/C++ references have no direct equivalent for
that Nim-specific lowering option.

Source checkouts are found from explicit environment variables first:
`FAST_POLY2TRI_DIR`, `LIBTESS2_DIR`, `TRIANGLE_DIR`, `DELABELLA_DIR`, `CDT_DIR`,
and `FADE2D_DIR`. `CC` and `CXX` override the C/C++ compilers. `P2T_FLAGS`
is appended to contender compile and link commands for platform-specific system
paths such as SDK include directories, library directories, and runtime linker
paths. The harness also checks `getTempDir()/p2t-contenders`; on Unix/macOS it
checks `/tmp/p2t-contenders` and `/private/tmp/p2t-contenders` for local
scratch checkouts.

The table reports best/median microseconds per triangulation. The `delta` column
is p2t raw's best-time advantage over the fastest non-p2t CDT reference for that
case. Benchmark binaries emit `config,...` rows before timing rows so the exact
backend switches and build flags stay attached to each run.

## Results

The faster `fast-poly2tri` float run stays in the table; the slower double
column is replaced by Triangle's per-fixture best configuration.

| Case | p2t raw | fast f32 | Triangle best | Triangle unsafe best | libtess2 | delta |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| fixture-test | 0.157 / 0.159 | 0.242 / 0.255 | 0.725 / 0.771 | 0.696 / 0.715 | 2.709 / 2.758 | +34.9% |
| diamond | 0.300 / 0.309 | 0.402 / 0.427 | 0.938 / 0.979 | 0.866 / 0.897 | 2.872 / 3.527 | +25.3% |
| star | 0.249 / 0.250 | 0.299 / 0.312 | 1.137 / 1.179 | 0.964 / 0.990 | 2.926 / 2.949 | +16.7% |
| dude-with-holes | 4.695 / 4.779 | 4.835 / 4.877 | 10.557 / 12.377 | 8.727 / 9.115 | 14.399 / 14.651 | +2.9% |
| nazca-monkey | 71.030 / 72.340 | 81.000 / 82.070 | 164.640 / 175.610 | 143.530 / 147.400 | 231.900 / 235.760 | +12.3% |
| nazca-heron | 56.860 / 59.530 | 68.730 / 72.250 | 134.870 / 140.060 | 102.930 / 105.130 | 206.570 / 211.700 | +17.3% |
| organic-large | 253.070 / 254.470 | failed | 863.350 / 883.830 | 573.380 / 616.140 | 1148.380 / 1152.980 | +55.9% vs Triangle unsafe |

Triangle switch winners for the raw/reference table:

| Case | Triangle best | Triangle unsafe best |
| --- | --- | --- |
| fixture-test | `plzQN` | `plzQNX` |
| diamond | `plzQN` | `plzQNX` |
| star | `pzQN` | `plzQNX` |
| dude-with-holes | `plzQN` | `plzQNX` |
| nazca-monkey | `pzQN` | `plzQNX` |
| nazca-heron | `plzQN` | `plzQNX` |
| organic-large | `plzQN` | `plzQNX` |

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

| Case | p2t trusted | fast f32 | Triangle best | Triangle unsafe best | libtess2 | delta |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| fixture-test | 0.196 / 0.196 | 0.242 / 0.255 | 0.725 / 0.771 | 0.696 / 0.715 | 2.709 / 2.758 | +18.9% vs fast f32 |
| diamond | 0.345 / 0.363 | 0.402 / 0.427 | 0.938 / 0.979 | 0.866 / 0.897 | 2.872 / 3.527 | +13.9% vs fast f32 |
| star | 0.292 / 0.298 | 0.299 / 0.312 | 1.137 / 1.179 | 0.964 / 0.990 | 2.926 / 2.949 | +2.2% vs fast f32 |
| dude-with-holes | 4.954 / 5.064 | 4.835 / 4.877 | 10.557 / 12.377 | 8.727 / 9.115 | 14.399 / 14.651 | -2.5% vs fast f32 |
| nazca-monkey | 74.540 / 75.630 | 81.000 / 82.070 | 164.640 / 175.610 | 143.530 / 147.400 | 231.900 / 235.760 | +8.0% vs fast f32 |
| nazca-heron | 63.270 / 63.760 | 68.730 / 72.250 | 134.870 / 140.060 | 102.930 / 105.130 | 206.570 / 211.700 | +7.9% vs fast f32 |
| organic-large | 267.560 / 268.260 | failed | 863.350 / 883.830 | 573.380 / 616.140 | 1148.380 / 1152.980 | +53.3% vs Triangle unsafe |

External contenders:

| Case | p2t trusted | Delabella | CDT | Fade2D | delta |
| --- | ---: | ---: | ---: | ---: | ---: |
| small-ui-quad | 0.101 / 0.124 | 0.241 / 0.255 | 1.605 / 1.749 | 2.580 / 2.911 | +58.3% vs Delabella |
| medium-icon | 2.504 / 2.726 | 67.174 / 67.445 | 30.555 / 31.165 | 290.432 / 291.244 | +91.8% vs CDT |
| large-shape | 39.010 / 40.838 | 510.266 / 579.064 | 403.342 / 429.738 | 2686.892 / 2687.568 | +90.3% vs CDT |
| fixture-test | 0.196 / 0.196 | 0.329 / 0.335 | 2.078 / 2.118 | 3.816 / 3.839 | +40.4% vs Delabella |
| diamond | 0.345 / 0.363 | 0.745 / 0.754 | 3.276 / 3.381 | 8.650 / 8.761 | +53.6% vs Delabella |
| star | 0.292 / 0.298 | 0.653 / 0.688 | 3.082 / 3.119 | 7.794 / 7.844 | +55.2% vs Delabella |
| dude-with-holes | 4.954 / 5.064 | 9.594 / 9.801 | 32.693 / 33.028 | 66.638 / 66.977 | +48.4% vs Delabella |
| nazca-monkey | 74.540 / 75.630 | 153.880 / 155.260 | 491.780 / 507.860 | 1190.120 / 1227.680 | +51.6% vs Delabella |
| nazca-heron | 63.270 / 63.760 | 118.770 / 120.610 | 409.030 / 417.270 | 943.200 / 983.560 | +46.7% vs Delabella |
| organic-large | 267.560 / 268.260 | 1125.050 / 1133.560 | 1784.250 / 1859.380 | 33969.460 / 34354.250 | +76.2% vs Delabella |

This is the honest public fast-path read: `tessellateTrusted` remains ahead of
fast-poly2tri f32 on every official fixture where fast-poly2tri completes except
the very close `dude-with-holes` case, while still paying to materialize the
public result.

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
  P2T_FLAGS="" \
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
