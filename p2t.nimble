# Package

version = "0.1.0"
author = "Mason Austin Green"
description = "Standalone constrained polygon tessellation for Nim"
license = "MIT"
srcDir = "src"

# Dependencies

requires "nim >= 2.2.4"

# Tasks

import std/os
import std/strutils

const CommonFlags =
  "--mm:orc --deepcopy:on -d:nimPreviewFloatRoundtrip --path:src --hint:Name:off"

proc sh(cmd: string) =
  exec cmd

proc nimRun(source: string; flags = ""; outPath = ""; nimcache = "") =
  var cmd = "nim r " & CommonFlags
  if flags.len > 0:
    cmd.add " " & flags
  if outPath.len > 0:
    cmd.add " --out:" & quoteShell(outPath)
  if nimcache.len > 0:
    cmd.add " --nimcache:" & quoteShell(nimcache)
  cmd.add " " & quoteShell(source)
  sh cmd

proc nimCompile(source: string; flags = ""; outPath = ""; nimcache = "") =
  var cmd = "nim c " & CommonFlags
  if flags.len > 0:
    cmd.add " " & flags
  if outPath.len > 0:
    cmd.add " --out:" & quoteShell(outPath)
  if nimcache.len > 0:
    cmd.add " --nimcache:" & quoteShell(nimcache)
  cmd.add " " & quoteShell(source)
  sh cmd

proc runTimed(path: string) =
  when defined(linux):
    sh "/usr/bin/time -v " & quoteShell(path)
  else:
    sh quoteShell(path)

proc findLibtess2Dir(): string =
  let envDir = getEnv("LIBTESS2_DIR")
  if envDir.len > 0 and fileExists(envDir / "Include" / "tesselator.h"):
    return envDir

  let homeDir = getHomeDir() / "src" / "libtess2"
  if fileExists(homeDir / "Include" / "tesselator.h"):
    return homeDir

  let siblingDir = getCurrentDir().parentDir / "libtess2"
  if fileExists(siblingDir / "Include" / "tesselator.h"):
    return siblingDir

proc findFastPoly2TriDir(): string =
  let envDir = getEnv("FAST_POLY2TRI_DIR")
  if envDir.len > 0 and fileExists(envDir / "MPE_fastpoly2tri.h"):
    return envDir

  let homeDir = getHomeDir() / "src" / "fast-poly2tri"
  if fileExists(homeDir / "MPE_fastpoly2tri.h"):
    return homeDir

  let siblingDir = getCurrentDir().parentDir / "fast-poly2tri"
  if fileExists(siblingDir / "MPE_fastpoly2tri.h"):
    return siblingDir

task testLibtess2, "compare dude fixture output against libtess2":
  let libtess2Dir = findLibtess2Dir()
  if libtess2Dir.len == 0:
    quit("libtess2 not found; set LIBTESS2_DIR=/path/to/libtess2", QuitFailure)
  nimRun(
    "tests/test_libtess2_compare",
    flags = "-d:libtess2Dir=" & quoteShell(libtess2Dir),
    outPath = "/tmp/p2t_test_libtess2",
    nimcache = "/tmp/p2t_test_libtess2_d",
  )

task benchLibtess2, "benchmark dude fixture against libtess2":
  let libtess2Dir = findLibtess2Dir()
  if libtess2Dir.len == 0:
    quit("libtess2 not found; set LIBTESS2_DIR=/path/to/libtess2", QuitFailure)
  nimCompile(
    "bench/bench_libtess2_compare",
    flags = "--mm:arc -d:release --opt:speed -d:libtess2Dir=" & quoteShell(libtess2Dir),
    outPath = "/tmp/p2t_bench_libtess2",
    nimcache = "/tmp/p2t_bench_libtess2_d",
  )
  sh "strip " & quoteShell("/tmp/p2t_bench_libtess2")
  runTimed("/tmp/p2t_bench_libtess2")

task qualityLibtess2, "compare Delaunay triangle quality against libtess2":
  let libtess2Dir = findLibtess2Dir()
  if libtess2Dir.len == 0:
    quit("libtess2 not found; set LIBTESS2_DIR=/path/to/libtess2", QuitFailure)
  nimRun(
    "bench/quality_compare",
    flags = "--mm:arc -d:release --opt:speed -d:libtess2Dir=" & quoteShell(libtess2Dir),
    outPath = "/tmp/p2t_quality_libtess2",
    nimcache = "/tmp/p2t_quality_libtess2_d",
  )

task test, "run p2t tests":
  nimRun("tests/test_p2t", outPath = "/tmp/p2t_test", nimcache = "/tmp/p2t_test_d")

task testUnsafeCdt, "run p2t tests with CDT runtime checks disabled":
  nimRun(
    "tests/test_p2t",
    flags = "-d:p2tUnsafeCdt",
    outPath = "/tmp/p2t_test_unsafe_cdt",
    nimcache = "/tmp/p2t_test_unsafe_cdt_d",
  )

