from illwill as iw import `[]`, `[]=`
import tables, sets
import pararules
import unicode
from os import nil
from strutils import format
from sequtils import nil
from sugar import nil
from times import nil
from ansiwavepkg/ansi import nil
from ansiwavepkg/wavescript import CommandTree
from ansiwavepkg/midi import nil
from ansiwavepkg/sound import nil
from ansiwavepkg/codes import stripCodes
from paramidi import Context
from json import nil
from parseopt import nil

const
  sleepMsecs = 10
  hintSecs = 5
  undoDelay = 0.5
  saveDelay = 0.5

type
  Id* = enum
    Global, TerminalWindow,
    Editor, Errors, Tutorial, Publish,
  Attr* = enum
    CursorX, CursorY,
    ScrollX, ScrollY,
    X, Y, Width, Height,
    SelectedBuffer, Lines,
    Editable, SelectedMode,
    SelectedChar, SelectedFgColor, SelectedBgColor,
    Prompt, ValidCommands, InvalidCommands, Links,
    HintText, HintTime, UndoHistory, UndoIndex, InsertMode,
    LastEditTime, LastSaveTime,
  PromptKind = enum
    None, DeleteLine, StopPlaying,
  RefStrings = ref seq[ref string]
  Moment = object
    lines: seq[ref string]
    cursorX: int
    cursorY: int
    time: float
  Moments = ref seq[Moment]
  RefCommands = ref seq[wavescript.CommandTree]
  Link = object
    icon: Rune
    callback: proc ()
    error: bool
  RefLinks = ref Table[int, Link]
  Options* = object
    input*: string
    output*: string
    args*: Table[string, string]

schema Fact(Id, Attr):
  CursorX: int
  CursorY: int
  ScrollX: int
  ScrollY: int
  X: int
  Y: int
  Width: int
  Height: int
  SelectedBuffer: Id
  Lines: RefStrings
  Editable: bool
  SelectedMode: int
  SelectedChar: string
  SelectedFgColor: string
  SelectedBgColor: string
  Prompt: PromptKind
  ValidCommands: RefCommands
  InvalidCommands: RefCommands
  Links: RefLinks
  HintText: string
  HintTime: float
  UndoHistory: Moments
  UndoIndex: int
  InsertMode: bool
  LastEditTime: float
  LastSaveTime: float

proc exitClean(message: string) =
  iw.illwillDeinit()
  iw.showCursor()
  if message.len > 0:
    quit(message)
  else:
    quit(0)

proc exitClean() {.noconv.} =
  exitClean("")

proc splitLines*(text: string): RefStrings =
  new result
  for line in strutils.splitLines(text):
    var s: ref string
    new s
    s[] = line
    result[].add(s)

proc add(lines: var RefStrings, line: string) =
  var s: ref string
  new s
  s[] = line
  lines[].add(s)

proc set(lines: var RefStrings, i: int, line: string) =
  var s: ref string
  new s
  s[] = line
  lines[i] = s

proc getCurrentLine(bufferId: int): int
proc moveCursor(bufferId: int, x: int, y: int)
proc tick*(): iw.TerminalBuffer

proc play(events: seq[paramidi.Event], bufferId: int, bufferWidth: int, lineTimes: seq[tuple[line: int, time: float]]) =
  if events.len == 0:
    return
  var
    tb = tick()
    lineTimesIdx = -1
  iw.display(tb)
  let
    (secs, playResult) = midi.play(events)
    startTime = times.epochTime()
  if playResult.kind == sound.Error:
    exitClean(playResult.message)
  while true:
    let currTime = times.epochTime() - startTime
    if currTime > secs:
      break
    # go to the right line
    if lineTimesIdx + 1 < lineTimes.len:
      let (line, time) = lineTimes[lineTimesIdx + 1]
      if currTime >= time:
        lineTimesIdx.inc
        moveCursor(bufferId, 0, line)
        tb = tick()
    # draw progress bar
    iw.fill(tb, 0, 0, bufferWidth + 1, if bufferId == Editor.ord: 1 else: 0, " ")
    iw.fill(tb, 0, 0, int((currTime / secs) * float(bufferWidth + 1)), 0, "▓")
    iw.display(tb)
    let key = iw.getKey()
    if key == iw.Key.Tab:
      break
    os.sleep(sleepMsecs)
  midi.stop(playResult.addrs)

proc setErrorLink(session: var auto, linksRef: RefLinks, cmdLine: int, errLine: int) =
  var sess = session
  let cb =
    proc () =
      sess.insert(Global, SelectedBuffer, Errors)
      sess.insert(Errors, CursorX, 0)
      sess.insert(Errors, CursorY, errLine)
  linksRef[cmdLine] = Link(icon: "!".runeAt(0), callback: cb, error: true)

proc setRuntimeError(session: var auto, cmdsRef: RefCommands, errsRef: RefCommands, linksRef: RefLinks, bufferId: int, line: int, message: string) =
  var cmdIndex = -1
  for i in 0 ..< cmdsRef[].len:
    if cmdsRef[0].line == line:
      cmdIndex = i
      break
  if cmdIndex >= 0:
    cmdsRef[].delete(cmdIndex)
    session.insert(bufferId, ValidCommands, cmdsRef)
  var errIndex = -1
  for i in 0 ..< errsRef[].len:
    if errsRef[0].line == line:
      errIndex = i
      break
  if errIndex >= 0:
    errsRef[].delete(errIndex)
  setErrorLink(session, linksRef, line, errsRef[].len)
  errsRef[].add(wavescript.CommandTree(kind: wavescript.Error, line: line, message: message))
  session.insert(bufferId, InvalidCommands, errsRef)
  session.insert(bufferId, Links, linksRef)
  if getCurrentLine(bufferId) != line:
    session.insert(bufferId, CursorX, 0)
    session.insert(bufferId, CursorY, line)

