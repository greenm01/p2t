#ifndef P2T_H
#define P2T_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#if defined(_WIN32)
#  if defined(P2T_BUILD_SHARED)
#    define P2T_API __declspec(dllexport)
#  else
#    define P2T_API __declspec(dllimport)
#  endif
#else
#  define P2T_API
#endif

typedef struct p2t_context p2t_context;

/* 2D input or output coordinate. */
typedef struct p2t_vec2 {
  double x;
  double y;
} p2t_vec2;

/*
 * Closed contour. Do not repeat the first point at the end.
 *
 * `id` is copied into errors. `points` may be NULL only when `count` is zero.
 */
typedef struct p2t_contour {
  int32_t id;
  const p2t_vec2 *points;
  int32_t count;
} p2t_contour;

/* Runtime options for p2t_tessellate. Boolean fields use 0 = false, nonzero = true. */
typedef struct p2t_options {
  /* Geometric tolerance for cleanup and validation. */
  double epsilon;
  /* Remove duplicate closing points, adjacent duplicates, and collinear points. */
  int32_t clean_input;
  /* Include outer and hole boundary edges in p2t_result. */
  int32_t keep_boundary_edges;
  /* Validate self-intersections, hole placement, and Steiner containment. */
  int32_t validate;
} p2t_options;

/* Error kind values returned in p2t_error.kind. */
typedef enum p2t_error_kind {
  P2T_ERROR_NONE = 0,
  P2T_ERROR_EMPTY_OUTER = 1,
  P2T_ERROR_TOO_FEW_VERTICES = 2,
  P2T_ERROR_DUPLICATE_POINT = 3,
  P2T_ERROR_DEGENERATE_EDGE = 4,
  P2T_ERROR_SELF_INTERSECTION = 5,
  P2T_ERROR_INVALID_HOLE = 6,
  P2T_ERROR_TRIANGULATION_FAILED = 7,
  P2T_ERROR_INVALID_INPUT = 100
} p2t_error_kind;

/* Failure details. `message` is owned by the context or a static string. */
typedef struct p2t_error {
  int32_t kind;
  int32_t contour_id;
  int32_t point_index;
  const char *message;
} p2t_error;

/* Triangle indices into p2t_result.vertices. */
typedef struct p2t_triangle {
  int32_t a;
  int32_t b;
  int32_t c;
} p2t_triangle;

/* Boundary edge indices into p2t_result.vertices. */
typedef struct p2t_edge {
  int32_t a;
  int32_t b;
} p2t_edge;

/*
 * Tessellation result.
 *
 * Arrays are owned by the context and remain valid until the next call using
 * that context, p2t_clear, or p2t_destroy. Array pointers are NULL when the
 * matching count is zero.
 */
typedef struct p2t_result {
  int32_t ok;
  p2t_error error;
  const p2t_vec2 *vertices;
  int32_t vertex_count;
  const p2t_triangle *triangles;
  int32_t triangle_count;
  const p2t_edge *boundary_edges;
  int32_t boundary_edge_count;
} p2t_result;

/* Return the ABI version string. */
P2T_API const char *p2t_version(void);

/* Return the default checked tessellation options. */
P2T_API p2t_options p2t_default_options(void);

/* Allocate a reusable tessellation context. Destroy it with p2t_destroy. */
P2T_API p2t_context *p2t_create(void);

/* Destroy a context returned by p2t_create. Accepts NULL. */
P2T_API void p2t_destroy(p2t_context *ctx);

/* Clear cached result data and reusable workspace contents. Accepts NULL. */
P2T_API void p2t_clear(p2t_context *ctx);

/*
 * Checked tessellation entry point.
 *
 * `holes` may be NULL only when `hole_count` is zero. `steiner` may be NULL only
 * when `steiner_count` is zero. `options` may be NULL to use defaults.
 */
P2T_API p2t_result p2t_tessellate(
  p2t_context *ctx,
  p2t_contour outer,
  const p2t_contour *holes,
  int32_t hole_count,
  const p2t_vec2 *steiner,
  int32_t steiner_count,
  const p2t_options *options);

/*
 * Fast trusted tessellation entry point.
 *
 * The outer contour must be counterclockwise, holes must be clockwise, contours
 * must be clean and valid, and Steiner points must be inside the outer contour.
 * Pointer and result lifetime rules match p2t_tessellate.
 */
P2T_API p2t_result p2t_tessellate_trusted(
  p2t_context *ctx,
  p2t_contour outer,
  const p2t_contour *holes,
  int32_t hole_count,
  const p2t_vec2 *steiner,
  int32_t steiner_count,
  double epsilon);

/*
 * Trusted tessellation with cheap contour normalization.
 *
 * Removes adjacent duplicate points, a repeated closing point, and collinear
 * contour points. The remaining trusted preconditions still apply: outer CCW,
 * holes CW, simple valid contours, valid holes, and valid Steiner points.
 */
P2T_API p2t_result p2t_tessellate_normalized_trusted(
  p2t_context *ctx,
  p2t_contour outer,
  const p2t_contour *holes,
  int32_t hole_count,
  const p2t_vec2 *steiner,
  int32_t steiner_count,
  double epsilon);

#ifdef __cplusplus
}
#endif

#endif
