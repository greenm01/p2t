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
`nimble qualityLibtess2` reports the Delaunay triangle quality (angle
distribution, slivers, aspect ratio) of `p2t` against libtess2.

## References

The triangulation algorithm is the Poly2Tri advancing-front sweep-line CDT,
combining the sweep-line Delaunay base algorithm with Thomas Åhlén's "FlipScan"
constrained-edge insertion.

- Žalik, B. (2005). *An efficient sweep-line Delaunay triangulation algorithm.*
  Computer-Aided Design, 37(10), pp. 1027–1038.
  doi:[10.1016/j.cad.2004.10.004](https://doi.org/10.1016/j.cad.2004.10.004)
- Domiter, V. and Žalik, B. (2008). *Sweep-line algorithm for constrained
  Delaunay triangulation.* International Journal of Geographical Information
  Science, 22(4), pp. 449–462.
  doi:[10.1080/13658810701492241](https://doi.org/10.1080/13658810701492241)
- Shewchuk, J. R. (1996). *Triangle: Engineering a 2D Quality Mesh Generator and
  Delaunay Triangulator.* WACG 1996, LNCS 1148, Springer.
  [PDF](https://people.eecs.berkeley.edu/~jrs/papers/triangle.pdf)

## License

MIT License. Copyright (c) 2009-2026 Mason Austin Green.
