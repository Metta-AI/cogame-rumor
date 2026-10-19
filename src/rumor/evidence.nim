## Private evidence artifacts: exclusive creation, no spectator publication.
import std/[json, os, posix]
import types

proc actionFromEvent*(event: GameEvent): JsonNode =
  case event.kind
  of evSay:
    %*{"claim": event.claim, "confidence": event.confidence,
      "belief": event.belief, "message": event.text, "notes": event.notes}
  of evVote:
    %*{"vote": event.vote, "belief": event.belief,
      "reason": event.text, "notes": event.notes}
  else:
    raise newException(ValueError, "expected an applied talk or ballot event")

type EvidenceError* = object of Defect

proc writePrivate*(destination, content: string) =
  let parent = destination.parentDir()
  if parent.len > 0 and not dirExists(parent):
    createDir(parent)
    setFilePermissions(parent, {fpUserRead, fpUserWrite, fpUserExec})
  let descriptor = posix.open(destination.cstring, O_WRONLY or O_CREAT or O_EXCL, Mode(0o600))
  if descriptor < 0:
    raise newException(EvidenceError, "cannot create private evidence: " & $osLastError())
  var output: File
  if not open(output, FileHandle(descriptor), fmWrite):
    let code = osLastError()
    discard posix.close(descriptor)
    raise newException(EvidenceError, "cannot open private evidence: " & $code)
  defer: output.close()
  if output.writeBuffer(content.cstring, content.len) != content.len:
    raise newException(EvidenceError, "incomplete private evidence write")

proc appendPrivate*(destination: string, record: JsonNode) =
  ## The owning host creates this file privately before starting its workers.
  var output: File
  if not open(output, destination, fmAppend):
    raise newException(EvidenceError, "cannot append private evidence")
  defer: output.close()
  let content = $record & "\n"
  if output.writeBuffer(content.cstring, content.len) != content.len:
    raise newException(EvidenceError, "incomplete private evidence append")
