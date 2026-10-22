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
##   nim r src/journal.nim -- --lan
##
## A debug build reads `web/` from disk, so a refresh picks up page edits.
## `nim c -d:release src/journal.nim` embeds those files into the binary.
## `--lan` does not open a window. It serves on this computer's network
## address so another machine can open the printed URL.

import std/os
import neel
import ./journal/lan
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
  var launch: Launch
  try:
    launch = parseLaunch(commandLineParams())
  except ValueError as e:
    stderr.writeLine(e.msg)
    quit(1)
  if launch.help:
    stdout.writeLine(usageText())
    quit(0)

  initStore()
  if not launch.lan:
    startApp(webDir = "../web", size = some((1280, 820)))
  else:
    var ip: string
    try:
      ip = thisLanAddress()
    except LanError as e:
      stderr.writeLine(e.msg)
      quit(1)
    let origin = lanOrigin(ip, launch.port)
    var proxy: Proxy
    try:
      proxy = openProxy(ip, launch.port, "127.0.0.1", launch.port)
    except LanError as e:
      stderr.writeLine(e.msg)
      quit(1)
    try:
      stdout.writeLine("Journal on this network: " & origin)
      stdout.writeLine("On this computer: http://127.0.0.1:" & $launch.port)
      stdout.writeLine("Windows may ask for permission to allow Journal on the network.")
      stdout.flushFile()
      startApp(webDir = "../web", serve = true, port = launch.port,
               allowedOrigins = @[origin])
    finally:
      proxy.stop()
