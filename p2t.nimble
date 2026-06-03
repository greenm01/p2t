# Package

version = "0.1.0"
author = "Mason Austin Green"
description = "Standalone constrained polygon tessellation for Nim"
license = "BSD-3-Clause"
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

# Champion Nim configuration: pointer arena + pdqsort default + front hash
# default-on (opt out with -d:p2tNoFrontHash) + fast raw trusted path + Tier 1
# tuned codegen flags.
const ChampionFlags =
  "--mm:arc --threads:off -d:release --opt:speed " &
  "-d:p2tUnsafeCdt -d:p2tFastRawCdt " & TunedFlags

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

proc cAbiLibPath(): string =
  when defined(macosx):
    "/tmp/libp2t.dylib"
  elif defined(windows):
    "/tmp/p2t.dll"
  else:
    "/tmp/libp2t.so"

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

proc stressBenchDefines(fixture, name: string, iterations: int): string =
  " -d:StressFixture=" & fixture & " -d:StressName=" & name &
    " -d:StressIterations=" & $iterations

proc findLibtess2Dir(): string =
  let vendorDir = getCurrentDir() / "vendor" / "libtess2"
  if fileExists(vendorDir / "Include" / "tesselator.h"):
    return vendorDir

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
  let vendorDir = getCurrentDir() / "vendor" / "fast-poly2tri"
  if fileExists(vendorDir / "MPE_fastpoly2tri.h"):
    return vendorDir

  let envDir = getEnv("FAST_POLY2TRI_DIR")
  if envDir.len > 0 and fileExists(envDir / "MPE_fastpoly2tri.h"):
    return envDir

  let homeDir = getHomeDir() / "src" / "fast-poly2tri"
  if fileExists(homeDir / "MPE_fastpoly2tri.h"):
    return homeDir

  let siblingDir = getCurrentDir().parentDir / "fast-poly2tri"
  if fileExists(siblingDir / "MPE_fastpoly2tri.h"):
    return siblingDir

proc hasTriangleSource(path: string): bool =
  fileExists(path / "triangle.c") and fileExists(path / "triangle.h")

proc findTriangleDir(): string =
  let envDir = getEnv("TRIANGLE_DIR")
  if envDir.len > 0 and hasTriangleSource(envDir):
    return envDir

  let homeDir = getHomeDir() / "src" / "triangle"
  if hasTriangleSource(homeDir):
    return homeDir

  let siblingDir = getCurrentDir().parentDir / "triangle"
  if hasTriangleSource(siblingDir):
    return siblingDir

proc hasDelabellaSource(path: string): bool =
  fileExists(path / "delabella.h") and fileExists(path / "delabella.cpp")

proc findDelabellaDir(): string =
  let envDir = getEnv("DELABELLA_DIR")
  if envDir.len > 0 and hasDelabellaSource(envDir):
    return envDir

  let homeDir = getHomeDir() / "src" / "delabella"
  if hasDelabellaSource(homeDir):
    return homeDir

  let siblingDir = getCurrentDir().parentDir / "delabella"
  if hasDelabellaSource(siblingDir):
    return siblingDir

proc hasCdtSource(path: string): bool =
  fileExists(path / "CDT" / "include" / "CDT.h")

proc findCdtDir(): string =
  let envDir = getEnv("CDT_DIR")
  if envDir.len > 0 and hasCdtSource(envDir):
    return envDir

  let homeDir = getHomeDir() / "src" / "CDT"
  if hasCdtSource(homeDir):
    return homeDir

  let siblingDir = getCurrentDir().parentDir / "CDT"
  if hasCdtSource(siblingDir):
    return siblingDir

proc hasFade2dSdk(path: string): bool =
  fileExists(path / "include_fade2d" / "Fade_2D.h") and
    fileExists(path / "lib_mac" / "libfade2d.dylib") and
    fileExists(path / "lib_mac" / "libgmp.10.dylib")

proc findFade2dDir(): string =
  let envDir = getEnv("FADE2D_DIR")
  if envDir.len > 0 and hasFade2dSdk(envDir):
    return envDir

  let homeDir = getHomeDir() / "src" / "fadeRelease"
  if hasFade2dSdk(homeDir):
    return homeDir

  let siblingDir = getCurrentDir().parentDir / "fadeRelease"
  if hasFade2dSdk(siblingDir):
    return siblingDir

