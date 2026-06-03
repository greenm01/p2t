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

proc addRows(rows: var seq[BenchRow], configs: var seq[string], engine, path: string) =
  if not fileExists(path):
    quit("benchmark binary not found: " & path, QuitFailure)

  let output = execProcess(path)
  for line in output.splitLines:
    if line.startsWith("config,"):
      configs.add "config," & engine & "," & line[7 .. ^1]
    else:
      let row = parseBenchLine(engine, line)
      if row.engine.len > 0:
        rows.add row

proc cell(row: BenchRow): string =
  &"{row.bestUs}/{row.medianUs}"

proc isTriangleVariant(engine: string): bool =
  engine.startsWith("triangle-") and
    engine notin ["triangle-best", "triangle-unsafe-best"]

proc isTriangleUnsafe(engine: string): bool =
  engine.startsWith("triangle-unsafe-")

proc triangleSwitch(engine: string): string =
  if engine.startsWith("triangle-unsafe-"):
    engine["triangle-unsafe-".len .. ^1]
  elif engine.startsWith("triangle-"):
    engine["triangle-".len .. ^1]
  else:
    engine

proc chooseTriangleBest(
    rows: seq[BenchRow], candidates: seq[string], caseName: string
): tuple[found: bool, row: BenchRow] =
  for candidate in candidates:
    let matches = rows.filterIt(
      it.engine == candidate and it.caseName == caseName and
        it.mode == "default" and it.bestUs >= 0
    )
    if matches.len == 0:
      continue
    if not result.found or matches[0].bestUs < result.row.bestUs:
      result.found = true
      result.row = matches[0]

proc addTriangleBest(
    rows: var seq[BenchRow], configs: var seq[string], engines: var seq[string],
    engineName: string, candidates: seq[string], caseOrder: seq[string]
) =
  if candidates.len == 0:
    return

  var added = false
  for caseName in caseOrder:
    let selected = rows.chooseTriangleBest(candidates, caseName)
    if selected.found:
      configs.add &"config,{engineName},{caseName},{selected.row.engine.triangleSwitch}"
      var row = selected.row
      row.engine = engineName
      rows.add row
      added = true

  if added:
    engines.add engineName

proc synthesizeTriangleBest(
    rows: var seq[BenchRow], configs: var seq[string], engines: var seq[string],
    caseOrder: seq[string]
) =
  let
    robustCandidates = engines.filterIt(it.isTriangleVariant and not it.isTriangleUnsafe)
    unsafeCandidates = engines.filterIt(it.isTriangleVariant and it.isTriangleUnsafe)

  let originalEngines = engines
  engines.setLen(0)
  var insertedTriangleBest = false
  for engine in originalEngines:
    if engine.isTriangleVariant:
      if not insertedTriangleBest:
        rows.addTriangleBest(
          configs, engines, "triangle-best", robustCandidates, caseOrder
        )
        rows.addTriangleBest(
          configs, engines, "triangle-unsafe-best", unsafeCandidates, caseOrder
        )
        insertedTriangleBest = true
      continue
    engines.add engine

proc main() =
  if paramCount() == 0:
    quit(
      "usage: bench_compare_all engine=/path/to/bench [engine=/path/to/bench ...]",
      QuitFailure,
    )

  var rows: seq[BenchRow]
  var configs: seq[string]
  var engines: seq[string]
  for arg in commandLineParams():
    let eq = arg.find('=')
    if eq <= 0 or eq == arg.high:
      quit("expected engine=/path argument, got: " & arg, QuitFailure)
    let
      engine = arg[0 ..< eq]
      path = arg[eq + 1 .. ^1]
    engines.add engine
    rows.addRows(configs, engine, path)

  var caseOrder: seq[string]
  var seenCases: Table[string, bool]
  for row in rows:
    if not seenCases.hasKey(row.caseName):
      seenCases[row.caseName] = true
      caseOrder.add row.caseName

  rows.synthesizeTriangleBest(configs, engines, caseOrder)

  echo "best/median microseconds"
  if configs.len > 0:
    echo "config,engine,key,value"
    for config in configs:
      echo config
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
