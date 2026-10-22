## store.nim - journals on disk.
##
## Everything lives under a single directory, `~/.journal` unless a test
## points the store somewhere else:
##
##   ~/.journal/journals.json
##   ~/.journal/journals/<id>/entries.json
##   ~/.journal/journals/<id>/<entryId>.md
##
## `journals.json` is the catalog (name, description, timestamps).
## `entries.json` is the metadata for one journal (title, timestamps,
## word count, a short preview). The markdown file is the entry itself
## and is the only copy of the body.
##
## Ids are 16 lowercase hex characters generated here. Callers never get
## to choose a path.
##
## Exposed procs run on Neel's worker threads, concurrently. Every public
## proc takes `storeLock` and then works on locals. The lock is not
## reentrant: a public proc must not call another public proc. The only
## globals are `gRoot` and `gFrozen`, and they are touched inside
## `{.cast(gcsafe).}` while the lock is held.

import std/[algorithm, json, locks, os, strutils, sysrand, times]

type
  JournalError* = object of CatchableError
    ## The store could not read or write its files.

  NotFoundError* = object of JournalError
    ## The journal or entry id is well formed and not in the catalog.

  InvalidNameError* = object of JournalError
    ## A name, title, body, or id was rejected.

  JournalMeta* = object
    id*: string
    name*: string
    description*: string
    created*: string
    updated*: string

  EntryMeta* = object
    id*: string
    title*: string
    displayTitle*: string
      ## What the entry list shows. Not written to disk: an empty title
      ## displays the start of the entry, or "Untitled".
    created*: string
    updated*: string
    wordCount*: int
    preview*: string

  Entry* = object
    meta*: EntryMeta
    body*: string

  SearchHit* = object
    journalId*: string
    journalName*: string
    entry*: EntryMeta
    snippet*: string

const
  MaxName = 80
  MaxDescription = 400
  MaxTitle = 200
  MaxBody = 1_000_000
  MaxHits = 50
  IdLen = 16
  PreviewRunes = 160
  TitleRunes = 80

var
  storeLock: Lock
  gRoot: string
    ## Absolute data directory. Empty until the first use, which selects
    ## `~/.journal`. Tests set it before that.
  gFrozen: string
    ## When non-empty, timestamps use this value instead of the clock.
    ## Tests only.

initLock(storeLock)

# --- small helpers --------------------------------------------------------------

proc isUtf8Cont(c: char): bool {.inline.} =
  (ord(c) and 0xC0) == 0x80

proc validId(s: string): bool =
  if s.len != IdLen:
    return false
  for c in s:
    if c notin {'0' .. '9', 'a' .. 'f'}:
      return false
  true

proc takeRunes(s: string; n: int): tuple[text: string, cut: bool] =
  ## The first `n` Unicode scalar values of `s`, and whether anything was left.
  var i = 0
  var count = 0
  while i < s.len and count < n:
    inc i
    while i < s.len and isUtf8Cont(s[i]):
      inc i
    inc count
  (s[0 ..< i], i < s.len)

proc collapseWhitespace(s: string): string =
  var prevSpace = true
  for c in s:
    if c in {' ', '\t', '\n', '\r'}:
      if not prevSpace:
        result.add ' '
      prevSpace = true
    else:
      result.add c
      prevSpace = false
  result.strip

proc stripToken(token: string): string =
  ## Drops markdown marks wrapped around a word so `**world**` and a bare
  ## list dash do not count as words. Hyphens inside a word stay.
  const
    lead = {'#', '*', '_', '-', '>', '`', '[', ']', '(', ')', '!'}
    trail = {'*', '_', '`', '.', ',', ';', ':', '!', '?', ')', ']'}
  var a = 0
  var b = token.len
  while a < b and token[a] in lead:
    inc a
  while b > a and token[b - 1] in trail:
    dec b
  token[a ..< b]

proc countWords(body: string): int =
  var token = ""
  template flush() =
    if stripToken(token).len > 0:
      inc result
    token.setLen(0)
  for c in body:
    if c <= ' ':
      flush()
    else:
      token.add c
  flush()

proc makePreview(body: string): string =
  let taken = takeRunes(collapseWhitespace(body), PreviewRunes)
  result = taken.text
  if taken.cut:
    result.add "…"

proc applyDisplay(e: var EntryMeta) =
  let trimmed = e.title.strip
  if trimmed.len > 0:
    let taken = takeRunes(trimmed, TitleRunes)
    e.displayTitle = taken.text
    if taken.cut:
      e.displayTitle.add "…"
  elif e.preview.len > 0:
    let taken = takeRunes(e.preview, 72)
    e.displayTitle = taken.text
    if taken.cut and not e.displayTitle.endsWith("…"):
      e.displayTitle.add "…"
  else:
    e.displayTitle = "Untitled"

