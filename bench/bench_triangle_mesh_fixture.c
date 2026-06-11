#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#ifndef REAL
#define REAL double
#endif

#ifndef TRIANGLE_SWITCHES
#define TRIANGLE_SWITCHES "pq30zQ"
#endif

#ifndef TRIANGLE_LABEL
#define TRIANGLE_LABEL "triangle-pq30zQ"
#endif

#include "triangle.h"

#define BENCH_ROUNDS 5

typedef struct BenchPoint {
  double x;
  double y;
} BenchPoint;

static double now_seconds(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (double)ts.tv_sec + (double)ts.tv_nsec * 1e-9;
}

static void sort_times(double *times, int count) {
  for (int i = 1; i < count; ++i) {
    double item = times[i];
    int j = i;
    while (j > 0 && item < times[j - 1]) {
      times[j] = times[j - 1];
      --j;
    }
    times[j] = item;
  }
}

static double orient(BenchPoint a, BenchPoint b, BenchPoint c) {
  return (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x);
}

static double triangle_area(BenchPoint a, BenchPoint b, BenchPoint c) {
  return fabs(orient(a, b, c)) * 0.5;
}

static double clamp_unit(double value) {
  if (value < -1.0) {
    return -1.0;
  }
  if (value > 1.0) {
    return 1.0;
  }
  return value;
}

static double distance_between(BenchPoint a, BenchPoint b) {
  double dx = a.x - b.x;
  double dy = a.y - b.y;
  return sqrt(dx * dx + dy * dy);
}

static double min_angle_degrees(BenchPoint a, BenchPoint b, BenchPoint c) {
  double ab = distance_between(a, b);
  double bc = distance_between(b, c);
  double ca = distance_between(c, a);
  if (ab == 0.0 || bc == 0.0 || ca == 0.0) {
    return 0.0;
  }

  double angle_a = acos(clamp_unit((ab * ab + ca * ca - bc * bc) /
                                   (2.0 * ab * ca)));
  double angle_b = acos(clamp_unit((ab * ab + bc * bc - ca * ca) /
                                   (2.0 * ab * bc)));
  double angle_c = acos(clamp_unit((ca * ca + bc * bc - ab * ab) /
                                   (2.0 * ca * bc)));
  double min_angle = fmin(angle_a, fmin(angle_b, angle_c));
  return min_angle * 180.0 / 3.14159265358979323846;
}

static double edge_ratio(BenchPoint a, BenchPoint b, BenchPoint c) {
  double ab = distance_between(a, b);
  double bc = distance_between(b, c);
  double ca = distance_between(c, a);
  double shortest = fmin(ab, fmin(bc, ca));
  double longest = fmax(ab, fmax(bc, ca));
  return shortest == 0.0 ? INFINITY : longest / shortest;
}

static double polygon_area(const BenchPoint *points, int count) {
  double twice = 0.0;
  for (int i = 0, j = count - 1; i < count; j = i++) {
    twice += points[j].x * points[i].y - points[i].x * points[j].y;
  }
  return fabs(twice) * 0.5;
}

static int read_points(const char *path, BenchPoint **points_out) {
  FILE *f = fopen(path, "r");
  if (!f) {
    perror(path);
    exit(1);
  }

  int cap = 1024;
  int count = 0;
  BenchPoint *points = (BenchPoint *)malloc((size_t)cap * sizeof(BenchPoint));
  if (!points) {
    fprintf(stderr, "out of memory\n");
    exit(1);
  }

  while (1) {
    BenchPoint p;
    int n = fscanf(f, "%lf %lf", &p.x, &p.y);
    if (n != 2) {
      break;
    }
    if (count == cap) {
      cap *= 2;
      points = (BenchPoint *)realloc(points, (size_t)cap * sizeof(BenchPoint));
      if (!points) {
        fprintf(stderr, "out of memory\n");
        exit(1);
      }
    }
    points[count++] = p;
  }
  fclose(f);
  *points_out = points;
  return count;
}

static int contains_segment(struct triangulateio *out, int a, int b) {
  for (int i = 0; i < out->numberofsegments; ++i) {
    int x = out->segmentlist[i * 2 + 0];
    int y = out->segmentlist[i * 2 + 1];
    if ((x == a && y == b) || (x == b && y == a)) {
      return 1;
    }
  }
  return 0;
}

