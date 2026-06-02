#!/usr/bin/env python3
"""
Generate an ORGANIC CONTROL fixture for the front-hash regression study.

Purpose: isolate ONE variable. The stress fixtures confound three things at
once -- large size, high hole density, AND an engineered x-density gradient +
axis-aligned periodicity designed to defeat the linear x-bucket hash. The
stress family showed the hash going net-negative and the gap widening with
size. We cannot tell whether that is caused by hole-density (a real default
concern) or by the engineered hostility (a torture-test artifact).

This generator HOLDS CONSTANT the two variables matched to stress-large:
  - total point count (~3340)
  - hole count (~287)
and REMOVES the two adversarial knobs:
  - no x-density gradient: boundary detail and holes are spatially UNIFORM in x
  - no axis-aligned periodicity: boundary is an organic midpoint-displacement
    (fractal coastline) loop; holes are scattered uniformly, not on a +x grid

Decision rule:
  - organic-large WINS or break-even for the hash  => the stress losses were the
    engineered x-skew. Default is safe; torture test did its job.
  - organic-large STILL LOSES for the hash         => hole-density staling
    buckets is a real effect at scale; revisit a hole-aware threshold.

Validates the rounded output before writing.
"""
import argparse, math, random, sys
from pathlib import Path

STRESS_DIR = Path(__file__).resolve().parents[1] / "stress"
sys.path.insert(0, str(STRESS_DIR))
from gen_fixture import signed_area, validate_fixture

def fractal_loop(n_pts, cx, cy, base_r, roughness, rng):
    """Organic closed boundary: sample n_pts angles around a circle and perturb
    the radius with summed octaves of noise (midpoint-displacement-like), so the
    outline has concavities and bays at multiple scales but NO periodicity and
    NO preferred x-direction. Returns CCW ring of (x,y).

    Radius perturbation is a sum of sinusoids with random phase/amplitude across
    several frequencies -- isotropic in angle, so detail density is uniform in x
    on average (the thing we are controlling for)."""
    # random multi-octave radial profile
    octaves = []
    for k in range(1, 7):
        amp = roughness * base_r * (0.5 ** (k - 1)) / k
        phase = rng.uniform(0, 2 * math.pi)
        octaves.append((k, amp, phase))
    pts = []
    for i in range(n_pts):
        a = 2 * math.pi * i / n_pts
        dr = 0.0
        for (k, amp, phase) in octaves:
            dr += amp * math.sin(k * a + phase)
        r = base_r + dr
        # keep strictly positive / bounded so the loop stays simple
        r = max(base_r * 0.35, min(base_r * 1.55, r))
        pts.append((cx + r * math.cos(a), cy + r * math.sin(a)))
    return pts

def poly_circle(cx, cy, r, n, ccw=False):
    pts = []
    for i in range(n):
        a = 2 * math.pi * i / n
        pts.append((cx + r * math.cos(a), cy + r * math.sin(a)))
    if not ccw:
        pts.reverse()   # holes wind opposite to outer
    return pts

def round_ring(ring, precision):
    return [(round(x, precision), round(y, precision)) for (x, y) in ring]

def point_in_ring(x, y, ring):
    """Ray cast; ring is list of (x,y)."""
    inside = False
    n = len(ring)
    j = n - 1
    for i in range(n):
        xi, yi = ring[i]; xj, yj = ring[j]
        if ((yi > y) != (yj > y)) and (x < (xj - xi) * (y - yi) / (yj - yi) + xi):
            inside = not inside
        j = i
    return inside

