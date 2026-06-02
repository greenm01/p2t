#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <time.h>

#ifndef REAL
#define REAL double
#endif

#include "triangle.h"

#define BENCH_ROUNDS 5

typedef struct BenchPoint {
  double x;
  double y;
} BenchPoint;

typedef struct BenchContour {
  BenchPoint *points;
  uint32_t count;
} BenchContour;

typedef struct BenchFixture {
  BenchContour *contours;
  uint32_t count;
} BenchFixture;

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

static int point_in_polygon(const BenchPoint *points, uint32_t count,
                            BenchPoint point) {
  int inside = 0;
  for (uint32_t i = 0, j = count - 1; i < count; j = i++) {
    BenchPoint a = points[i];
    BenchPoint b = points[j];
    int crosses = ((a.y > point.y) != (b.y > point.y));
    if (crosses) {
      double x = (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x;
      if (point.x < x) {
        inside = !inside;
      }
    }
  }
  return inside;
}

static BenchPoint polygon_average(const BenchContour *contour) {
  BenchPoint result = {0, 0};
  for (uint32_t i = 0; i < contour->count; ++i) {
    result.x += contour->points[i].x;
    result.y += contour->points[i].y;
  }
  result.x /= (double)contour->count;
  result.y /= (double)contour->count;
  return result;
}

static BenchPoint polygon_centroid(const BenchContour *contour) {
  double area2 = 0.0;
  BenchPoint centroid = {0, 0};
  for (uint32_t i = 0, j = contour->count - 1; i < contour->count; j = i++) {
    BenchPoint a = contour->points[j];
    BenchPoint b = contour->points[i];
    double cross = a.x * b.y - b.x * a.y;
    area2 += cross;
    centroid.x += (a.x + b.x) * cross;
    centroid.y += (a.y + b.y) * cross;
  }
  if (fabs(area2) < 1e-12) {
    return polygon_average(contour);
  }
  centroid.x /= 3.0 * area2;
  centroid.y /= 3.0 * area2;
  return centroid;
}

static BenchPoint hole_seed(const BenchContour *contour) {
  BenchPoint candidate = polygon_centroid(contour);
  if (point_in_polygon(contour->points, contour->count, candidate)) {
    return candidate;
  }

  candidate = polygon_average(contour);
  if (point_in_polygon(contour->points, contour->count, candidate)) {
    return candidate;
  }

  double min_x = contour->points[0].x;
  double max_x = contour->points[0].x;
  double min_y = contour->points[0].y;
  double max_y = contour->points[0].y;
  for (uint32_t i = 1; i < contour->count; ++i) {
    BenchPoint point = contour->points[i];
    if (point.x < min_x) {
      min_x = point.x;
    }
    if (point.x > max_x) {
      max_x = point.x;
    }
    if (point.y < min_y) {
      min_y = point.y;
    }
    if (point.y > max_y) {
      max_y = point.y;
    }
  }

  for (int y = 1; y < 32; ++y) {
    for (int x = 1; x < 32; ++x) {
      candidate.x = min_x + (max_x - min_x) * (double)x / 32.0;
      candidate.y = min_y + (max_y - min_y) * (double)y / 32.0;
      if (point_in_polygon(contour->points, contour->count, candidate)) {
        return candidate;
      }
    }
  }

  fprintf(stderr, "failed to find Triangle hole seed\n");
  exit(1);
}

static BenchContour read_dat(const char *path) {
  BenchContour result = {0};
  FILE *file = fopen(path, "r");
  if (!file) {
    fprintf(stderr, "failed to open %s\n", path);
    exit(1);
  }

  uint32_t cap = 128;
  result.points = (BenchPoint *)malloc(sizeof(BenchPoint) * cap);
  if (!result.points) {
    fprintf(stderr, "out of memory\n");
    exit(1);
  }

  char line[256];
  while (fgets(line, sizeof(line), file)) {
    double x, y;
    if (sscanf(line, "%lf %lf", &x, &y) != 2) {
      break;
    }
    if (result.count == cap) {
      cap *= 2;
      BenchPoint *grown =
          (BenchPoint *)realloc(result.points, sizeof(BenchPoint) * cap);
      if (!grown) {
        fprintf(stderr, "out of memory\n");
        exit(1);
      }
      result.points = grown;
    }
    result.points[result.count++] = (BenchPoint){x, y};
  }

  fclose(file);
  return result;
}

static void push_fixture_contour(BenchFixture *fixture, BenchContour contour) {
  if (contour.count == 0) {
    free(contour.points);
    return;
  }
  BenchContour *grown = (BenchContour *)realloc(
      fixture->contours, sizeof(BenchContour) * (fixture->count + 1));
  if (!grown) {
    fprintf(stderr, "out of memory\n");
    exit(1);
  }
  fixture->contours = grown;
  fixture->contours[fixture->count++] = contour;
}

static BenchFixture read_dat_rings(const char *path) {
  BenchFixture result = {0};
  FILE *file = fopen(path, "r");
  if (!file) {
    fprintf(stderr, "failed to open %s\n", path);
    exit(1);
  }

  BenchContour current = {0};
  uint32_t cap = 0;
  char line[256];
  while (fgets(line, sizeof(line), file)) {
    double x, y;
    if (sscanf(line, "%lf %lf", &x, &y) != 2) {
      push_fixture_contour(&result, current);
      current = (BenchContour){0};
      cap = 0;
      continue;
    }
    if (current.count == cap) {
      cap = cap == 0 ? 128 : cap * 2;
      BenchPoint *grown =
          (BenchPoint *)realloc(current.points, sizeof(BenchPoint) * cap);
      if (!grown) {
        fprintf(stderr, "out of memory\n");
        exit(1);
      }
      current.points = grown;
    }
    current.points[current.count++] = (BenchPoint){x, y};
  }
  push_fixture_contour(&result, current);
  fclose(file);

  if (result.count == 0) {
    fprintf(stderr, "empty fixture %s\n", path);
    exit(1);
  }
  return result;
}

static BenchContour regular_polygon(uint32_t count, double radius) {
  BenchContour result = {0};
  result.points = (BenchPoint *)malloc(sizeof(BenchPoint) * count);
  if (!result.points) {
    fprintf(stderr, "out of memory\n");
    exit(1);
  }
  result.count = count;
  for (uint32_t i = 0; i < count; ++i) {
    double angle = 2.0 * 3.14159265358979323846 * (double)i / (double)count;
    result.points[i] = (BenchPoint){cos(angle) * radius, sin(angle) * radius};
  }
  return result;
}

static BenchContour small_quad(void) {
  BenchContour result = {0};
  result.count = 4;
  result.points = (BenchPoint *)malloc(sizeof(BenchPoint) * result.count);
  if (!result.points) {
    fprintf(stderr, "out of memory\n");
    exit(1);
  }
  result.points[0] = (BenchPoint){0, 0};
  result.points[1] = (BenchPoint){100, 0};
  result.points[2] = (BenchPoint){100, 40};
  result.points[3] = (BenchPoint){0, 40};
  return result;
}

static void free_fixture(BenchFixture *fixture) {
  for (uint32_t i = 0; i < fixture->count; ++i) {
    free(fixture->contours[i].points);
  }
  free(fixture->contours);
  fixture->contours = NULL;
  fixture->count = 0;
}

static void init_triangle_input(const BenchFixture *fixture,
                                struct triangulateio *input) {
  memset(input, 0, sizeof(*input));

  uint32_t point_count = 0;
  uint32_t segment_count = 0;
  for (uint32_t i = 0; i < fixture->count; ++i) {
    point_count += fixture->contours[i].count;
    segment_count += fixture->contours[i].count;
  }

  input->numberofpoints = (int)point_count;
  input->pointlist = (REAL *)malloc(sizeof(REAL) * point_count * 2);
  input->numberofsegments = (int)segment_count;
  input->segmentlist = (int *)malloc(sizeof(int) * segment_count * 2);
  input->numberofholes = fixture->count > 0 ? (int)fixture->count - 1 : 0;
  if (input->numberofholes > 0) {
    input->holelist = (REAL *)malloc(sizeof(REAL) * (uint32_t)input->numberofholes * 2);
  }

  if (!input->pointlist || !input->segmentlist ||
      (input->numberofholes > 0 && !input->holelist)) {
    fprintf(stderr, "out of memory\n");
    exit(1);
  }

  uint32_t point_offset = 0;
  uint32_t segment_offset = 0;
  for (uint32_t contour_index = 0; contour_index < fixture->count; ++contour_index) {
    const BenchContour *contour = &fixture->contours[contour_index];
    for (uint32_t i = 0; i < contour->count; ++i) {
      input->pointlist[(point_offset + i) * 2] = (REAL)contour->points[i].x;
      input->pointlist[(point_offset + i) * 2 + 1] = (REAL)contour->points[i].y;
      input->segmentlist[(segment_offset + i) * 2] = (int)(point_offset + i);
      input->segmentlist[(segment_offset + i) * 2 + 1] =
          (int)(point_offset + ((i + 1) % contour->count));
    }
    if (contour_index > 0) {
      BenchPoint seed = hole_seed(contour);
      uint32_t hole_index = contour_index - 1;
      input->holelist[hole_index * 2] = (REAL)seed.x;
      input->holelist[hole_index * 2 + 1] = (REAL)seed.y;
    }
    point_offset += contour->count;
    segment_offset += contour->count;
  }
}

static void free_triangle_input(struct triangulateio *input) {
  free(input->pointlist);
  free(input->segmentlist);
  free(input->holelist);
  memset(input, 0, sizeof(*input));
}

static void triangle_free(void *ptr) {
  if (ptr) {
    trifree(ptr);
  }
}

static void free_triangle_output(struct triangulateio *output) {
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

static void bench_fixture(const char *name, int iterations, BenchFixture fixture) {
  struct triangulateio input;
  init_triangle_input(&fixture, &input);

  double times[BENCH_ROUNDS];
  uint64_t reported_triangles = 0;
  for (int round = 0; round < BENCH_ROUNDS; ++round) {
    uint64_t triangles = 0;
    double start = now_seconds();
    for (int i = 0; i < iterations; ++i) {
      struct triangulateio output;
      memset(&output, 0, sizeof(output));
      triangulate("pzQN", &input, &output, NULL);
      triangles += (uint64_t)output.numberoftriangles;
      free_triangle_output(&output);
    }
    times[round] = (now_seconds() - start) * 1000000.0;
    reported_triangles = triangles;
  }
  sort_times(times, BENCH_ROUNDS);

  printf("%s: %d runs, %llu triangles, best %.0f us, median %.0f us\n", name,
         iterations, (unsigned long long)reported_triangles, times[0],
         times[BENCH_ROUNDS / 2]);
  fflush(stdout);

  free_triangle_input(&input);
  free_fixture(&fixture);
}

static void bench_case(const char *name, const char *path, int iterations) {
  BenchFixture fixture = {0};
  push_fixture_contour(&fixture, read_dat(path));
  bench_fixture(name, iterations, fixture);
}

static void bench_contour(const char *name, int iterations, BenchContour contour) {
  BenchFixture fixture = {0};
  push_fixture_contour(&fixture, contour);
  bench_fixture(name, iterations, fixture);
}

static void bench_dude(void) {
  static const BenchPoint head_hole_points[] = {
      {325, 437}, {320, 423}, {329, 413}, {332, 423}};
  static const BenchPoint chest_hole_points[] = {
      {320.72342, 480},       {338.90617, 465.96863},
      {347.99754, 480.61584}, {329.8148, 510.41534},
      {339.91632, 480.11077}, {334.86556, 478.09046}};

  BenchFixture fixture = {0};
  push_fixture_contour(&fixture, read_dat("tests/fixtures/dude.dat"));

  BenchContour head_hole = {0};
  head_hole.count = 4;
  head_hole.points = (BenchPoint *)malloc(sizeof(head_hole_points));
  if (!head_hole.points) {
    fprintf(stderr, "out of memory\n");
    exit(1);
  }
  memcpy(head_hole.points, head_hole_points, sizeof(head_hole_points));
  push_fixture_contour(&fixture, head_hole);

  BenchContour chest_hole = {0};
  chest_hole.count = 6;
  chest_hole.points = (BenchPoint *)malloc(sizeof(chest_hole_points));
  if (!chest_hole.points) {
    fprintf(stderr, "out of memory\n");
    exit(1);
  }
  memcpy(chest_hole.points, chest_hole_points, sizeof(chest_hole_points));
  push_fixture_contour(&fixture, chest_hole);

  bench_fixture("dude-with-holes", 1000, fixture);
}

int main(void) {
  printf("triangle\n");
  fflush(stdout);
  bench_contour("small-ui-quad", 10000, small_quad());
  bench_contour("medium-icon", 2000, regular_polygon(48, 50));
  bench_contour("large-shape", 500, regular_polygon(512, 100));
  bench_case("fixture-test", "tests/fixtures/test.dat", 10000);
  bench_case("diamond", "tests/fixtures/diamond.dat", 10000);
  bench_case("star", "tests/fixtures/star.dat", 10000);
  bench_dude();
  bench_case("nazca-monkey", "tests/fixtures/nazca_monkey.dat", 100);
  bench_case("nazca-heron", "tests/fixtures/nazca_heron.dat", 100);
  bench_fixture(
      "organic-large", 100,
      read_dat_rings("tests/fixtures/organic/cdt_organic_large.dat"));
  return 0;
}
