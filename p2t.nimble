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

# Tier 1 release codegen tuning. Measured (Apple M4 Pro, best-of-3, raw path):
# 1.32x-1.57x faster than the untuned best config, no output change.
#   --panics:on          : drops exception unwinding, frees the C optimizer
#   -flto                : cross-module inlining of predicates/allocator
#   -mcpu=native         : host-tuned codegen
# Deliberately excluded: -ffp-contract=fast (FMA gave no win; predicates are
# already non-robust float) and -d:useMalloc (no win vs ARC TLS allocator).
const TunedFlags =
  "--panics:on --passC:-flto --passL:-flto --passC:-mcpu=native --passL:-mcpu=native"

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

proc quoteArgs(args: openArray[string]): string =
  for arg in args:
    if result.len > 0:
      result.add " "
    result.add quoteShell(arg)

proc tomlString(value: string): string =
  result = "\""
  for ch in value:
    case ch
    of '\\':
      result.add "\\\\"
    of '"':
      result.add "\\\""
    else:
      result.add ch
  result.add "\""

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

proc findEarcutDir(): string =
  let envDir = getEnv("EARCUT_DIR")
  if envDir.len > 0 and fileExists(envDir / "Cargo.toml"):
    return envDir

  let homeDir = getHomeDir() / "src" / "earcut"
  if fileExists(homeDir / "Cargo.toml"):
    return homeDir

  let siblingDir = getCurrentDir().parentDir / "earcut"
  if fileExists(siblingDir / "Cargo.toml"):
    return siblingDir

proc buildEarcutBench(outPath: string): bool =
  let earcutDir = findEarcutDir()
  if earcutDir.len == 0:
    echo "skipping earcut; set EARCUT_DIR=/path/to/earcut"
    return false

  let projectDir = "/tmp/p2t_earcut_bench"
  sh "mkdir -p " & quoteShell(projectDir / "src")
  writeFile(
    projectDir / "Cargo.toml",
    "[package]\n" &
      "name = \"p2t_earcut_bench\"\n" &
      "version = \"0.1.0\"\n" &
      "edition = \"2024\"\n\n" &
      "[dependencies]\n" &
      "earcut = { path = " & tomlString(earcutDir) & " }\n\n" &
      "[profile.release]\n" &
      "opt-level = 3\n" &
      "codegen-units = 1\n" &
      "lto = \"fat\"\n" &
      "panic = \"abort\"\n",
  )
  sh "cp " & quoteShell("bench/bench_earcut.rs") & " " &
    quoteShell(projectDir / "src" / "main.rs")
  sh "cargo build --release --manifest-path " & quoteShell(projectDir / "Cargo.toml")
  sh "cp " & quoteShell(projectDir / "target" / "release" / "p2t_earcut_bench") &
    " " & quoteShell(outPath)
  true

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

task testArenaFrontHashCdt, "run p2t tests with arena CDT front hash":
  nimRun(
    "tests/test_p2t",
    flags = "-d:p2tArenaCdt -d:p2tFrontHash",
    outPath = "/tmp/p2t_test_arena_front_hash_cdt",
    nimcache = "/tmp/p2t_test_arena_front_hash_cdt_d",
  )

task testArenaSlotCdt, "run p2t tests with arena CDT neighbor slots":
  nimRun(
    "tests/test_p2t",
    flags = "-d:p2tArenaCdt -d:p2tSlotCdt",
    outPath = "/tmp/p2t_test_arena_slot_cdt",
    nimcache = "/tmp/p2t_test_arena_slot_cdt_d",
  )

task testArenaSlotFrontHashCdt, "run p2t tests with arena CDT neighbor slots and front hash":
  nimRun(
    "tests/test_p2t",
    flags = "-d:p2tArenaCdt -d:p2tSlotCdt -d:p2tFrontHash",
    outPath = "/tmp/p2t_test_arena_slot_front_hash_cdt",
    nimcache = "/tmp/p2t_test_arena_slot_front_hash_cdt_d",
  )