static void init_input(const BenchPoint *points, int count, int boundary_count,
                       struct triangulateio *input) {
  if (boundary_count <= 0 || boundary_count > count) {
    boundary_count = count;
  }

  memset(input, 0, sizeof(*input));
  input->numberofpoints = count;
  input->pointlist = (REAL *)malloc((size_t)count * 2 * sizeof(REAL));
  input->pointmarkerlist = (int *)calloc((size_t)count, sizeof(int));
  input->numberofsegments = boundary_count;
  input->segmentlist =
      (int *)malloc((size_t)boundary_count * 2 * sizeof(int));
  input->segmentmarkerlist =
      (int *)calloc((size_t)boundary_count, sizeof(int));
  if (!input->pointlist || !input->pointmarkerlist || !input->segmentlist ||
      !input->segmentmarkerlist) {
    fprintf(stderr, "out of memory\n");
    exit(1);
  }

  for (int i = 0; i < count; ++i) {
    input->pointlist[i * 2 + 0] = points[i].x;
    input->pointlist[i * 2 + 1] = points[i].y;
    input->pointmarkerlist[i] = i < boundary_count ? 1 : 0;
  }
  for (int i = 0; i < boundary_count; ++i) {
    input->segmentlist[i * 2 + 0] = i;
    input->segmentlist[i * 2 + 1] = (i + 1) % boundary_count;
    input->segmentmarkerlist[i] = 1;
  }
}

static void free_input(struct triangulateio *input) {
  free(input->pointlist);
  free(input->pointmarkerlist);
  free(input->segmentlist);
  free(input->segmentmarkerlist);
  memset(input, 0, sizeof(*input));
}

static void triangle_free(void *ptr) {
  if (ptr != NULL) {
    trifree(ptr);
  }
}

static void free_output(struct triangulateio *output) {
  triangle_free(output->pointlist);
  triangle_free(output->pointattributelist);
  triangle_free(output->pointmarkerlist);
  triangle_free(output->trianglelist);
  triangle_free(output->triangleattributelist);
  triangle_free(output->trianglearealist);
  triangle_free(output->neighborlist);
  triangle_free(output->segmentlist);
  triangle_free(output->segmentmarkerlist);
  triangle_free(output->edgelist);
  triangle_free(output->edgemarkerlist);
  triangle_free(output->normlist);
  memset(output, 0, sizeof(*output));
}

static int triangle_once(struct triangulateio *input, int *output_points,
                         double *area, int *inverted,
                         int *missing_segments, double *min_angle,
                         double *mean_min_angle, double *max_edge_ratio,
                         double *mean_edge_ratio) {
  struct triangulateio output;
  memset(&output, 0, sizeof(output));
  triangulate(TRIANGLE_SWITCHES, input, &output, NULL);

  *output_points = output.numberofpoints;
  *area = 0.0;
  *inverted = 0;
  *min_angle = INFINITY;
  *mean_min_angle = 0.0;
  *max_edge_ratio = 0.0;
  *mean_edge_ratio = 0.0;
  for (int i = 0; i < output.numberoftriangles; ++i) {
    int a = output.trianglelist[i * output.numberofcorners + 0];
    int b = output.trianglelist[i * output.numberofcorners + 1];
    int c = output.trianglelist[i * output.numberofcorners + 2];
    BenchPoint pa = {output.pointlist[a * 2 + 0], output.pointlist[a * 2 + 1]};
    BenchPoint pb = {output.pointlist[b * 2 + 0], output.pointlist[b * 2 + 1]};
    BenchPoint pc = {output.pointlist[c * 2 + 0], output.pointlist[c * 2 + 1]};
    double tri_min_angle = min_angle_degrees(pa, pb, pc);
    double tri_edge_ratio = edge_ratio(pa, pb, pc);
    if (orient(pa, pb, pc) <= 0.0) {
      (*inverted)++;
    }
    *area += triangle_area(pa, pb, pc);
    if (tri_min_angle < *min_angle) {
      *min_angle = tri_min_angle;
    }
    if (tri_edge_ratio > *max_edge_ratio) {
      *max_edge_ratio = tri_edge_ratio;
    }
    *mean_min_angle += tri_min_angle;
    *mean_edge_ratio += tri_edge_ratio;
  }
  if (output.numberoftriangles > 0) {
    *mean_min_angle /= (double)output.numberoftriangles;
    *mean_edge_ratio /= (double)output.numberoftriangles;
  }

  *missing_segments = 0;
  for (int i = 0; i < input->numberofsegments; ++i) {
    if (!contains_segment(&output, i, (i + 1) % input->numberofsegments)) {
      (*missing_segments)++;
    }
  }

  int triangles = output.numberoftriangles;
  free_output(&output);
  return triangles;
}

