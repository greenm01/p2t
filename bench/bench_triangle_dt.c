#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#ifndef REAL
#define REAL double
#endif

#ifndef TRIANGLE_SWITCHES
#define TRIANGLE_SWITCHES "zQ"
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

static int read_points(const char *path, BenchPoint **points_out) {
  FILE *f = fopen(path, "r");
  if (!f) {
    perror(path);
    exit(1);
  }

  int cap = 1024;
  int count = 0;
  BenchPoint *points = (BenchPoint *)malloc((size_t)cap * sizeof(BenchPoint));
  while (1) {
    BenchPoint p;
    int n = fscanf(f, "%lf %lf", &p.x, &p.y);
    if (n != 2) {
      break;
    }
    if (count == cap) {
      cap *= 2;
      points = (BenchPoint *)realloc(points, (size_t)cap * sizeof(BenchPoint));
    }
    points[count++] = p;
  }
  fclose(f);
  *points_out = points;
  return count;
}

static void init_input(const BenchPoint *points, int count,
                       struct triangulateio *input) {
  memset(input, 0, sizeof(*input));
  input->numberofpoints = count;
  input->pointlist = (REAL *)malloc((size_t)count * 2 * sizeof(REAL));
  for (int i = 0; i < count; ++i) {
    input->pointlist[i * 2 + 0] = points[i].x;
    input->pointlist[i * 2 + 1] = points[i].y;
  }
}

static void free_input(struct triangulateio *input) {
  free(input->pointlist);
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
}

static int triangle_once(struct triangulateio *input) {
  struct triangulateio output;
  memset(&output, 0, sizeof(output));
  triangulate(TRIANGLE_SWITCHES, input, &output, NULL);
  int triangles = output.numberoftriangles;
  free_output(&output);
  return triangles;
}

static void bench_case(const char *name, const char *fixture, int iterations) {
  BenchPoint *points = NULL;
  int count = read_points(fixture, &points);

  struct triangulateio input;
  init_input(points, count, &input);
  int validation = triangle_once(&input);
  if (validation <= 0) {
    fprintf(stderr, "%s failed Triangle DT validation\n", name);
    exit(1);
  }

  double times[BENCH_ROUNDS];
  unsigned long long reported_triangles = 0;
  for (int round = 0; round < BENCH_ROUNDS; ++round) {
    unsigned long long triangles = 0;
    double start = now_seconds();
    for (int i = 0; i < iterations; ++i) {
      triangles += (unsigned long long)triangle_once(&input);
    }
    times[round] = (now_seconds() - start) * 1000000.0;
    reported_triangles = triangles;
  }
  sort_times(times, BENCH_ROUNDS);

  printf("%s: %d runs, %llu triangles, best %.0f us, median %.0f us\n", name,
         iterations, reported_triangles, times[0], times[BENCH_ROUNDS / 2]);

  free_input(&input);
  free(points);
}

int main(int argc, char **argv) {
  const char *fixture =
      argc > 1 ? argv[1] : "tests/fixtures/nazca_heron.dat";
  int iterations = argc > 2 ? atoi(argv[2]) : 100;
  if (iterations <= 0) {
    iterations = 1;
  }

  printf("triangle-dt\n");
  printf("config,triangleSwitches,%s\n", TRIANGLE_SWITCHES);
  bench_case("nazca-heron", fixture, iterations);
  return 0;
}