proc alignDown(s: string; index: int): int =
  result = clamp(index, 0, s.len)
  while result > 0 and result < s.len and isUtf8Cont(s[result]):
    dec result

proc alignUp(s: string; index: int): int =
  result = clamp(index, 0, s.len)
  while result < s.len and isUtf8Cont(s[result]):
    inc result

proc snippetAround(body, query: string): string =
  let at = body.toLowerAscii.find(query.toLowerAscii)
  let startAt = if at < 0: 0 else: at
  let needleLen = if at < 0: 0 else: query.len
  let start = alignDown(body, max(0, startAt - 48))
  let stop = alignUp(body, min(body.len, startAt + needleLen + 96))
  let chunk = collapseWhitespace(body[start ..< stop])
  if start > 0:
    result = "…" & chunk
  else:
    result = chunk
  if stop < body.len:
    result.add "…"

proc nowIso(frozen: string): string =
  if frozen.len > 0:
    return frozen
  now().utc.format("yyyy-MM-dd'T'HH:mm:ss'Z'")

proc newId(): string =
  var bytes: array[8, byte]
  if not urandom(bytes):
    raise newException(JournalError, "Could not generate an id.")
  const hexits = "0123456789abcdef"
  result = newString(IdLen)
  var n = 0
  for b in bytes:
    let v = ord(b)
    result[n] = hexits[v shr 4]
    result[n + 1] = hexits[v and 0x0F]
    inc n, 2

proc guard(root, path: string): string =
  ## `path` joined under `root`, or an error if it escapes.
  let base = normalizedPath(absolutePath(root))
  let full = normalizedPath(absolutePath(path))
  let prefix = if base.endsWith(DirSep): base else: base & DirSep
  if full != base and not full.startsWith(prefix):
    raise newException(JournalError, "Refusing to touch a path outside the journal folder.")
  full

proc writeAtomic(path, content: string) =
  ## Write `content` to a sibling temp file, then replace `path`.
  ## `moveFile` overwrites the destination on the same volume.
  let tmp = path & ".tmp"
  try:
    writeFile(tmp, content)
    moveFile(tmp, path)
  except IOError, OSError:
    discard tryRemoveFile(tmp)
    raise newException(JournalError, "Could not write " & extractFilename(path) & ".")

proc readJsonFile(path: string): JsonNode =
  var text: string
  try:
    text = readFile(path)
  except IOError, OSError:
    raise newException(JournalError, "Could not read " & extractFilename(path) & ".")
  try:
    result = parseJson(text)
  except JsonParsingError, ValueError:
    raise newException(JournalError, extractFilename(path) & " is not valid JSON.")

proc dumpJson(node: JsonNode): string =
  node.pretty & "\n"

proc fieldStr(n: JsonNode; key, file: string): string =
  if n.kind != JObject or not n.hasKey(key) or n[key].kind != JString:
    raise newException(JournalError, file & " is missing \"" & key & "\".")
  n[key].getStr

proc fieldInt(n: JsonNode; key, file: string): int =
  if n.kind != JObject or not n.hasKey(key) or n[key].kind != JInt:
    raise newException(JournalError, file & " is missing \"" & key & "\".")
  let value = n[key].getInt
  if value < 0 or value > high(int):
    raise newException(JournalError, file & " has a bad \"" & key & "\".")
  int(value)

proc noControls(s, message: string) =
  for c in s:
    if ord(c) < 32:
      raise newException(InvalidNameError, message)

proc cleanName(name: string): string =
  result = name.strip
  if result.len == 0:
    raise newException(InvalidNameError, "A journal needs a name.")
  if result.len > MaxName:
    raise newException(InvalidNameError, "That journal name is too long.")
  noControls(result, "The journal name contains invalid characters.")

proc cleanDescription(description: string): string =
  result = description.strip
  if result.len > MaxDescription:
    raise newException(InvalidNameError, "That description is too long.")
  for c in result:
    if ord(c) < 32 and c notin {'\n', '\t'}:
      raise newException(InvalidNameError, "The description contains invalid characters.")

proc cleanTitle(title: string): string =
  ## Stored as typed, aside from rejecting control characters and a hard length.
  ## Stripping would fight the editor: a trailing space would never match the
  ## saved title, and autosave would loop.
  if title.len > MaxTitle:
    raise newException(InvalidNameError, "That title is too long.")
  noControls(title, "The title contains invalid characters.")
  result = title

