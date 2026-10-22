## journal.nim - a personal journal.
##
## The page is HTML, CSS, and JavaScript. This module is the backend:
## each `{.expose.}` proc is what the page calls as `neel.<name>(...)`.
## Entries are markdown files under `~/.journal`; names, timestamps, and
## the other metadata are JSON. See `journal/store.nim`.
##
## Run it from anywhere:
##
##   nim r src/journal.nim
##
## A debug build reads `web/` from disk, so a refresh picks up page edits.
## `nim c -d:release src/journal.nim` embeds those files into the binary.

import neel
import ./journal/store

type
  AppInfo* = object
    dataDir*: string
    version*: string

const AppVersion = "0.1.0"

proc appInfo(): AppInfo {.expose.} =
  AppInfo(dataDir: dataDirectory(), version: AppVersion)

proc listJournals(): seq[JournalMeta] {.expose.} =
  store.listJournals()

proc createJournal(name: string; description: string = ""): JournalMeta {.expose.} =
  store.createJournal(name, description)

proc updateJournal(id, name, description: string): JournalMeta {.expose.} =
  store.updateJournal(id, name, description)

proc deleteJournal(id: string) {.expose.} =
  store.deleteJournal(id)

proc listEntries(journalId: string): seq[EntryMeta] {.expose.} =
  store.listEntries(journalId)

proc readEntry(journalId, entryId: string): Entry {.expose.} =
  store.readEntry(journalId, entryId)

proc createEntry(journalId, title, body: string): Entry {.expose.} =
  store.createEntry(journalId, title, body)

proc updateEntry(journalId, entryId, title, body: string): Entry {.expose.} =
  store.updateEntry(journalId, entryId, title, body)

proc deleteEntry(journalId, entryId: string) {.expose.} =
  store.deleteEntry(journalId, entryId)

proc searchEntries(query: string): seq[SearchHit] {.expose.} =
  store.searchEntries(query)

when isMainModule:
  initStore()
  startApp(webDir = "../web", size = some((1280, 820)))
