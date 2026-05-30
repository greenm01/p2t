# p2t

`p2t` is a backend-neutral polygon tessellation library for Nim.

The package intentionally has no dependency on Koi, Pixie, NanoVG, WGPU, WebGPU,
or a graphics backend. It accepts plain contours and returns plain vertices,
triangle indices, and optional boundary-edge metadata that a renderer can upload
to any backend.

## Status

This package implements validation, contour cleanup, and a Nim port of the
Poly2Tri advancing-front constrained-Delaunay triangulation algorithm behind the
public API planned for Koi's future vector renderer.

## Commands

```sh
nimble test
nimble testLibtess2
nimble bench
nimble benchLibtess2
nimble tidy
```

`nimble testLibtess2` compares the `dude.dat` fixture against a local libtess2
checkout. It auto-detects `~/src/libtess2` and `../libtess2`; otherwise set
`LIBTESS2_DIR=/path/to/libtess2`.
`nimble benchLibtess2` runs the same fixture as a release benchmark.

## License

MIT License. Copyright (c) 2009-2026 Mason Austin Green.
