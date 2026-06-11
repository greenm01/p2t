#include "parallel_meshing_2d.hh"

#include <algorithm>
#include <cerrno>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <string>
#include <sys/stat.h>
#include <unistd.h>
#include <vector>

using namespace voro;

namespace {

struct Point {
  double x;
  double y;
};

struct RunStats {
  long long setupUs;
  long long meshUs;
  long long extractUs;
  int outputPoints;
  int triangles;
  int inverted;
  double polygonArea;
  double triangleArea;
  double minAngleDeg;
  double meanMinAngleDeg;
  double maxEdgeRatio;
  double meanEdgeRatio;
};

long long micros(std::chrono::steady_clock::duration d) {
  return std::chrono::duration_cast<std::chrono::microseconds>(d).count();
}

double orient(const Point &a, const Point &b, const Point &c) {
  return (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x);
}

double clamp_unit(double value) {
  if (value < -1.0) {
    return -1.0;
  }
  if (value > 1.0) {
    return 1.0;
  }
  return value;
}

double distance_between(const Point &a, const Point &b) {
  double dx = a.x - b.x;
  double dy = a.y - b.y;
  return std::sqrt(dx * dx + dy * dy);
}

double min_angle_degrees(const Point &a, const Point &b, const Point &c) {
  double ab = distance_between(a, b);
  double bc = distance_between(b, c);
  double ca = distance_between(c, a);
  if (ab == 0.0 || bc == 0.0 || ca == 0.0) {
    return 0.0;
  }

  double angleA = std::acos(clamp_unit((ab * ab + ca * ca - bc * bc) /
                                       (2.0 * ab * ca)));
  double angleB = std::acos(clamp_unit((ab * ab + bc * bc - ca * ca) /
                                       (2.0 * ab * bc)));
  double angleC = std::acos(clamp_unit((ca * ca + bc * bc - ab * ab) /
                                       (2.0 * ca * bc)));
  double minAngle = std::min(angleA, std::min(angleB, angleC));
  return minAngle * 180.0 / 3.14159265358979323846;
}

double edge_ratio(const Point &a, const Point &b, const Point &c) {
  double ab = distance_between(a, b);
  double bc = distance_between(b, c);
  double ca = distance_between(c, a);
  double shortest = std::min(ab, std::min(bc, ca));
  double longest = std::max(ab, std::max(bc, ca));
  return shortest == 0.0 ? INFINITY : longest / shortest;
}

void collect_triangle_stats(mesh_alg_2d &mesh, parallel_meshing_2d &pm2d,
                            RunStats &stats) {
  mesh.sort_tria_vertex_ids_ccw();
  stats.triangles = mesh.tria_ct;
  stats.outputPoints = pm2d.Ncurrent;
  stats.inverted = 0;
  stats.triangleArea = 0.0;
  stats.minAngleDeg = INFINITY;
  stats.meanMinAngleDeg = 0.0;
  stats.maxEdgeRatio = 0.0;
  stats.meanEdgeRatio = 0.0;
  for (int i = 0; i < mesh.tria_ct; ++i) {
    int a = mesh.tria_vertex[i * 3];
    int b = mesh.tria_vertex[i * 3 + 1];
    int c = mesh.tria_vertex[i * 3 + 2];
    Point pa{pm2d.xy_id[a * 2], pm2d.xy_id[a * 2 + 1]};
    Point pb{pm2d.xy_id[b * 2], pm2d.xy_id[b * 2 + 1]};
    Point pc{pm2d.xy_id[c * 2], pm2d.xy_id[c * 2 + 1]};
    double o = orient(pa, pb, pc);
    double triMinAngle = min_angle_degrees(pa, pb, pc);
    double triEdgeRatio = edge_ratio(pa, pb, pc);
    if (o <= 0.0) {
      stats.inverted++;
    }
    stats.triangleArea += std::fabs(o) * 0.5;
    if (triMinAngle < stats.minAngleDeg) {
      stats.minAngleDeg = triMinAngle;
    }
    if (triEdgeRatio > stats.maxEdgeRatio) {
      stats.maxEdgeRatio = triEdgeRatio;
    }
    stats.meanMinAngleDeg += triMinAngle;
    stats.meanEdgeRatio += triEdgeRatio;
  }
  if (mesh.tria_ct > 0) {
    stats.meanMinAngleDeg /= static_cast<double>(mesh.tria_ct);
    stats.meanEdgeRatio /= static_cast<double>(mesh.tria_ct);
  }
}

double polygon_area(const std::vector<Point> &points) {
  double twice = 0.0;
  for (size_t i = 0, j = points.size() - 1; i < points.size(); j = i++) {
    twice += points[j].x * points[i].y - points[i].x * points[j].y;
  }
  return std::fabs(twice) * 0.5;
}

std::vector<Point> read_points(const char *path) {
  FILE *f = std::fopen(path, "r");
  if (f == nullptr) {
    std::perror(path);
    std::exit(1);
  }

  std::vector<Point> points;
  while (true) {
    Point p;
    int n = std::fscanf(f, "%lf %lf", &p.x, &p.y);
    if (n != 2) {
      break;
    }
    points.push_back(p);
  }
  std::fclose(f);
  if (points.size() < 3) {
    std::fprintf(stderr, "fixture needs at least three points\n");
    std::exit(1);
  }
  return points;
}

std::vector<std::vector<double>> contour_boundaries(std::vector<Point> points) {
  if (polygon_area(points) > 0.0) {
    std::reverse(points.begin(), points.end());
  }

  std::vector<double> boundary;
  boundary.reserve((points.size() + 1) * 2);
  for (const Point &p : points) {
    boundary.push_back(p.x);
    boundary.push_back(p.y);
  }
  boundary.push_back(points.front().x);
  boundary.push_back(points.front().y);
  return {boundary};
}

void ensure_dir(const std::string &path) {
  if (mkdir(path.c_str(), 0700) != 0 && errno != EEXIST) {
    std::perror(path.c_str());
    std::exit(1);
  }
}

void write_points(const char *path, parallel_meshing_2d &pm2d) {
  if (path == nullptr || path[0] == '\0') {
    return;
  }
  FILE *f = std::fopen(path, "w");
  if (f == nullptr) {
    std::perror(path);
    std::exit(1);
  }
  for (int i = 0; i < pm2d.Ncurrent; ++i) {
    std::fprintf(f, "%.17g %.17g\n", pm2d.xy_id[i * 2],
                 pm2d.xy_id[i * 2 + 1]);
  }
  std::fclose(f);
}

class ScopedStdoutSilence {
public:
  explicit ScopedStdoutSilence(bool enabled) : enabled_(enabled) {
    if (!enabled_) {
      return;
    }
    std::fflush(stdout);
    saved_ = dup(STDOUT_FILENO);
    int null_fd = open("/dev/null", O_WRONLY);
    if (saved_ >= 0 && null_fd >= 0) {
      dup2(null_fd, STDOUT_FILENO);
    }
    if (null_fd >= 0) {
      close(null_fd);
    }
  }

