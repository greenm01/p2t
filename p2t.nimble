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

when defined(amd64) or defined(i386):
  const NativeCpuFlag = "-march=native"
else:
  const NativeCpuFlag = "-mcpu=native"

# Tier 1 release codegen tuning. Measured (Apple M4 Pro, best-of-3, raw path):
# 1.32x-1.57x faster than the untuned best config, no output change.
#   --panics:on          : drops exception unwinding, frees the C optimizer
#   -flto                : cross-module inlining of predicates/allocator
#   -mcpu/-march=native  : host-tuned codegen
# Deliberately excluded: -ffp-contract=fast (FMA gave no win; predicates are
# already non-robust float) and -d:useMalloc (no win vs ARC TLS allocator).
const TunedFlags =
  "--panics:on --passC:-flto --passL:-flto --passC:" & NativeCpuFlag &
  " --passL:" & NativeCpuFlag

# Host-tuned release flags for non-Nim benchmark contenders. These mirror the
# C/linker side of `TunedFlags` so p2t is not the only entry getting LTO and
# native CPU codegen in head-to-head comparisons.
const ContenderBaseCFlags = "-O3 -DNDEBUG -flto " & NativeCpuFlag
const ContenderBaseLinkFlags = "-flto " & NativeCpuFlag

# Champion Nim configuration: pointer arena + pdqsort default + front hash
# default-on (opt out with -d:p2tNoFrontHash) + fast raw trusted path + Tier 1
# tuned codegen flags.
const ChampionFlags =
  "--mm:arc --threads:off -d:release --opt:speed " &
  "-d:p2tUnsafeCdt -d:p2tFastRawCdt " & TunedFlags

proc sh(cmd: string) =
  exec cmd

proc p2tFlags(): string =
  ## Optional per-machine flags for benchmark contender builds.
  ##
  ## Use this for platform-specific include/library/runtime paths, for example
  ## `-I/opt/foo/include -L/opt/foo/lib -Wl,-rpath,/opt/foo/lib`.
  getEnv("P2T_FLAGS")

proc addFlags(base, extra: string): string =
  if extra.len == 0:
    base
  elif base.len == 0:
    extra
  else:
    base & " " & extra

proc contenderCFlags(): string =
  ContenderBaseCFlags.addFlags(p2tFlags())

proc contenderLinkFlags(): string =
  ContenderBaseLinkFlags.addFlags(p2tFlags())

proc cCompiler(): string =
  getEnv("CC", "clang")

proc cxxCompiler(): string =
  getEnv("CXX", "clang++")

proc exeExt(): string =
  when defined(windows):
    ".exe"
  else:
    ""

proc tmpExe(name: string): string =
  getTempDir() / (name & exeExt())

proc tempRoots(): seq[string] =
  result.add getTempDir()
  when not defined(windows):
    for path in ["/tmp", "/private/tmp"]:
      if path notin result:
        result.add path

proc stripBinary(path: string) =
  when not defined(windows):
    sh "strip " & quoteShell(path)

proc mathLibFlag(): string =
  when defined(windows):
    ""
  else:
    "-lm"

proc compileFastPoly2Tri(fastDir: string) =
  let
    cFlags = contenderCFlags()
    linkFlags = contenderLinkFlags()
    headerDefine = "-DFAST_POLY2TRI_HEADER=\\\"" & fastDir /
      "MPE_fastpoly2tri.h" & "\\\""
    buildFlagsDefine = quoteShell(
      "-DBENCH_BUILD_FLAGS=\"" & cFlags & " " & linkFlags & "\""
    )
    mathFlag = mathLibFlag()
  sh cCompiler() & " -std=gnu99 " & cFlags & " " & buildFlagsDefine & " " &
    headerDefine & " bench/bench_fastpoly2tri.c " & linkFlags &
    " -o " & quoteShell(tmpExe("p2t_fastpoly2tri_float")) & " " & mathFlag
  sh cCompiler() & " -std=gnu99 " & cFlags & " -DMPE_POLY2TRI_USE_DOUBLE " &
    buildFlagsDefine & " " & headerDefine & " bench/bench_fastpoly2tri.c " &
    linkFlags & " -o " & quoteShell(tmpExe("p2t_fastpoly2tri_double")) &
    " " & mathFlag

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

  for root in tempRoots():
    let tmpDir = root / "triangle"
    if hasTriangleSource(tmpDir):
      return tmpDir

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

  for root in tempRoots():
    let tmpDir = root / "p2t-contenders" / "delabella"
    if hasDelabellaSource(tmpDir):
      return tmpDir

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

  for root in tempRoots():
    let tmpDir = root / "p2t-contenders" / "CDT"
    if hasCdtSource(tmpDir):
      return tmpDir

  let homeDir = getHomeDir() / "src" / "CDT"
  if hasCdtSource(homeDir):
    return homeDir

  let siblingDir = getCurrentDir().parentDir / "CDT"
  if hasCdtSource(siblingDir):
    return siblingDir

