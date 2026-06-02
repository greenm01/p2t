## Isolated sort microbenchmark: our mergeSort vs fast-poly2tri's MPE_PolySort.
## Sorts the dude contour points (array of pointers) repeatedly, restoring the
## original order each iteration. Reports best-of-N total time.
import std/[os, strutils, monotimes, times, algorithm]

type
  Real = float64
  Pt = object
    x, y: Real

const Epsilon = Real(1e-12)

proc readDat(name: string): seq[Pt] =
  let path = currentSourcePath().parentDir.parentDir / "tests" / "fixtures" / name
  for line in lines(path):
    let trimmed = line.strip()
    if trimmed.len == 0:
      break
    let parts = trimmed.splitWhitespace()
    result.add Pt(x: parseFloat(parts[0]), y: parseFloat(parts[1]))

# ---- comparators ----
proc pointCmp(a, b: ptr Pt): int {.inline.} =
  if a.y < b.y: -1
  elif a.y > b.y: 1
  elif a.x < b.x: -1
  elif a.x > b.x: 1
  else: 0

proc lessEq(a, b: ptr Pt): bool {.inline.} =
  # fast-poly2tri MPE_POLY_COMPARE style (a <= b), Y with epsilon then X
  (a.y < b.y) or ((a.y - b.y) < Epsilon and a.x <= b.x)

proc poly2Less(a, b: ptr Pt): bool {.inline.} =
  (a.y < b.y) or ((a.y - b.y) < Epsilon and a.x < b.x)

# ---- OUR current merge sort (insertion base, full pointCmp skip, scalar copy) ----
proc insertionSort(a: var seq[ptr Pt], lo, hi: int) =
  for i in lo + 1 ..< hi:
    let item = a[i]
    var j = i
    while j > lo and pointCmp(item, a[j - 1]) < 0:
      a[j] = a[j - 1]
      dec j
    a[j] = item

proc ourMergeRange(a, tmp: var seq[ptr Pt], lo, hi: int) =
  const InsertionLimit = 24
  if hi - lo <= InsertionLimit:
    insertionSort(a, lo, hi)
    return
  let mid = (lo + hi) shr 1
  ourMergeRange(a, tmp, lo, mid)
  ourMergeRange(a, tmp, mid, hi)
  if pointCmp(a[mid - 1], a[mid]) <= 0:
    return
  var left = lo
  var right = mid
  var outIdx = lo
  while left < mid and right < hi:
    if pointCmp(a[left], a[right]) <= 0:
      tmp[outIdx] = a[left]; inc left
    else:
      tmp[outIdx] = a[right]; inc right
    inc outIdx
  while left < mid:
    tmp[outIdx] = a[left]; inc left; inc outIdx
  while right < hi:
    tmp[outIdx] = a[right]; inc right; inc outIdx
  for i in lo ..< hi:
    a[i] = tmp[i]

proc ourSort(a, tmp: var seq[ptr Pt]) =
  if a.len > 1:
    tmp.setLen(a.len)
    ourMergeRange(a, tmp, 0, a.len)

# ---- faithful fast-poly2tri MPE_PolySort port ----
proc polySort(points: var openArray[ptr Pt], temp: var seq[ptr Pt], lo, count: int) =
  if count <= 1:
    discard
  elif count == 2:
    let a = points[lo]
    let b = points[lo + 1]
    if (a.y > b.y) or ((b.y - a.y) < Epsilon and a.x >= b.x):
      points[lo] = b
      points[lo + 1] = a
  else:
    let half0 = count div 2
    let half1 = count - half0
    polySort(points, temp, lo, half0)
    polySort(points, temp, lo + half0, half1)
    # don't merge if already sorted (Y only)
    if points[lo + half0 - 1].y > points[lo + half0].y:
      var read0 = lo
      var read1 = lo + half0
      let end1 = lo + count
      var o = 0
      while o < count:
        if read0 == lo + half0:
          temp[o] = points[read1]; inc read1
        elif read1 == end1:
          temp[o] = points[read0]; inc read0
        else:
          if poly2Less(points[read0], points[read1]):
            temp[o] = points[read0]; inc read0
          else:
            temp[o] = points[read1]; inc read1
        inc o
      for i in 0 ..< count:
        points[lo + i] = temp[i]

proc polyEntry(a: var seq[ptr Pt], tmp: var seq[ptr Pt]) =
  if a.len > 1:
    tmp.setLen(a.len)
    polySort(a, tmp, 0, a.len)

# ---- std/algorithm sort (introsort) for reference ----
proc stdSort(a: var seq[ptr Pt]) =
  a.sort(proc(x, y: ptr Pt): int = pointCmp(x, y))

# ---- driver ----
let master = readDat("dude.dat")
echo "points: ", master.len
# build pointer array master
var pts = newSeq[Pt](master.len)
for i in 0 ..< master.len: pts[i] = master[i]
var orig = newSeq[ptr Pt](master.len)
for i in 0 ..< master.len: orig[i] = addr pts[i]

const Iter = 2_000_000

template run(name: string, body: untyped) =
  block:
    var work {.inject.} = newSeq[ptr Pt](orig.len)
    var tmp {.inject.} = newSeq[ptr Pt](orig.len)
    var best = high(int64)
    for round in 0 ..< 7:
      let start = getMonoTime()
      for _ in 0 ..< Iter:
        for i in 0 ..< orig.len: work[i] = orig[i]
        body
      let dt = inMicroseconds(getMonoTime() - start)
      if dt < best: best = dt
    echo name, ": best ", best, " us for ", Iter, " sorts"

# correctness: our + poly2tri must match std-sort ordering (by full y,x compare)
block:
  var a = orig
  var b = orig
  var c = orig
  var t1, t2: seq[ptr Pt]
  ourSort(a, t1)
  polyEntry(b, t2)
  stdSort(c)
  var ourOk = true
  var polyOk = true
  for i in 0 ..< a.len:
    if pointCmp(a[i], c[i]) != 0: ourOk = false
    if pointCmp(b[i], c[i]) != 0: polyOk = false
  echo "our matches std: ", ourOk, "  poly2tri matches std: ", polyOk

# baseline: just the restore loop (subtract this)
run("restore-only", (discard))
run("our-merge", ourSort(work, tmp))
run("poly2tri-merge", polyEntry(work, tmp))
run("std-sort", stdSort(work))
