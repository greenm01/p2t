//! GPU-oriented polygon tessellator (work in progress).
//!
//! Goal: turn polygon contours (outer + holes) into a clean, non-overlapping
//! triangle mesh with good aspect ratios for single-pass GPU rendering -
//! unlike nanovg's overlapping stencil fan, and leaner than libtess2 by
//! specializing to valid simple polygons (no winding rules / self-intersection).
//!
//! Public API. Tests live in src/tests.zig.

const tri = @import("triangulate.zig");

pub const Vec2 = tri.Vec2;
pub const Mesh = tri.Mesh;
pub const triangulateSimple = tri.triangulateSimple;