task testLibtess2, "compare dude fixture output against libtess2":
  let libtess2Dir = findLibtess2Dir()
  if libtess2Dir.len == 0:
    quit(
      "libtess2 not found; expected vendor/libtess2 or set LIBTESS2_DIR=/path/to/libtess2",
      QuitFailure,
    )
  nimRun(
    "tests/test_libtess2_compare",
    flags = "-d:libtess2Dir=" & quoteShell(libtess2Dir),
    outPath = "/tmp/p2t_test_libtess2",
    nimcache = "/tmp/p2t_test_libtess2_d",
  )

task benchLibtess2, "benchmark dude fixture against libtess2":
  let libtess2Dir = findLibtess2Dir()
  if libtess2Dir.len == 0:
    quit(
      "libtess2 not found; expected vendor/libtess2 or set LIBTESS2_DIR=/path/to/libtess2",
      QuitFailure,
    )
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
    quit(
      "libtess2 not found; expected vendor/libtess2 or set LIBTESS2_DIR=/path/to/libtess2",
      QuitFailure,
    )
  nimRun(
    "bench/quality_compare",
    flags = "--mm:arc -d:release --opt:speed -d:libtess2Dir=" & quoteShell(libtess2Dir),
    outPath = "/tmp/p2t_quality_libtess2",
    nimcache = "/tmp/p2t_quality_libtess2_d",
  )

task test, "run p2t tests":
  nimRun(
    "tests/test_public_api",
    outPath = "/tmp/p2t_test_public_api",
    nimcache = "/tmp/p2t_test_public_api_d",
  )
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
    flags = "",
    outPath = "/tmp/p2t_test_arena_cdt",
    nimcache = "/tmp/p2t_test_arena_cdt_d",
  )

task testArenaFrontHashCdt, "run p2t tests with arena CDT front hash default-on":
  nimRun(
    "tests/test_p2t",
    flags = "",
    outPath = "/tmp/p2t_test_arena_front_hash_cdt",
    nimcache = "/tmp/p2t_test_arena_front_hash_cdt_d",
  )

task testArenaSlotCdt, "run p2t tests with arena CDT neighbor slots":
  nimRun(
    "tests/test_p2t",
    flags = "-d:p2tSlotCdt",
    outPath = "/tmp/p2t_test_arena_slot_cdt",
    nimcache = "/tmp/p2t_test_arena_slot_cdt_d",
  )

task testArenaSlotFrontHashCdt, "run p2t tests with arena CDT neighbor slots and front hash default-on":
  nimRun(
    "tests/test_p2t",
    flags = "-d:p2tSlotCdt",
    outPath = "/tmp/p2t_test_arena_slot_front_hash_cdt",
    nimcache = "/tmp/p2t_test_arena_slot_front_hash_cdt_d",
  )

task testArenaFloat32Cdt, "run p2t tests with arena-backed float32 CDT":
  nimRun(
    "tests/test_p2t",
    flags = "-d:p2tFloat32Cdt",
    outPath = "/tmp/p2t_test_arena_float32_cdt",
    nimcache = "/tmp/p2t_test_arena_float32_cdt_d",
  )

task testIdxCdt, "run p2t tests with int32-index CDT twin":
  nimRun(
    "tests/test_p2t",
    flags = "-d:p2tIdxCdt",
    outPath = "/tmp/p2t_test_idx_cdt",
    nimcache = "/tmp/p2t_test_idx_cdt_d",
  )

task testMemory, "run repeated tessellation memory smoke":
  nimRun(
    "tests/test_memory",
    outPath = "/tmp/p2t_test_memory",
    nimcache = "/tmp/p2t_test_memory_d",
  )

task buildCAbi, "build optional p2t C ABI shared library":
  nimCompile(
    "src/p2t/capi",
    flags = "--app:lib --mm:arc -d:release --opt:speed -d:p2tUnsafeCdt -d:p2tFastRawCdt",
    outPath = cAbiLibPath(),
    nimcache = "/tmp/p2t_capi_d",
  )

