#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <fstream>
#include <iostream>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>

#include "delabella.h"
#include "CDT.h"
#include <Fade_2D.h>

using namespace GEOM_FADE2D;

#define BENCH_ROUNDS 5

struct BenchPoint {
  double x;
  double y;
};

struct BenchContour {
  std::vector<BenchPoint> points;
};

struct BenchFixture {
  std::vector<BenchContour> contours;
};

struct FlatFixture {
  std::vector<BenchPoint> points;
  std::vector<double> xy;
  std::vector<int> edgeA;
  std::vector<int> edgeB;
  std::vector<CDT::V2d<double>> cdtPoints;
  std::vector<CDT::Edge> cdtEdges;
};

struct FadeFixture {
  std::vector<Point2> points;
  std::vector<std::vector<Segment2>> contourSegments;
  Point2 seed;
};

static double nowSeconds() {
  using clock = std::chrono::steady_clock;
  return std::chrono::duration<double>(clock::now().time_since_epoch()).count();
}

static BenchFixture readDatRings(const std::string &path) {
  BenchFixture result;
  std::ifstream file(path);
  if (!file) {
    throw std::runtime_error("failed to open " + path);
  }

  BenchContour current;
  std::string line;
  while (std::getline(file, line)) {
    std::istringstream iss(line);
    double x, y;
    if (!(iss >> x >> y)) {
      if (!current.points.empty()) {
        result.contours.push_back(std::move(current));
        current = BenchContour();
      }
      continue;
    }
    current.points.push_back({x, y});
  }
  if (!current.points.empty()) {
    result.contours.push_back(std::move(current));
  }
  if (result.contours.empty()) {
    throw std::runtime_error("empty fixture " + path);
  }
  return result;
}

static BenchFixture singleDat(const std::string &path) {
  BenchFixture result;
  result.contours.push_back(readDatRings(path).contours.front());
  return result;
}

static BenchFixture dudeWithHoles() {
  BenchFixture result = singleDat("tests/fixtures/dude.dat");
  result.contours.push_back(BenchContour{
      {{325, 437}, {320, 423}, {329, 413}, {332, 423}}});
  result.contours.push_back(BenchContour{
      {{320.72342, 480},
       {338.90617, 465.96863},
       {347.99754, 480.61584},
       {329.8148, 510.41534},
       {339.91632, 480.11077},
       {334.86556, 478.09046}}});
  return result;
}

static BenchContour regularPolygon(int count, double radius) {
  BenchContour contour;
  contour.points.reserve(count);
  for (int i = 0; i < count; ++i) {
    double angle = 2.0 * M_PI * double(i) / double(count);
    contour.points.push_back(
        {std::cos(angle) * radius, std::sin(angle) * radius});
  }
  return contour;
}

