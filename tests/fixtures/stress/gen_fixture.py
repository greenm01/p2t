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
hole) and validates with shapely that the outer ring is simple and holes are
disjoint + contained.

Scale with --teeth and --holes; default lands around ~4-6k points.
"""
import argparse, math, sys

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

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--teeth", type=int, default=60)
    ap.add_argument("--holes", type=int, default=40)
    ap.add_argument("--width", type=float, default=1000.0)
    ap.add_argument("--height", type=float, default=600.0)
    ap.add_argument("--out", default="cdt_stress.dat")
    args = ap.parse_args()

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

    # validate with shapely
    try:
        from shapely.geometry import Polygon
        poly = Polygon(outer, holes)
        if not poly.is_valid:
            from shapely.validation import explain_validity
            print("INVALID:", explain_validity(poly), file=sys.stderr)
            # try buffer(0) fix only for reporting; we still emit raw
        else:
            npts = len(outer) + sum(len(h) for h in holes)
            print(f"valid polygon, area={poly.area:.0f}, "
                  f"outer={len(outer)} pts, holes={len(holes)}, "
                  f"total={npts} pts", file=sys.stderr)
    except Exception as e:
        print("shapely check skipped:", e, file=sys.stderr)

    with open(args.out, "w") as f:
        for (x, y) in outer:
            f.write(f"{x:.4f} {y:.4f}\n")
        for h in holes:
            f.write("\n")
            for (x, y) in h:
                f.write(f"{x:.4f} {y:.4f}\n")
    print(f"wrote {args.out}", file=sys.stderr)

if __name__ == "__main__":
    main()
