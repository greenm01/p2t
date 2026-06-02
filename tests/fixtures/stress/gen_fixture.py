#!/usr/bin/env python3
"""
Generate a CDT stress fixture targeting the advancing-front 1D x-bucket hash's
specific weak points:

  1. Non-uniform x-density  -> linear x->bucket mapping over/under-resolves.
     We build a comb of vertical "fingers" whose spacing tightens toward +x,
     so the right half of the front has many nodes packed into few buckets.
  2. Deep concavity / non-monotone front -> "closest node to representative x"
     picks the wrong side; the comb teeth force the front to fold back on itself.
  3. Front-length swings -> teeth of varying height make the active front grow
     and shrink repeatedly during the sweep (staleness churn).
  4. Many holes -> forces front splits; each hole is an independent locate
     workload and stresses bucket staleness around the hole boundary.

Outputs a simple .dat (x y per line, blank line between outer ring and each
hole) and validates the rounded output coordinates before writing.

Scale with --teeth and --holes; default lands around ~4-6k points.
"""
import argparse, math, sys

EPS = 1e-9

PRESETS = {
    "small": dict(teeth=60, holes=40, width=1000.0, height=600.0),
    "mid": dict(teeth=180, holes=160, width=2000.0, height=1000.0),
    "large": dict(teeth=260, holes=320, width=2800.0, height=1400.0),
}

def comb_outline(teeth, width, height, tighten=3.0):
    """Outer boundary: a rectangle whose TOP edge is a comb of `teeth` slots.
    Tooth x-positions are spaced non-uniformly (denser toward +x) via a power
    curve, creating the non-uniform x-density that attacks the linear bucket map.
    Returns a list of (x,y) for a simple, CCW outer ring."""
    pts = []
    # bottom edge left->right
    pts.append((0.0, 0.0))
    pts.append((width, 0.0))
    # right edge up
    pts.append((width, height))
    # top edge right->left, cut by comb teeth (slots going DOWN into the body)
    # non-uniform tooth centers: t in (0,1), mapped by t**tighten so they bunch
    # near x=0 when we traverse right->left (i.e. dense region on one side).
    slot_w = (width / teeth) * 0.35
    # keep all slots strictly inside [margin, width-margin]
    margin = (width / teeth) * 0.5
    span = width - 2 * margin
    xs = []
    for i in range(teeth):
        t = (i + 0.5) / teeth
        xt = 1.0 - (1.0 - t) ** tighten
        xs.append(margin + xt * span)
    # per-tooth slot width: a fraction of the SMALLER neighbor gap, so densely
    # packed teeth on the +x side get narrow slots and never overlap.
    def local_gap(i):
        left = xs[i] - xs[i-1] if i > 0 else xs[1] - xs[0]
        right = xs[i+1] - xs[i] if i < teeth-1 else xs[-1] - xs[-2]
        return min(left, right)
    slot_ws = [min(slot_w, 0.6 * local_gap(i)) for i in range(teeth)]
    depth_base = height * 0.55
    # traverse top edge from right to left, dropping a slot at each tooth center.
    # NB: top-right corner (width,height) already appended above; do not repeat.
    for i in range(teeth - 1, -1, -1):
        cx = xs[i]
        # vary depth so the front length swings as the sweep crosses teeth
        depth = depth_base * (0.4 + 0.6 * abs(math.sin(i * 1.3)))
        left = cx - slot_ws[i] / 2
        right = cx + slot_ws[i] / 2
        # come along top to right wall of slot, dive down, across, back up
        pts.append((right, height))
        pts.append((right, height - depth))
        pts.append((left, height - depth))
        pts.append((left, height))
    pts.append((0.0, height))
    # close back to origin via left edge
    # (0,0) already first point; polygon closes implicitly)
    # dedupe consecutive duplicates
    out = []
    for p in pts:
        if not out or (abs(out[-1][0]-p[0])>1e-9 or abs(out[-1][1]-p[1])>1e-9):
            out.append(p)
    return out

