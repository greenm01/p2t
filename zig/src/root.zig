//! GPU-oriented polygon tessellator (work in progress).
//!
//! Goal: turn polygon contours (outer + holes) into a clean, non-overlapping
//! triangle mesh with good aspect ratios for single-pass GPU rendering -
//! unlike nanovg's overlapping stencil fan, and leaner than libtess2 by
//! specializing to valid simple polygons (no winding rules / self-intersection).
//!
//! Public API. Tests live in src/tests.zig.

const tri = @import("triangulate.zig");
const fill = @import("fill_tess.zig");
const fist = @import("fist_earcut.zig");

/// Generic over coordinate type (f32/f64) and index type (u16/u32).
pub const Tessellator = tri.Tessellator;

/// Compact f32 / u32 vertices+indices, ideal for GPU upload.
pub const GpuTess = tri.GpuTess;

/// Double-precision f64 / u32.
pub const Tess = tri.Tess;

/// Generic immediate-mode GPU fill tessellator workspace.
pub const FillTessellator = fill.FillTessellator;

/// GPU-oriented f32 / u32 fill tessellator workspace.
pub const GpuFillTess = fill.GpuFillTess;

/// Default fill tessellator workspace.
pub const FillTess = fill.FillTess;

/// Experimental FIST/Mapbox-Earcut style raw seed triangulator.
pub const FistEarcut = fist.FistEarcut;

/// Compact f32 / u32 experimental FIST/Earcut seed.
pub const GpuFistEarcut = fist.FistEarcut(GpuFillTess.Vec, u32);