proc compileAndPlayAll(session: var auto, buffer: tuple) =
  session.insert(buffer.id, Prompt, StopPlaying)
  var
    noErrors = true
    nodes = json.JsonNode(kind: json.JArray)
    lineTimes: seq[tuple[line: int, time: float]]
    midiContext = paramidi.initContext()
    lastTime = 0.0
  for cmd in buffer.commands[]:
    if cmd.skip:
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
      lineTimes.add((cmd.line, lastTime))
      lastTime = midiContext.seconds
    of midi.Error:
      setRuntimeError(session, buffer.commands, buffer.errors, buffer.links, buffer.id, cmd.line, res.message)
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
      play(res.events, buffer.id, buffer.width, lineTimes)
    of midi.Error:
      discard
  session.insert(buffer.id, Prompt, None)

let rules =
  ruleset:
    rule getGlobals(Fact):
      what:
        (Global, SelectedBuffer, selectedBuffer)
        (Global, HintText, hintText)
        (Global, HintTime, hintTime)
    rule getTerminalWindow(Fact):
      what:
        (TerminalWindow, Width, windowWidth)
        (TerminalWindow, Height, windowHeight)
    rule updateBufferSize(Fact):
      what:
        (TerminalWindow, Width, width)
        (TerminalWindow, Height, height)
        (id, Y, bufferY, then = false)
      then:
        session.insert(id, Width, min(width - 2, 80))
        session.insert(id, Height, height - 3 - bufferY)
    rule updateTerminalScrollX(Fact):
      what:
        (id, Width, bufferWidth)
        (id, CursorX, cursorX)
        (id, ScrollX, scrollX, then = false)
      cond:
        cursorX >= 0
      then:
        let scrollRight = scrollX + bufferWidth - 1
        if cursorX < scrollX:
          session.insert(id, ScrollX, cursorX)
        elif cursorX > scrollRight:
          session.insert(id, ScrollX, scrollX + (cursorX - scrollRight))
    rule updateTerminalScrollY(Fact):
      what:
        (id, Height, bufferHeight)
        (id, CursorY, cursorY)
        (id, Lines, lines)
        (id, ScrollY, scrollY, then = false)
      cond:
        cursorY >= 0
      then:
        let scrollBottom = scrollY + bufferHeight - 1
        if cursorY < scrollY:
          session.insert(id, ScrollY, cursorY)
        elif cursorY > scrollBottom and cursorY < lines[].len:
          session.insert(id, ScrollY, scrollY + (cursorY - scrollBottom))
    rule cursorChanged(Fact):
      what:
        (id, CursorX, cursorX)
        (id, CursorY, cursorY)
        (id, Lines, lines, then = false)
      then:
        if lines[].len == 0:
          if cursorX != 0:
            session.insert(id, CursorX, 0)
          if cursorY != 0:
            session.insert(id, CursorY, 0)
          return
        if cursorY < 0:
          session.insert(id, CursorY, 0)
        elif cursorY >= lines[].len:
          session.insert(id, CursorY, lines[].len - 1)
        else:
          if cursorX > lines[cursorY][].stripCodes.runeLen:
            session.insert(id, CursorX, lines[cursorY][].stripCodes.runeLen)
          elif cursorX < 0:
            session.insert(id, CursorX, 0)
    rule addClearToBeginningOfEveryLine(Fact):
      what:
        (id, Lines, lines)
      then:
        var shouldInsert = false
        for i in 0 ..< lines[].len:
          if lines[i][].len == 0 or not strutils.startsWith(lines[i][], "\e[0"):
            lines[i][] = codes.dedupeCodes("\e[0m" & lines[i][])
            shouldInsert = true
        if shouldInsert:
          session.insert(id, Lines, lines)
    rule parseCommands(Fact):
      what:
        (id, Lines, lines)
        (id, Width, width)
      cond:
        id != Errors.ord
      then:
        var scriptContext = waveScript.initContext()
        let
          cmds = wavescript.parse(sequtils.map(lines[], codes.stripCodesIfCommand))
          treesTemp = sequtils.map(cmds, proc (text: auto): wavescript.CommandTree = wavescript.parse(scriptContext, text))
          trees = wavescript.parseOperatorCommands(treesTemp)
        var cmdsRef, errsRef: RefCommands
        var linksRef: RefLinks
        new cmdsRef
        new errsRef
        new linksRef
        var
          sess = session
          midiContext = paramidi.initContext()
        for tree in trees:
          case tree.kind:
          of wavescript.Valid:
            # set the play button in the gutter to play the line
            let treeLocal = tree
            sugar.capture treeLocal, midiContext:
              let
                cb =
                  proc () =
                    sess.insert(id, Prompt, StopPlaying)
                    var ctx = midiContext
                    ctx.time = 0
                    new ctx.events
                    let res =
                      try:
                        midi.compileScore(ctx, wavescript.toJson(treeLocal), true)
                      except Exception as e:
                        midi.CompileResult(kind: midi.Error, message: e.msg)
                    case res.kind:
                    of midi.Valid:
                      play(res.events, id, width, @[])
                    of midi.Error:
                      setRuntimeError(sess, cmdsRef, errsRef, linksRef, id, treeLocal.line, res.message)
                    sess.insert(id, Prompt, None)
              linksRef[treeLocal.line] = Link(icon: "♫".runeAt(0), callback: cb)
            cmdsRef[].add(tree)
            # compile the line so the context object updates
            # this is important so attributes changed by previous lines
            # affect the play button
            try:
              discard paramidi.compile(midiContext, wavescript.toJson(tree))
            except:
              discard
          of wavescript.Error, wavescript.Discard:
            if id == Editor.ord:
              setErrorLink(sess, linksRef, tree.line, errsRef[].len)
              errsRef[].add(tree)
        session.insert(id, ValidCommands, cmdsRef)
        session.insert(id, InvalidCommands, errsRef)
        session.insert(id, Links, linksRef)
    rule updateErrors(Fact):
      what:
        (Editor, InvalidCommands, errors)
      then:
        var newLines: RefStrings
        var linksRef: RefLinks
        new newLines
        new linksRef
        for error in errors[]:
          var sess = session
          let line = error.line
          sugar.capture line:
            let cb =
              proc () =
                sess.insert(Global, SelectedBuffer, Editor)
                sess.insert(Editor, SelectedMode, 0) # force it to be write mode so the cursor is visible
                if getCurrentLine(Editor.ord) != line:
                  sess.insert(Editor, CursorX, 0)
                  sess.insert(Editor, CursorY, line)
            linksRef[newLines[].len] = Link(icon: "!".runeAt(0), callback: cb, error: true)
          newLines.add(error.message)
        session.insert(Errors, Lines, newLines)
        session.insert(Errors, CursorX, 0)
        session.insert(Errors, CursorY, 0)
        session.insert(Errors, ValidCommands, cast[RefCommands](nil))
        session.insert(Errors, InvalidCommands, cast[RefCommands](nil))
        session.insert(Errors, Links, linksRef)
    rule updateHistory(Fact):
      what:
        (id, Lines, lines)
        (id, UndoHistory, history, then = false)
        (id, UndoIndex, undoIndex, then = false)
        (id, CursorX, x, then = false)
        (id, CursorY, y, then = false)
      then:
        if undoIndex >= 0 and
            undoIndex < history[].len and
            history[undoIndex].lines == lines[]:
          return
        let
          currTime = times.epochTime()
          newIndex =
            # if there is a previous undo moment that occurred recently,
            # replace that instead of making a new moment
            if undoIndex > 0 and currTime - history[undoIndex].time <= undoDelay:
              undoIndex
            else:
              undoIndex + 1
        if history[].len == newIndex:
          history[].add(Moment(lines: lines[], cursorX: x, cursorY: y, time: currTime))
        elif history[].len > newIndex:
          history[] = history[0 .. newIndex]
          history[newIndex] = Moment(lines: lines[], cursorX: x, cursorY: y, time: currTime)
        session.insert(id, UndoHistory, history)
        session.insert(id, UndoIndex, newIndex)
    rule undoIndexChanged(Fact):
      what:
        (id, Lines, lines, then = false)
        (id, UndoIndex, undoIndex)
        (id, UndoHistory, history)
      cond:
        undoIndex >= 0
        undoIndex < history[].len
        history[undoIndex].lines != lines[]
      then:
        let moment = history[undoIndex]
        var newLines: RefStrings
        new newLines
        newLines[] = moment.lines
        session.insert(id, Lines, newLines)
        session.insert(id, CursorX, moment.cursorX)
        session.insert(id, CursorY, moment.cursorY)
    rule updateLastEditTime(Fact):
      what:
        (id, Lines, lines)
      then:
        session.insert(id, LastEditTime, times.epochTime())
    rule getBuffer(Fact):
      what:
        (id, CursorX, cursorX)
        (id, CursorY, cursorY)
        (id, ScrollX, scrollX)
        (id, ScrollY, scrollY)
        (id, Lines, lines)
        (id, X, x)
        (id, Y, y)
        (id, Width, width)
        (id, Height, height)
        (id, Editable, editable)
        (id, SelectedMode, mode)
        (id, SelectedChar, selectedChar)
        (id, SelectedFgColor, selectedFgColor)
        (id, SelectedBgColor, selectedBgColor)
        (id, Prompt, prompt)
        (id, ValidCommands, commands)
        (id, InvalidCommands, errors)
        (id, Links, links)
        (id, UndoHistory, undoHistory)
        (id, UndoIndex, undoIndex)
        (id, InsertMode, insertMode)
        (id, LastEditTime, lastEditTime)
        (id, LastSaveTime, lastSaveTime)

