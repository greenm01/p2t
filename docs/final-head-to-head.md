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
- trusted raw path
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