  ~ScopedStdoutSilence() {
    if (!enabled_) {
      return;
    }
    std::fflush(stdout);
    if (saved_ >= 0) {
      dup2(saved_, STDOUT_FILENO);
      close(saved_);
    }
  }

private:
  bool enabled_;
  int saved_ = -1;
};

RunStats run_once(const std::vector<Point> &points, const char *fixture,
                  int totalPoints, int setupThreads, int meshThreads,
                  double k, const char *method, const char *mode, int round,
                  bool quiet, const char *pointsOut) {
  if (totalPoints <= static_cast<int>(points.size())) {
    std::fprintf(stderr,
                 "TriMe Ntotal must exceed fixed boundary point count (%zu)\n",
                 points.size());
    std::exit(1);
  }

  RunStats stats = {};
  auto setupStart = std::chrono::steady_clock::now();

  ScopedStdoutSilence silence(quiet);
  std::vector<std::vector<double>> boundaries = contour_boundaries(points);
  std::string prefix = std::string("/tmp/p2t_trime_heron_") +
                       std::to_string(getpid()) + "_" + std::to_string(round);
  ensure_dir(prefix);

  int cn = std::max(2, static_cast<int>(std::sqrt(totalPoints / 3.3)));
  container_2d con(0.0, 1.0, 0.0, 1.0, cn, cn, false, false, 16,
                   setupThreads);
  int contourThreads = points.size() > 200 ? setupThreads : 1;
  bool normalizeModel = true;
  shape_2d_contour_lines shape(con, setupThreads, contourThreads, boundaries,
                               normalizeModel);
  sizing_2d_automatic sizeField(&shape, k);
  parallel_meshing_2d pm2d(&con, &shape, &sizeField, setupThreads, 0,
                           prefix.c_str());

  std::vector<double> fixed(points.size() * 2);
  for (size_t i = 0; i < points.size(); ++i) {
    fixed[i * 2] = points[i].x;
    fixed[i * 2 + 1] = points[i].y;
  }
  pm2d.add_fixed_points_normailze(static_cast<int>(points.size()), &shape,
                                  fixed.data());

  srand(10);
  pm2d.pt_init(totalPoints);
  if (round == 0) {
    write_points(pointsOut, pm2d);
  }
  auto setupEnd = std::chrono::steady_clock::now();

  bool onePass = std::strcmp(mode, "one-pass") == 0;
  auto meshStart = std::chrono::steady_clock::now();
  if (std::strcmp(method, "dm") == 0) {
    mesh_alg_2d_dm mesh(&pm2d);
    mesh.change_number_thread(meshThreads);
    if (onePass) {
      mesh.meshing_init();
    } else {
      pm2d.meshing(&mesh);
    }
    auto meshEnd = std::chrono::steady_clock::now();
    double *dummy = new double[1];
    auto extractStart = std::chrono::steady_clock::now();
    mesh.voro_compute_and_store_info(false, false, true, false, false, false,
                                     false, false, dummy);
    auto extractEnd = std::chrono::steady_clock::now();
    delete[] dummy;
    stats.meshUs = micros(meshEnd - meshStart);
    stats.extractUs = micros(extractEnd - extractStart);
    collect_triangle_stats(mesh, pm2d, stats);
  } else if (std::strcmp(method, "cvd") == 0) {
    mesh_alg_2d_cvd mesh(&pm2d);
    mesh.change_number_thread(meshThreads);
    if (onePass) {
      mesh.meshing_init();
    } else {
      pm2d.meshing(&mesh);
    }
    auto meshEnd = std::chrono::steady_clock::now();
    double *dummy = new double[1];
    auto extractStart = std::chrono::steady_clock::now();
    mesh.voro_compute_and_store_info(false, false, true, false, false, false,
                                     false, false, dummy);
    auto extractEnd = std::chrono::steady_clock::now();
    delete[] dummy;
    stats.meshUs = micros(meshEnd - meshStart);
    stats.extractUs = micros(extractEnd - extractStart);
    collect_triangle_stats(mesh, pm2d, stats);
  } else {
    mesh_alg_2d_hybrid mesh(&pm2d);
    mesh.change_number_thread(meshThreads);
    if (onePass) {
      mesh.meshing_init();
    } else {
      pm2d.meshing(&mesh);
    }
    auto meshEnd = std::chrono::steady_clock::now();
    double *dummy = new double[1];
    auto extractStart = std::chrono::steady_clock::now();
    mesh.voro_compute_and_store_info(false, false, true, false, false, false,
                                     false, false, dummy);
    auto extractEnd = std::chrono::steady_clock::now();
    delete[] dummy;
    stats.meshUs = micros(meshEnd - meshStart);
    stats.extractUs = micros(extractEnd - extractStart);
    collect_triangle_stats(mesh, pm2d, stats);
  }

  stats.setupUs = micros(setupEnd - setupStart);
  std::vector<Point> normalizedBoundary(points.size());
  for (size_t i = 0; i < points.size(); ++i) {
    normalizedBoundary[i] = Point{pm2d.xy_id[i * 2], pm2d.xy_id[i * 2 + 1]};
  }
  stats.polygonArea = polygon_area(normalizedBoundary);
  (void)fixture;
  return stats;
}

void sort_values(std::vector<long long> &values) {
  std::sort(values.begin(), values.end());
}

} // namespace