var session* = initSession(Fact, autoFire = false)

proc getCurrentLine(bufferId: int): int =
  session.query(rules.getBuffer, id = bufferId).cursorY

proc moveCursor(bufferId: int, x: int, y: int) =
  session.insert(bufferId, CursorX, x)
  session.insert(bufferId, CursorY, y)
  session.fireRules

proc onWindowResize(width: int, height: int) =
  session.insert(TerminalWindow, Width, width)
  session.insert(TerminalWindow, Height, height)

proc insertBuffer(id: Id, x: int, y: int, editable: bool, text: string) =
  session.insert(id, CursorX, 0)
  session.insert(id, CursorY, 0)
  session.insert(id, ScrollX, 0)
  session.insert(id, ScrollY, 0)
  session.insert(id, Lines, text.splitLines)
  session.insert(id, X, x)
  session.insert(id, Y, y)
  session.insert(id, Width, 0)
  session.insert(id, Height, 0)
  session.insert(id, Editable, editable)
  session.insert(id, SelectedMode, 0)
  session.insert(id, SelectedChar, "█")
  session.insert(id, SelectedFgColor, "")
  session.insert(id, SelectedBgColor, "")
  session.insert(id, Prompt, None)
  var history: Moments
  new history
  session.insert(id, UndoHistory, history)
  session.insert(id, UndoIndex, -1)
  session.insert(id, InsertMode, false)
  session.insert(id, LastEditTime, 0.0)
  session.insert(id, LastSaveTime, 0.0)

