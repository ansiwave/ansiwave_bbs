from illwave as iw import nil
from nimwave import nil
import tables, json

type
  ViewFocusArea* = tuple[tb: iw.TerminalBuffer, action: string, actionData: OrderedTable[string, JsonNode], copyableText: seq[string]]
  State* = object
    focusIndex*: int
    focusAreas*: ref seq[ViewFocusArea]
  Context* = nimwave.Context[State]

proc initContext*(tb: iw.TerminalBuffer): Context =
  result = nimwave.initContext[State](tb)
  new result.data.focusAreas