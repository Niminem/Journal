## Store tests. They use tests/scratch and never touch ~/.journal.

import std/[json, os, strutils, unicode, unittest]
import journal/store

let scratch = currentSourcePath().parentDir / "scratch"

proc resetStore() =
  doAssert extractFilename(scratch) == "scratch"
  doAssert extractFilename(scratch.parentDir) == "tests"
  doAssert normalizedPath(absolutePath(scratch)) != normalizedPath(getHomeDir() / ".journal")
  setFrozenTime("")
  if dirExists(scratch):
    removeDir(scratch)
  setDataRoot(scratch)
  initStore()

proc mdPath(journalId, entryId: string): string =
  dataDirectory() / "journals" / journalId / (entryId & ".md")

suite "journal store":
  setup:
    resetStore()

  test "init creates an empty catalog and nothing in the home directory":
    let root = dataDirectory()
    check root == normalizedPath(absolutePath(scratch))
    check dirExists(root / "journals")
    let node = parseFile(root / "journals.json")
    check node["journals"].kind == JArray
    check node["journals"].len == 0
    check not dirExists(getHomeDir() / ".journal") or
      normalizedPath(getHomeDir() / ".journal") != root

  test "journals round-trip and stay in the catalog":
    let daily = createJournal("  Daily  ", "  ordinary days\nstill here  ")
    check daily.name == "Daily"
    check daily.description == "ordinary days\nstill here"
    check daily.created == daily.updated
    check fileExists(dataDirectory() / "journals" / daily.id / "entries.json")
    let again = listJournals()
    check again.len == 1
    check again[0].id == daily.id
    check again[0].name == "Daily"
    let renamed = updateJournal(daily.id, "Morning", "shorter")
    check renamed.id == daily.id
    check renamed.created == daily.created
    check renamed.name == "Morning"
    check listJournals()[0].description == "shorter"
    let raw = readFile(dataDirectory() / "journals.json")
    check "Morning" in raw
    check "\n" in raw

  test "newest journal activity is listed first":
    setFrozenTime("2026-10-21T10:00:00Z")
    let alpha = createJournal("Alpha", "")
    setFrozenTime("2026-10-21T11:00:00Z")
    let beta = createJournal("Beta", "")
    check listJournals()[0].id == beta.id
    setFrozenTime("2026-10-21T12:00:00Z")
    discard updateJournal(alpha.id, "Alpha", "touched")
    check listJournals()[0].id == alpha.id
    check listJournals()[0].created == "2026-10-21T10:00:00Z"
    check listJournals()[0].updated == "2026-10-21T12:00:00Z"

  test "empty and oversized names are rejected":
    expect InvalidNameError:
      discard createJournal("   ", "")
    expect InvalidNameError:
      discard createJournal("a".repeat(81), "")
    let journal = createJournal("Notes", "")
    expect InvalidNameError:
      discard updateJournal(journal.id, "bad\x01name", "")

  test "unknown and malformed journal ids":
    expect InvalidNameError:
      discard listEntries("..")
    expect InvalidNameError:
      discard listEntries("..\\..\\Windows")
    expect InvalidNameError:
      deleteJournal("not-an-id")
    expect NotFoundError:
      discard listEntries("0123456789abcdef")

  test "entries are markdown plus metadata":
    setFrozenTime("2026-10-21T12:00:00Z")
    let journal = createJournal("Daily", "")
    let body = "café — snow\n\nstill here\n"
    let entry = createEntry(journal.id, "  Evening  ", body)
    check entry.meta.title == "  Evening  "
    check entry.meta.displayTitle == "Evening"
    check entry.body == body
    check entry.meta.wordCount == 5
    check entry.meta.created == "2026-10-21T12:00:00Z"
    check readFile(mdPath(journal.id, entry.meta.id)) == body
    let index = readFile(dataDirectory() / "journals" / journal.id / "entries.json")
    check "café" in index
    check "wordCount" in index
    check "displayTitle" notin index
    let catalog = readFile(dataDirectory() / "journals.json")
    check "café" notin catalog
    let loaded = readEntry(journal.id, entry.meta.id)
    check loaded.body == body
    check loaded.meta.displayTitle == "Evening"

  test "a blank title displays the start of the entry":
    let journal = createJournal("Daily", "")
    let entry = createEntry(journal.id, "", "First line of the day\n\nmore")
    check entry.meta.title == ""
    check entry.meta.displayTitle == "First line of the day more"
    check entry.meta.wordCount == 6
    check entry.meta.preview == "First line of the day more"

  test "long entries keep a short preview":
    let journal = createJournal("Daily", "")
    let entry = createEntry(journal.id, "Long", "x".repeat(500))
    check entry.meta.wordCount == 1
    check entry.meta.preview.endsWith("…")
    check entry.meta.preview.runeLen == 161
    let tail = "UNIQUE-TAIL-9f3a"
    let fat = "y".repeat(400) & tail
    let second = createEntry(journal.id, "Tail", fat)
    check tail in readFile(mdPath(journal.id, second.meta.id))
    check tail notin readFile(dataDirectory() / "journals" / journal.id / "entries.json")

  test "updating an entry keeps created and replaces the file":
    setFrozenTime("2026-10-21T12:00:00Z")
    let journal = createJournal("Daily", "")
    let entry = createEntry(journal.id, "Morning", "one")
    setFrozenTime("2026-10-21T15:30:00Z")
    let saved = updateEntry(journal.id, entry.meta.id, "Morning", "one two")
    check saved.meta.created == "2026-10-21T12:00:00Z"
    check saved.meta.updated == "2026-10-21T15:30:00Z"
    check saved.meta.wordCount == 2
    check readFile(mdPath(journal.id, entry.meta.id)) == "one two"
    check listJournals()[0].updated == "2026-10-21T15:30:00Z"

  test "entries are listed newest first":
    let journal = createJournal("Daily", "")
    setFrozenTime("2026-10-21T10:00:00Z")
    let older = createEntry(journal.id, "Older", "a")
    setFrozenTime("2026-10-21T11:00:00Z")
    let newer = createEntry(journal.id, "Newer", "b")
    let listed = listEntries(journal.id)
    check listed.len == 2
    check listed[0].id == newer.meta.id
    check listed[1].id == older.meta.id

  test "delete removes the markdown and leaves the other journal alone":
    let daily = createJournal("Daily", "")
    let ideas = createJournal("Ideas", "")
    let entry = createEntry(daily.id, "Gone", "text")
    let kept = createEntry(ideas.id, "Stay", "safe")
    deleteEntry(daily.id, entry.meta.id)
    check not fileExists(mdPath(daily.id, entry.meta.id))
    check listEntries(daily.id).len == 0
    expect NotFoundError:
      discard readEntry(daily.id, entry.meta.id)
    check readEntry(ideas.id, kept.meta.id).body == "safe"
    deleteJournal(daily.id)
    check not dirExists(dataDirectory() / "journals" / daily.id)
    check listJournals().len == 1
    check listJournals()[0].id == ideas.id

  test "a missing markdown file is reported":
    let journal = createJournal("Daily", "")
    let entry = createEntry(journal.id, "T", "body")
    removeFile(mdPath(journal.id, entry.meta.id))
    expect JournalError:
      discard readEntry(journal.id, entry.meta.id)

  test "duplicate ids in the catalog are rejected":
    let id = "0123456789abcdef"
    let item = %*{
      "id": id,
      "name": "A",
      "description": "",
      "created": "2026-10-21T00:00:00Z",
      "updated": "2026-10-21T00:00:00Z"
    }
    writeFile(dataDirectory() / "journals.json", $(%*{"journals": [item, item]}))
    expect JournalError:
      discard listJournals()

  test "search reads titles and bodies and ignores a blank query":
    let daily = createJournal("Daily", "")
    let ideas = createJournal("Ideas", "")
    discard createEntry(daily.id, "Markets", "nothing special")
    discard createEntry(ideas.id, "Later", "The café on the corner")
    check searchEntries("   ").len == 0
    let byTitle = searchEntries("market")
    check byTitle.len == 1
    check byTitle[0].journalName == "Daily"
    check byTitle[0].entry.displayTitle == "Markets"
    let byBody = searchEntries("CORNER")
    check byBody.len == 1
    check byBody[0].journalId == ideas.id
    check "corner" in byBody[0].snippet
    let byAccent = searchEntries("café")
    check byAccent.len == 1
    check byAccent[0].journalId == ideas.id
    let entry = createEntry(daily.id, "Wide", "héllo " & "z".repeat(80) & " world")
    let found = searchEntries("world")
    var hit = found[0]
    for item in found:
      if item.entry.id == entry.meta.id:
        hit = item
    check "world" in hit.snippet
    check hit.snippet.startsWith("…")

  test "search stops at fifty matches":
    let journal = createJournal("Daily", "")
    for i in 1 .. 55:
      discard createEntry(journal.id, "n" & $i, "mark")
    check searchEntries("mark").len == 50

  test "word count skips markdown marks":
    let journal = createJournal("Daily", "")
    let entry = createEntry(journal.id, "T", "Hello **world**\n\n- one\n- two\n")
    check entry.meta.wordCount == 4
    let plain = createEntry(journal.id, "P", "well-known, yes")
    check plain.meta.wordCount == 2

  test "an entry that is too large is rejected":
    let journal = createJournal("Daily", "")
    expect InvalidNameError:
      discard createEntry(journal.id, "Big", "a".repeat(1_000_001))
    expect InvalidNameError:
      discard createEntry(journal.id, "t".repeat(201), "ok")