task testCAbi, "build and run optional p2t C ABI smoke test":
  nimCompile(
    "src/p2t/capi",
    flags = "--app:lib --mm:arc -d:release --opt:speed -d:p2tUnsafeCdt -d:p2tFastRawCdt",
    outPath = cAbiLibPath(),
    nimcache = "/tmp/p2t_capi_d",
  )
  sh "clang -std=c99 -Iinclude tests/capi_smoke.c " & quoteShell(cAbiLibPath()) &
    " -o /tmp/p2t_capi_smoke -lm"
  sh "/tmp/p2t_capi_smoke"

task bench, "run champion Nim p2t benchmark":
  nimCompile(
    "bench/bench_p2t",
    flags = ChampionFlags,
    outPath = "/tmp/p2t_bench_champion",
    nimcache = "/tmp/p2t_bench_champion_d",
  )
  sh "strip " & quoteShell("/tmp/p2t_bench_champion")
  echo "p2t champion: pointer arena + pdqsort + front hash default-on + Tier 1 tuned"
  sh quoteShell("/tmp/p2t_bench_champion")

task benchTrusted, "run champion Nim tessellateTrusted benchmark":
  nimCompile(
    "bench/bench_p2t",
    flags = ChampionFlags & " -d:p2tBenchOnlyTrusted",
    outPath = "/tmp/p2t_bench_trusted",
    nimcache = "/tmp/p2t_bench_trusted_d",
  )
  sh "strip " & quoteShell("/tmp/p2t_bench_trusted")
  echo "p2t tessellateTrusted: public trusted path"
  sh quoteShell("/tmp/p2t_bench_trusted")

task benchNormalizedTrusted, "benchmark cheap normalized trusted path":
  nimCompile(
    "bench/bench_normalized_trusted",
    flags = ChampionFlags,
    outPath = "/tmp/p2t_bench_normalized_trusted",
    nimcache = "/tmp/p2t_bench_normalized_trusted_d",
  )
  sh "strip " & quoteShell("/tmp/p2t_bench_normalized_trusted")
  sh quoteShell("/tmp/p2t_bench_normalized_trusted")

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
    flags = "--mm:arc -d:release --opt:speed",
    outPath = "/tmp/p2t_bench_arena_cdt",
    nimcache = "/tmp/p2t_bench_arena_cdt_d",
  )
  sh "strip " & quoteShell("/tmp/p2t_bench_arena_cdt")
  echo "p2t arena CDT"
  sh quoteShell("/tmp/p2t_bench_arena_cdt")

task benchArenaFrontHashCdt, "run p2t benchmark with arena CDT front hash default-on":
  nimCompile(
    "bench/bench_p2t",
    flags = "--mm:arc -d:release --opt:speed -d:p2tUnsafeCdt -d:p2tFastRawCdt",
    outPath = "/tmp/p2t_bench_arena_front_hash_cdt",
    nimcache = "/tmp/p2t_bench_arena_front_hash_cdt_d",
  )
  sh "strip " & quoteShell("/tmp/p2t_bench_arena_front_hash_cdt")
  echo "p2t arena front hash CDT (default-on)"
  sh quoteShell("/tmp/p2t_bench_arena_front_hash_cdt")

task benchArenaSlotFrontHashCdt, "run p2t benchmark with arena CDT neighbor slots and front hash default-on":
  nimCompile(
    "bench/bench_p2t",
    flags = "--mm:arc -d:release --opt:speed -d:p2tUnsafeCdt -d:p2tFastRawCdt -d:p2tSlotCdt",
    outPath = "/tmp/p2t_bench_arena_slot_front_hash_cdt",
    nimcache = "/tmp/p2t_bench_arena_slot_front_hash_cdt_d",
  )
  sh "strip " & quoteShell("/tmp/p2t_bench_arena_slot_front_hash_cdt")
  echo "p2t arena slot front hash CDT (default-on)"
  sh quoteShell("/tmp/p2t_bench_arena_slot_front_hash_cdt")

