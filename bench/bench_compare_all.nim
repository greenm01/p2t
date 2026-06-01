import std/[algorithm, os, osproc, sequtils, strformat, strutils, tables]

type BenchRow = object
  engine: string
  caseName: string
  mode: string
  runs: int
  triangles: int
  bestUs: int
  medianUs: int

proc parseMetric(line, key: string): int =
  let start = line.find(key)
  if start < 0:
    return -1
  var pos = start + key.len
  while pos < line.len and line[pos] == ' ':
    inc pos
  let first = pos
  while pos < line.len and line[pos].isDigit:
    inc pos
  if pos == first:
    return -1
  parseInt(line[first ..< pos])

proc parseBenchLine(engine, line: string): BenchRow =
  let colon = line.find(':')
  if colon < 0 or line.find(" best ") < 0 or line.find(" median ") < 0:
    return BenchRow()

  let label = line[0 ..< colon]
  var caseName = label
  var mode = "default"
  if engine.startsWith("nim-"):
    let parts = label.rsplit(maxsplit = 1)
    if parts.len == 2:
      caseName = parts[0]
      mode = parts[1]
  result = BenchRow(
    engine: engine,
    caseName: caseName,
    mode: mode,
    runs: parseMetric(line, ":"),
    triangles: parseMetric(line, "runs,"),
    bestUs: parseMetric(line, "best"),
    medianUs: parseMetric(line, "median"),
  )

proc addRows(rows: var seq[BenchRow], engine, path: string) =
  if not fileExists(path):
    quit("benchmark binary not found: " & path, QuitFailure)

  let output = execProcess(path)
  for line in output.splitLines:
    let row = parseBenchLine(engine, line)
    if row.engine.len > 0:
      rows.add row

proc cell(row: BenchRow): string =
  &"{row.bestUs}/{row.medianUs}"

proc main() =
  if paramCount() == 0:
    quit(
      "usage: bench_compare_all engine=/path/to/bench [engine=/path/to/bench ...]",
      QuitFailure,
    )

  var rows: seq[BenchRow]
  var engines: seq[string]
  for arg in commandLineParams():
    let eq = arg.find('=')
    if eq <= 0 or eq == arg.high:
      quit("expected engine=/path argument, got: " & arg, QuitFailure)
    let
      engine = arg[0 ..< eq]
      path = arg[eq + 1 .. ^1]
    engines.add engine
    rows.addRows(engine, path)

  var caseOrder: seq[string]
  var seenCases: Table[string, bool]
  for row in rows:
    if not seenCases.hasKey(row.caseName):
      seenCases[row.caseName] = true
      caseOrder.add row.caseName

  echo "best/median microseconds"
  echo "case,mode," & engines.join(",")
  for caseName in caseOrder:
    let modes = rows.filterIt(it.caseName == caseName).mapIt(it.mode).deduplicate()
    for mode in modes.sorted():
      var fields = @[caseName, mode]
      for engine in engines:
        let matches = rows.filterIt(
          it.caseName == caseName and it.mode == mode and it.engine == engine
        )
        fields.add(
          if matches.len == 0:
            ""
          else:
            matches[0].cell
        )
      echo fields.join(",")

main()