proc setCursor(tb: var iw.TerminalBuffer, col: int, row: int) =
  if col < 0 or row < 0:
    return
  var ch = tb[col, row]
  ch.bg = iw.bgYellow
  if ch.fg == iw.fgYellow:
    ch.fg = iw.fgWhite
  elif $ch.ch == "█":
    ch.fg = iw.fgYellow
  tb[col, row] = ch
  iw.setCursorPos(tb, col, row)

proc onInput(key: iw.Key, buffer: tuple): bool =
  case key:
  of iw.Key.Backspace:
    if not buffer.editable:
      return false
    if buffer.cursorX == 0:
      session.insert(buffer.id, Prompt, DeleteLine)
    elif buffer.cursorX > 0:
      let
        line = buffer.lines[buffer.cursorY][].toRunes
        realX = codes.getRealX(line, buffer.cursorX - 1)
        before = line[0 ..< realX]
      var after = line[realX + 1 ..< line.len]
      if buffer.insertMode:
        after = @[" ".runeAt(0)] & after
      let newLine = codes.dedupeCodes($before & $after)
      var newLines = buffer.lines
      newLines.set(buffer.cursorY, newLine)
      session.insert(buffer.id, Lines, newLines)
      session.insert(buffer.id, CursorX, buffer.cursorX - 1)
  of iw.Key.Delete:
    if not buffer.editable:
      return false
    let charCount = buffer.lines[buffer.cursorY][].stripCodes.runeLen
    if buffer.cursorX == charCount and buffer.cursorY < buffer.lines[].len - 1:
      var newLines = buffer.lines
      newLines.set(buffer.cursorY, codes.dedupeCodes(newLines[buffer.cursorY][] & newLines[buffer.cursorY + 1][]))
      newLines[].delete(buffer.cursorY + 1)
      session.insert(buffer.id, Lines, newLines)
    elif buffer.cursorX < charCount:
      let
        line = buffer.lines[buffer.cursorY][].toRunes
        realX = codes.getRealX(line, buffer.cursorX)
        newLine = codes.dedupeCodes($line[0 ..< realX] & $line[realX + 1 ..< line.len])
      var newLines = buffer.lines
      newLines.set(buffer.cursorY, newLine)
      session.insert(buffer.id, Lines, newLines)
  of iw.Key.Enter:
    if not buffer.editable:
      return false
    let
      line = buffer.lines[buffer.cursorY][].toRunes
      realX = codes.getRealX(line, buffer.cursorX)
      prefix = "\e[" & strutils.join(@[0] & codes.getParamsBeforeRealX(line, realX), ";") & "m"
      before = line[0 ..< realX]
      after = line[realX ..< line.len]
    var newLines: RefStrings
    new newLines
    newLines[] = buffer.lines[][0 ..< buffer.cursorY]
    newLines.add(codes.dedupeCodes($before))
    newLines.add(codes.dedupeCodes(prefix & $after))
    newLines[] &= buffer.lines[][buffer.cursorY + 1 ..< buffer.lines[].len]
    session.insert(buffer.id, Lines, newLines)
    session.insert(buffer.id, CursorX, 0)
    session.insert(buffer.id, CursorY, buffer.cursorY + 1)
  of iw.Key.Up:
    session.insert(buffer.id, CursorY, buffer.cursorY - 1)
  of iw.Key.Down:
    session.insert(buffer.id, CursorY, buffer.cursorY + 1)
  of iw.Key.Left:
    session.insert(buffer.id, CursorX, buffer.cursorX - 1)
  of iw.Key.Right:
    session.insert(buffer.id, CursorX, buffer.cursorX + 1)
  of iw.Key.Home:
    session.insert(buffer.id, CursorX, 0)
  of iw.Key.End:
    session.insert(buffer.id, CursorX, buffer.lines[buffer.cursorY][].stripCodes.runeLen)
  of iw.Key.PageUp, iw.Key.CtrlU:
    session.insert(buffer.id, CursorY, buffer.cursorY - int(buffer.height / 2))
  of iw.Key.PageDown, iw.Key.CtrlD:
    session.insert(buffer.id, CursorY, buffer.cursorY + int(buffer.height / 2))
  of iw.Key.Tab:
    case buffer.prompt:
    of DeleteLine:
      var newLines = buffer.lines
      if newLines[].len == 1:
        newLines.set(0, "")
      else:
        newLines[].delete(buffer.cursorY)
      session.insert(buffer.id, Lines, newLines)
      if buffer.cursorY > newLines[].len - 1:
        session.insert(buffer.id, CursorY, newLines[].len - 1)
    else:
      discard
  of iw.Key.Insert:
    if not buffer.editable:
      return false
    session.insert(buffer.id, InsertMode, not buffer.insertMode)
  else:
    return false
  true

proc makePrefix(buffer: tuple): string =
  if buffer.selectedFgColor == "" and buffer.selectedBgColor != "":
    result = "\e[0m" & buffer.selectedBgColor
  elif buffer.selectedFgColor != "" and buffer.selectedBgColor == "":
    result = "\e[0m" & buffer.selectedFgColor
  elif buffer.selectedFgColor == "" and buffer.selectedBgColor == "":
    result = "\e[0m"
  elif buffer.selectedFgColor != "" and buffer.selectedBgColor != "":
    result = buffer.selectedFgColor & buffer.selectedBgColor