int main(int argc, char **argv) {
  const char *fixture =
      argc > 1 ? argv[1] : "tests/fixtures/nazca_heron.dat";
  int rounds = argc > 2 ? std::atoi(argv[2]) : 3;
  int setupThreads = argc > 3 ? std::atoi(argv[3]) : 4;
  int meshThreads = argc > 4 ? std::atoi(argv[4]) : 8;
  int totalPoints = argc > 5 ? std::atoi(argv[5]) : 5000;
  double k = argc > 6 ? std::atof(argv[6]) : 0.1;
  const char *method = argc > 7 ? argv[7] : "hybrid";
  const char *mode = argc > 8 ? argv[8] : "full";
  const char *pointsOut = argc > 9 ? argv[9] : "";
  if (rounds <= 0) {
    rounds = 1;
  }
  if (setupThreads <= 0) {
    setupThreads = 1;
  }
  if (meshThreads <= 0) {
    meshThreads = 1;
  }

  std::vector<Point> points = read_points(fixture);
  std::vector<long long> totalTimes;
  std::vector<long long> setupTimes;
  std::vector<long long> meshTimes;
  std::vector<long long> extractTimes;
  RunStats last = {};

  for (int round = 0; round < rounds; ++round) {
    last = run_once(points, fixture, totalPoints, setupThreads, meshThreads, k,
                    method, mode, round, true, pointsOut);
    totalTimes.push_back(last.setupUs + last.meshUs + last.extractUs);
    setupTimes.push_back(last.setupUs);
    meshTimes.push_back(last.meshUs);
    extractTimes.push_back(last.extractUs);
  }

  sort_values(totalTimes);
  sort_values(setupTimes);
  sort_values(meshTimes);
  sort_values(extractTimes);
  size_t median = totalTimes.size() / 2;

  std::printf("trime++-mesh\n");
  std::printf("fixture,%s\n", fixture);
  std::printf("config,method,%s\n", method);
  std::printf("config,mode,%s\n", mode);
  std::printf("config,totalPoints,%d\n", totalPoints);
  std::printf("config,K,%.17g\n", k);
  std::printf("config,setupThreads,%d\n", setupThreads);
  std::printf("config,meshThreads,%d\n", meshThreads);
  std::printf("inputBoundaryPoints,%zu\n", points.size());
  std::printf("outputPoints,%d\n", last.outputPoints);
  std::printf("triangles,%d\n", last.triangles);
  std::printf("polygonArea,%.17g\n", last.polygonArea);
  std::printf("triangleArea,%.17g\n", last.triangleArea);
  std::printf("areaError,%.17g\n",
              std::fabs(last.triangleArea - last.polygonArea));
  std::printf("inverted,%d\n", last.inverted);
  std::printf("minAngleDeg,%.17g\n", last.minAngleDeg);
  std::printf("meanMinAngleDeg,%.17g\n", last.meanMinAngleDeg);
  std::printf("maxEdgeRatio,%.17g\n", last.maxEdgeRatio);
  std::printf("meanEdgeRatio,%.17g\n", last.meanEdgeRatio);
  std::printf("trime++-mesh-total: %d runs, best %lld us, median %lld us\n",
              rounds, totalTimes[0], totalTimes[median]);
  std::printf("trime++-mesh-setup: %d runs, best %lld us, median %lld us\n",
              rounds, setupTimes[0], setupTimes[median]);
  std::printf("trime++-mesh-meshing: %d runs, best %lld us, median %lld us\n",
              rounds, meshTimes[0], meshTimes[median]);
  std::printf("trime++-mesh-extract: %d runs, best %lld us, median %lld us\n",
              rounds, extractTimes[0], extractTimes[median]);
  return last.triangles > 0 && last.inverted == 0 ? 0 : 1;
}