proc hasFade2dSdk(path: string): bool =
  fileExists(path / "include_fade2d" / "Fade_2D.h")

proc fade2dLibraryDir(path: string): string =
  const candidates = [
    "lib_mac", "lib_linux", "lib", "bin", "x64", "x86_64", "Release"
  ]
  const names = [
    "libfade2d.dylib", "libfade2d.so", "libfade2d.a", "fade2d.lib", "fade2d.dll"
  ]
  for dirName in candidates:
    let dir = path / dirName
    for name in names:
      if fileExists(dir / name):
        return dir

proc optionalLibraryPath(dir: string, names: openArray[string]): string =
  for name in names:
    let path = dir / name
    if fileExists(path):
      return path

proc rpathFlag(dir: string): string =
  when defined(windows):
    ""
  elif defined(macosx):
    "-Wl,-rpath," & quoteShell(dir)
  else:
    "-Wl,-rpath," & quoteShell(dir)

proc fade2dLinkFlags(fade2dDir: string): string =
  let libDir = fade2dLibraryDir(fade2dDir)
  if libDir.len == 0:
    return p2tFlags()

  result = "-L" & quoteShell(libDir) & " -lfade2d"
  let gmp = optionalLibraryPath(
    libDir,
    [
      "libgmp.10.dylib", "libgmp.dylib", "libgmp.so", "libgmp.a", "gmp.lib",
      "libgmp-10.dll", "gmp.dll"
    ]
  )
  if gmp.len > 0:
    result.add " " & quoteShell(gmp)
  let rpath = rpathFlag(libDir)
  if rpath.len > 0:
    result.add " " & rpath
  result = result.addFlags(p2tFlags())

proc findFade2dDir(): string =
  let envDir = getEnv("FADE2D_DIR")
  if envDir.len > 0 and hasFade2dSdk(envDir):
    return envDir

  for root in tempRoots():
    let tmpDir = root / "p2t-contenders" / "fadeRelease_v2.17.3" /
      "fadeRelease_v2.17.3"
    if hasFade2dSdk(tmpDir):
      return tmpDir

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
    flags = "--mm:arc --threads:off -d:release --opt:speed " & TunedFlags &
      " -d:libtess2Dir=" & quoteShell(libtess2Dir),
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
    flags = "--mm:arc --threads:off -d:release --opt:speed " & TunedFlags &
      " -d:libtess2Dir=" & quoteShell(libtess2Dir),
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

task testDewall, "run experimental DeWall DT tests":
  nimRun(
    "tests/test_dewall",
    outPath = "/tmp/p2t_test_dewall",
    nimcache = "/tmp/p2t_test_dewall_d",
  )