proc cleanBody(body: string): string =
  if body.len > MaxBody:
    raise newException(InvalidNameError, "That entry is too large.")
  result = body

# --- paths (lock held, root already chosen) ------------------------------------

proc journalDirectory(root, id: string): string =
  if not validId(id):
    raise newException(InvalidNameError, "That journal id is not valid.")
  guard(root, root / "journals" / id)

proc entryPath(root, journalId, entryId: string): string =
  if not validId(entryId):
    raise newException(InvalidNameError, "That entry id is not valid.")
  guard(root, journalDirectory(root, journalId) / (entryId & ".md"))

proc entriesPath(root, journalId: string): string =
  guard(root, journalDirectory(root, journalId) / "entries.json")

# --- catalog --------------------------------------------------------------------

proc cmpJournals(a, b: JournalMeta): int =
  result = cmp(b.updated, a.updated)
  if result == 0:
    result = cmp(a.name.toLowerAscii, b.name.toLowerAscii)
  if result == 0:
    result = cmp(a.id, b.id)

proc cmpEntries(a, b: EntryMeta): int =
  result = cmp(b.created, a.created)
  if result == 0:
    result = cmp(a.id, b.id)

proc journalToJson(j: JournalMeta): JsonNode =
  %*{
    "id": j.id,
    "name": j.name,
    "description": j.description,
    "created": j.created,
    "updated": j.updated
  }

proc entryToJson(e: EntryMeta): JsonNode =
  %*{
    "id": e.id,
    "title": e.title,
    "created": e.created,
    "updated": e.updated,
    "wordCount": e.wordCount,
    "preview": e.preview
  }

proc parseJournal(n: JsonNode): JournalMeta =
  if n.kind != JObject:
    raise newException(JournalError, "journals.json has an entry that is not an object.")
  result.id = fieldStr(n, "id", "journals.json")
  if not validId(result.id):
    raise newException(JournalError, "journals.json has an invalid id.")
  result.name = fieldStr(n, "name", "journals.json")
  result.description = fieldStr(n, "description", "journals.json")
  result.created = fieldStr(n, "created", "journals.json")
  result.updated = fieldStr(n, "updated", "journals.json")

proc parseEntry(n: JsonNode): EntryMeta =
  if n.kind != JObject:
    raise newException(JournalError, "entries.json has an entry that is not an object.")
  result.id = fieldStr(n, "id", "entries.json")
  if not validId(result.id):
    raise newException(JournalError, "entries.json has an invalid id.")
  result.title = fieldStr(n, "title", "entries.json")
  result.created = fieldStr(n, "created", "entries.json")
  result.updated = fieldStr(n, "updated", "entries.json")
  result.wordCount = fieldInt(n, "wordCount", "entries.json")
  result.preview = fieldStr(n, "preview", "entries.json")
  applyDisplay(result)

proc loadJournals(root: string): seq[JournalMeta] =
  let node = readJsonFile(guard(root, root / "journals.json"))
  if node.kind != JObject or not node.hasKey("journals") or node["journals"].kind != JArray:
    raise newException(JournalError, "journals.json is not valid.")
  var seen = ""
  for item in node["journals"]:
    let journal = parseJournal(item)
    if journal.id in seen:
      raise newException(JournalError, "journals.json lists the same journal twice.")
    if seen.len > 0:
      seen.add ' '
    seen.add journal.id
    result.add journal
  result.sort(cmpJournals)

proc saveJournals(root: string; journals: seq[JournalMeta]) =
  var ordered = journals
  ordered.sort(cmpJournals)
  var arr = newJArray()
  for journal in ordered:
    arr.add journalToJson(journal)
  var doc = newJObject()
  doc["journals"] = arr
  writeAtomic(guard(root, root / "journals.json"), dumpJson(doc))

proc loadEntries(root, journalId: string): seq[EntryMeta] =
  let node = readJsonFile(entriesPath(root, journalId))
  if node.kind != JObject or not node.hasKey("entries") or node["entries"].kind != JArray:
    raise newException(JournalError, "entries.json is not valid.")
  var seen = ""
  for item in node["entries"]:
    let entry = parseEntry(item)
    if entry.id in seen:
      raise newException(JournalError, "entries.json lists the same entry twice.")
    if seen.len > 0:
      seen.add ' '
    seen.add entry.id
    result.add entry
  result.sort(cmpEntries)

proc saveEntries(root, journalId: string; entries: seq[EntryMeta]) =
  var ordered = entries
  ordered.sort(cmpEntries)
  var arr = newJArray()
  for entry in ordered:
    arr.add entryToJson(entry)
  var doc = newJObject()
  doc["entries"] = arr
  writeAtomic(entriesPath(root, journalId), dumpJson(doc))

