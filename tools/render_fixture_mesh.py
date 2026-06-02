#!/usr/bin/env python3
from __future__ import annotations

import argparse
import subprocess
from pathlib import Path

from PIL import Image, ImageDraw


ROOT = Path(__file__).resolve().parents[1]
FIXTURE_DIR = ROOT / "tests" / "fixtures"
CHAMPION_FLAGS = [
    "--mm:arc",
    "--threads:off",
    "-d:release",
    "--opt:speed",
    "-d:p2tArenaCdt",
    "-d:p2tUnsafeCdt",
    "-d:p2tFastRawCdt",
    "-d:nimPreviewFloatRoundtrip",
    "--panics:on",
    "--passC:-flto",
    "--passL:-flto",
    "--passC:-mcpu=native",
    "--passL:-mcpu=native",
]


def parse_mesh(text: str):
    outer: list[tuple[float, float]] = []
    holes: list[list[tuple[float, float]]] = []
    triangles: list[tuple[tuple[float, float], tuple[float, float], tuple[float, float]]] = []
    section = ""
    current_hole: list[tuple[float, float]] | None = None

    for raw_line in text.splitlines():
        line = raw_line.strip()
        if not line:
            current_hole = None
            continue
        if line == "outer":
            section = "outer"
            continue
        if line == "hole":
            section = "hole"
            current_hole = []
            holes.append(current_hole)
            continue
        if line == "triangles":
            section = "triangles"
            current_hole = None
            continue

        values = [float(part) for part in line.split()]
        if section == "outer":
            outer.append((values[0], values[1]))
        elif section == "hole":
            assert current_hole is not None
            current_hole.append((values[0], values[1]))
        elif section == "triangles":
            triangles.append(
                (
                    (values[0], values[1]),
                    (values[2], values[3]),
                    (values[4], values[5]),
                )
            )

    return outer, holes, triangles


def transform(points, bounds, size, padding):
    min_x, min_y, max_x, max_y = bounds
    width, height = size
    sx = (width - padding * 2) / (max_x - min_x)
    sy = (height - padding * 2) / (max_y - min_y)
    scale = min(sx, sy)
    used_w = (max_x - min_x) * scale
    used_h = (max_y - min_y) * scale
    ox = (width - used_w) * 0.5
    oy = (height - used_h) * 0.5

    def one(p):
        x, y = p
        return (ox + (x - min_x) * scale, oy + (max_y - y) * scale)

    return [one(p) for p in points]


def draw_polyline(draw: ImageDraw.ImageDraw, points, color, width):
    if len(points) < 2:
        return
    draw.line(points + [points[0]], fill=color, width=width, joint="curve")


def fixture_output_name(fixture: str) -> str:
    if fixture == "dude-with-holes":
        return "dude-with-holes.png"
    return Path(fixture).with_suffix(".png").name


def dump_mesh(fixture: str) -> str:
    return subprocess.check_output(
        [
            "nim",
            "r",
            "--path:src",
            "--nimcache:/private/tmp/p2t_fixture_mesh_nimcache",
            "--hints:off",
            "--warnings:off",
            *CHAMPION_FLAGS,
            "tools/dump_fixture_mesh.nim",
            fixture,
        ],
        cwd=ROOT,
        text=True,
    )


def render_fixture(fixture: str, out: Path, width: int, height: int, scale: int) -> None:
    outer, holes, triangles = parse_mesh(dump_mesh(fixture))
    all_points = outer + [p for hole in holes for p in hole]
    min_x = min(p[0] for p in all_points)
    min_y = min(p[1] for p in all_points)
    max_x = max(p[0] for p in all_points)
    max_y = max(p[1] for p in all_points)

    size = (width * scale, height * scale)
    padding = 56 * scale
    bounds = (min_x, min_y, max_x, max_y)

    img = Image.new("RGB", size, (0, 0, 0))
    draw = ImageDraw.Draw(img)
    red = (236, 34, 49)
    red_dim = (145, 18, 30)
    blue = (35, 132, 255)

    for tri in triangles:
        pts = transform(list(tri), bounds, size, padding)
        draw.line(pts + [pts[0]], fill=red_dim, width=max(1, scale))

    draw_polyline(draw, transform(outer, bounds, size, padding), blue, 4 * scale)
    for hole in holes:
        draw_polyline(draw, transform(hole, bounds, size, padding), blue, 3 * scale)

    radius = 3.2 * scale
    for x, y in transform(all_points, bounds, size, padding):
        draw.ellipse((x - radius, y - radius, x + radius, y + radius), fill=red)

    if scale != 1:
        img = img.resize((width, height), Image.Resampling.LANCZOS)

    if fixture == "dude-with-holes":
        img = img.rotate(180)

    out.parent.mkdir(parents=True, exist_ok=True)
    img.save(out)
    print(out.relative_to(ROOT))


def root_fixtures() -> list[str]:
    fixtures = [path.name for path in sorted(FIXTURE_DIR.glob("*.dat"))]
    fixtures.append("dude-with-holes")
    return fixtures


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("fixture", nargs="?", help="fixture .dat name or dude-with-holes")
    parser.add_argument("--all", action="store_true", help="render all root fixtures")
    parser.add_argument("--width", type=int, default=1600)
    parser.add_argument("--height", type=int, default=720)
    parser.add_argument("--scale", type=int, default=3, help="supersampling factor")
    args = parser.parse_args()

    fixtures = root_fixtures() if args.all else [args.fixture]
    if not fixtures or fixtures[0] is None:
        raise SystemExit("usage: render_fixture_mesh.py [--all|fixture.dat]")

    for fixture in fixtures:
        render_fixture(
            fixture,
            FIXTURE_DIR / fixture_output_name(fixture),
            args.width,
            args.height,
            args.scale,
        )


if __name__ == "__main__":
    main()
