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

static void free_fixture(BenchFixture *fixture) {
  for (uint32_t i = 0; i < fixture->count; ++i) {
    free(fixture->contours[i].points);
  }
  free(fixture->contours);
  fixture->contours = NULL;
  fixture->count = 0;
}

static void push_contour(MPEPolyContext *ctx, const BenchContour *contour) {
  MPEPolyPoint *points = MPE_PolyPushPointArray(ctx, contour->count);
  for (uint32_t i = 0; i < contour->count; ++i) {
    points[i].X = (poly_float)contour->points[i].x;
    points[i].Y = (poly_float)contour->points[i].y;
  }
}

static void bench_fixture(const char *name, int iterations, BenchFixture fixture) {
  uint32_t max_points = 0;
  for (uint32_t i = 0; i < fixture.count; ++i) {
    max_points += fixture.contours[i].count;
  }
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

      push_contour(&ctx, &fixture.contours[0]);
      MPE_PolyAddEdge(&ctx);
      for (uint32_t hole = 1; hole < fixture.count; ++hole) {
        push_contour(&ctx, &fixture.contours[hole]);
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
  fflush(stdout);

  free(memory);
  free_fixture(&fixture);
}

static void bench_case(const char *name, const char *path, int iterations) {
  BenchFixture fixture = {0};
  BenchContour outer = read_dat(path);
  push_fixture_contour(&fixture, outer);
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
#ifdef MPE_POLY2TRI_USE_DOUBLE
  const char *precision = "fast-poly2tri double";
#else
  const char *precision = "fast-poly2tri float";
#endif
  printf("%s\n", precision);
  fflush(stdout);
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
