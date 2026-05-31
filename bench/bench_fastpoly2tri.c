#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <time.h>

#ifndef FAST_POLY2TRI_HEADER
#error "compile with -DFAST_POLY2TRI_HEADER=\"/path/to/MPE_fastpoly2tri.h\""
#endif

#define MPE_POLY2TRI_IMPLEMENTATION
#define MPE_POLY2TRI_USE_CUSTOM_SORT
#include FAST_POLY2TRI_HEADER

#define BENCH_ROUNDS 5

typedef struct BenchPoint {
  double x;
  double y;
} BenchPoint;

typedef struct BenchContour {
  BenchPoint *points;
  uint32_t count;
} BenchContour;

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

static void push_contour(MPEPolyContext *ctx, const BenchContour *contour) {
  MPEPolyPoint *points = MPE_PolyPushPointArray(ctx, contour->count);
  for (uint32_t i = 0; i < contour->count; ++i) {
    points[i].X = (poly_float)contour->points[i].x;
    points[i].Y = (poly_float)contour->points[i].y;
  }
}

static void bench_case(const char *name, const char *path, int iterations,
                       int add_dude_holes) {
  static const BenchPoint head_hole_points[] = {
      {325, 437}, {320, 423}, {329, 413}, {332, 423}};
  static const BenchPoint chest_hole_points[] = {
      {320.72342, 480},      {338.90617, 465.96863},
      {347.99754, 480.61584}, {329.8148, 510.41534},
      {339.91632, 480.11077}, {334.86556, 478.09046}};
  const BenchContour head_hole = {(BenchPoint *)head_hole_points, 4};
  const BenchContour chest_hole = {(BenchPoint *)chest_hole_points, 6};

  BenchContour outer = read_dat(path);
  uint32_t max_points = outer.count + (add_dude_holes ? 10u : 0u);
  size_t memory_size = MPE_PolyMemoryRequired(max_points);
  void *memory = calloc(memory_size, 1);
  if (!memory) {
    fprintf(stderr, "out of memory\n");
    exit(1);
  }

  double times[BENCH_ROUNDS];
  uint64_t reported_triangles = 0;
  for (int round = 0; round < BENCH_ROUNDS; ++round) {
    uint64_t triangles = 0;
    double start = now_seconds();
    for (int i = 0; i < iterations; ++i) {
      memset(memory, 0, memory_size);
      MPEPolyContext ctx;
      if (!MPE_PolyInitContext(&ctx, memory, max_points)) {
        fprintf(stderr, "failed to initialize fast-poly2tri context\n");
        exit(1);
      }

      push_contour(&ctx, &outer);
      MPE_PolyAddEdge(&ctx);
      if (add_dude_holes) {
        push_contour(&ctx, &head_hole);
        MPE_PolyAddHole(&ctx);
        push_contour(&ctx, &chest_hole);
        MPE_PolyAddHole(&ctx);
      }

      MPE_PolyTriangulate(&ctx);
      triangles += ctx.TriangleCount;
    }
    times[round] = (now_seconds() - start) * 1000000.0;
    reported_triangles = triangles;
  }
  sort_times(times, BENCH_ROUNDS);

  printf("%s: %d runs, %llu triangles, best %.0f us, median %.0f us\n", name,
         iterations, (unsigned long long)reported_triangles, times[0],
         times[BENCH_ROUNDS / 2]);

  free(memory);
  free(outer.points);
}

int main(void) {
#ifdef MPE_POLY2TRI_USE_DOUBLE
  const char *precision = "fast-poly2tri double";
#else
  const char *precision = "fast-poly2tri float";
#endif
  printf("%s\n", precision);
  bench_case("fixture-test", "tests/fixtures/test.dat", 10000, 0);
  bench_case("diamond", "tests/fixtures/diamond.dat", 10000, 0);
  bench_case("star", "tests/fixtures/star.dat", 10000, 0);
  bench_case("dude-with-holes", "tests/fixtures/dude.dat", 1000, 1);
  bench_case("nazca-monkey", "tests/fixtures/nazca_monkey.dat", 100, 0);
  bench_case("nazca-heron", "tests/fixtures/nazca_heron.dat", 100, 0);
  return 0;
}