proc onInput(code: int, buffer: tuple): bool =
  if code < 32:
    return false
  let ch =
    try:
      char(code)
    except:
      return false
  if not buffer.editable:
    return false
  let
    line = buffer.lines[buffer.cursorY][].toRunes
    realX = codes.getRealX(line, buffer.cursorX)
    prefix = buffer.makePrefix
    suffix = "\e[" & strutils.join(@[0] & codes.getParamsBeforeRealX(line, realX), ";") & "m"
    chColored = prefix & $ch & suffix
    before = line[0 ..< realX]
  var after = line[realX ..< line.len]
  if buffer.insertMode and after.len > 0:
    after = after[1 ..< after.len]
  let newLine = codes.dedupeCodes($before & chColored & $after)
  var newLines = buffer.lines
  newLines.set(buffer.cursorY, newLine)
  session.insert(buffer.id, Lines, newLines)
  session.insert(buffer.id, CursorX, buffer.cursorX + 1)
  true

proc renderBuffer(tb: var iw.TerminalBuffer, buffer: tuple, key: iw.Key) =
  let focused = buffer.prompt != StopPlaying
  iw.drawRect(tb, buffer.x, buffer.y, buffer.x + buffer.width + 1, buffer.y + buffer.height + 1, doubleStyle = focused)

  let
    lines = buffer.lines[]
    scrollX = buffer.scrollX
    scrollY = buffer.scrollY
  var screenLine = 0
  for i in scrollY ..< lines.len:
    if screenLine > buffer.height - 1:
      break
    var line = lines[i][].toRunes
    line = line[0 ..< lines[i][].runeLen]
    if scrollX < line.stripCodes.len:
      if scrollX > 0:
        codes.deleteBefore(line, scrollX)
    else:
      line = @[]
    codes.deleteAfter(line, buffer.width - 1)
    codes.write(tb, buffer.x + 1, buffer.y + 1 + screenLine, $line)
    if buffer.prompt != StopPlaying and buffer.mode == 0:
      # press gutter button with mouse or Tab
      if buffer.links[].contains(i):
        let linkY = buffer.y + 1 + screenLine
        iw.write(tb, buffer.x, linkY, $buffer.links[i].icon)
        if key == iw.Key.Mouse:
          let info = iw.getMouse()
          if info.button == iw.MouseButton.mbLeft and info.action == iw.MouseButtonAction.mbaPressed:
            if info.x == buffer.x and info.y == linkY:
              session.insert(buffer.id, CursorX, 0)
              session.insert(buffer.id, CursorY, i)
              let hintText =
                if buffer.links[i].error:
                  if buffer.id == Editor.ord:
                    "Hint: see the error with Tab"
                  elif buffer.id == Errors.ord:
                    "Hint: see where the error happened with Tab"
                  else:
                    ""
                else:
                  "Hint: play the current line with Tab"
              session.insert(Global, HintText, hintText)
              session.insert(Global, HintTime, times.epochTime() + hintSecs)
              buffer.links[i].callback()
        elif i == buffer.cursorY and key == iw.Key.Tab and buffer.prompt == None:
          buffer.links[i].callback()
    screenLine += 1

  if key == iw.Key.Mouse:
    let info = iw.getMouse()
    if info.button == iw.MouseButton.mbLeft and info.action == iw.MouseButtonAction.mbaPressed:
      session.insert(buffer.id, Prompt, None)
      if info.x >= buffer.x and
          info.x <= buffer.x + buffer.width and
          info.y >= buffer.y and
          info.y <= buffer.y + buffer.height:
        if buffer.mode == 0:
            session.insert(buffer.id, CursorX, info.x - (buffer.x + 1 - buffer.scrollX))
            session.insert(buffer.id, CursorY, info.y - (buffer.y + 1 - buffer.scrollY))
        elif buffer.mode == 1:
          let
            x = info.x - buffer.x - 1 + buffer.scrollX
            y = info.y - buffer.y - 1 + buffer.scrollY
          if x >= 0 and y >= 0:
            var lines = buffer.lines
            while y > lines[].len - 1:
              lines.add("")
            var line = lines[y][].toRunes
            while x > line.stripCodes.len - 1:
              line.add(" ".runeAt(0))
            let
              realX = codes.getRealX(line, x)
              prefix = buffer.makePrefix
              suffix = "\e[" & strutils.join(@[0] & codes.getParamsBeforeRealX(line, realX), ";") & "m"
              oldChar = line[realX].toUTF8
              newChar = if oldChar in wavescript.whitespaceChars: buffer.selectedChar else: oldChar
            lines.set(y, codes.dedupeCodes($line[0 ..< realX] & prefix & newChar & suffix & $line[realX + 1 ..< line.len]))
            session.insert(buffer.id, Lines, lines)
  elif focused and buffer.mode == 0:
    if key != iw.Key.None:
      session.insert(buffer.id, Prompt, None)
      discard onInput(key, buffer) or onInput(key.ord, buffer)

  if buffer.mode == 0 or buffer.prompt == StopPlaying:
    let
      col = buffer.x + 1 + buffer.cursorX - buffer.scrollX
      row = buffer.y + 1 + buffer.cursorY - buffer.scrollY
    setCursor(tb, col, row)
    var
      xBlock = tb[col, buffer.y]
      yBlock = tb[buffer.x, row]
    xBlock.fg = iw.fgYellow
    yBlock.fg = iw.fgYellow
    tb[col, buffer.y] = xBlock
    tb[buffer.x, row] = yBlock

  if buffer.mode == 0:
    var prompt = ""
    case buffer.prompt:
    of None:
      if buffer.insertMode:
        prompt = "Press Insert to turn off insert mode"
    of DeleteLine:
      prompt = "Press Tab to delete the current line"
    of StopPlaying:
      prompt = "Press Tab to stop playing"
    if prompt.len > 0:
      let x = buffer.x + 1 + buffer.width - prompt.runeLen
      iw.write(tb, max(x, buffer.x + 1), buffer.y, prompt)

