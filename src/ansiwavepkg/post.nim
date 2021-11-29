from illwill as iw import `[]`, `[]=`
from wavecorepkg/wavescript import nil
from strutils import format
from sequtils import nil
from ./codes import stripCodes
from unicode import nil
from paramidi import nil
from ./midi import nil
from times import nil
from ./sound import nil
from os import nil
from ./constants import nil
from json import nil
from ./storage import nil
from wavecorepkg/common import nil
from parseutils import nil
import tables
from wavecorepkg/client import nil
import unicode

type
  RefStrings* = ref seq[ref string]

proc splitLines*(text: string): RefStrings =
  new result
  var row = 0
  for line in strutils.splitLines(text):
    var s: ref string
    new s
    s[] = codes.dedupeCodes(line)
    result[].add(s)
    # make sure the line is UTF-8
    let col = unicode.validateUtf8(line)
    if col != -1:
      raise newException(Exception, "Invalid UTF-8 data in line $1, byte $2".format(row+1, col+1))
    row.inc

proc wrapLine(line: string, maxWidth: int): seq[string] =
  var
    partitions: seq[tuple[isWhitespace: bool, chars: seq[Rune]]]
    lastPartition: tuple[isWhitespace: bool, chars: seq[Rune]]
  for ch in runes(line):
    if lastPartition.chars.len == 0:
      lastPartition = (unicode.isWhitespace(ch), @[ch])
    else:
      let isWhitespace = unicode.isWhitespace(ch)
      if isWhitespace == lastPartition.isWhitespace:
        lastPartition.chars.add ch
      else:
        partitions.add lastPartition
        lastPartition = (isWhitespace, @[ch])
  partitions.add lastPartition
  var currentLine: seq[Rune]
  for (isWhitespace, chars) in partitions:
    if isWhitespace:
      currentLine &= chars
    else:
      if currentLine.len + chars.len <= maxWidth:
        currentLine &= chars
      else:
        result.add $currentLine
        currentLine = chars
  result.add $currentLine

proc wrapLines*(lines: RefStrings): tuple[lines: RefStrings, ranges: seq[(int, int)]] =
  new result.lines
  var i = 0
  for line in lines[]:
    let newLines = wrapLine(line[], constants.editorWidth)
    if newLines.len == 1:
      result.lines[].add(line)
      i.inc
    else:
      result.ranges.add((i, newLines.len))
      for newLine in newLines:
        var s: ref string
        new s
        s[] = newLine
        result.lines[].add(s)
        i.inc

proc joinLines*(lines: RefStrings): string =
  let lineCount = lines[].len
  var i = 0
  for line in lines[]:
    result &= line[]
    if i != lineCount - 1:
      result &= "\n"
    i.inc

proc add*(lines: var RefStrings, line: string) =
  var s: ref string
  new s
  s[] = line
  lines[].add(s)

proc set*(lines: var RefStrings, i: int, line: string) =
  var s: ref string
  new s
  s[] = line
  lines[i] = s

proc splitAfterHeaders*(content: string): seq[string] =
  let idx = strutils.find(content, "\n\n")
  if idx == -1: # this should never happen
    @[""]
  else:
    strutils.splitLines(content[idx + 2 ..< content.len])

proc drafts*(): seq[string] =
  for filename in storage.list():
    if strutils.endsWith(filename, ".new") or strutils.endsWith(filename, ".edit"):
      result.add(filename)

type
  CommandTreesRef* = ref seq[wavescript.CommandTree]

proc linesToTrees*(lines: seq[string] | seq[ref string]): seq[wavescript.CommandTree] =
  var scriptContext = waveScript.initContext()
  let
    cmds = wavescript.extract(sequtils.map(lines, codes.stripCodesIfCommand))
    treesTemp = sequtils.map(cmds, proc (text: auto): wavescript.CommandTree = wavescript.parse(scriptContext, text))
  wavescript.parseOperatorCommands(treesTemp)