int main(int argc, char **argv) {
  const char *fixture =
      argc > 1 ? argv[1] : "tests/fixtures/nazca_heron.dat";
  int iterations = argc > 2 ? atoi(argv[2]) : 100;
  int boundary_count = argc > 3 ? atoi(argv[3]) : 0;
  int point_limit = argc > 4 ? atoi(argv[4]) : 0;
  if (iterations <= 0) {
    iterations = 1;
  }

  BenchPoint *points = NULL;
  int count = read_points(fixture, &points);
  if (point_limit > 0 && point_limit < count) {
    count = point_limit;
  }
  if (boundary_count <= 0 || boundary_count > count) {
    boundary_count = count;
  }
  struct triangulateio input;
  init_input(points, count, boundary_count, &input);

  int output_points = 0;
  int inverted = 0;
  int missing_segments = 0;
  double area = 0.0;
  double min_angle = 0.0;
  double mean_min_angle = 0.0;
  double max_edge_ratio = 0.0;
  double mean_edge_ratio = 0.0;
  int validation_triangles =
      triangle_once(&input, &output_points, &area, &inverted,
                    &missing_segments, &min_angle, &mean_min_angle,
                    &max_edge_ratio, &mean_edge_ratio);
  double poly_area = polygon_area(points, boundary_count);
  if (validation_triangles <= 0 || inverted != 0) {
    fprintf(stderr, "%s failed validation\n", TRIANGLE_LABEL);
    return 1;
  }

  double times[BENCH_ROUNDS];
  uint64_t reported_triangles = 0;
  for (int round = 0; round < BENCH_ROUNDS; ++round) {
    uint64_t triangles = 0;
    double start = now_seconds();
    for (int i = 0; i < iterations; ++i) {
      int ignored_points = 0;
      int ignored_inverted = 0;
      int ignored_missing = 0;
      double ignored_area = 0.0;
      double ignored_min_angle = 0.0;
      double ignored_mean_min_angle = 0.0;
      double ignored_max_edge_ratio = 0.0;
      double ignored_mean_edge_ratio = 0.0;
      triangles += (uint64_t)triangle_once(
          &input, &ignored_points, &ignored_area, &ignored_inverted,
          &ignored_missing, &ignored_min_angle, &ignored_mean_min_angle,
          &ignored_max_edge_ratio, &ignored_mean_edge_ratio);
    }
    times[round] = (now_seconds() - start) * 1000000.0;
    reported_triangles = triangles;
  }
  sort_times(times, BENCH_ROUNDS);

  printf("%s\n", TRIANGLE_LABEL);
  printf("config,triangleSwitches,%s\n", TRIANGLE_SWITCHES);
  printf("fixture,%s\n", fixture);
  printf("inputPoints,%d\n", count);
  printf("boundaryPoints,%d\n", boundary_count);
  printf("outputPoints,%d\n", output_points);
  printf("triangles,%d\n", validation_triangles);
  printf("polygonArea,%.17g\n", poly_area);
  printf("triangleArea,%.17g\n", area);
  printf("areaError,%.17g\n", fabs(area - poly_area));
  printf("inverted,%d\n", inverted);
  printf("missingBoundarySegments,%d\n", missing_segments);
  printf("minAngleDeg,%.17g\n", min_angle);
  printf("meanMinAngleDeg,%.17g\n", mean_min_angle);
  printf("maxEdgeRatio,%.17g\n", max_edge_ratio);
  printf("meanEdgeRatio,%.17g\n", mean_edge_ratio);
  printf("%s: %d runs, %llu triangles, best %.0f us, median %.0f us\n",
         TRIANGLE_LABEL, iterations, (unsigned long long)reported_triangles,
         times[0], times[BENCH_ROUNDS / 2]);

  free_input(&input);
  free(points);
  return 0;
}