static bool pointInPolygon(const std::vector<BenchPoint> &points,
                           BenchPoint point) {
  bool inside = false;
  for (size_t i = 0, j = points.size() - 1; i < points.size(); j = i++) {
    const BenchPoint &a = points[i];
    const BenchPoint &b = points[j];
    bool crosses = ((a.y > point.y) != (b.y > point.y));
    if (crosses) {
      double x = (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x;
      if (point.x < x) {
        inside = !inside;
      }
    }
  }
  return inside;
}

static BenchPoint polygonCentroidOrAverage(
    const std::vector<BenchPoint> &points) {
  double area2 = 0.0;
  BenchPoint centroid{0, 0};
  for (size_t i = 0, j = points.size() - 1; i < points.size(); j = i++) {
    BenchPoint a = points[j];
    BenchPoint b = points[i];
    double cross = a.x * b.y - b.x * a.y;
    area2 += cross;
    centroid.x += (a.x + b.x) * cross;
    centroid.y += (a.y + b.y) * cross;
  }
  if (std::fabs(area2) > 1e-12) {
    centroid.x /= 3.0 * area2;
    centroid.y /= 3.0 * area2;
    return centroid;
  }

  for (BenchPoint point : points) {
    centroid.x += point.x;
    centroid.y += point.y;
  }
  centroid.x /= double(points.size());
  centroid.y /= double(points.size());
  return centroid;
}

static bool validSeed(const BenchFixture &fixture, BenchPoint point) {
  if (!pointInPolygon(fixture.contours[0].points, point)) {
    return false;
  }
  for (size_t i = 1; i < fixture.contours.size(); ++i) {
    if (pointInPolygon(fixture.contours[i].points, point)) {
      return false;
    }
  }
  return true;
}

static BenchPoint findSeed(const BenchFixture &fixture) {
  BenchPoint point = polygonCentroidOrAverage(fixture.contours[0].points);
  if (validSeed(fixture, point)) {
    return point;
  }

  double minX = fixture.contours[0].points[0].x;
  double maxX = minX;
  double minY = fixture.contours[0].points[0].y;
  double maxY = minY;
  for (BenchPoint current : fixture.contours[0].points) {
    minX = std::min(minX, current.x);
    maxX = std::max(maxX, current.x);
    minY = std::min(minY, current.y);
    maxY = std::max(maxY, current.y);
  }

  for (int y = 1; y < 128; ++y) {
    for (int x = 1; x < 128; ++x) {
      point.x = minX + (maxX - minX) * double(x) / 128.0;
      point.y = minY + (maxY - minY) * double(y) / 128.0;
      if (validSeed(fixture, point)) {
        return point;
      }
    }
  }

  throw std::runtime_error("failed to find Fade2D zone seed");
}

static FlatFixture flatten(const BenchFixture &fixture) {
  FlatFixture result;
  for (const BenchContour &contour : fixture.contours) {
    int base = int(result.points.size());
    for (BenchPoint point : contour.points) {
      result.points.push_back(point);
    }
    int count = int(contour.points.size());
    for (int i = 0; i < count; ++i) {
      result.edgeA.push_back(base + i);
      result.edgeB.push_back(base + ((i + 1) % count));
    }
  }

  result.xy.reserve(result.points.size() * 2);
  result.cdtPoints.reserve(result.points.size());
  for (BenchPoint point : result.points) {
    result.xy.push_back(point.x);
    result.xy.push_back(point.y);
    result.cdtPoints.push_back(CDT::V2d<double>(point.x, point.y));
  }
  result.cdtEdges.reserve(result.edgeA.size());
  for (size_t i = 0; i < result.edgeA.size(); ++i) {
    result.cdtEdges.push_back(CDT::Edge(
        CDT::VertInd(result.edgeA[i]), CDT::VertInd(result.edgeB[i])));
  }
  return result;
}

static FadeFixture makeFadeFixture(const BenchFixture &fixture) {
  FadeFixture result;
  for (const BenchContour &contour : fixture.contours) {
    std::vector<Segment2> segments;
    for (size_t i = 0; i < contour.points.size(); ++i) {
      BenchPoint a = contour.points[i];
      BenchPoint b = contour.points[(i + 1) % contour.points.size()];
      Point2 pa(a.x, a.y);
      Point2 pb(b.x, b.y);
      result.points.push_back(pa);
      segments.push_back(Segment2(pa, pb));
    }
    result.contourSegments.push_back(std::move(segments));
  }

  BenchPoint seed = findSeed(fixture);
  result.seed = Point2(seed.x, seed.y);
  return result;
}

static long long delabellaOnce(IDelaBella2<double, int> *db,
                               const FlatFixture &fixture) {
  int ok = db->Triangulate(
      int(fixture.points.size()), fixture.xy.data(), nullptr,
      sizeof(double) * 2);
  if (ok <= 0) {
    throw std::runtime_error("Delabella Triangulate failed");
  }
  int constrained = db->ConstrainEdges(
      int(fixture.edgeA.size()), fixture.edgeA.data(), fixture.edgeB.data(),
      sizeof(int));
  if (constrained < 0) {
    throw std::runtime_error("Delabella ConstrainEdges failed");
  }
  return db->FloodFill(false);
}

static long long cdtOnce(const FlatFixture &fixture) {
  CDT::Triangulation<double> cdt(
      CDT::VertexInsertionOrder::Auto,
      CDT::IntersectingConstraintEdges::DontCheck, 0.0);
  cdt.insertVertices(fixture.cdtPoints);
  cdt.insertEdges(fixture.cdtEdges);
  cdt.eraseOuterTrianglesAndHoles();
  return static_cast<long long>(cdt.triangles.size());
}

static long long fadeOnce(const FadeFixture &fixture) {
  Fade_2D dt;
  dt.insert(fixture.points);

  std::vector<ConstraintGraph2 *> graphs;
  graphs.reserve(fixture.contourSegments.size());
  for (const std::vector<Segment2> &contour : fixture.contourSegments) {
    std::vector<Segment2> segments = contour;
    ConstraintGraph2 *graph =
        dt.createConstraint(segments, CIS_CONSTRAINED_DELAUNAY, false);
    if (graph == nullptr) {
      throw std::runtime_error("Fade2D createConstraint failed");
    }
    graphs.push_back(graph);
  }

  Zone2 *zone = dt.createZone(graphs, ZL_GROW, fixture.seed, false);
  if (zone == nullptr) {
    throw std::runtime_error("Fade2D createZone failed");
  }

  std::vector<Triangle2 *> triangles;
  zone->getTriangles(triangles);
  return static_cast<long long>(triangles.size());
}

template <typename Func>
static void benchLine(const char *engine, const char *name, int iterations,
                      Func func) {
  double times[BENCH_ROUNDS];
  long long reportedTriangles = 0;
  for (int round = 0; round < BENCH_ROUNDS; ++round) {
    long long triangles = 0;
    double start = nowSeconds();
    for (int i = 0; i < iterations; ++i) {
      triangles += func();
    }
    times[round] = (nowSeconds() - start) * 1000000.0;
    reportedTriangles = triangles;
  }
  std::sort(times, times + BENCH_ROUNDS);
  std::printf(
      "%s,%s,%d,%lld,%.0f,%.0f\n", engine, name, iterations,
      reportedTriangles, times[0], times[BENCH_ROUNDS / 2]);
  std::fflush(stdout);
}

static void benchCase(const std::string &name, int iterations,
                      const BenchFixture &fixture) {
  FlatFixture flat = flatten(fixture);
  FadeFixture fade = makeFadeFixture(fixture);

  try {
    IDelaBella2<double, int> *db = IDelaBella2<double, int>::Create();
    benchLine("delabella", name.c_str(), iterations,
              [&]() { return delabellaOnce(db, flat); });
    db->Destroy();
  } catch (const std::exception &e) {
    std::printf("delabella,%s,failed,%s\n", name.c_str(), e.what());
  }

  try {
    benchLine("cdt", name.c_str(), iterations,
              [&]() { return cdtOnce(flat); });
  } catch (const std::exception &e) {
    std::printf("cdt,%s,failed,%s\n", name.c_str(), e.what());
  }

  try {
    benchLine("fade2d", name.c_str(), iterations,
              [&]() { return fadeOnce(fade); });
  } catch (const std::exception &e) {
    std::printf("fade2d,%s,failed,%s\n", name.c_str(), e.what());
  }
}

int main() {
  std::printf("engine,case,runs,triangles,best_us,median_us\n");

  benchCase(
      "small-ui-quad", 10000,
      BenchFixture{{BenchContour{{{0, 0}, {100, 0}, {100, 40}, {0, 40}}}}});
  benchCase("medium-icon", 2000,
            BenchFixture{{regularPolygon(48, 50)}});
  benchCase("large-shape", 500,
            BenchFixture{{regularPolygon(512, 100)}});
  benchCase("fixture-test", 10000, singleDat("tests/fixtures/test.dat"));
  benchCase("diamond", 10000, singleDat("tests/fixtures/diamond.dat"));
  benchCase("star", 10000, singleDat("tests/fixtures/star.dat"));
  benchCase("dude-with-holes", 1000, dudeWithHoles());
  benchCase("nazca-monkey", 100, singleDat("tests/fixtures/nazca_monkey.dat"));
  benchCase("nazca-heron", 100, singleDat("tests/fixtures/nazca_heron.dat"));
  benchCase(
      "organic-large", 100,
      readDatRings("tests/fixtures/organic/cdt_organic_large.dat"));
  return 0;
}