proc play*(events: seq[paramidi.Event]): midi.PlayResult =
  if iw.gIllwillInitialised:
    let
      (secs, playResult) = midi.play(events)
      startTime = times.epochTime()
    if playResult.kind == sound.Error:
      return
    var tb = iw.newTerminalBuffer(iw.terminalWidth(), iw.terminalHeight())
    while true:
      let currTime = times.epochTime() - startTime
      if currTime > secs:
        break
      iw.fill(tb, 0, 0, constants.editorWidth + 1, 2, " ")
      iw.fill(tb, 0, 0, int((currTime / secs) * float(constants.editorWidth + 1)), 0, "▓")
      iw.write(tb, 0, 1, "press tab to stop playing")
      iw.display(tb)
      let key = iw.getKey()
      if key in {iw.Key.Tab, iw.Key.Escape}:
        break
      os.sleep(constants.sleepMsecs)
    midi.stop(playResult.addrs)
  else:
    let currentTime = times.epochTime()
    let res = midi.play(events)
    if res.playResult.kind == sound.Valid:
      return res

proc compileAndPlayAll*(trees: seq[wavescript.CommandTree]): midi.PlayResult =
  var
    noErrors = true
    nodes = json.JsonNode(kind: json.JArray)
    midiContext = paramidi.initContext()
  for cmd in trees:
    if cmd.kind != wavescript.Valid or cmd.skip:
      continue
    let
      res =
        try:
          let node = wavescript.toJson(cmd)
          nodes.elems.add(node)
          midi.compileScore(midiContext, node, false)
        except Exception as e:
          midi.CompileResult(kind: midi.Error, message: e.msg)
    case res.kind:
    of midi.Valid:
      discard
    of midi.Error:
      noErrors = false
      break
  if noErrors:
    midiContext = paramidi.initContext()
    let res =
      try:
        midi.compileScore(midiContext, nodes, true)
      except Exception as e:
        midi.CompileResult(kind: midi.Error, message: e.msg)
    case res.kind:
    of midi.Valid:
      if res.events.len > 0:
        return play(res.events)
    of midi.Error:
      discard

type
  ParsedKind* = enum
    Local, Remote, Error,
  Parsed* = object
    case kind*: ParsedKind
    of Local, Remote:
      key*: string
      sig*: string
      target*: string
      time*: string
      content*: string
    of Error:
      discard

proc parseAnsiwave*(ansiwave: string, parsed: var Parsed) =
  try:
    let
      (commands, headersAndContent, content) = common.parseAnsiwave(ansiwave)
      key = commands["/head.key"]
      sig = commands["/head.sig"]
      target = commands["/head.target"]
      time = commands["/head.time"]
    parsed.key = key
    parsed.sig = sig
    parsed.target = target
    parsed.time = time
    parsed.content = content
  except Exception as ex:
    parsed = Parsed(kind: Error)

proc getTime*(parsed: Parsed): int =
  try:
    discard parseutils.parseInt(parsed.time, result)
  except Exception as ex:
    discard

proc getFromLocalOrRemote*(response: client.Result[client.Response], sig: string): Parsed =
  let local = storage.get(sig & ".ansiwave")

  # if both failed, return error
  if local == "" and response.kind == client.Error:
    return Parsed(kind: Error)

  var
    localParsed: Parsed
    remoteParsed: Parsed

  # parse local
  if local == "":
    localParsed = Parsed(kind: Error)
  else:
    localParsed = Parsed(kind: Local)
    parseAnsiwave(local, localParsed)

  # parse remote
  if response.kind == client.Error:
    remoteParsed = Parsed(kind: Error)
  else:
    remoteParsed = Parsed(kind: Remote)
    parseAnsiwave(response.valid.body, remoteParsed)

  # if both parsed successfully, compare their timestamps and use the later one
  if localParsed.kind != Error and remoteParsed.kind != Error:
    if localParsed.getTime > remoteParsed.getTime:
      localParsed
    else:
      remoteParsed
  elif localParsed.kind != Error:
    localParsed
  else:
    remoteParsed

