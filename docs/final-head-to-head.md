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
no valid fast-poly2tri timing for that fixture. The Nim champion and libtess2
both complete it.

## Conclusion

The champion Nim path wins every fixture where fast-poly2tri completes and is
far ahead of libtess2 across the suite. The organic-large control also confirms
the final front-hash default: at the same large hole count used in the stress
fixture, organic geometry is strongly hash-positive and the reference C
implementation fails the case.

Optimization work is closed for this round. The established wins are:

- pdqsort/Tier 1 tuning across all fixture sizes
- pointer arena as the default backend
- front hash default-on for large organic inputs
- no extra sub-512 locate optimization, because `searchNode` locality already
  covers that path and legalize is intrinsic work