task testDewallHotStats, "run experimental DeWall hot-stats tests":
  nimRun(
    "tests/test_dewall_hot_stats",
    flags = "-d:p2tDewallHotStats",
    outPath = "/tmp/p2t_test_dewall_hot_stats",
    nimcache = "/tmp/p2t_test_dewall_hot_stats_d",
  )

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
  let
    championPath = tmpExe("p2t_bench_champion")
    noFrontHashPath = tmpExe("p2t_bench_champion_no_front_hash")
    slotPath = tmpExe("p2t_bench_arena_slot_front_hash_cdt")
    idxPath = tmpExe("p2t_bench_idx_tuned")
    comparePath = tmpExe("p2t_bench_compare_all")
    libtess2Path = tmpExe("p2t_bench_libtess2_fixtures")

  nimCompile(
    "bench/bench_p2t",
    flags = ChampionFlags,
    outPath = championPath,
    nimcache = getTempDir() / "p2t_bench_champion_d",
  )
  stripBinary(championPath)

  nimCompile(
    "bench/bench_p2t",
    flags = ChampionFlags & " -d:p2tNoFrontHash",
    outPath = noFrontHashPath,
    nimcache = getTempDir() / "p2t_bench_champion_no_front_hash_d",
  )
  stripBinary(noFrontHashPath)

  nimCompile(
    "bench/bench_p2t",
    flags = ChampionFlags & " -d:p2tSlotCdt",
    outPath = slotPath,
    nimcache = getTempDir() / "p2t_bench_arena_slot_front_hash_cdt_d",
  )
  stripBinary(slotPath)

  nimCompile(
    "bench/bench_p2t",
    flags =
      "--mm:arc --threads:off -d:release --opt:speed -d:p2tIdxCdt " &
      "-d:p2tUnsafeCdt -d:p2tFastRawCdt " & TunedFlags,
    outPath = idxPath,
    nimcache = getTempDir() / "p2t_bench_idx_tuned_d",
  )
  stripBinary(idxPath)

  var reportArgs = @[
    "nim-champion=" & championPath,
    "nim-no-front-hash=" & noFrontHashPath,
    "nim-slot-front-hash=" & slotPath,
    "nim-idx-front-hash=" & idxPath,
  ]

  let fastDir = findFastPoly2TriDir()
  if fastDir.len > 0:
    compileFastPoly2Tri(fastDir)
    reportArgs.add "fast-float=" & tmpExe("p2t_fastpoly2tri_float")
    reportArgs.add "fast-double=" & tmpExe("p2t_fastpoly2tri_double")
  else:
    echo "skipping fast-poly2tri; expected vendor/fast-poly2tri or set FAST_POLY2TRI_DIR=/path/to/fast-poly2tri"

  let libtess2Dir = findLibtess2Dir()
  if libtess2Dir.len > 0:
    nimCompile(
      "bench/bench_libtess2_fixtures",
      flags = "--mm:arc --threads:off -d:release --opt:speed " & TunedFlags &
        " -d:libtess2Dir=" &
        quoteShell(libtess2Dir),
      outPath = libtess2Path,
      nimcache = getTempDir() / "p2t_bench_libtess2_fixtures_d",
    )
    stripBinary(libtess2Path)
    reportArgs.add "libtess2=" & libtess2Path
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
        outPath = tmpExe("p2t_" & engine.replace("-", "_"))
        cFlags = contenderCFlags()
        linkFlags = contenderLinkFlags()
      sh cCompiler() & " -std=gnu99 " & cFlags &
        " -Wno-deprecated-non-prototype " &
        quoteShell(
          "-DBENCH_BUILD_FLAGS=\"" & cFlags & " " & linkFlags & "\""
        ) & " " &
        "-DTRILIBRARY -DNO_TIMER " &
        "-DTRIANGLE_SWITCHES=\\\"" & switches & "\\\" " &
        "-DTRIANGLE_LABEL=\\\"" & engine & "\\\" " &
        "-I" & quoteShell(triangleDir) & " " &
        quoteShell(triangleDir / "triangle.c") &
        " bench/bench_triangle.c " & linkFlags &
        " -o " & quoteShell(outPath) & " " & mathLibFlag()
      reportArgs.add engine & "=" & outPath
  else:
    echo "skipping Triangle; set TRIANGLE_DIR=/path/to/triangle containing triangle.c and triangle.h"

  nimCompile(
    "bench/bench_compare_all",
    flags = "--mm:arc -d:release --opt:speed",
    outPath = comparePath,
    nimcache = getTempDir() / "p2t_bench_compare_all_d",
  )
  sh quoteShell(comparePath) & " " & quoteArgs(reportArgs)

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

  let
    externalPath = tmpExe("p2t_external_contenders")
    cFlags = contenderCFlags()
    linkFlags = contenderLinkFlags()
    fadeFlags = fade2dLinkFlags(fade2dDir)
  if fade2dLibraryDir(fade2dDir).len == 0 and p2tFlags().len == 0:
    quit(
      "Fade2D library not found; set FADE2D_DIR to the SDK root and/or P2T_FLAGS with required -L/-l flags",
      QuitFailure,
    )
  sh cxxCompiler() & " -std=c++17 " & cFlags & " " &
    quoteShell(
      "-DBENCH_BUILD_FLAGS=\"" & cFlags & " " & linkFlags & " " &
        fadeFlags & "\""
    ) & " " &
    "-I" & quoteShell(delabellaDir) & " " &
    "-I" & quoteShell(cdtDir / "CDT" / "include") & " " &
    "-I" & quoteShell(fade2dDir / "include_fade2d") & " " &
    "bench/bench_external_contenders.cpp " &
    quoteShell(delabellaDir / "delabella.cpp") & " " &
    linkFlags & " " & fadeFlags & " " &
    "-o " & quoteShell(externalPath)
  sh quoteShell(externalPath)

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
  let benchPath = tmpExe("p2t_bench_cross")

  nimCompile(
    "bench/bench_p2t",
    flags = "--mm:arc -d:release --opt:speed",
    outPath = benchPath,
    nimcache = getTempDir() / "p2t_bench_cross_d",
  )
  stripBinary(benchPath)
  echo "p2t"
  sh quoteShell(benchPath)

  compileFastPoly2Tri(fastDir)
  sh quoteShell(tmpExe("p2t_fastpoly2tri_float"))
  sh quoteShell(tmpExe("p2t_fastpoly2tri_double"))