proc renderRadioButtons(tb: var iw.TerminalBuffer, x: int, y: int, choices: openArray[tuple[id: int, label: string, callback: proc ()]], selected: int, key: iw.Key, horiz: bool, shortcut: tuple[key: iw.Key, hint: string]): int =
  const space = 2
  var
    xx = x
    yy = y
  for i in 0 ..< choices.len:
    let choice = choices[i]
    if choice.id == selected:
      iw.write(tb, xx, yy, "→")
    iw.write(tb, xx + space, yy, choice.label)
    let
      oldX = xx
      newX = xx + space + choice.label.runeLen + 1
      oldY = yy
      newY = if horiz: yy else: yy + 1
    if key == iw.Key.Mouse:
      let info = iw.getMouse()
      if info.button == iw.MouseButton.mbLeft and info.action == iw.MouseButtonAction.mbaPressed:
        if info.x >= oldX and
            info.x <= newX and
            info.y == oldY:
          session.insert(Global, HintText, shortcut.hint)
          session.insert(Global, HintTime, times.epochTime() + hintSecs)
          choice.callback()
    elif choice.id == selected and shortcut.key != iw.Key.None and shortcut.key == key:
      let nextChoice =
        if i+1 == choices.len:
          choices[0]
        else:
          choices[i+1]
      nextChoice.callback()
    if horiz:
      xx = newX
    else:
      yy = newY
  if not horiz:
    let labelWidths = sequtils.map(choices, proc (x: tuple): int = x.label.runeLen)
    xx += labelWidths[sequtils.maxIndex(labelWidths)] + space * 2
  return xx

proc renderButton(tb: var iw.TerminalBuffer, text: string, x: int, y: int, key: iw.Key, cb: proc (), shortcut: tuple[key: iw.Key, hint: string] = (iw.Key.None, "")): int =
  codes.write(tb, x, y, text)
  result = x + text.stripCodes.runeLen + 2
  if key == iw.Key.Mouse:
    let info = iw.getMouse()
    if info.button == iw.MouseButton.mbLeft and info.action == iw.MouseButtonAction.mbaPressed:
      if info.x >= x and
          info.x <= result and
          info.y == y:
        if shortcut.hint.len > 0:
          session.insert(Global, HintText, shortcut.hint)
          session.insert(Global, HintTime, times.epochTime() + hintSecs)
        cb()
  elif shortcut.key != iw.Key.None and shortcut.key == key:
    cb()

proc renderColors(tb: var iw.TerminalBuffer, buffer: tuple, key: iw.Key, colorX: int): int =
  const
    colorFgCodes = ["", "\e[30m", "\e[31m", "\e[32m", "\e[33m", "\e[34m", "\e[35m", "\e[36m", "\e[37m"]
    colorBgCodes = ["", "\e[40m", "\e[41m", "\e[42m", "\e[43m", "\e[44m", "\e[45m", "\e[46m", "\e[47m"]
    colorFgShortcuts    = ['x', 'k', 'r', 'g', 'y', 'b', 'm', 'c', 'w']
    colorFgShortcutsSet = {'x', 'k', 'r', 'g', 'y', 'b', 'm', 'c', 'w'}
    colorBgShortcuts    = ['X', 'K', 'R', 'G', 'Y', 'B', 'M', 'C', 'W']
    colorBgShortcutsSet = {'X', 'K', 'R', 'G', 'Y', 'B', 'M', 'C', 'W'}
    colorNames = ["default", "black", "red", "green", "yellow", "blue", "magenta", "cyan", "white"]
  result = colorX + colorFgCodes.len * 3 + 1
  var colorChars = ""
  for code in colorFgCodes:
    if code == "":
      colorChars &= "╳╳"
    else:
      colorChars &= code & "██\e[0m"
    colorChars &= " "
  let fgIndex = find(colorFgCodes, buffer.selectedFgColor)
  let bgIndex = find(colorBgCodes, buffer.selectedBgColor)
  codes.write(tb, colorX, 0, colorChars)
  iw.write(tb, colorX + fgIndex * 3, 1, "↑")
  codes.write(tb, colorX + bgIndex * 3 + 1, 1, "↑")
  if key == iw.Key.Mouse:
    let info = iw.getMouse()
    if info.y == 0:
      if info.action == iw.MouseButtonAction.mbaPressed:
        if info.button == iw.MouseButton.mbLeft:
          let index = int((info.x - colorX) / 3)
          if index >= 0 and index < colorFgCodes.len:
            session.insert(buffer.id, SelectedFgColor, colorFgCodes[index])
            if buffer.mode == 1:
              session.insert(Global, HintText, "Hint: press " & colorFgShortcuts[index] & " for " & colorNames[index] & " foreground")
              session.insert(Global, HintTime, times.epochTime() + hintSecs)
        elif info.button == iw.MouseButton.mbRight:
          let index = int((info.x - colorX) / 3)
          if index >= 0 and index < colorBgCodes.len:
            session.insert(buffer.id, SelectedBgColor, colorBgCodes[index])
            if buffer.mode == 1:
              session.insert(Global, HintText, "Hint: press " & colorBgShortcuts[index] & " for " & colorNames[index] & " background")
              session.insert(Global, HintTime, times.epochTime() + hintSecs)
  elif buffer.mode == 1:
    try:
      let ch = char(key.ord)
      if ch in colorFgShortcutsSet:
        let index = find(colorFgShortcuts, ch)
        session.insert(buffer.id, SelectedFgColor, colorFgCodes[index])
      elif ch in colorBgShortcutsSet:
        let index = find(colorBgShortcuts, ch)
        session.insert(buffer.id, SelectedBgColor, colorBgCodes[index])
    except:
      discard

