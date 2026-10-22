# Journal

A personal journal. The window is HTML, CSS, and JavaScript. Nim stores the writing, and [Neel](https://github.com/Niminem/Neel) connects the two. The only dependency besides the Nim standard library is Neel.

You can keep more than one journal. Each entry has a title and a markdown body. The page saves on its own shortly after you stop typing. Switch between Write and Preview, and search across every journal. Ctrl+N starts an entry. Ctrl+S saves immediately.

## Run

```
nim r src/journal.nim
```

A debug build reads `web/` from disk, so refresh the window after editing the page. `nim c -d:release src/journal.nim` embeds those files into the binary.

To open the journal from another computer on the same network:

```
nim r src/journal.nim -- --lan
```

NOTE: the initial `--` you see above simply tells nim to stop reading compiler flags, and everything after that is passed to the resulting binary CLI args.

That serves on this machine's network address at port 8770 and prints the URL. `--lan:9000` uses a different port. No window opens. Open the URL in a browser on this network, including a phone. Windows may ask before it allows the connection. One browser can use it at a time, and there is no login.

## Files

Everything is stored in `~/.journal`:

```
~/.journal/journals.json
~/.journal/journals/<id>/entries.json
~/.journal/journals/<id>/<entryId>.md
```

`journals.json` is the list of journals. `entries.json` holds titles, timestamps, word counts, and a short preview. The markdown file is the entry.

## Tests

```
nimble test
```

Tests write to `tests/scratch` and leave `~/.journal` alone.
