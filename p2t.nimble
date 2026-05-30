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

task test, "run p2t tests":
  nimRun("tests/test_p2t", outPath = "/tmp/p2t_test", nimcache = "/tmp/p2t_test_d")

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

task tidy, "format p2t sources":
  sh "nph src/p2t.nim src/p2t/types.nim src/p2t/geometry.nim src/p2t/internal/cdt.nim src/p2t/triangulate.nim tests/test_p2t.nim tests/test_memory.nim bench/bench_p2t.nim"
