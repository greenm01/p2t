#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifndef REAL
#define REAL double
#endif

#ifndef TRIANGLE_SWITCHES
#define TRIANGLE_SWITCHES "pzQ"
#endif

#include "triangle.h"

typedef struct BenchPoint {
  double x;
  double y;
} BenchPoint;

typedef struct TriKey {
  int a;
  int b;
  int c;
} TriKey;

static double orient(BenchPoint a, BenchPoint b, BenchPoint c) {
  return (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x);
}

static double triangle_area(BenchPoint a, BenchPoint b, BenchPoint c) {
  return fabs(orient(a, b, c)) * 0.5;
}

static double polygon_area(BenchPoint *points, int count) {
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

static void sort3(int *a, int *b, int *c) {
  int tmp;
  if (*a > *b) {
    tmp = *a;
    *a = *b;
    *b = tmp;
  }
  if (*b > *c) {
    tmp = *b;
    *b = *c;
    *c = tmp;
  }
  if (*a > *b) {
    tmp = *a;
    *a = *b;
    *b = tmp;
  }
}

static int compare_trikeys(const void *lhs, const void *rhs) {
  const TriKey *a = (const TriKey *)lhs;
  const TriKey *b = (const TriKey *)rhs;
  if (a->a != b->a) {
    return a->a < b->a ? -1 : 1;
  }
  if (a->b != b->b) {
    return a->b < b->b ? -1 : 1;
  }
  if (a->c != b->c) {
    return a->c < b->c ? -1 : 1;
  }
  return 0;
}

static void write_trikeys(const char *path, struct triangulateio *out) {
  TriKey *keys =
      (TriKey *)malloc((size_t)out->numberoftriangles * sizeof(TriKey));
  for (int i = 0; i < out->numberoftriangles; ++i) {
    keys[i].a = out->trianglelist[i * out->numberofcorners + 0];
    keys[i].b = out->trianglelist[i * out->numberofcorners + 1];
    keys[i].c = out->trianglelist[i * out->numberofcorners + 2];
    sort3(&keys[i].a, &keys[i].b, &keys[i].c);
  }
  qsort(keys, (size_t)out->numberoftriangles, sizeof(TriKey), compare_trikeys);

  FILE *f = fopen(path, "w");
  if (!f) {
    perror(path);
    exit(1);
  }
  for (int i = 0; i < out->numberoftriangles; ++i) {
    fprintf(f, "%d %d %d\n", keys[i].a, keys[i].b, keys[i].c);
  }
  fclose(f);
  free(keys);
}

static void free_output(struct triangulateio *out) {
  trifree(out->pointlist);
  trifree(out->pointattributelist);
  trifree(out->pointmarkerlist);
  trifree(out->trianglelist);
  trifree(out->triangleattributelist);
  trifree(out->trianglearealist);
  trifree(out->neighborlist);
  trifree(out->segmentlist);
  trifree(out->segmentmarkerlist);
  trifree(out->edgelist);
  trifree(out->edgemarkerlist);
  trifree(out->normlist);
}

int main(int argc, char **argv) {
  const char *input_path =
      argc > 1 ? argv[1] : "tests/fixtures/nazca_heron.dat";
  const char *keys_path = argc > 2 ? argv[2] : "";
  BenchPoint *input_points = NULL;
  int input_count = read_points(input_path, &input_points);

  struct triangulateio in;
  struct triangulateio out;
  memset(&in, 0, sizeof(in));
  memset(&out, 0, sizeof(out));

  in.numberofpoints = input_count;
  in.pointlist = (REAL *)malloc((size_t)input_count * 2 * sizeof(REAL));
  in.pointmarkerlist = (int *)calloc((size_t)input_count, sizeof(int));
  for (int i = 0; i < input_count; ++i) {
    in.pointlist[i * 2 + 0] = input_points[i].x;
    in.pointlist[i * 2 + 1] = input_points[i].y;
    in.pointmarkerlist[i] = 1;
  }

  in.numberofsegments = input_count;
  in.segmentlist = (int *)malloc((size_t)input_count * 2 * sizeof(int));
  in.segmentmarkerlist = (int *)calloc((size_t)input_count, sizeof(int));
  for (int i = 0; i < input_count; ++i) {
    in.segmentlist[i * 2 + 0] = i;
    in.segmentlist[i * 2 + 1] = (i + 1) % input_count;
    in.segmentmarkerlist[i] = 1;
  }

  triangulate(TRIANGLE_SWITCHES, &in, &out, NULL);

  int inverted = 0;
  double area = 0.0;
  for (int i = 0; i < out.numberoftriangles; ++i) {
    int a = out.trianglelist[i * out.numberofcorners + 0];
    int b = out.trianglelist[i * out.numberofcorners + 1];
    int c = out.trianglelist[i * out.numberofcorners + 2];
    BenchPoint pa = {out.pointlist[a * 2 + 0], out.pointlist[a * 2 + 1]};
    BenchPoint pb = {out.pointlist[b * 2 + 0], out.pointlist[b * 2 + 1]};
    BenchPoint pc = {out.pointlist[c * 2 + 0], out.pointlist[c * 2 + 1]};
    if (orient(pa, pb, pc) <= 0.0) {
      inverted++;
    }
    area += triangle_area(pa, pb, pc);
  }

  int missing_segments = 0;
  for (int i = 0; i < input_count; ++i) {
    if (!contains_segment(&out, i, (i + 1) % input_count)) {
      missing_segments++;
    }
  }

  double poly_area = polygon_area(input_points, input_count);
  printf("triangle.switches,%s\n", TRIANGLE_SWITCHES);
  printf("triangle.inputPoints,%d\n", input_count);
  printf("triangle.outputPoints,%d\n", out.numberofpoints);
  printf("triangle.segments,%d\n", out.numberofsegments);
  printf("triangle.triangles,%d\n", out.numberoftriangles);
  printf("triangle.polygonArea,%.17g\n", poly_area);
  printf("triangle.triangleArea,%.17g\n", area);
  printf("triangle.areaError,%.17g\n", fabs(area - poly_area));
  printf("triangle.inverted,%d\n", inverted);
  printf("triangle.missingBoundarySegments,%d\n", missing_segments);

  if (keys_path[0] != '\0') {
    write_trikeys(keys_path, &out);
  }

  free(in.pointlist);
  free(in.pointmarkerlist);
  free(in.segmentlist);
  free(in.segmentmarkerlist);
  free(input_points);
  free_output(&out);
  return 0;
}