task benchFastPoly2TriUnsafe, "compare unsafe CDT p2t against local fast-poly2tri":
  let fastDir = findFastPoly2TriDir()
  if fastDir.len == 0:
    quit(
      "fast-poly2tri not found; expected vendor/fast-poly2tri or set FAST_POLY2TRI_DIR=/path/to/fast-poly2tri",
      QuitFailure,
    )
  let benchPath = tmpExe("p2t_bench_cross_unsafe_cdt")

  nimCompile(
    "bench/bench_p2t",
    flags = "--mm:arc -d:release --opt:speed -d:p2tUnsafeCdt",
    outPath = benchPath,
    nimcache = getTempDir() / "p2t_bench_cross_unsafe_cdt_d",
  )
  stripBinary(benchPath)
  echo "p2t unsafe CDT"
  sh quoteShell(benchPath)

  compileFastPoly2Tri(fastDir)
  sh quoteShell(tmpExe("p2t_fastpoly2tri_float"))
  sh quoteShell(tmpExe("p2t_fastpoly2tri_double"))

task benchFastPoly2TriArena, "compare arena CDT p2t against local fast-poly2tri":
  let fastDir = findFastPoly2TriDir()
  if fastDir.len == 0:
    quit(
      "fast-poly2tri not found; expected vendor/fast-poly2tri or set FAST_POLY2TRI_DIR=/path/to/fast-poly2tri",
      QuitFailure,
    )
  let benchPath = tmpExe("p2t_bench_cross_arena_cdt")

  nimCompile(
    "bench/bench_p2t",
    flags = "--mm:arc -d:release --opt:speed -d:p2tUnsafeCdt",
    outPath = benchPath,
    nimcache = getTempDir() / "p2t_bench_cross_arena_cdt_d",
  )
  stripBinary(benchPath)
  echo "p2t arena unsafe CDT"
  sh quoteShell(benchPath)

  compileFastPoly2Tri(fastDir)
  sh quoteShell(tmpExe("p2t_fastpoly2tri_float"))
  sh quoteShell(tmpExe("p2t_fastpoly2tri_double"))

task benchBestFastPoly2Tri, "compare best raw trusted p2t against local fast-poly2tri":
  let fastDir = findFastPoly2TriDir()
  if fastDir.len == 0:
    quit(
      "fast-poly2tri not found; expected vendor/fast-poly2tri or set FAST_POLY2TRI_DIR=/path/to/fast-poly2tri",
      QuitFailure,
    )
  let benchPath = tmpExe("p2t_bench_best")

  nimCompile(
    "bench/bench_p2t",
    flags = "--mm:arc -d:release --opt:speed -d:p2tUnsafeCdt -d:p2tFastRawCdt",
    outPath = benchPath,
    nimcache = getTempDir() / "p2t_bench_best_d",
  )
  stripBinary(benchPath)
  echo "p2t best raw trusted CDT"
  sh quoteShell(benchPath)

  compileFastPoly2Tri(fastDir)
  sh quoteShell(tmpExe("p2t_fastpoly2tri_float"))
  sh quoteShell(tmpExe("p2t_fastpoly2tri_double"))

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
  let benchPath = tmpExe("p2t_bench_champion")

  nimCompile(
    "bench/bench_p2t",
    flags = ChampionFlags,
    outPath = benchPath,
    nimcache = getTempDir() / "p2t_bench_champion_d",
  )
  stripBinary(benchPath)
  echo "p2t champion: pointer arena + pdqsort + front hash default-on + Tier 1 tuned"
  sh quoteShell(benchPath)

  compileFastPoly2Tri(fastDir)
  sh quoteShell(tmpExe("p2t_fastpoly2tri_float"))
  sh quoteShell(tmpExe("p2t_fastpoly2tri_double"))