task testArenaCdt, "run p2t tests with arena-backed CDT":
  nimRun(
    "tests/test_p2t",
    flags = "-d:p2tArenaCdt",
    outPath = "/tmp/p2t_test_arena_cdt",
    nimcache = "/tmp/p2t_test_arena_cdt_d",
  )

task testMemory, "run repeated tessellation memory smoke":
  nimRun(
    "tests/test_memory",
    outPath = "/tmp/p2t_test_memory",
    nimcache = "/tmp/p2t_test_memory_d",
  )

task bench, "run p2t benchmark":
  nimCompile(
    "bench/bench_p2t",
    flags = "--mm:arc -d:release --opt:speed",
    outPath = "/tmp/p2t_bench",
    nimcache = "/tmp/p2t_bench_d",
  )
  sh "strip " & quoteShell("/tmp/p2t_bench")
  sh quoteShell("/tmp/p2t_bench")

task benchUnsafeCdt, "run p2t benchmark with CDT runtime checks disabled":
  nimCompile(
    "bench/bench_p2t",
    flags = "--mm:arc -d:release --opt:speed -d:p2tUnsafeCdt",
    outPath = "/tmp/p2t_bench_unsafe_cdt",
    nimcache = "/tmp/p2t_bench_unsafe_cdt_d",
  )
  sh "strip " & quoteShell("/tmp/p2t_bench_unsafe_cdt")
  echo "p2t unsafe CDT"
  sh quoteShell("/tmp/p2t_bench_unsafe_cdt")

task benchArenaCdt, "run p2t benchmark with arena-backed CDT":
  nimCompile(
    "bench/bench_p2t",
    flags = "--mm:arc -d:release --opt:speed -d:p2tArenaCdt",
    outPath = "/tmp/p2t_bench_arena_cdt",
    nimcache = "/tmp/p2t_bench_arena_cdt_d",
  )
  sh "strip " & quoteShell("/tmp/p2t_bench_arena_cdt")
  echo "p2t arena CDT"
  sh quoteShell("/tmp/p2t_bench_arena_cdt")

task sizes, "report core p2t CDT struct sizes":
  nimRun(
    "bench/bench_struct_sizes",
    flags = "--mm:arc -d:release --opt:speed",
    outPath = "/tmp/p2t_struct_sizes",
    nimcache = "/tmp/p2t_struct_sizes_d",
  )

task benchVariants, "run p2t benchmark with ORC and ARC release variants":
  nimCompile(
    "bench/bench_p2t",
    flags = "--mm:orc -d:release --opt:speed",
    outPath = "/tmp/p2t_bench_orc",
    nimcache = "/tmp/p2t_bench_orc_d",
  )
  sh "strip " & quoteShell("/tmp/p2t_bench_orc")
  runTimed("/tmp/p2t_bench_orc")
  nimCompile(
    "bench/bench_p2t",
    flags = "--mm:arc -d:release --opt:speed",
    outPath = "/tmp/p2t_bench_arc",
    nimcache = "/tmp/p2t_bench_arc_d",
  )
  sh "strip " & quoteShell("/tmp/p2t_bench_arc")
  runTimed("/tmp/p2t_bench_arc")

task benchSortVariants, "compare quicksort and merge-sort CDT point ordering":
  nimCompile(
    "bench/bench_p2t",
    flags = "--mm:arc -d:release --opt:speed -d:p2tQuickSort",
    outPath = "/tmp/p2t_bench_sort_quick",
    nimcache = "/tmp/p2t_bench_sort_quick_d",
  )
  sh "strip " & quoteShell("/tmp/p2t_bench_sort_quick")
  echo "p2t quicksort"
  sh quoteShell("/tmp/p2t_bench_sort_quick")

  nimCompile(
    "bench/bench_p2t",
    flags = "--mm:arc -d:release --opt:speed",
    outPath = "/tmp/p2t_bench_sort_merge",
    nimcache = "/tmp/p2t_bench_sort_merge_d",
  )
  sh "strip " & quoteShell("/tmp/p2t_bench_sort_merge")
  echo "p2t merge sort"
  sh quoteShell("/tmp/p2t_bench_sort_merge")

task benchFastPoly2Tri, "compare p2t against local fast-poly2tri":
  let fastDir = findFastPoly2TriDir()
  if fastDir.len == 0:
    quit(
      "fast-poly2tri not found; set FAST_POLY2TRI_DIR=/path/to/fast-poly2tri",
      QuitFailure,
    )

  nimCompile(
    "bench/bench_p2t",
    flags = "--mm:arc -d:release --opt:speed",
    outPath = "/tmp/p2t_bench_cross",
    nimcache = "/tmp/p2t_bench_cross_d",
  )
  sh "strip " & quoteShell("/tmp/p2t_bench_cross")
  echo "p2t"
  sh quoteShell("/tmp/p2t_bench_cross")

  let headerDefine = "-DFAST_POLY2TRI_HEADER=\\\"" & fastDir / "MPE_fastpoly2tri.h" & "\\\""
  sh "clang -std=gnu99 -O3 -DNDEBUG " & headerDefine &
    " bench/bench_fastpoly2tri.c -o /tmp/p2t_fastpoly2tri_float -lm"
  sh "clang -std=gnu99 -O3 -DNDEBUG -DMPE_POLY2TRI_USE_DOUBLE " & headerDefine &
    " bench/bench_fastpoly2tri.c -o /tmp/p2t_fastpoly2tri_double -lm"
  sh quoteShell("/tmp/p2t_fastpoly2tri_float")
  sh quoteShell("/tmp/p2t_fastpoly2tri_double")