task benchArenaFloat32Cdt, "run p2t benchmark with arena-backed float32 CDT":
  nimCompile(
    "bench/bench_p2t",
    flags = "--mm:arc -d:release --opt:speed -d:p2tFloat32Cdt",
    outPath = "/tmp/p2t_bench_arena_float32_cdt",
    nimcache = "/tmp/p2t_bench_arena_float32_cdt_d",
  )
  sh "strip " & quoteShell("/tmp/p2t_bench_arena_float32_cdt")
  echo "p2t arena float32 CDT"
  sh quoteShell("/tmp/p2t_bench_arena_float32_cdt")

task benchCdtStats, "report arena CDT operation counts":
  nimCompile(
    "bench/bench_cdt_stats",
    flags = "--mm:arc -d:release --opt:speed -d:p2tUnsafeCdt -d:p2tFastRawCdt -d:p2tCdtStats -d:p2tNoFrontHash",
    outPath = "/tmp/p2t_bench_cdt_stats",
    nimcache = "/tmp/p2t_bench_cdt_stats_d",
  )
  sh quoteShell("/tmp/p2t_bench_cdt_stats")

  nimCompile(
    "bench/bench_cdt_stats",
    flags = "--mm:arc -d:release --opt:speed -d:p2tUnsafeCdt -d:p2tFastRawCdt -d:p2tCdtStats -d:p2tFrontHashStats",
    outPath = "/tmp/p2t_bench_cdt_stats_front_hash",
    nimcache = "/tmp/p2t_bench_cdt_stats_front_hash_d",
  )
  sh quoteShell("/tmp/p2t_bench_cdt_stats_front_hash")

task benchPhaseProfile, "profile arena CDT phase timing on small fixtures":
  nimCompile(
    "bench/bench_phase_profile",
    flags = ChampionFlags & " -d:p2tPhaseProf",
    outPath = "/tmp/p2t_bench_phase_profile",
    nimcache = "/tmp/p2t_bench_phase_profile_d",
  )
  sh quoteShell("/tmp/p2t_bench_phase_profile")

task benchIncircleProfile, "profile arena CDT in-circle legalize work":
  nimCompile(
    "bench/bench_incircle_profile",
    flags = ChampionFlags & " -d:p2tCdtStats -d:p2tIncircleProf",
    outPath = "/tmp/p2t_bench_incircle_profile",
    nimcache = "/tmp/p2t_bench_incircle_profile_d",
  )
  sh quoteShell("/tmp/p2t_bench_incircle_profile")

task benchStressSmall, "benchmark the small stress fixture with champion Nim flags":
  nimCompile(
    "bench/bench_stress_small",
    flags = ChampionFlags & stressBenchDefines("stress/cdt_stress.dat", "stress-small", 5000),
    outPath = "/tmp/p2t_bench_stress_small",
    nimcache = "/tmp/p2t_bench_stress_small_d",
  )
  sh "strip " & quoteShell("/tmp/p2t_bench_stress_small")
  echo "p2t stress-small champion: pointer arena + pdqsort + front hash default-on + Tier 1 tuned"
  sh quoteShell("/tmp/p2t_bench_stress_small")

task benchStressSmallNoHash, "benchmark the small stress fixture with champion Nim flags and front hash disabled":
  nimCompile(
    "bench/bench_stress_small",
    flags = ChampionFlags & " -d:p2tNoFrontHash" &
      stressBenchDefines("stress/cdt_stress.dat", "stress-small", 5000),
    outPath = "/tmp/p2t_bench_stress_small_no_hash",
    nimcache = "/tmp/p2t_bench_stress_small_no_hash_d",
  )
  sh "strip " & quoteShell("/tmp/p2t_bench_stress_small_no_hash")
  echo "p2t stress-small champion without front hash"
  sh quoteShell("/tmp/p2t_bench_stress_small_no_hash")

task benchStressSmallStats, "report arena CDT stats for the small stress fixture":
  nimCompile(
    "bench/bench_stress_small",
    flags = ChampionFlags & " -d:p2tCdtStats -d:p2tFrontHashStats" &
      stressBenchDefines("stress/cdt_stress.dat", "stress-small", 5000),
    outPath = "/tmp/p2t_bench_stress_small_stats",
    nimcache = "/tmp/p2t_bench_stress_small_stats_d",
  )
  sh quoteShell("/tmp/p2t_bench_stress_small_stats")