task testArenaFloat32Cdt, "run p2t tests with arena-backed float32 CDT":
  nimRun(
    "tests/test_p2t",
    flags = "-d:p2tArenaCdt -d:p2tFloat32Cdt",
    outPath = "/tmp/p2t_test_arena_float32_cdt",
    nimcache = "/tmp/p2t_test_arena_float32_cdt_d",
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

task benchArenaFrontHashCdt, "run p2t benchmark with arena CDT front hash":
  nimCompile(
    "bench/bench_p2t",
    flags = "--mm:arc -d:release --opt:speed -d:p2tArenaCdt -d:p2tUnsafeCdt -d:p2tFastRawCdt -d:p2tFrontHash",
    outPath = "/tmp/p2t_bench_arena_front_hash_cdt",
    nimcache = "/tmp/p2t_bench_arena_front_hash_cdt_d",
  )
  sh "strip " & quoteShell("/tmp/p2t_bench_arena_front_hash_cdt")
  echo "p2t arena front hash CDT"
  sh quoteShell("/tmp/p2t_bench_arena_front_hash_cdt")

task benchArenaSlotFrontHashCdt, "run p2t benchmark with arena CDT neighbor slots and front hash":
  nimCompile(
    "bench/bench_p2t",
    flags = "--mm:arc -d:release --opt:speed -d:p2tArenaCdt -d:p2tUnsafeCdt -d:p2tFastRawCdt -d:p2tSlotCdt -d:p2tFrontHash",
    outPath = "/tmp/p2t_bench_arena_slot_front_hash_cdt",
    nimcache = "/tmp/p2t_bench_arena_slot_front_hash_cdt_d",
  )
  sh "strip " & quoteShell("/tmp/p2t_bench_arena_slot_front_hash_cdt")
  echo "p2t arena slot front hash CDT"
  sh quoteShell("/tmp/p2t_bench_arena_slot_front_hash_cdt")

task benchArenaFloat32Cdt, "run p2t benchmark with arena-backed float32 CDT":
  nimCompile(
    "bench/bench_p2t",
    flags = "--mm:arc -d:release --opt:speed -d:p2tArenaCdt -d:p2tFloat32Cdt",
    outPath = "/tmp/p2t_bench_arena_float32_cdt",
    nimcache = "/tmp/p2t_bench_arena_float32_cdt_d",
  )
  sh "strip " & quoteShell("/tmp/p2t_bench_arena_float32_cdt")
  echo "p2t arena float32 CDT"
  sh quoteShell("/tmp/p2t_bench_arena_float32_cdt")

task benchEarcutFixtures, "run earcut against the p2t benchmark fixtures":
  if buildEarcutBench("/tmp/p2t_bench_earcut"):
    sh quoteShell("/tmp/p2t_bench_earcut")

task benchCdtStats, "report arena CDT operation counts":
  nimCompile(
    "bench/bench_cdt_stats",
    flags = "--mm:arc -d:release --opt:speed -d:p2tArenaCdt -d:p2tUnsafeCdt -d:p2tFastRawCdt -d:p2tCdtStats",
    outPath = "/tmp/p2t_bench_cdt_stats",
    nimcache = "/tmp/p2t_bench_cdt_stats_d",
  )
  sh quoteShell("/tmp/p2t_bench_cdt_stats")

  nimCompile(
    "bench/bench_cdt_stats",
    flags = "--mm:arc -d:release --opt:speed -d:p2tArenaCdt -d:p2tUnsafeCdt -d:p2tFastRawCdt -d:p2tCdtStats -d:p2tFrontHash",
    outPath = "/tmp/p2t_bench_cdt_stats_front_hash",
    nimcache = "/tmp/p2t_bench_cdt_stats_front_hash_d",
  )
  sh quoteShell("/tmp/p2t_bench_cdt_stats_front_hash")

task benchCompareAll, "compare best Nim, front hash, fast-poly2tri, and libtess2":
  nimCompile(
    "bench/bench_p2t",
    flags = "--mm:arc -d:release --opt:speed -d:p2tArenaCdt -d:p2tUnsafeCdt -d:p2tFastRawCdt",
    outPath = "/tmp/p2t_bench_best",
    nimcache = "/tmp/p2t_bench_best_d",
  )
  sh "strip " & quoteShell("/tmp/p2t_bench_best")

  nimCompile(
    "bench/bench_p2t",
    flags = "--mm:arc -d:release --opt:speed -d:p2tArenaCdt -d:p2tUnsafeCdt -d:p2tFastRawCdt -d:p2tFrontHash",
    outPath = "/tmp/p2t_bench_arena_front_hash_cdt",
    nimcache = "/tmp/p2t_bench_arena_front_hash_cdt_d",
  )
  sh "strip " & quoteShell("/tmp/p2t_bench_arena_front_hash_cdt")

  nimCompile(
    "bench/bench_p2t",
    flags = "--mm:arc -d:release --opt:speed -d:p2tArenaCdt -d:p2tUnsafeCdt -d:p2tFastRawCdt -d:p2tSlotCdt -d:p2tFrontHash",
    outPath = "/tmp/p2t_bench_arena_slot_front_hash_cdt",
    nimcache = "/tmp/p2t_bench_arena_slot_front_hash_cdt_d",
  )
  sh "strip " & quoteShell("/tmp/p2t_bench_arena_slot_front_hash_cdt")

  var reportArgs = @[
    "nim-best=/tmp/p2t_bench_best",
    "nim-front-hash=/tmp/p2t_bench_arena_front_hash_cdt",
    "nim-slot-front-hash=/tmp/p2t_bench_arena_slot_front_hash_cdt",
  ]

  let fastDir = findFastPoly2TriDir()
  if fastDir.len > 0:
    let headerDefine = "-DFAST_POLY2TRI_HEADER=\\\"" & fastDir /
      "MPE_fastpoly2tri.h" & "\\\""
    sh "clang -std=gnu99 -O3 -DNDEBUG " & headerDefine &
      " bench/bench_fastpoly2tri.c -o /tmp/p2t_fastpoly2tri_float -lm"
    sh "clang -std=gnu99 -O3 -DNDEBUG -DMPE_POLY2TRI_USE_DOUBLE " & headerDefine &
      " bench/bench_fastpoly2tri.c -o /tmp/p2t_fastpoly2tri_double -lm"
    reportArgs.add "fast-float=/tmp/p2t_fastpoly2tri_float"
    reportArgs.add "fast-double=/tmp/p2t_fastpoly2tri_double"
  else:
    echo "skipping fast-poly2tri; set FAST_POLY2TRI_DIR=/path/to/fast-poly2tri"

  if buildEarcutBench("/tmp/p2t_bench_earcut"):
    reportArgs.add "earcut-f64=/tmp/p2t_bench_earcut"

  let libtess2Dir = findLibtess2Dir()
  if libtess2Dir.len > 0:
    nimCompile(
      "bench/bench_libtess2_fixtures",
      flags = "--mm:arc -d:release --opt:speed -d:libtess2Dir=" &
        quoteShell(libtess2Dir),
      outPath = "/tmp/p2t_bench_libtess2_fixtures",
      nimcache = "/tmp/p2t_bench_libtess2_fixtures_d",
    )
    sh "strip " & quoteShell("/tmp/p2t_bench_libtess2_fixtures")
    reportArgs.add "libtess2=/tmp/p2t_bench_libtess2_fixtures"
  else:
    echo "skipping libtess2; set LIBTESS2_DIR=/path/to/libtess2"

  nimCompile(
    "bench/bench_compare_all",
    flags = "--mm:arc -d:release --opt:speed",
    outPath = "/tmp/p2t_bench_compare_all",
    nimcache = "/tmp/p2t_bench_compare_all_d",
  )
  sh quoteShell("/tmp/p2t_bench_compare_all") & " " & quoteArgs(reportArgs)

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

task benchBestFastPoly2Tri, "compare best raw trusted p2t against local fast-poly2tri":
  let fastDir = findFastPoly2TriDir()
  if fastDir.len == 0:
    quit(
      "fast-poly2tri not found; set FAST_POLY2TRI_DIR=/path/to/fast-poly2tri",
      QuitFailure,
    )

  nimCompile(
    "bench/bench_p2t",
    flags = "--mm:arc -d:release --opt:speed -d:p2tArenaCdt -d:p2tUnsafeCdt -d:p2tFastRawCdt",
    outPath = "/tmp/p2t_bench_best",
    nimcache = "/tmp/p2t_bench_best_d",
  )
  sh "strip " & quoteShell("/tmp/p2t_bench_best")
  echo "p2t best raw trusted CDT"
  sh quoteShell("/tmp/p2t_bench_best")

  let headerDefine = "-DFAST_POLY2TRI_HEADER=\\\"" & fastDir / "MPE_fastpoly2tri.h" & "\\\""
  sh "clang -std=gnu99 -O3 -DNDEBUG " & headerDefine &
    " bench/bench_fastpoly2tri.c -o /tmp/p2t_fastpoly2tri_float -lm"
  sh "clang -std=gnu99 -O3 -DNDEBUG -DMPE_POLY2TRI_USE_DOUBLE " & headerDefine &
    " bench/bench_fastpoly2tri.c -o /tmp/p2t_fastpoly2tri_double -lm"
  sh quoteShell("/tmp/p2t_fastpoly2tri_float")
  sh quoteShell("/tmp/p2t_fastpoly2tri_double")

task benchBestTuned, "run best raw trusted p2t with Tier 1 tuned codegen flags":
  nimCompile(
    "bench/bench_p2t",
    flags =
      "--mm:arc -d:release --opt:speed -d:p2tArenaCdt -d:p2tUnsafeCdt -d:p2tFastRawCdt -d:p2tFrontHash " &
      TunedFlags,
    outPath = "/tmp/p2t_bench_best_tuned",
    nimcache = "/tmp/p2t_bench_best_tuned_d",
  )
  sh "strip " & quoteShell("/tmp/p2t_bench_best_tuned")
  echo "p2t best raw trusted CDT (Tier 1 tuned)"
  sh quoteShell("/tmp/p2t_bench_best_tuned")

task benchBestTunedFastPoly2Tri, "compare Tier 1 tuned p2t against local fast-poly2tri":
  let fastDir = findFastPoly2TriDir()
  if fastDir.len == 0:
    quit(
      "fast-poly2tri not found; set FAST_POLY2TRI_DIR=/path/to/fast-poly2tri",
      QuitFailure,
    )

  nimCompile(
    "bench/bench_p2t",
    flags =
      "--mm:arc -d:release --opt:speed -d:p2tArenaCdt -d:p2tUnsafeCdt -d:p2tFastRawCdt -d:p2tFrontHash " &
      TunedFlags,
    outPath = "/tmp/p2t_bench_best_tuned",
    nimcache = "/tmp/p2t_bench_best_tuned_d",
  )
  sh "strip " & quoteShell("/tmp/p2t_bench_best_tuned")
  echo "p2t best raw trusted CDT (Tier 1 tuned)"
  sh quoteShell("/tmp/p2t_bench_best_tuned")

  let headerDefine = "-DFAST_POLY2TRI_HEADER=\\\"" & fastDir / "MPE_fastpoly2tri.h" & "\\\""
  sh "clang -std=gnu99 -O3 -DNDEBUG " & headerDefine &
    " bench/bench_fastpoly2tri.c -o /tmp/p2t_fastpoly2tri_float -lm"
  sh "clang -std=gnu99 -O3 -DNDEBUG -DMPE_POLY2TRI_USE_DOUBLE " & headerDefine &
    " bench/bench_fastpoly2tri.c -o /tmp/p2t_fastpoly2tri_double -lm"
  sh quoteShell("/tmp/p2t_fastpoly2tri_float")
  sh quoteShell("/tmp/p2t_fastpoly2tri_double")

task benchBestFastPoly2TriFloat32, "compare best float32 raw trusted p2t against local fast-poly2tri":
  let fastDir = findFastPoly2TriDir()
  if fastDir.len == 0:
    quit(
      "fast-poly2tri not found; set FAST_POLY2TRI_DIR=/path/to/fast-poly2tri",
      QuitFailure,
    )

  nimCompile(
    "bench/bench_p2t",
    flags = "--mm:arc -d:release --opt:speed -d:p2tArenaCdt -d:p2tUnsafeCdt -d:p2tFloat32Cdt -d:p2tFastRawCdt",
    outPath = "/tmp/p2t_bench_best_float32",
    nimcache = "/tmp/p2t_bench_best_float32_d",
  )
  sh "strip " & quoteShell("/tmp/p2t_bench_best_float32")
  echo "p2t best float32 raw trusted CDT"
  sh quoteShell("/tmp/p2t_bench_best_float32")

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
  sh "nph src/p2t.nim src/p2t/types.nim src/p2t/geometry.nim src/p2t/internal/cdt.nim src/p2t/internal/arena_cdt.nim src/p2t/triangulate.nim tests/test_p2t.nim tests/test_memory.nim tests/test_libtess2_compare.nim bench/bench_p2t.nim bench/bench_libtess2_compare.nim bench/bench_libtess2_fixtures.nim bench/bench_compare_all.nim bench/bench_cdt_stats.nim bench/quality_compare.nim bench/bench_parallel.nim bench/bench_struct_sizes.nim"
