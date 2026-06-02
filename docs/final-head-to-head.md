# Final Head-to-Head Benchmark

## Configuration

Command:

```sh
nimble benchCompareAll
```

Champion Nim configuration:

- pointer arena CDT
- pdqsort active-point sort
- front hash default-on at `FrontHashMinPoints = 512`
- trusted raw path
- Tier 1 tuned release flags

The table reports best/median microseconds per triangulation. The source
benchmark output uses different loop counts per fixture; these values normalize
back to one run.

## Results

| Fixture | Nim champion raw | fast-poly2tri f32 | fast-poly2tri f64 | libtess2 | Nim vs fastest ref |
| --- | ---: | ---: | ---: | ---: | ---: |
| fixture-test | 0.148 / 0.152 | 0.241 / 0.264 | 0.257 / 0.260 | 2.139 / 2.205 | +38.4% |
| diamond | 0.286 / 0.295 | 0.419 / 0.440 | 0.404 / 0.429 | 2.575 / 2.621 | +29.1% |
| star | 0.228 / 0.232 | 0.305 / 0.314 | 0.313 / 0.320 | 2.733 / 2.737 | +25.2% |
| dude-with-holes | 4.318 / 4.428 | 4.888 / 4.942 | 4.489 / 4.845 | 14.640 / 14.975 | +3.8% |
| nazca-monkey | 65.180 / 67.750 | 75.510 / 76.410 | 72.200 / 77.790 | 235.920 / 237.400 | +9.7% |
| nazca-heron | 52.870 / 55.130 | 66.210 / 66.920 | 65.910 / 67.450 | 203.630 / 205.810 | +19.8% |
| organic-large | 230.100 / 238.250 | failed | failed | 1188.930 / 1194.890 | +80.6% vs libtess2 |

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