def diamond_hole(cx, cy, r, n=8):
    """A small convex hole (CW winding for a hole)."""
    pts = []
    for i in range(n):
        a = 2*math.pi*i/n
        pts.append((cx + r*math.cos(a), cy + r*math.sin(a)))
    pts.reverse()  # holes opposite winding
    return pts

def round_ring(ring, precision):
    return [(round(x, precision), round(y, precision)) for (x, y) in ring]

def signed_area(points):
    area = 0.0
    for i, p in enumerate(points):
        q = points[(i + 1) % len(points)]
        area += p[0] * q[1] - q[0] * p[1]
    return area * 0.5

def orient(a, b, c):
    return (b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0])

def on_segment(p, a, b, eps=EPS):
    return (
        abs(orient(a, b, p)) <= eps
        and min(a[0], b[0]) - eps <= p[0] <= max(a[0], b[0]) + eps
        and min(a[1], b[1]) - eps <= p[1] <= max(a[1], b[1]) + eps
    )

def segments_intersect(a, b, c, d, eps=EPS):
    if (
        on_segment(c, a, b, eps)
        or on_segment(d, a, b, eps)
        or on_segment(a, c, d, eps)
        or on_segment(b, c, d, eps)
    ):
        return True
    o1 = orient(a, b, c)
    o2 = orient(a, b, d)
    o3 = orient(c, d, a)
    o4 = orient(c, d, b)
    return (
        ((o1 > eps and o2 < -eps) or (o1 < -eps and o2 > eps))
        and ((o3 > eps and o4 < -eps) or (o3 < -eps and o4 > eps))
    )

def point_in_polygon(p, polygon, eps=EPS):
    inside = False
    j = len(polygon) - 1
    for i, a in enumerate(polygon):
        b = polygon[j]
        if on_segment(p, a, b, eps):
            return True
        if (a[1] > p[1]) != (b[1] > p[1]):
            x = (b[0] - a[0]) * (p[1] - a[1]) / (b[1] - a[1]) + a[0]
            if p[0] < x:
                inside = not inside
        j = i
    return inside

def duplicate_point(ring):
    seen = {}
    for i, p in enumerate(ring):
        if p in seen:
            return seen[p], i, p
        seen[p] = i
    return None

def self_intersection(ring):
    n = len(ring)
    for i in range(n):
        a = ring[i]
        b = ring[(i + 1) % n]
        for j in range(i + 1, n):
            if i == j or (i + 1) % n == j or (j + 1) % n == i:
                continue
            c = ring[j]
            d = ring[(j + 1) % n]
            if segments_intersect(a, b, c, d):
                return i, j
    return None

def rings_intersect(a, b):
    for i in range(len(a)):
        a0 = a[i]
        a1 = a[(i + 1) % len(a)]
        for j in range(len(b)):
            b0 = b[j]
            b1 = b[(j + 1) % len(b)]
            if segments_intersect(a0, a1, b0, b1):
                return i, j
    return None

