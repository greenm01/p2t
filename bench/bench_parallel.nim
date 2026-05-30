## Throughput scaling of tessellateBatch across threads.
##
## A single triangulation is serial, so this measures the realistic win:
## triangulating many independent shapes (as a vector renderer does per frame)
## in parallel, one reused workspace per thread.

import std/[cpuinfo, monotimes, os, strformat, strutils, times]

import p2t

proc contour(id: int, points: sink seq[Vec2]): TessContour =
  TessContour(id: id, points: points)

proc readDat(name: string): seq[Vec2] =
  let path = currentSourcePath().parentDir.parentDir / "tests" / "fixtures" / name
  for line in lines(path):
    let trimmed = line.strip()
    if trimmed.len == 0:
      break
    let parts = trimmed.splitWhitespace()
    result.add vec2(parseFloat(parts[0]), parseFloat(parts[1]))

proc dudeInput(): TessInput =
  TessInput(
    outer: contour(1, readDat("dude.dat")),
    holes:
      @[
        contour(2, @[vec2(325, 437), vec2(320, 423), vec2(329, 413), vec2(332, 423)]),
        contour(
          3,
          @[
            vec2(320.72342, 480),
            vec2(338.90617, 465.96863),
            vec2(347.99754, 480.61584),
            vec2(329.8148, 510.41534),
            vec2(339.91632, 480.11077),
            vec2(334.86556, 478.09046),
          ],
        ),
      ],
  )

proc run(name: string, inputs: seq[TessInput]) =
  echo &"{name}: {inputs.len} shapes, {countProcessors()} cores detected"

  # Reference result (serial) to validate parallel output and report work size.
  let reference = tessellateBatch(inputs, threads = 1)
  var triangles = 0
  for r in reference:
    doAssert r.ok
    triangles += r.triangles.len
  echo &"  total triangles: {triangles}"

  var baseline = 0.0
  for threads in [1, 2, 4, 8, 0]:
    # Best of 3 to reduce noise; thread 0 means "all detected cores".
    var best = int64.high
    var results: seq[TessResult]
    for _ in 0 ..< 3:
      let start = getMonoTime()
      results = tessellateBatch(inputs, threads = threads)
      best = min(best, inMicroseconds(getMonoTime() - start))

    # Validate parallel output matches the serial reference exactly.
    doAssert results.len == reference.len
    for i in 0 ..< results.len:
      doAssert results[i].ok
      doAssert results[i].triangles.len == reference[i].triangles.len

    let us = best.float64
    let perShape = us / inputs.len.float64
    let label =
      if threads == 0:
        "all"
      else:
        $threads
    if threads == 1:
      baseline = us
      echo &"  {label:>3} thread(s): {us/1000.0:8.2f} ms   {perShape:6.3f} us/shape"
    else:
      echo &"  {label:>3} thread(s): {us/1000.0:8.2f} ms   {perShape:6.3f} us/shape   {baseline/us:5.2f}x"

var dudeBatch: seq[TessInput]
for _ in 0 ..< 4000:
  dudeBatch.add dudeInput()
run("dude-with-holes", dudeBatch)

echo ""

var monkeyBatch: seq[TessInput]
for _ in 0 ..< 400:
  monkeyBatch.add TessInput(outer: contour(7, readDat("nazca_monkey.dat")))
run("nazca-monkey", monkeyBatch)