task benchStressMid, "benchmark the mid stress fixture with champion Nim flags":
  nimCompile(
    "bench/bench_stress_small",
    flags = ChampionFlags & stressBenchDefines("stress/cdt_stress_mid.dat", "stress-mid", 1500),
    outPath = "/tmp/p2t_bench_stress_mid",
    nimcache = "/tmp/p2t_bench_stress_mid_d",
  )
  sh "strip " & quoteShell("/tmp/p2t_bench_stress_mid")
  echo "p2t stress-mid champion: pointer arena + pdqsort + front hash default-on + Tier 1 tuned"
  sh quoteShell("/tmp/p2t_bench_stress_mid")

task benchStressMidNoHash, "benchmark the mid stress fixture with champion Nim flags and front hash disabled":
  nimCompile(
    "bench/bench_stress_small",
    flags = ChampionFlags & " -d:p2tNoFrontHash" &
      stressBenchDefines("stress/cdt_stress_mid.dat", "stress-mid", 1500),
    outPath = "/tmp/p2t_bench_stress_mid_no_hash",
    nimcache = "/tmp/p2t_bench_stress_mid_no_hash_d",
  )
  sh "strip " & quoteShell("/tmp/p2t_bench_stress_mid_no_hash")
  echo "p2t stress-mid champion without front hash"
  sh quoteShell("/tmp/p2t_bench_stress_mid_no_hash")

task benchStressMidStats, "report arena CDT stats for the mid stress fixture":
  nimCompile(
    "bench/bench_stress_small",
    flags = ChampionFlags & " -d:p2tCdtStats -d:p2tFrontHashStats" &
      stressBenchDefines("stress/cdt_stress_mid.dat", "stress-mid", 1500),
    outPath = "/tmp/p2t_bench_stress_mid_stats",
    nimcache = "/tmp/p2t_bench_stress_mid_stats_d",
  )
  sh quoteShell("/tmp/p2t_bench_stress_mid_stats")

task benchStressLarge, "benchmark the large stress fixture with champion Nim flags":
  nimCompile(
    "bench/bench_stress_small",
    flags = ChampionFlags & stressBenchDefines("stress/cdt_stress_large.dat", "stress-large", 500),
    outPath = "/tmp/p2t_bench_stress_large",
    nimcache = "/tmp/p2t_bench_stress_large_d",
  )
  sh "strip " & quoteShell("/tmp/p2t_bench_stress_large")
  echo "p2t stress-large champion: pointer arena + pdqsort + front hash default-on + Tier 1 tuned"
  sh quoteShell("/tmp/p2t_bench_stress_large")

task benchStressLargeNoHash, "benchmark the large stress fixture with champion Nim flags and front hash disabled":
  nimCompile(
    "bench/bench_stress_small",
    flags = ChampionFlags & " -d:p2tNoFrontHash" &
      stressBenchDefines("stress/cdt_stress_large.dat", "stress-large", 500),
    outPath = "/tmp/p2t_bench_stress_large_no_hash",
    nimcache = "/tmp/p2t_bench_stress_large_no_hash_d",
  )
  sh "strip " & quoteShell("/tmp/p2t_bench_stress_large_no_hash")
  echo "p2t stress-large champion without front hash"
  sh quoteShell("/tmp/p2t_bench_stress_large_no_hash")

task benchStressLargeStats, "report arena CDT stats for the large stress fixture":
  nimCompile(
    "bench/bench_stress_small",
    flags = ChampionFlags & " -d:p2tCdtStats -d:p2tFrontHashStats" &
      stressBenchDefines("stress/cdt_stress_large.dat", "stress-large", 500),
    outPath = "/tmp/p2t_bench_stress_large_stats",
    nimcache = "/tmp/p2t_bench_stress_large_stats_d",
  )
  sh quoteShell("/tmp/p2t_bench_stress_large_stats")

