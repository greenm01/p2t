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

typedef struct p2t_vec2 {
  double x;
  double y;
} p2t_vec2;

typedef struct p2t_contour {
  int32_t id;
  const p2t_vec2 *points;
  int32_t count;
} p2t_contour;

typedef struct p2t_options {
  double epsilon;
  int32_t clean_input;
  int32_t keep_boundary_edges;
  int32_t validate;
} p2t_options;

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

typedef struct p2t_error {
  int32_t kind;
  int32_t contour_id;
  int32_t point_index;
  const char *message;
} p2t_error;

typedef struct p2t_triangle {
  int32_t a;
  int32_t b;
  int32_t c;
} p2t_triangle;

typedef struct p2t_edge {
  int32_t a;
  int32_t b;
} p2t_edge;

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

P2T_API const char *p2t_version(void);
P2T_API p2t_options p2t_default_options(void);
P2T_API p2t_context *p2t_create(void);
P2T_API void p2t_destroy(p2t_context *ctx);
P2T_API void p2t_clear(p2t_context *ctx);

P2T_API p2t_result p2t_tessellate(
  p2t_context *ctx,
  p2t_contour outer,
  const p2t_contour *holes,
  int32_t hole_count,
  const p2t_vec2 *steiner,
  int32_t steiner_count,
  const p2t_options *options);

P2T_API p2t_result p2t_tessellate_trusted(
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