proc indexOfId(ids: seq[string]; id, missing: string): int =
  for i, existing in ids:
    if existing == id:
      return i
  raise newException(NotFoundError, missing)

proc journalIndex(journals: seq[JournalMeta]; id: string): int =
  if not validId(id):
    raise newException(InvalidNameError, "That journal id is not valid.")
  var ids: seq[string]
  for journal in journals:
    ids.add journal.id
  indexOfId(ids, id, "No journal with that id.")

proc entryIndex(entries: seq[EntryMeta]; id: string): int =
  if not validId(id):
    raise newException(InvalidNameError, "That entry id is not valid.")
  var ids: seq[string]
  for entry in entries:
    ids.add entry.id
  indexOfId(ids, id, "No entry with that id.")

proc freshId(taken: seq[string]): string =
  for _ in 1 .. 8:
    result = newId()
    if result notin taken:
      return
  raise newException(JournalError, "Could not generate an id.")

proc emptyEntriesDoc(): string =
  var doc = newJObject()
  doc["entries"] = newJArray()
  dumpJson(doc)

# --- root -----------------------------------------------------------------------

proc currentFrozen(): string {.gcsafe.} =
  {.cast(gcsafe).}:
    result = gFrozen

proc ensureRoot(): string {.gcsafe.} =
  ## Caller holds `storeLock`. Creates the directory and an empty catalog
  ## the first time.
  {.cast(gcsafe).}:
    if gRoot.len == 0:
      gRoot = normalizedPath(getHomeDir() / ".journal")
    result = gRoot
  try:
    createDir(result)
    createDir(result / "journals")
  except OSError, IOError:
    raise newException(JournalError, "Could not create the journal folder.")
  let index = result / "journals.json"
  if not fileExists(index):
    var doc = newJObject()
    doc["journals"] = newJArray()
    writeAtomic(index, dumpJson(doc))

proc setDataRoot*(path: string) {.gcsafe.} =
  ## Tests call this before any other store proc. Not used by the app.
  withLock storeLock:
    {.cast(gcsafe).}:
      gRoot = normalizedPath(absolutePath(path))

proc setFrozenTime*(iso: string) {.gcsafe.} =
  ## Tests pin `created` / `updated`. Pass "" to use the real clock again.
  withLock storeLock:
    {.cast(gcsafe).}:
      gFrozen = iso

proc initStore*() {.gcsafe.} =
  ## Creates `~/.journal` (or the test root) if it does not exist yet.
  withLock storeLock:
    discard ensureRoot()

proc dataDirectory*(): string {.gcsafe.} =
  withLock storeLock:
    result = ensureRoot()

# --- journals -------------------------------------------------------------------

proc listJournals*(): seq[JournalMeta] {.gcsafe.} =
  withLock storeLock:
    result = loadJournals(ensureRoot())

proc createJournal*(name, description: string): JournalMeta {.gcsafe.} =
  withLock storeLock:
    let root = ensureRoot()
    let stamp = nowIso(currentFrozen())
    var journals = loadJournals(root)
    var ids: seq[string]
    for journal in journals:
      ids.add journal.id
    result = JournalMeta(
      id: freshId(ids),
      name: cleanName(name),
      description: cleanDescription(description),
      created: stamp,
      updated: stamp
    )
    let dir = journalDirectory(root, result.id)
    createDir(dir)
    try:
      writeAtomic(entriesPath(root, result.id), emptyEntriesDoc())
      journals.add result
      saveJournals(root, journals)
    except CatchableError:
      discard tryRemoveFile(entriesPath(root, result.id))
      if dirExists(dir):
        removeDir(dir)
      raise

proc updateJournal*(id, name, description: string): JournalMeta {.gcsafe.} =
  withLock storeLock:
    let root = ensureRoot()
    var journals = loadJournals(root)
    let index = journalIndex(journals, id)
    journals[index].name = cleanName(name)
    journals[index].description = cleanDescription(description)
    journals[index].updated = nowIso(currentFrozen())
    saveJournals(root, journals)
    result = journals[index]

proc deleteJournal*(id: string) {.gcsafe.} =
  withLock storeLock:
    let root = ensureRoot()
    var journals = loadJournals(root)
    let index = journalIndex(journals, id)
    let dir = journalDirectory(root, id)
    if dirExists(dir):
      removeDir(dir)
    journals.delete(index)
    saveJournals(root, journals)

# --- entries --------------------------------------------------------------------