task benchStressOrganicLarge, "benchmark the organic large control fixture with champion Nim flags":
  nimCompile(
    "bench/bench_stress_small",
    flags = ChampionFlags &
      stressBenchDefines("organic/cdt_organic_large.dat", "organic-large", 500),
    outPath = "/tmp/p2t_bench_stress_organic_large",
    nimcache = "/tmp/p2t_bench_stress_organic_large_d",
  )
  sh "strip " & quoteShell("/tmp/p2t_bench_stress_organic_large")
  echo "p2t organic-large champion: pointer arena + pdqsort + front hash default-on + Tier 1 tuned"
  sh quoteShell("/tmp/p2t_bench_stress_organic_large")

task benchStressOrganicLargeNoHash, "benchmark the organic large control fixture with champion Nim flags and front hash disabled":
  nimCompile(
    "bench/bench_stress_small",
    flags = ChampionFlags & " -d:p2tNoFrontHash" &
      stressBenchDefines("organic/cdt_organic_large.dat", "organic-large", 500),
    outPath = "/tmp/p2t_bench_stress_organic_large_no_hash",
    nimcache = "/tmp/p2t_bench_stress_organic_large_no_hash_d",
  )
  sh "strip " & quoteShell("/tmp/p2t_bench_stress_organic_large_no_hash")
  echo "p2t organic-large champion without front hash"
  sh quoteShell("/tmp/p2t_bench_stress_organic_large_no_hash")

task benchStressOrganicLargeStats, "report arena CDT stats for the organic large control fixture":
  nimCompile(
    "bench/bench_stress_small",
    flags = ChampionFlags & " -d:p2tCdtStats -d:p2tNoFrontHash" &
      stressBenchDefines("organic/cdt_organic_large.dat", "organic-large-nohash", 500),
    outPath = "/tmp/p2t_bench_stress_organic_large_stats_no_hash",
    nimcache = "/tmp/p2t_bench_stress_organic_large_stats_no_hash_d",
  )
  sh quoteShell("/tmp/p2t_bench_stress_organic_large_stats_no_hash")

  nimCompile(
    "bench/bench_stress_small",
    flags = ChampionFlags & " -d:p2tCdtStats -d:p2tFrontHashStats" &
      stressBenchDefines("organic/cdt_organic_large.dat", "organic-large", 500),
    outPath = "/tmp/p2t_bench_stress_organic_large_stats",
    nimcache = "/tmp/p2t_bench_stress_organic_large_stats_d",
  )
  sh quoteShell("/tmp/p2t_bench_stress_organic_large_stats")

