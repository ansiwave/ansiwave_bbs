from ./ansiwavepkg/illwill as iw import `[]`, `[]=`
import tables, sets
import pararules
import unicode
from os import nil
from strutils import format
from sequtils import nil
from times import nil
from ./ansiwavepkg/ansi import nil
from ./ansiwavepkg/wavescript import CommandTree
from ./ansiwavepkg/midi import nil
from ./ansiwavepkg/codes import stripCodes
from ./ansiwavepkg/chafa import nil
from ./ansiwavepkg/bbs import nil
import ./ansiwavepkg/constants
from paramidi import Context
from json import nil
from parseopt import nil
from zippy import nil
from base64 import nil
import streams
from uri import nil
from ./ansiwavepkg/ui/editor import nil

proc exitClean(ex: ref Exception) =
  iw.illwillDeinit()
  iw.showCursor()
  raise ex

proc exitClean(message: string) =
  iw.illwillDeinit()
  iw.showCursor()
  if message.len > 0:
    quit(message)
  else:
    quit(0)

proc exitClean() {.noconv.} =
  exitClean("")

proc parseOptions(): editor.Options =
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

proc convertToWav(opts: editor.Options) =
  # parse code
  let lines = editor.splitLines(readFile(opts.input))
  var scriptContext = waveScript.initContext()
  let
    cmds = wavescript.parse(sequtils.map(lines[], codes.stripCodesIfCommand))
    treesTemp = sequtils.map(cmds, proc (text: auto): wavescript.CommandTree = wavescript.parse(scriptContext, text))
    trees = wavescript.parseOperatorCommands(treesTemp)
  # compile code into JSON representation
  var
    noErrors = true
    nodes = json.JsonNode(kind: json.JArray)
    midiContext = paramidi.initContext()
  for cmd in trees:
    case cmd.kind:
    of wavescript.Valid:
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
        discard
      of midi.Error:
        echo "Error on line " & $(cmd.line+1) & ": " & res.message
        noErrors = false
    of wavescript.Error, wavescript.Discard:
      echo "Error on line " & $(cmd.line+1) & ": " & cmd.message
      noErrors = false
  # compile JSON into MIDI events and write to disk
  if nodes.elems.len == 0:
    echo "No music found"
  elif noErrors:
    midiContext = paramidi.initContext()
    let res =
      try:
        midi.compileScore(midiContext, nodes, true)
      except Exception as e:
        echo "Error: " & e.msg
        midi.CompileResult(kind: midi.Error, message: e.msg)
    case res.kind:
    of midi.Valid:
      discard midi.play(res.events, opts.output)
    of midi.Error:
      discard

proc convert(opts: editor.Options) =
  if uri.isAbsolute(uri.parseUri(opts.input)): # a url
    let outputExt = os.splitFile(opts.output).ext
    if outputExt == ".ansiwave":
      let link = editor.parseLink(opts.input)
      var f: File
      if open(f, opts.output, fmWrite):
        editor.saveBuffer(f, editor.splitLines(link["data"]))
        close(f)
      else:
        raise newException(Exception, "Cannot open: " & opts.output)
    else:
      raise newException(Exception, "Don't know how to convert link to $1 (the .ansiwave extension is required)".format(opts.output))
  else:
    let
      inputExt = strutils.toLowerAscii(os.splitFile(opts.input).ext)
      outputExt = os.splitFile(opts.output).ext
    if inputExt == ".ans" and outputExt == ".ansiwave":
      if "width" notin opts.args:
        raise newException(Exception, "--width is required")
      let width = strutils.parseInt(opts.args["width"])
      var f: File
      if open(f, opts.output, fmWrite):
        ansi.write(f, ansi.ansiToUtf8(readFile(opts.input), width), width)
        close(f)
      else:
        raise newException(Exception, "Cannot open: " & opts.output)
    elif inputExt in [".jpg", ".jpeg", ".png", ".gif", ".bmp", ".psd"].toHashSet and outputExt == ".ansiwave":
      if "width" notin opts.args:
        raise newException(Exception, "--width is required")
      let width = strutils.parseInt(opts.args["width"])
      var f: File
      if open(f, opts.output, fmWrite):
        write(f, chafa.imageToAnsi(readFile(opts.input), width.cint))
        close(f)
      else:
        raise newException(Exception, "Cannot open: " & opts.output)
    elif inputExt == ".ansiwave" and outputExt == ".url":
      let
        lines = editor.splitLines(readFile(opts.input))
        link = editor.initLink((lines: lines, name: os.splitFile(opts.input).name))
      var f: File
      if open(f, opts.output, fmWrite):
        write(f, "[InternetShortcut]\n")
        write(f, "URL=" & link)
        close(f)
      else:
        raise newException(Exception, "Cannot open: " & opts.output)
    elif inputExt == ".ansiwave" and outputExt == ".wav":
      convertToWav(opts)
    else:
      raise newException(Exception, "Don't know how to convert $1 to $2 (try changing the file extensions)".format(opts.input, opts.output))