proc renderBrushes(tb: var iw.TerminalBuffer, buffer: tuple, key: iw.Key, brushX: int): int =
  const
    brushChars        = ["█", "▓", "▒", "░", "▀", "▄", "▌", "▐"]
    brushShortcuts    = ['1', '2', '3', '4', '5', '6', '7', '8']
    brushShortcutsSet = {'1', '2', '3', '4', '5', '6', '7', '8'}
  # make sure that all brush chars are treated as whitespace by wavescript
  static: assert brushChars.toHashSet < wavescript.whitespaceChars
  var brushCharsColored = ""
  for ch in brushChars:
    brushCharsColored &= buffer.selectedFgColor & buffer.selectedBgColor
    brushCharsColored &= ch
    brushCharsColored &= "\e[0m "
  result = brushX + brushChars.len * 2
  let brushIndex = find(brushChars, buffer.selectedChar)
  codes.write(tb, brushX, 0, brushCharsColored)
  iw.write(tb, brushX + brushIndex * 2, 1, "↑")
  if key == iw.Key.Mouse:
    let info = iw.getMouse()
    if info.button == iw.MouseButton.mbLeft and info.action == iw.MouseButtonAction.mbaPressed:
      if info.y == 0:
        let index = int((info.x - brushX) / 2)
        if index >= 0 and index < brushChars.len:
          session.insert(buffer.id, SelectedChar, brushChars[index])
          if buffer.mode == 1:
            session.insert(Global, HintText, "Hint: press " & brushShortcuts[index] & " for that brush")
            session.insert(Global, HintTime, times.epochTime() + hintSecs)
  elif buffer.mode == 1:
    try:
      let ch = char(key.ord)
      if ch in brushShortcutsSet:
        let index = find(brushShortcuts, ch)
        session.insert(buffer.id, SelectedChar, brushChars[index])
    except:
      discard

proc undo(buffer: tuple) =
  if buffer.undoIndex > 0:
    session.insert(buffer.id, UndoIndex, buffer.undoIndex - 1)

proc redo(buffer: tuple) =
  if buffer.undoIndex + 1 < buffer.undoHistory[].len:
    session.insert(buffer.id, UndoIndex, buffer.undoIndex + 1)

proc init*(opts: Options, editorText: string) =
  iw.illwillInit(fullscreen=true, mouse=true)
  setControlCHook(exitClean)
  iw.hideCursor()

  for r in rules.fields:
    session.add(r)

  const
    tutorialText = staticRead("ansiwavepkg/assets/tutorial.ansiwave")
    publishText = staticRead("ansiwavepkg/assets/publish.ansiwave")
  insertBuffer(Editor, 0, 2, true, editorText)
  insertBuffer(Errors, 0, 1, false, "")
  insertBuffer(Tutorial, 0, 1, false, tutorialText)
  insertBuffer(Publish, 0, 1, false, publishText)
  session.insert(Global, SelectedBuffer, Editor)
  session.insert(Global, HintText, "")
  session.insert(Global, HintTime, 0.0)
  session.fireRules

  onWindowResize(iw.terminalWidth(), iw.terminalHeight())