task benchCompareAll, "compare champion Nim, hash-off, slot, idx, fast-poly2tri, libtess2, and Triangle":
  nimCompile(
    "bench/bench_p2t",
    flags = ChampionFlags,
    outPath = "/tmp/p2t_bench_champion",
    nimcache = "/tmp/p2t_bench_champion_d",
  )
  sh "strip " & quoteShell("/tmp/p2t_bench_champion")

  nimCompile(
    "bench/bench_p2t",
    flags = ChampionFlags & " -d:p2tNoFrontHash",
    outPath = "/tmp/p2t_bench_champion_no_front_hash",
    nimcache = "/tmp/p2t_bench_champion_no_front_hash_d",
  )
  sh "strip " & quoteShell("/tmp/p2t_bench_champion_no_front_hash")

  nimCompile(
    "bench/bench_p2t",
    flags = ChampionFlags & " -d:p2tSlotCdt",
    outPath = "/tmp/p2t_bench_arena_slot_front_hash_cdt",
    nimcache = "/tmp/p2t_bench_arena_slot_front_hash_cdt_d",
  )
  sh "strip " & quoteShell("/tmp/p2t_bench_arena_slot_front_hash_cdt")

  nimCompile(
    "bench/bench_p2t",
    flags =
      "--mm:arc --threads:off -d:release --opt:speed -d:p2tIdxCdt " &
      "-d:p2tUnsafeCdt -d:p2tFastRawCdt " & TunedFlags,
    outPath = "/tmp/p2t_bench_idx_tuned",
    nimcache = "/tmp/p2t_bench_idx_tuned_d",
  )
  sh "strip " & quoteShell("/tmp/p2t_bench_idx_tuned")

  var reportArgs = @[
    "nim-champion=/tmp/p2t_bench_champion",
    "nim-no-front-hash=/tmp/p2t_bench_champion_no_front_hash",
    "nim-slot-front-hash=/tmp/p2t_bench_arena_slot_front_hash_cdt",
    "nim-idx-front-hash=/tmp/p2t_bench_idx_tuned",
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
    echo "skipping fast-poly2tri; expected vendor/fast-poly2tri or set FAST_POLY2TRI_DIR=/path/to/fast-poly2tri"

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
    echo "skipping libtess2; expected vendor/libtess2 or set LIBTESS2_DIR=/path/to/libtess2"

  let triangleDir = findTriangleDir()
  if triangleDir.len > 0:
    for variant in [
      ("triangle-pzQN", "pzQN"),
      ("triangle-plzQN", "plzQN"),
      ("triangle-pizQN", "pizQN"),
      ("triangle-pFzQN", "pFzQN"),
      ("triangle-unsafe-pzQNX", "pzQNX"),
      ("triangle-unsafe-plzQNX", "plzQNX"),
      ("triangle-unsafe-pizQNX", "pizQNX"),
      ("triangle-unsafe-pFzQNX", "pFzQNX"),
    ]:
      let
        engine = variant[0]
        switches = variant[1]
        outPath = "/tmp/p2t_" & engine.replace("-", "_")
      sh "clang -std=gnu99 -O3 -Wno-deprecated-non-prototype -DNDEBUG " &
        "-DTRILIBRARY -DNO_TIMER " &
        "-DTRIANGLE_SWITCHES=\\\"" & switches & "\\\" " &
        "-DTRIANGLE_LABEL=\\\"" & engine & "\\\" " &
        "-I" & quoteShell(triangleDir) & " " &
        quoteShell(triangleDir / "triangle.c") &
        " bench/bench_triangle.c -o " & quoteShell(outPath) & " -lm"
      reportArgs.add engine & "=" & outPath
  else:
    echo "skipping Triangle; set TRIANGLE_DIR=/path/to/triangle containing triangle.c and triangle.h"

  nimCompile(
    "bench/bench_compare_all",
    flags = "--mm:arc -d:release --opt:speed",
    outPath = "/tmp/p2t_bench_compare_all",
    nimcache = "/tmp/p2t_bench_compare_all_d",
  )
  sh quoteShell("/tmp/p2t_bench_compare_all") & " " & quoteArgs(reportArgs)

task benchExternalContenders, "run external Delabella, CDT, and Fade2D contender benchmark":
  let delabellaDir = findDelabellaDir()
  if delabellaDir.len == 0:
    quit(
      "Delabella not found; set DELABELLA_DIR=/path/to/delabella containing delabella.h and delabella.cpp",
      QuitFailure,
    )

  let cdtDir = findCdtDir()
  if cdtDir.len == 0:
    quit(
      "artem-ogre/CDT not found; set CDT_DIR=/path/to/CDT containing CDT/include/CDT.h",
      QuitFailure,
    )

  let fade2dDir = findFade2dDir()
  if fade2dDir.len == 0:
    quit(
      "Fade2D SDK not found; set FADE2D_DIR=/path/to/fadeRelease containing include_fade2d/ and lib_mac/",
      QuitFailure,
    )

  let fadeLibDir = fade2dDir / "lib_mac"
  sh "clang++ -std=c++17 -O3 -DNDEBUG " &
    "-I" & quoteShell(delabellaDir) & " " &
    "-I" & quoteShell(cdtDir / "CDT" / "include") & " " &
    "-I" & quoteShell(fade2dDir / "include_fade2d") & " " &
    "bench/bench_external_contenders.cpp " &
    quoteShell(delabellaDir / "delabella.cpp") & " " &
    "-L" & quoteShell(fadeLibDir) & " -lfade2d " &
    quoteShell(fadeLibDir / "libgmp.10.dylib") & " " &
    "-Wl,-rpath," & quoteShell(fadeLibDir) & " " &
    "-o /tmp/p2t_external_contenders"
  sh quoteShell("/tmp/p2t_external_contenders")

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
      "fast-poly2tri not found; expected vendor/fast-poly2tri or set FAST_POLY2TRI_DIR=/path/to/fast-poly2tri",
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
      "fast-poly2tri not found; expected vendor/fast-poly2tri or set FAST_POLY2TRI_DIR=/path/to/fast-poly2tri",
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
      "fast-poly2tri not found; expected vendor/fast-poly2tri or set FAST_POLY2TRI_DIR=/path/to/fast-poly2tri",
      QuitFailure,
    )

  nimCompile(
    "bench/bench_p2t",
    flags = "--mm:arc -d:release --opt:speed -d:p2tUnsafeCdt",
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
      "fast-poly2tri not found; expected vendor/fast-poly2tri or set FAST_POLY2TRI_DIR=/path/to/fast-poly2tri",
      QuitFailure,
    )

  nimCompile(
    "bench/bench_p2t",
    flags = "--mm:arc -d:release --opt:speed -d:p2tUnsafeCdt -d:p2tFastRawCdt",
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

task benchBestTuned, "run champion Nim p2t with Tier 1 tuned codegen flags":
  nimCompile(
    "bench/bench_p2t",
    flags = ChampionFlags,
    outPath = "/tmp/p2t_bench_champion",
    nimcache = "/tmp/p2t_bench_champion_d",
  )
  sh "strip " & quoteShell("/tmp/p2t_bench_champion")
  echo "p2t champion: pointer arena + pdqsort + front hash default-on + Tier 1 tuned"
  sh quoteShell("/tmp/p2t_bench_champion")

task benchIdxTuned, "run int32-index CDT twin with Tier 1 tuned codegen flags":
  nimCompile(
    "bench/bench_p2t",
    flags =
      "--mm:arc --threads:off -d:release --opt:speed -d:p2tIdxCdt -d:p2tUnsafeCdt -d:p2tFastRawCdt " &
      TunedFlags,
    outPath = "/tmp/p2t_bench_idx_tuned",
    nimcache = "/tmp/p2t_bench_idx_tuned_d",
  )
  sh "strip " & quoteShell("/tmp/p2t_bench_idx_tuned")
  echo "p2t int32-index CDT twin (Tier 1 tuned)"
  sh quoteShell("/tmp/p2t_bench_idx_tuned")

task benchBestTunedFastPoly2Tri, "compare champion Nim p2t against local fast-poly2tri":
  let fastDir = findFastPoly2TriDir()
  if fastDir.len == 0:
    quit(
      "fast-poly2tri not found; expected vendor/fast-poly2tri or set FAST_POLY2TRI_DIR=/path/to/fast-poly2tri",
      QuitFailure,
    )

  nimCompile(
    "bench/bench_p2t",
    flags = ChampionFlags,
    outPath = "/tmp/p2t_bench_champion",
    nimcache = "/tmp/p2t_bench_champion_d",
  )
  sh "strip " & quoteShell("/tmp/p2t_bench_champion")
  echo "p2t champion: pointer arena + pdqsort + front hash default-on + Tier 1 tuned"
  sh quoteShell("/tmp/p2t_bench_champion")

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
      "fast-poly2tri not found; expected vendor/fast-poly2tri or set FAST_POLY2TRI_DIR=/path/to/fast-poly2tri",
      QuitFailure,
    )

  nimCompile(
    "bench/bench_p2t",
    flags = "--mm:arc -d:release --opt:speed -d:p2tUnsafeCdt -d:p2tFloat32Cdt -d:p2tFastRawCdt",
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
  sh "nph src/p2t.nim src/p2t/types.nim src/p2t/geometry.nim src/p2t/capi.nim src/p2t/internal/cdt.nim src/p2t/internal/arena_cdt.nim src/p2t/triangulate.nim tests/test_public_api.nim tests/test_p2t.nim tests/test_memory.nim tests/test_libtess2_compare.nim bench/bench_p2t.nim bench/bench_libtess2_compare.nim bench/bench_libtess2_fixtures.nim bench/bench_compare_all.nim bench/bench_cdt_stats.nim bench/bench_stress_small.nim bench/bench_normalized_trusted.nim bench/quality_compare.nim bench/bench_parallel.nim bench/bench_struct_sizes.nim"