task benchBestFastPoly2TriFloat32, "compare best float32 raw trusted p2t against local fast-poly2tri":
  let fastDir = findFastPoly2TriDir()
  if fastDir.len == 0:
    quit(
      "fast-poly2tri not found; expected vendor/fast-poly2tri or set FAST_POLY2TRI_DIR=/path/to/fast-poly2tri",
      QuitFailure,
    )
  let benchPath = tmpExe("p2t_bench_best_float32")

  nimCompile(
    "bench/bench_p2t",
    flags = "--mm:arc -d:release --opt:speed -d:p2tUnsafeCdt -d:p2tFloat32Cdt -d:p2tFastRawCdt",
    outPath = benchPath,
    nimcache = getTempDir() / "p2t_bench_best_float32_d",
  )
  stripBinary(benchPath)
  echo "p2t best float32 raw trusted CDT"
  sh quoteShell(benchPath)

  compileFastPoly2Tri(fastDir)
  sh quoteShell(tmpExe("p2t_fastpoly2tri_float"))
  sh quoteShell(tmpExe("p2t_fastpoly2tri_double"))

task benchParallel, "benchmark tessellateBatch scaling across threads":
  nimCompile(
    "bench/bench_parallel",
    flags = "--mm:orc --threads:on -d:useMalloc -d:release --opt:speed",
    outPath = "/tmp/p2t_bench_parallel",
    nimcache = "/tmp/p2t_bench_parallel_d",
  )
  sh "strip " & quoteShell("/tmp/p2t_bench_parallel")
  sh quoteShell("/tmp/p2t_bench_parallel")

task benchDewall, "benchmark experimental DeWall DT prototype":
  nimCompile(
    "bench/bench_dewall",
    flags = "--mm:orc --threads:on -d:useMalloc -d:release --opt:speed " & TunedFlags,
    outPath = "/tmp/p2t_bench_dewall",
    nimcache = "/tmp/p2t_bench_dewall_d",
  )
  sh "strip " & quoteShell("/tmp/p2t_bench_dewall")
  sh quoteShell("/tmp/p2t_bench_dewall")

task benchDewallProfile, "profile experimental DeWall prewall behavior":
  nimCompile(
    "bench/bench_dewall_profile",
    flags = "--mm:orc --threads:on -d:useMalloc -d:release --opt:speed " & TunedFlags,
    outPath = "/tmp/p2t_bench_dewall_profile",
    nimcache = "/tmp/p2t_bench_dewall_profile_d",
  )
  sh "strip " & quoteShell("/tmp/p2t_bench_dewall_profile")
  sh quoteShell("/tmp/p2t_bench_dewall_profile")

task benchDewallHotStats, "report experimental DeWall hot-path counters":
  nimCompile(
    "bench/bench_dewall_hot_stats",
    flags = "--mm:orc --threads:on -d:useMalloc -d:release --opt:speed " &
      "-d:p2tDewallHotStats " & TunedFlags,
    outPath = "/tmp/p2t_bench_dewall_hot_stats",
    nimcache = "/tmp/p2t_bench_dewall_hot_stats_d",
  )
  sh "strip " & quoteShell("/tmp/p2t_bench_dewall_hot_stats")
  sh quoteShell("/tmp/p2t_bench_dewall_hot_stats")

task tidy, "format p2t sources":
  sh "nph src/p2t.nim src/p2t/types.nim src/p2t/geometry.nim src/p2t/capi.nim src/p2t/internal/cdt.nim src/p2t/internal/arena_cdt.nim src/p2t/internal/dewall.nim src/p2t/triangulate.nim tests/test_public_api.nim tests/test_p2t.nim tests/test_dewall.nim tests/test_dewall_hot_stats.nim tests/test_memory.nim tests/test_libtess2_compare.nim bench/bench_p2t.nim bench/bench_libtess2_compare.nim bench/bench_libtess2_fixtures.nim bench/bench_compare_all.nim bench/bench_cdt_stats.nim bench/bench_stress_small.nim bench/bench_normalized_trusted.nim bench/bench_dewall.nim bench/bench_dewall_profile.nim bench/bench_dewall_hot_stats.nim bench/quality_compare.nim bench/bench_parallel.nim bench/bench_struct_sizes.nim"