task benchFastPoly2TriUnsafe, "compare unsafe CDT p2t against local fast-poly2tri":
  let fastDir = findFastPoly2TriDir()
  if fastDir.len == 0:
    quit(
      "fast-poly2tri not found; set FAST_POLY2TRI_DIR=/path/to/fast-poly2tri",
      QuitFailure,
    )

  nimCompile(
    "bench/bench_p2t",
    flags = "--mm:arc -d:release --opt:speed -d:p2tUnsafeCdt",
    outPath = "/tmp/p2t_bench_cross_unsafe_cdt",
    nimcache = "/tmp/p2t_bench_cross_unsafe_cdt_d",
  )
  sh "strip " & quoteShell("/tmp/p2t_bench_cross_unsafe_cdt")
  echo "p2t unsafe CDT"
  sh quoteShell("/tmp/p2t_bench_cross_unsafe_cdt")

  let headerDefine = "-DFAST_POLY2TRI_HEADER=\\\"" & fastDir / "MPE_fastpoly2tri.h" & "\\\""
  sh "clang -std=gnu99 -O3 -DNDEBUG " & headerDefine &
    " bench/bench_fastpoly2tri.c -o /tmp/p2t_fastpoly2tri_float -lm"
  sh "clang -std=gnu99 -O3 -DNDEBUG -DMPE_POLY2TRI_USE_DOUBLE " & headerDefine &
    " bench/bench_fastpoly2tri.c -o /tmp/p2t_fastpoly2tri_double -lm"
  sh quoteShell("/tmp/p2t_fastpoly2tri_float")
  sh quoteShell("/tmp/p2t_fastpoly2tri_double")

task benchFastPoly2TriArena, "compare arena CDT p2t against local fast-poly2tri":
  let fastDir = findFastPoly2TriDir()
  if fastDir.len == 0:
    quit(
      "fast-poly2tri not found; set FAST_POLY2TRI_DIR=/path/to/fast-poly2tri",
      QuitFailure,
    )

  nimCompile(
    "bench/bench_p2t",
    flags = "--mm:arc -d:release --opt:speed -d:p2tArenaCdt -d:p2tUnsafeCdt",
    outPath = "/tmp/p2t_bench_cross_arena_cdt",
    nimcache = "/tmp/p2t_bench_cross_arena_cdt_d",
  )
  sh "strip " & quoteShell("/tmp/p2t_bench_cross_arena_cdt")
  echo "p2t arena unsafe CDT"
  sh quoteShell("/tmp/p2t_bench_cross_arena_cdt")

  let headerDefine = "-DFAST_POLY2TRI_HEADER=\\\"" & fastDir / "MPE_fastpoly2tri.h" & "\\\""
  sh "clang -std=gnu99 -O3 -DNDEBUG " & headerDefine &
    " bench/bench_fastpoly2tri.c -o /tmp/p2t_fastpoly2tri_float -lm"
  sh "clang -std=gnu99 -O3 -DNDEBUG -DMPE_POLY2TRI_USE_DOUBLE " & headerDefine &
    " bench/bench_fastpoly2tri.c -o /tmp/p2t_fastpoly2tri_double -lm"
  sh quoteShell("/tmp/p2t_fastpoly2tri_float")
  sh quoteShell("/tmp/p2t_fastpoly2tri_double")

task benchParallel, "benchmark tessellateBatch scaling across threads":
  nimCompile(
    "bench/bench_parallel",
    flags = "--mm:orc --threads:on -d:useMalloc -d:release --opt:speed",
    outPath = "/tmp/p2t_bench_parallel",
    nimcache = "/tmp/p2t_bench_parallel_d",
  )
  sh "strip " & quoteShell("/tmp/p2t_bench_parallel")
  sh quoteShell("/tmp/p2t_bench_parallel")

task tidy, "format p2t sources":
  sh "nph src/p2t.nim src/p2t/types.nim src/p2t/geometry.nim src/p2t/internal/cdt.nim src/p2t/internal/arena_cdt.nim src/p2t/triangulate.nim tests/test_p2t.nim tests/test_memory.nim tests/test_libtess2_compare.nim bench/bench_p2t.nim bench/bench_libtess2_compare.nim bench/quality_compare.nim bench/bench_parallel.nim bench/bench_struct_sizes.nim"
