# Stress Fixture Profile

## Small Stress Fixture

`tests/fixtures/stress/cdt_stress.dat` is a blank-separated multi-ring fixture:
the first ring is the outer contour and the remaining rings are holes. The small
case has 244 outer vertices, 36 eight-point holes, 532 total ring vertices, and
602 output triangles.

The public safe path succeeds on the full ring set. Summing the emitted triangle
areas matches `outer area - hole areas` with zero observed error in the initial
run, so the check exercises the triangulator output rather than only the input
loader.

## Front Hash Result

This fixture is useful because it sits just over the default 512-point front-hash
threshold and contains many holes. On the champion path, the default hash cuts
locate work substantially:

| Config | Locate steps | Best raw us/run | Median raw us/run |
| --- | ---: | ---: | ---: |
| No front hash | 4,295 | 33.98 | 35.73 |
| Default hash, factor 2 | 1,803 | 35.56 | 36.53 |
| Bucket factor 4 | 1,334 | 35.79 | 36.08 |
| Scan radius 1 | 1,837 | 35.66 | 36.34 |
| Hash compiled, thresholded off at 1024 | 4,295 | 34.48 | 34.81 |

The per-lookup histograms say the hash hints are good: default hash hit 529 of
531 point events, direct hits averaged 2.75 post-hint walk steps, scan hits
averaged 1.78, and fallback happened only twice. Scan hits mostly came from
radius 1.

The wall-time result is different: at 532 points, maintaining and probing the
bucket index costs more than the saved front walks. This is an activation-policy
finding, not a hint-quality failure.

## Current Decision

Do not raise `FrontHashMinPoints` from this one small stress fixture. That would
overfit the threshold to one adversarial just-over-threshold case and risk
regressing the known 512-point `large-shape` win.

Keep the champion/default path unchanged until the mid and large stress fixtures
are measured. The bucket-factor-4 result is the main breadcrumb for the next
tuning pass: it improves locate steps here and previously looked promising on
Nazca, but it still needs cross-fixture timing before becoming a default.