def validate_fixture(outer, holes):
    if len(outer) < 3:
        return "outer has fewer than 3 points"
    if signed_area(outer) <= 0:
        return "outer ring is not counter-clockwise"
    dup = duplicate_point(outer)
    if dup:
        return f"outer duplicate point {dup[2]} at {dup[0]} and {dup[1]}"
    hit = self_intersection(outer)
    if hit:
        return f"outer edge {hit[0]} intersects edge {hit[1]}"

    all_points = {p: ("outer", i) for i, p in enumerate(outer)}
    for h, hole in enumerate(holes):
        if len(hole) < 3:
            return f"hole {h} has fewer than 3 points"
        if signed_area(hole) >= 0:
            return f"hole {h} is not clockwise"
        dup = duplicate_point(hole)
        if dup:
            return f"hole {h} duplicate point {dup[2]} at {dup[0]} and {dup[1]}"
        for i, p in enumerate(hole):
            if p in all_points:
                return f"hole {h} point {i} duplicates {all_points[p]}"
            all_points[p] = (f"hole {h}", i)
        hit = self_intersection(hole)
        if hit:
            return f"hole {h} edge {hit[0]} intersects edge {hit[1]}"
        if not all(point_in_polygon(p, outer) for p in hole):
            return f"hole {h} has a point outside the outer contour"
        hit = rings_intersect(outer, hole)
        if hit:
            return f"outer edge {hit[0]} intersects hole {h} edge {hit[1]}"

    for i in range(len(holes)):
        for j in range(i + 1, len(holes)):
            if any(point_in_polygon(p, holes[i]) for p in holes[j]):
                return f"hole {j} is nested in hole {i}"
            hit = rings_intersect(holes[i], holes[j])
            if hit:
                return f"hole {i} edge {hit[0]} intersects hole {j} edge {hit[1]}"
    return None

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--preset", choices=sorted(PRESETS), default=None)
    ap.add_argument("--teeth", type=int, default=60)
    ap.add_argument("--holes", type=int, default=40)
    ap.add_argument("--width", type=float, default=1000.0)
    ap.add_argument("--height", type=float, default=600.0)
    ap.add_argument("--precision", type=int, default=8)
    ap.add_argument("--out", default="cdt_stress.dat")
    args = ap.parse_args()

    if args.preset:
        for key, value in PRESETS[args.preset].items():
            setattr(args, key, value)

    outer = comb_outline(args.teeth, args.width, args.height)

    # place holes in the lower band (below the comb slots) on a jittered grid,
    # clustered toward +x to compound the non-uniform density. Reject any hole
    # that would collide with another hole or sit too near the boundary, so the
    # polygon stays valid regardless of --holes/--teeth combos.
    holes = []
    centers = []  # (cx, cy, rad) accepted so far
    max_band_y = args.height * 0.42  # keep holes clear of the comb slots above
    cols = max(1, int(math.sqrt(args.holes) * 1.6))
    rows = max(1, math.ceil(args.holes / cols))
    placed = 0
    for r in range(rows):
        for c in range(cols):
            if placed >= args.holes: break
            t = (c + 0.5) / cols
            xt = 1.0 - (1.0 - t) ** 2.2
            cx = 50 + xt * (args.width - 100)
            cy = 35 + (r + 0.5) / rows * (max_band_y - 35)
            rad = 6 + 8 * ((c % 3) / 2.0)
            # reject if it overlaps an accepted hole (with a gap) or nears edges
            ok = cx - rad > 25 and cx + rad < args.width - 25 and cy - rad > 25
            if ok:
                for (ox, oy, orad) in centers:
                    if math.hypot(cx-ox, cy-oy) < rad + orad + 8.0:
                        ok = False
                        break
            if ok:
                holes.append(diamond_hole(cx, cy, rad, n=8))
                centers.append((cx, cy, rad))
            placed += 1

    outer = round_ring(outer, args.precision)
    holes = [round_ring(h, args.precision) for h in holes]

    validation_error = validate_fixture(outer, holes)
    if validation_error:
        print("INVALID:", validation_error, file=sys.stderr)
        sys.exit(1)

    npts = len(outer) + sum(len(h) for h in holes)
    area = abs(signed_area(outer)) - sum(abs(signed_area(h)) for h in holes)
    print(
        f"valid polygon, area={area:.0f}, outer={len(outer)} pts, "
        f"holes={len(holes)}, total={npts} pts",
        file=sys.stderr,
    )

    with open(args.out, "w") as f:
        for (x, y) in outer:
            f.write(f"{x:.{args.precision}f} {y:.{args.precision}f}\n")
        for h in holes:
            f.write("\n")
            for (x, y) in h:
                f.write(f"{x:.{args.precision}f} {y:.{args.precision}f}\n")
    print(f"wrote {args.out}", file=sys.stderr)

if __name__ == "__main__":
    main()
