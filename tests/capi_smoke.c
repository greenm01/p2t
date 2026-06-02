#include <math.h>
#include <stdio.h>

#include "p2t.h"

static double tri_area(p2t_vec2 a, p2t_vec2 b, p2t_vec2 c) {
  double cross =
      (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x);
  return fabs(cross) * 0.5;
}

static double result_area(p2t_result result) {
  double area = 0.0;
  for (int32_t i = 0; i < result.triangle_count; ++i) {
    p2t_triangle tri = result.triangles[i];
    area += tri_area(result.vertices[tri.a], result.vertices[tri.b],
                     result.vertices[tri.c]);
  }
  return area;
}

static int check(int condition, const char *message) {
  if (!condition) {
    fprintf(stderr, "%s\n", message);
    return 1;
  }
  return 0;
}

int main(void) {
  p2t_context *ctx = p2t_create();
  if (check(ctx != NULL, "p2t_create returned null")) return 1;

  p2t_vec2 square[] = {
      {0.0, 0.0},
      {4.0, 0.0},
      {4.0, 4.0},
      {0.0, 4.0},
  };
  p2t_contour outer = {1, square, 4};
  p2t_options options = p2t_default_options();
  options.keep_boundary_edges = 1;

  p2t_result result =
      p2t_tessellate(ctx, outer, NULL, 0, NULL, 0, &options);
  if (check(result.ok, "square tessellation failed")) return 1;
  if (check(result.vertex_count == 4, "unexpected square vertex count")) return 1;
  if (check(result.triangle_count == 2, "unexpected square triangle count")) return 1;
  if (check(result.boundary_edge_count == 4, "unexpected boundary edge count")) return 1;
  if (check(fabs(result_area(result) - 16.0) < 1e-9, "unexpected square area")) return 1;

  p2t_vec2 hole_points[] = {
      {1.0, 1.0},
      {1.0, 2.0},
      {2.0, 2.0},
      {2.0, 1.0},
  };
  p2t_contour hole = {2, hole_points, 4};
  result = p2t_tessellate(ctx, outer, &hole, 1, NULL, 0, &options);
  if (check(result.ok, "hole tessellation failed")) return 1;
  if (check(fabs(result_area(result) - 15.0) < 1e-9, "unexpected hole area")) return 1;

  p2t_contour invalid = {3, square, 2};
  result = p2t_tessellate(ctx, invalid, NULL, 0, NULL, 0, &options);
  if (check(!result.ok, "invalid contour unexpectedly succeeded")) return 1;
  if (check(result.error.kind == P2T_ERROR_TOO_FEW_VERTICES,
            "unexpected invalid contour error kind")) return 1;

  p2t_destroy(ctx);
  return 0;
}