def min_dist_to_ring(x, y, ring):
    """Min distance from point to ring edges (for boundary clearance)."""
    best = float('inf')
    n = len(ring)
    for i in range(n):
        ax, ay = ring[i]; bx, by = ring[(i + 1) % n]
        dx, dy = bx - ax, by - ay
        L2 = dx * dx + dy * dy
        if L2 == 0:
            d = math.hypot(x - ax, y - ay)
        else:
            t = max(0.0, min(1.0, ((x - ax) * dx + (y - ay) * dy) / L2))
            px, py = ax + t * dx, ay + t * dy
            d = math.hypot(x - px, y - py)
        best = min(best, d)
    return best

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--total-pts", type=int, default=3340,
                    help="derive --outer-pts to hit this total given holes*sides")
    ap.add_argument("--outer-pts", type=int, default=None,
                    help="vertices on the organic outer boundary; overrides --total-pts")
    ap.add_argument("--holes", type=int, default=287)
    ap.add_argument("--hole-sides", type=int, default=6)
    ap.add_argument("--radius", type=float, default=900.0)
    ap.add_argument("--roughness", type=float, default=0.55)
    ap.add_argument("--seed", type=int, default=7)
    ap.add_argument("--precision", type=int, default=4)
    ap.add_argument("--out", default="cdt_organic_large.dat")
    args = ap.parse_args()

    if args.outer_pts is None:
        args.outer_pts = args.total_pts - args.holes * args.hole_sides
        if args.outer_pts < 16:
            ap.error(
                f"--total-pts {args.total_pts} too small for "
                f"{args.holes} holes x {args.hole_sides} sides"
            )

    rng = random.Random(args.seed)

    cx = cy = 0.0
    outer = fractal_loop(args.outer_pts, cx, cy, args.radius, args.roughness, rng)

    # bounding box of the organic outline
    xs = [p[0] for p in outer]; ys = [p[1] for p in outer]
    xmin, xmax, ymin, ymax = min(xs), max(xs), min(ys), max(ys)

    # scatter holes UNIFORMLY (rejection sampling) -- no +x clustering.
    holes = []
    centers = []
    hole_r = args.radius * 0.018          # small relative to domain
    clearance = hole_r * 1.8
    attempts = 0
    max_attempts = args.holes * 400
    while len(holes) < args.holes and attempts < max_attempts:
        attempts += 1
        x = rng.uniform(xmin, xmax)
        y = rng.uniform(ymin, ymax)
        r = hole_r * rng.uniform(0.7, 1.3)   # mild size variation, not x-correlated
        # must be inside outer with clearance from the boundary
        if not point_in_ring(x, y, outer):
            continue
        if min_dist_to_ring(x, y, outer) < r + clearance:
            continue
        ok = True
        for (ox, oy, orad) in centers:
            if math.hypot(x - ox, y - oy) < r + orad + clearance:
                ok = False; break
        if not ok:
            continue
        holes.append(poly_circle(x, y, r, args.hole_sides))
        centers.append((x, y, r))

    if len(holes) != args.holes:
        sys.exit(
            f"ERROR: placed {len(holes)}/{args.holes} holes; "
            f"adjust --radius or --holes for an exact control fixture"
        )

    outer = round_ring(outer, args.precision)
    holes = [round_ring(h, args.precision) for h in holes]

    total = len(outer) + sum(len(h) for h in holes)
    if args.total_pts == 3340 and args.holes == 287 and args.hole_sides == 6:
        if len(outer) != 1618 or len(holes) != 287 or total != 3340:
            sys.exit(
                "ERROR: organic-large control drifted: "
                f"outer={len(outer)} holes={len(holes)} total={total}"
            )

    validation_error = validate_fixture(outer, holes)
    if validation_error:
        sys.exit("INVALID: " + validation_error)

    area = abs(signed_area(outer)) - sum(abs(signed_area(h)) for h in holes)
    print(f"valid polygon, area={area:.0f}, "
          f"outer={len(outer)} pts, holes={len(holes)}, "
          f"total={total} pts", file=sys.stderr)

    with open(args.out, "w") as f:
        for (x, y) in outer:
            f.write(f"{x:.{args.precision}f} {y:.{args.precision}f}\n")
        for h in holes:
            f.write("\n")
            for (x, y) in h:
                f.write(f"{x:.{args.precision}f} {y:.{args.precision}f}\n")
    print(f"wrote {args.out}  ({total} pts, {len(holes)} holes)", file=sys.stderr)

if __name__ == "__main__":
    main()