proc listEntries*(journalId: string): seq[EntryMeta] {.gcsafe.} =
  withLock storeLock:
    let root = ensureRoot()
    let journals = loadJournals(root)
    discard journalIndex(journals, journalId)
    result = loadEntries(root, journalId)

proc readEntry*(journalId, entryId: string): Entry {.gcsafe.} =
  withLock storeLock:
    let root = ensureRoot()
    let journals = loadJournals(root)
    discard journalIndex(journals, journalId)
    let entries = loadEntries(root, journalId)
    let index = entryIndex(entries, entryId)
    let path = entryPath(root, journalId, entryId)
    if not fileExists(path):
      raise newException(JournalError, "The entry file is missing.")
    try:
      result.body = readFile(path)
    except IOError, OSError:
      raise newException(JournalError, "Could not read the entry.")
    result.meta = entries[index]

proc createEntry*(journalId, title, body: string): Entry {.gcsafe.} =
  withLock storeLock:
    let root = ensureRoot()
    let stamp = nowIso(currentFrozen())
    var journals = loadJournals(root)
    let ji = journalIndex(journals, journalId)
    let storedTitle = cleanTitle(title)
    let storedBody = cleanBody(body)
    var entries = loadEntries(root, journalId)
    var ids: seq[string]
    for entry in entries:
      ids.add entry.id
    var meta = EntryMeta(
      id: freshId(ids),
      title: storedTitle,
      created: stamp,
      updated: stamp,
      wordCount: countWords(storedBody),
      preview: makePreview(storedBody)
    )
    applyDisplay(meta)
    let path = entryPath(root, journalId, meta.id)
    writeAtomic(path, storedBody)
    try:
      entries.add meta
      saveEntries(root, journalId, entries)
      journals[ji].updated = stamp
      saveJournals(root, journals)
    except CatchableError:
      discard tryRemoveFile(path)
      raise
    result = Entry(meta: meta, body: storedBody)

proc updateEntry*(journalId, entryId, title, body: string): Entry {.gcsafe.} =
  withLock storeLock:
    let root = ensureRoot()
    let stamp = nowIso(currentFrozen())
    var journals = loadJournals(root)
    let ji = journalIndex(journals, journalId)
    var entries = loadEntries(root, journalId)
    let ei = entryIndex(entries, entryId)
    let storedTitle = cleanTitle(title)
    let storedBody = cleanBody(body)
    var meta = entries[ei]
    meta.title = storedTitle
    meta.updated = stamp
    meta.wordCount = countWords(storedBody)
    meta.preview = makePreview(storedBody)
    applyDisplay(meta)
    writeAtomic(entryPath(root, journalId, entryId), storedBody)
    entries[ei] = meta
    saveEntries(root, journalId, entries)
    journals[ji].updated = stamp
    saveJournals(root, journals)
    result = Entry(meta: meta, body: storedBody)

proc deleteEntry*(journalId, entryId: string) {.gcsafe.} =
  withLock storeLock:
    let root = ensureRoot()
    let journals = loadJournals(root)
    discard journalIndex(journals, journalId)
    var entries = loadEntries(root, journalId)
    let index = entryIndex(entries, entryId)
    let path = entryPath(root, journalId, entryId)
    if fileExists(path):
      try:
        removeFile(path)
      except OSError, IOError:
        raise newException(JournalError, "Could not delete the entry.")
    entries.delete(index)
    saveEntries(root, journalId, entries)

# --- search ---------------------------------------------------------------------

proc searchEntries*(query: string): seq[SearchHit] {.gcsafe.} =
  ## Case-insensitive substring search over titles and bodies, newest
  ## journals first, at most `MaxHits` matches. An empty query matches nothing.
  let needle = query.strip
  if needle.len == 0:
    return
  let folded = needle.toLowerAscii
  withLock storeLock:
    let root = ensureRoot()
    for journal in loadJournals(root):
      if not dirExists(journalDirectory(root, journal.id)):
        continue
      for entry in loadEntries(root, journal.id):
        let titleHit = folded in entry.title.toLowerAscii
        let path = entryPath(root, journal.id, entry.id)
        if not fileExists(path):
          continue
        var body = ""
        try:
          body = readFile(path)
        except IOError, OSError:
          continue
        let bodyHit = folded in body.toLowerAscii
        if not titleHit and not bodyHit:
          continue
        result.add SearchHit(
          journalId: journal.id,
          journalName: journal.name,
          entry: entry,
          snippet: if bodyHit: snippetAround(body, needle) else: entry.preview
        )
        if result.len >= MaxHits:
          return