proc saveEditor(session: var auto, opts: editor.Options) =
  let globals = session.query(editor.rules.getGlobals)
  let buffer = session.query(editor.rules.getEditor)
  if buffer.editable and
      buffer.lastEditTime > buffer.lastSaveTime and
      times.epochTime() - buffer.lastEditTime > saveDelay:
    try:
      var f: File
      if open(f, opts.input, fmWrite):
        editor.saveBuffer(f, buffer.lines)
        close(f)
      else:
        raise newException(Exception, "Cannot open: " & opts.input)
      editor.insert(session, editor.Editor, editor.LastSaveTime, times.epochTime())
    except Exception as ex:
      exitClean(ex)

proc renderHome(opts: var editor.Options) =
  var fname = ""
  const
    homeText = strutils.splitLines(staticRead("ansiwavepkg/assets/home.ansiwave"))
    firstText = "Greetings, user. Give me a file name:"
    ext = ".ansiwave"
  while true:
    let
      width = iw.terminalWidth()
      height = iw.terminalHeight()
      x = max(0, int(width/2 - editorWidth/2))
    var
      tb = iw.newTerminalBuffer(width, height)
      y = 0
    for line in homeText:
      iw.write(tb, x, y, line)
      y.inc
    codes.write(tb, max(0, int(width/2 - firstText.runeLen/2)), y-2, "\e[3m" & firstText & "\e[0m")
    # process input
    let key = iw.getKey()
    if key != iw.Key.None:
      if key == iw.Key.Backspace:
        if fname != "":
          let fnameRunes = fname.toRunes
          fname = $fnameRunes[0 ..< fnameRunes.len - 1]
      elif key == iw.Key.Enter:
        if fname != "":
          opts.input = fname & ext
          break
      else:
        let code = key.ord
        if code < 32:
          continue
        let ch =
          try:
            char(code)
          except:
            continue
        fname &= $ch
    # write file name and cursor
    let cursorX = max(0, int(width/2))
    if fname != "":
      let
        fnameRunes = fname.toRunes
        fnameX = int(width/2) - fnameRunes.len
        fnameTruncated = if fnameX < 0: $fnameRunes[abs(fnameX) ..< fnameRunes.len] else : fname
      iw.write(tb, max(0, fnameX), y, fnameTruncated)
      iw.write(tb, cursorX, y, ext)
    editor.setCursor(tb, cursorX, y)
    # write text indicating if file exists
    let existsText =
      if fname == "":
        ""
      elif os.fileExists(fname & ext):
        "File exists. Press Enter to open it."
      else:
        "File doesn't exist. Press Enter to create it."
    codes.write(tb, max(0, int(width/2 - existsText.runeLen/2)), y+2, "\e[3m" & existsText & "\e[0m")
    iw.write(tb, 0, height-1, "Version " & version)
    # display and sleep
    iw.display(tb)
    os.sleep(sleepMsecs)

proc main*() =
  # parse options
  var opts = parseOptions()
  if opts.output != "":
    if opts.input == opts.output:
      raise newException(Exception, "Input and output cannot be the same")
    convert(opts)
    quit(0)
  # initialize illwill
  iw.illwillInit(fullscreen=true, mouse=true)
  setControlCHook(exitClean)
  iw.hideCursor()
  if opts.args.hasKey("bbstest"):
    bbs.renderBBS()
  # render home if no args are passed
  if opts.input == "":
    renderHome(opts)
  if opts.input == "":
    exitClean("No file or link to open")
  # enter the main render loop
  var session = editor.initSession()
  editor.init(session, opts)
  var tickCount = 0
  while true:
    var tb = editor.tick(session)
    # save if necessary
    # don't render every tick because it's wasteful
    if tickCount mod 5 == 0:
      iw.display(tb)
    session.fireRules
    saveEditor(session, opts)
    os.sleep(sleepMsecs)
    tickCount.inc

when isMainModule:
  main()
