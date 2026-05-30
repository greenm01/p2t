//! GPU-oriented polygon tessellator (work in progress).
//!
//! Goal: turn polygon contours (outer + holes) into a clean, non-overlapping
//! triangle mesh with good aspect ratios for single-pass GPU rendering -
//! unlike nanovg's overlapping stencil fan, and leaner than libtess2 by
//! specializing to valid simple polygons (no winding rules / self-intersection).
//!
//! Public API. Tests live in src/tests.zig.

const tri = @import("triangulate.zig");

/// Generic over coordinate type (f32/f64) and index type (u16/u32).
pub const Tessellator = tri.Tessellator;

/// Compact f32 / u32 vertices+indices, ideal for GPU upload.
pub const GpuTess = tri.GpuTess;

/// Double-precision f64 / u32.
pub const Tess = tri.Tess;