proc tick*(): iw.TerminalBuffer =
  let key = iw.getKey()

  let
    (windowWidth, windowHeight) = session.query(rules.getTerminalWindow)
    globals = session.query(rules.getGlobals)
    selectedBuffer = session.query(rules.getBuffer, id = globals.selectedBuffer)
    width = iw.terminalWidth()
    height = iw.terminalHeight()
  var tb = iw.newTerminalBuffer(width, height)
  if width != windowWidth or height != windowHeight:
    onWindowResize(width, height)

  # render top bar
  let titleX = renderButton(tb, "\e[3m≈ANSIWAVE≈\e[0m", 1, 0, key, proc () = discard)
  if globals.selectedBuffer == Editor.ord:
    let playX =
      if selectedBuffer.prompt != StopPlaying and selectedBuffer.commands[].len > 0:
        renderButton(tb, "♫ Play", 1, 1, key, proc () = compileAndPlayAll(session, selectedBuffer), (key: iw.Key.CtrlP, hint: "Hint: play all lines with Ctrl P"))
      else:
        0
    var x = max(titleX, playX)

    let undoX = renderButton(tb, "◄ Undo", x, 0, key, proc () = undo(selectedBuffer), (key: iw.Key.CtrlX, hint: "Hint: undo with Ctrl X"))
    let redoX = renderButton(tb, "► Redo", x, 1, key, proc () = redo(selectedBuffer), (key: iw.Key.CtrlR, hint: "Hint: redo with Ctrl R"))
    x = max(undoX, redoX)

    let
      choices = [
        (id: 0, label: "Write Mode", callback: proc () = session.insert(selectedBuffer.id, SelectedMode, 0)),
        (id: 1, label: "Draw Mode", callback: proc () = session.insert(selectedBuffer.id, SelectedMode, 1)),
      ]
      shortcut = (key: iw.Key.CtrlE, hint: "Hint: switch modes with Ctrl E")
    x = renderRadioButtons(tb, x, 0, choices, selectedBuffer.mode, key, false, shortcut)

    x = renderColors(tb, selectedBuffer, key, x + 1)

    if selectedBuffer.mode == 1:
      x = renderBrushes(tb, selectedBuffer, key, x + 2)
  elif globals.selectedBuffer == Publish.ord:
    discard renderButton(tb, "↕ Copy Link", titleX, 0, key, proc () = echo("copy"), (key: iw.Key.CtrlL, hint: "Hint: copy link with Ctrl L"))

  renderBuffer(tb, selectedBuffer, key)

  # render bottom bar
  var x = 0
  if selectedBuffer.prompt != StopPlaying:
    let
      errorCount = session.query(rules.getBuffer, id = Editor).errors[].len
      choices = [
        (id: Editor.ord, label: "Editor", callback: proc () {.closure.} = session.insert(Global, SelectedBuffer, Editor)),
        (id: Errors.ord, label: strutils.format("Errors ($1)", errorCount), callback: proc () {.closure.} = session.insert(Global, SelectedBuffer, Errors)),
        (id: Tutorial.ord, label: "Tutorial", callback: proc () {.closure.} = session.insert(Global, SelectedBuffer, Tutorial)),
        (id: Publish.ord, label: "Publish", callback: proc () {.closure.} = session.insert(Global, SelectedBuffer, Publish)),
      ]
      shortcut = (key: iw.Key.CtrlN, hint: "Hint: switch tabs with Ctrl N")
    x = renderRadioButtons(tb, 0, windowHeight - 1, choices, globals.selectedBuffer, key, true, shortcut)

  # render hints
  if globals.hintTime > 0 and times.epochTime() >= globals.hintTime:
    session.insert(Global, HintText, "")
    session.insert(Global, HintTime, 0.0)
  else:
    let
      showHint = globals.hintText.len > 0
      text =
        if showHint:
          globals.hintText
        else:
          "‼ Exit"
      textX = max(x + 2, selectedBuffer.width + 1 - text.runeLen)
    if showHint:
      codes.write(tb, textX, windowHeight - 1, "\e[3m" & text & "\e[0m")
    elif selectedBuffer.prompt != StopPlaying:
      let cb =
        proc () =
          session.insert(Global, HintText, "Press Ctrl C to exit")
          session.insert(Global, HintTime, times.epochTime() + hintSecs)
      discard renderButton(tb, text, textX, windowHeight - 1, key, cb)

  return tb

proc parseOptions(): Options =
  var p = parseopt.initOptParser()
  while true:
    parseopt.next(p)
    case p.kind:
    of parseopt.cmdEnd:
      break
    of parseopt.cmdShortOption, parseopt.cmdLongOption:
      result.args[p.key] = p.val
    of parseopt.cmdArgument:
      if result.args.len > 0:
        raise newException(Exception, p.key & " is not in a valid place.\nIf you're trying to pass an option, you need an equals sign like --width=80")
      elif result.input == "":
        result.input = p.key
      elif result.output == "":
        result.output = p.key
      else:
        raise newException(Exception, "Extra argument: " & p.key)

proc convert(opts: Options) =
  let
    inputExt = os.splitFile(opts.input).ext
    outputExt = os.splitFile(opts.output).ext
  if inputExt == ".ans":
    if "width" notin opts.args:
      raise newException(Exception, "--width is required for .ans files")
    let width = strutils.parseInt(opts.args["width"])
    var f: File
    if open(f, opts.output, fmWrite):
      ansi.write(f, ansi.ansiToUtf8(readFile(opts.input), width), width)
      close(f)
    else:
      raise newException(Exception, "Cannot open: " & opts.output)
  elif outputExt == ".url":
    echo "Convert to url..."
  elif outputExt == ".wav":
    echo "Convert to wav..."
  else:
    raise newException(Exception, "Don't know how to convert $1 to $2".format(inputExt, outputExt))

proc saveEditor(opts: Options) =
  let buffer = session.query(rules.getBuffer, id = Editor)
  if buffer.lastEditTime > buffer.lastSaveTime and times.epochTime() - buffer.lastEditTime > saveDelay:
    try:
      var f: File
      if open(f, opts.input, fmWrite):
        let lineCount = buffer.lines[].len
        var i = 0
        for line in buffer.lines[]:
          write(f, line[])
          if i != lineCount - 1:
            write(f, "\n")
          i.inc
        close(f)
      else:
        raise newException(Exception, "Cannot open: " & opts.input)
      session.insert(Editor, LastSaveTime, times.epochTime())
    except Exception as ex:
      exitClean(ex.msg)

proc main*() =
  let opts = parseOptions()
  if opts.input == "":
    raise newException(Exception, "Input file required")
  elif opts.output != "":
    convert(opts)
    quit(0)
  init(opts, readFile(opts.input))
  var tickCount = 0
  while true:
    var tb = tick()
    # save if necessary
    # don't render every tick because it's wasteful
    if tickCount mod 5 == 0:
      iw.display(tb)
    session.fireRules
    saveEditor(opts)
    os.sleep(sleepMsecs)
    tickCount.inc

when isMainModule:
  main()
