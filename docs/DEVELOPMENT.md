# For developers

How to build, test, sign and release Yaseen Emoji.

## Build

You need Xcode. The package has no outside dependency.

- `swift build`: build the app for development.
- `swift test`: run the unit tests. They open no window and need no permission.
- `scripts/bundle.sh`: make `build/Yaseen Emoji.app` from a release build and sign it.
- `scripts/bundle.sh --dmg`: also make `build/Yaseen-Emoji-<version>-arm64.dmg`.
- `scripts/install.sh`: quit the app that runs, put the new app in `/Applications`, and open it. Run `scripts/bundle.sh` first. The script changes `/Applications`, so the owner of the Mac runs it.
- `scripts/make-signing-cert.sh`: make the certificate "Yaseen Local Signing" in your login keychain. Read [The signature](#the-signature) first.
- `swift scripts/make-icon.swift`: draw the app icon again into `Support/AppIcon.icns`. Run it only after a change to the drawing. It also writes three preview pictures into `build/`.

The version is in one place: `CFBundleShortVersionString` in `Support/Info.plist`.

`build/` and `.build/` are in `.gitignore`. `scripts/bundle.sh` removes only its own earlier output from `build/`.

### Resources

SwiftPM puts the resources of `EmojiKit` into `YaseenEmoji_EmojiKit.bundle`, next to the binary. Today the one resource is `emoji.json`. `scripts/bundle.sh` copies each `*.bundle` of the build into `Contents/Resources` of the app. A file at the top of the `.app` breaks the signature. `EmojiCatalog.bundledURL()` looks in `Contents/Resources` first. It uses `Bundle.module` only outside an `.app`, because an older SwiftPM looks for the bundle in a different place.

### The emoji data

`Sources/EmojiKit/Resources/emoji.json` is in the repository, so a build never goes online. To make it again, for example for a new Emoji version:

```bash
swift scripts/make-emoji-data.swift
```

The script downloads five sources at fixed versions and checks the SHA-256 of each file. A changed source stops the script. A new version of a source needs a new URL and a new SHA-256 in the script. Then update `THIRD-PARTY-NOTICES.md`.

## Install and the EmojiFinder history

`scripts/install.sh` does these steps:

1. It quits Yaseen Emoji if it runs.
2. It puts `build/Yaseen Emoji.app` in `/Applications`.
3. The first time, it imports your history from EmojiFinder (D6). See below.
4. It opens the app.
5. If EmojiFinder runs, it prints a warning. EmojiFinder also uses ⌘E. Quit it and remove it from your login items.

The import runs only if both of these are true:

- `~/Library/Containers/com.marioiannotta.searchmoji/Data/Documents/Database.sqlite` exists.
- `~/Library/Application Support/Yaseen Emoji` has no history: no `you.json` and no `you-*.json`.

The script copies the EmojiFinder database into a temporary folder and reads the copy with `sqlite3 -json`. Thus the EmojiFinder database never changes. It sends the rows to `YaseenEmoji --import-uses <default folder>`. The app writes this Mac's file, `you-<Mac name>.json`, and exits. If the import fails, the script prints a warning and continues. The next run tries the import again.

`--import-uses` reads rows like `[{"emoji": "🤣", "count": 358}]` on standard input. It adds the counts to `uses` and writes the time of the import in `imported`. With a folder, it does nothing when the folder has any history. A path that ends in `.json` is one file: a second import into the same file changes nothing. Exit codes: 0 done or nothing changed, 1 bad input, 2 no path.

## The preferences folder (D16)

The history and the synced settings are in the preferences folder. The default is `~/Library/Application Support/Yaseen Emoji`. The path is in the pref `yaseenEmoji.preferencesFolder` ("" is the default). Settings → "Set preferences folder…" and "Reset to Mac Default Folder" change it.

- **One file for each Mac:** `you-<Mac name>.json`. The app makes the Mac name one time from the computer name (A-Z, a-z, 0-9 and `-`) and keeps it in `yaseenEmoji.macName`. Each Mac writes only its own file, so git never gets a conflict.
- **The merge:** each Mac reads each `you-<name>.json` of the folder. `uses` and `learned` add up, `added` is the union, and `hidden` and each setting use the newest change. The 5,000 learned pairs are a limit of each file. `you.json` and `*.bad.json` never count.
- **Synced settings:** `settings.hotKey`, `settings.afterEnter`, `settings.pickModes`, `settings.keepOnClipboard`, `settings.defaultTone`, `settings.klipyGIFs` and `settings.klipyMemes`, each with the time of the change. `afterEnter` is `stayOpen` or `close` (D20 of YAZ-2919). A file with no `afterEnter` gives the start value, Stay open. `pickModes` and `keepOnClipboard` are maps keyed by the kind (`emoji`, `gif`, `meme`): the newest change of each kind wins. The v0.1 `settings.pickMode` stays readable but is not written: a kind with no value of its own uses it, so an old file with Copy only gives Copy only for all three kinds. A Mac writes a setting only when you change it in Settings. `UserDefaults` keeps the value and the time that this Mac applied. A newer hotkey from a different Mac works at once. If macOS refuses it, the old key stays and Settings shows the red line.
- **Forget learned words:** writes `forgotAt`. Each Mac that sees a newer `forgotAt` clears its own learned and added words, and writes the time in `forgetApplied`.
- **Reload:** each time the panel or Settings opens, the app lists the folder and reads only the files with a new modification date.
- **The first start of D16:** if this Mac's file is missing, the app copies this Mac's file of the default folder, or else `you.json`. The source stays as a backup.
- **A missing folder:** the app uses the default folder, and Settings shows "Can't find the preferences folder. This Mac uses its own history."
- **The files:** sorted keys, one value on each line, atomic writes.

### The files, the folders and the caches (v0.2)

| Path | What | Syncs | Limit and clean-up |
| - | - | - | - |
| `<preferences folder>/you-<Mac name>.json` | The history and the synced settings of this Mac | Yes | 5,000 learned pairs |
| `<preferences folder>/library-<Mac name>.json` | The list of GIFs and memes of this Mac, and the KLIPY cards (D3, D18 of YAZ-2919) | Yes | 2,000 cards: the least recently used card goes |
| `<GIFs and memes folder>/gifs/…/<name>.gif` | Your GIF files, in subfolders at any depth (D22 of YAZ-3018) | Yes | None. You delete a file in Finder |
| `<GIFs and memes folder>/memes/…/<name>.<png, jpg or gif>` | Your meme files, the same | Yes | The same |
| `~/Library/Caches/Yaseen Emoji/files.json` | The hash cache: the size, the date and the `id` of each file (D27 of YAZ-3018) | No | Only the files of the last scan |
| `~/Library/Caches/Yaseen Emoji/thumbs/<id>.png` | The 290 × 290 still picture of your tile (D5) | No | The app makes a missing one again. At each open, it deletes the still picture of each item that does not show |
| `~/Library/Caches/Yaseen Emoji/paste/<uuid>/<slug>.<ext>` | The downloaded file of a KLIPY item (D6) | No | 5 minutes, and all at quit. A pick moves it into `klipy/` |
| `~/Library/Application Support/Yaseen Emoji/klipy/<slug>.<ext>` | The files of the KLIPY items that you used (D18) | No, never | 50 files and 200 MB: the oldest last use goes. A `.part` file of a stopped move goes at the next open |
| `$TMPDIR/YaseenEmoji-drop-<uuid>/` | The files of a drop from a browser or Telegram (file promises) | No | All at quit |
| Keychain: service `com.yaseenarshad.yaseenemoji`, account `klipy` | The KLIPY key (D2) | No | "Remove…" in Settings |

The "GIFs and memes folder" is the pref `yaseenEmoji.mediaFolder`. "" means the preferences folder itself. For Yaseen, that is `yaseen-os/Sync/yaseen-emoji`, so `gifs/` and `memes/` are in git. The KLIPY files of D18 are never in the preferences folder, so they are never in git (D18 update on YAZ-2919). Only their cards (small text) sync.

The prefs of v0.2 in `UserDefaults` (all on this Mac only): `yaseenEmoji.mediaFolder`, `yaseenEmoji.settingsPage`, `yaseenEmoji.afterEnter`, `yaseenEmoji.pickMode.<kind>`, `yaseenEmoji.keepOnClipboard.<kind>`, `yaseenEmoji.klipyGIFs`, `yaseenEmoji.klipyMemes`, and a `…ChangedAt` key for each synced value. `<kind>` is `emoji`, `gif` or `meme`.

### GIFs and memes (D3 and D4 of YAZ-2919)

- **The list:** `library-<Mac name>.json` in the preferences folder, one file for each Mac, with the same Mac name as `you-<Mac name>.json`. Each Mac writes only its own file. The app reads the files of all Macs and combines them. `PreferencesFolder.isLibraryFile` takes only `library-<A-Z a-z 0-9 ->.json`, so `library-A.bad.json` and `library-A 2.json` never count. A bad file of this Mac moves to `library-<Mac name>.bad.json`. A bad file of a different Mac keeps its last good data.
- **The format** (sorted keys, ISO 8601 dates with milliseconds, atomic writes through `MacFiles.save`). A field with no value is not in the file:

  ```json
  {
    "cards" : {
      "klipy:hello-hi-662" : {
        "bytes" : 836000, "file" : "https://static.klipy.com/…/md.gif", "fileExtension" : "gif",
        "fileType" : "com.compuserve.gif", "height" : 280, "kind" : "gif", "lastUsed" : "2026-10-16T23:51:42.187Z",
        "preview" : "https://static.klipy.com/…/sm.gif", "slug" : "hello-hi-662", "still" : "https://static.klipy.com/…/sm.jpg",
        "title" : "Hello", "width" : 498
      }
    },
    "items" : {
      "3fa9c1d2e8b04a77" : {
        "added" : "2026-10-16T23:51:42.187Z", "changed" : "2026-10-17T01:02:03.004Z", "file" : "gifs/3fa9c1d2e8b04a77.gif",
        "id" : "3fa9c1d2e8b04a77", "kind" : "gif", "title" : "midwit mba", "words" : ["dance", "party"]
      }
    }
  }
  ```

  - `id`: the first 16 hex characters of the SHA-256 of the file. Two Macs that add the same GIF get the same `id` and the same file name, so git has no conflict. A KLIPY item that an earlier build saved by its slug (D7) has the `id` `klipy-<slug>`, a `klipyID` and no `file`.
  - `klipyID` of your own file: the slug of the KLIPY item that "Save to your GIFs" copied (D18). Its card then does not show as a second tile.
  - `removed`: the time of "Remove from your GIFs" of a saved KLIPY item (or of "Move to Trash" of an earlier build).
  - `file`: the path at the add, for old builds. This build finds the file by the scan (D22 of YAZ-3018), and a scan never writes it.
  - `title` (D15): "" by default. A file of an earlier build with no `title` loads with "". Since D23 of YAZ-3018, the title of your own file is its file name. The field stays for old builds.
- **The combine rule:** for each `id`, the item with the newest `changed` wins. The same time: the delete wins. Then more words, then the larger text of the words, then the larger title, so each Mac selects the same item. A remove keeps the item with `removed`, so a later add on any Mac can win. For each card key, the card with the newest `lastUsed` wins.
- **The keys in `you-<Mac name>.json`:** `gif:<id>` and `meme:<id>` for your own files, `klipy:<slug>` for a KLIPY item (`Item.key`, `KlipyCard.key`). The uses, the learned words, "Your most used", "Hide from Your most used" and "Forget learned words" work the same as for emojis. `You.key()` does not change these keys. The words of an item live in the item, not in `added`, so "Forget learned words" keeps them.
- **The files are the collection (D22, D23, D27 of YAZ-3018):** each GIF, PNG or JPEG file in `gifs/` or `memes/`, at any depth, is an item. The top folder gives the tab. You make folders, move and rename files in Finder. At each open, `LibraryStore.reload()` reads the full tree (`MediaScan.list`). It skips hidden files, hidden folders, packages and symbolic links. A file with the same path, size and date as in the hash cache uses the saved `id`. A new or changed file gets its hash off the main thread, and the panel shows it when the hash is ready (`onHashed`). The scan of 500 files with a warm cache takes about 8 ms. The same picture in two places is one item: the first path in sorted order. The title is the file name (`MediaName.title`), and the names of the folders between `gifs/` or `memes/` and the file are search words (`MediaName.folderWords`). A file with no record shows with no words. "Add a word…" makes its record.
- **Delete a GIF or meme:** right-click → "Show in Finder", then delete the file in Finder. The app has no "Move to Trash", and it never deletes a file of `gifs/` or `memes/`. A record whose file is not on disk (`LibraryStore.missing`) does not show, but it stays in the list. When the file comes back (a `git pull`), the item shows again at the next open.
- **A missing GIFs and memes folder** (an unmounted drive): your items do not show, the GIFs and Memes tabs show "Can't find the GIFs and memes folder.", and KLIPY still works. An add does not make a new folder in its place.
- **The still pictures:** `Thumbnails` makes a missing still picture when its tile shows, and decodes it off the main thread, at most 4 at a time. One `NSCache` of 120 keeps the stills of your tiles and of the KLIPY tiles (D11: about 41 MB). At each open, `Thumbnails.removeStills(keeping:)` deletes the still picture of each item that does not show (removed, or its file is gone). It skips this while the GIFs and memes folder is missing.
- **Settings → "GIFs and memes":** "Set GIFs and memes folder…" and "Reset to Same Folder…" (type "reset") call `LibraryStore.useMediaFolder(_:)`: copy the full tree with the subfolders, check the size and the SHA-256 of each file, then remove the old copies. A failure keeps the old files and the old folder. "Set preferences folder…" and "Reset to Mac Default Folder…" also move `library-<Mac name>.json` (`LibraryStore.move(to:)`), and `gifs/` and `memes/` when the GIFs and memes folder is the preferences folder. If that file move fails, the files stay, and the GIFs and memes folder becomes the old folder. The copy and the check run off the main thread (`FileWork`; `BackgroundFileWork` in the app). The two list files and `LibraryStore.mediaFolderMoved(to:)` stay on the main actor. During the move, the row shows "Moving your files…" and the buttons of both folder rows are off. During a move with the preferences folder, `yaseenEmoji.mediaFolder` points at the old folder, where all the files still are. Only a move with no error sets it back to "".

### KLIPY (D1, D2, D7, D18 of YAZ-2919)

**The rules of KLIPY for the code** (docs.klipy.com, read on 16 Oct 2026). Keep them in each change:

- The placeholder of the GIFs and Memes tabs is exactly "Search KLIPY" when the tab searches KLIPY. With the switch of the tab off, or with no key: "Search your GIFs" or "Search your memes" (`PickSession.placeholder`).
- "From KLIPY" keeps KLIPY's order and composition. Do not sort, filter, insert into or mix this section. Your own items go in their own section, "Yours", above it. `PickSession.buildTiles` adds `OnlineSection.items` as they come.
- Each KLIPY tile has the "KLIPY" mark (`EmojiGridView.drawMark`).
- Use the media URLs exactly as KLIPY gives them (`OnlineItem`, `KlipyCard`). Do not change their parameters.
- The requests come from the app on the Mac. No proxy. The app sends no user ID and asks for no ads.
- Copies of KLIPY files: KLIPY's terms ask apps not to keep copies. The app keeps the paste file of D6 for 5 minutes, and the 50 files of D18. **D18 is a risk that Yaseen accepts**: the worst case is that KLIPY turns off the key. Do not add a different copy or cache of KLIPY files without a new decision.

**The parts:**

- **The key:** Settings → "KLIPY key". With no key: the box, "Save" and "Get a free key" (`https://partner.klipy.com/`). "Save" or Enter in the box saves it into this Mac's Keychain (`KeychainKeyStore`). An empty box saves nothing ("Paste a key first."). A saved key is locked: the row shows "Saved", "Change…" and "Remove…". "Change…" opens an empty box with "Save" and "Cancel". "Remove…" asks you to type "remove". A click outside the box or a close of the window changes nothing. The app reads the key at the start and after a change in Settings, not at each open. A wrong key gives HTTP 404 with a message that names the API key: the app shows "KLIPY refused the key. Check it in Settings."
- **The switches:** Settings → "Search KLIPY in GIFs" (on at the start) and "Search KLIPY in Memes" (off at the start). They sync (D16). A tab with its switch off sends no request and shows no "From KLIPY", no grey KLIPY line and no KLIPY item. `PickSession` and `TileEntries` ask KLIPY only through `TileEntries.klipy(kind)`, which is nil when the switch is off.
- **The search:** 350 ms after the last key (`SearchDebouncer`), 24 a page, the next page near the end of the grid, at most 96, in "From KLIPY" below "Yours". The last 8 searches stay in memory. A failed search gives one grey line (D2), and the next open tries again.
- **Saved and learned items of an earlier build:** "Yours" shows them. The app gets the unknown slugs of one grid in one `items` call for each kind, and keeps at most 500 KLIPY items in memory. An item that KLIPY deleted drops with no line. The first lookup that succeeds makes its card.
- **The items that you use (D18 of YAZ-2919):** each pick of a KLIPY GIF or meme (Enter, a click, Shift+Enter, Copy only) keeps a card and a file.
  - **The card** goes into `cards` of `library-<Mac name>.json` after the paste starts. A pick saves the full list file: about 34 ms with 2,000 items and 2,000 cards (release build), on the main thread.
  - **The file** goes into `klipy/` on this Mac (`KlipyFiles`). The pick moves the paste file there before the paste, so the clipboard gets the kept file and nothing downloads two times. The move goes to a hidden `.part` name in the folder, then one rename. The modification date of a file is its last use on this Mac.
  - **The tiles:** a card gives its tile with no lookup (`OnlineResults.item(for:)`). The still and the moving picture come from the kept file when this Mac has it, else from the card URLs. A still that fails asks KLIPY for the slug one time. If KLIPY deleted the item and this Mac has no file, the tile does not show, and the card stays. A kept file pastes at once.
  - **Where cards show:** "Your most used", and "Yours" for their learned words and their title. Not in "Your GIFs" / "Your memes" with no search, and not in "All your GIFs" / "All your memes".
- **"Save to your GIFs" / "Save to your memes" (D18):** copies the kept file, else the paste file (a download, with "Getting the GIF…" for up to 3 s), into `gifs/` or `memes/` with the steps of the add window, with KLIPY's title, the search text as the word, and the slug in `klipyID`. The item is your own file (its key is `gif:<id>`), and it syncs like a meme. A KLIPY item that an earlier build saved by its slug (D7) keeps "Remove from your GIFs".
- **The paste:** a kept file pastes at once. Else the paste file downloads when the blue box stays 300 ms on a KLIPY tile. Enter waits up to 3 s with "Getting the GIF…". The app deletes the paste files older than 5 minutes at each open of the panel and each minute, and all of them at quit.
- **The pictures** of KLIPY tiles: the stills share the cache of `Thumbnails` (120). The moving `sm.gif` previews of the tiles on the screen load at most 4 at a time, in the order of the grid, and the last 30 stay in memory.

### The add window (D12 of YAZ-2919)

"Add a GIF or meme…" in the menu bar or in the right-click menu of the GIFs and Memes tabs opens the add window. A drop of files on the search panel also opens it, with the files. It is a non-activating panel, like Settings, and it stays open until you close it.

- **Ways to add:** drop files on the window, "Choose files…" (more than one file), "Paste", or ⌘V.
- **The paste** reads the best form on the clipboard, in this order: a file URL, GIF bytes, video bytes (MP4, MOV), then still image bytes (PNG, JPEG, HEIC, HEIF, TIFF). The first form that any clipboard item has wins, and each item with that form gives one row. A still picture shows the grey line "This came in as a still picture. To keep it moving, save the file and drag it in."
- **A drop** takes files, then file promises (a drag from a browser or from Telegram, received into a temp folder), then the same bytes as a paste.
- **Each row:** "Getting it ready…" while `MediaImport.prepare` runs off the main thread. Then the preview, the Title box, GIF / Meme, the words box, "Add" and "Remove". A meme gets its read words (D8). "Add" needs one word ("Type one word first."). A duplicate says "You have this one already." and adds only its new words.
- **The Title box (D15 of YAZ-2919)** starts with the file name with no extension, with `-` and `_` as spaces and no copy mark (` (1)`): `midwit-mba.png` gives `midwit mba`. These give an empty box: a paste or a drop of bytes, a name of only digits, a UUID or a code name (16 or more hex characters), and a camera or system name with digits after it (`IMG_2231`, `Screenshot 2026-…`, `WhatsApp Image …`, `giphy`). `AddSource.title(fromName:)` holds the rule. A duplicate shows the title of its item. It adds only its words: a typed title changes nothing (D25 of YAZ-3018).
- **The add:** the file goes into `gifs/` or `memes/` off the main thread (`LibraryStore.writeMediaFile`), as `<title>.<ext>` (D25 of YAZ-3018). An empty title gives the code name `<id>.<ext>`. A different file with the same name gets " 2". A file that is already in the GIFs and memes folder is not copied (`LibraryStore.fileToAdd`). Then `LibraryStore.add` saves the list on the main thread, because the panel reads the list there.
- **A close** with rows that wait asks "Close and drop N files?" in the window. A refused row does not count.
- **The temp files** of a drop of file promises go into `$TMPDIR/YaseenEmoji-drop-<uuid>/`. The app deletes them at quit (`FileDrop.cleanUp`). A row keeps the bytes of its file after "Getting it ready…".

### The panel: titles and the meme preview (D15 of YAZ-2919)

- **The text below a tile:** one line of 16 points below the picture of each GIF and meme tile, cut with "…". It is the title, else the first 3 words of the item. A KLIPY tile shows KLIPY's `title`. `PickSession.label(of:)` holds the rule. `GridMetrics.rowHeight` adds the 16 points in the GIFs and Memes tabs. The Emoji tab does not change.
- **"Rename…"** is on the right-click menu of your own GIFs and memes, not on KLIPY items. It works like "Add a word…": the grid shows `Type a title for "<short name>". Enter saves. Esc stops.`, and the search box starts with the title. Enter renames the file in its folder (D24 of YAZ-3018, `LibraryStore.rename(_:to:)`). The name rule (`MediaName.fileName`): trimmed, one space between words, `/` and `:` as `-`, no dot at the start, 120 characters at most. A different file with that name gives " 2". An empty text, the same name and Esc change nothing. A failure keeps the old name and shows "Can't rename the file." with the reason. The list file does not change.
- **The search:** the title counts like the name of an emoji. `TileEntry.name` is the title, so a full title that is the search text gives `isName`. The words of the title match like the words of the item. A saved KLIPY item uses KLIPY's title.
- **The big preview:** on the Memes tab, the meme with the blue box shows in a second panel beside the search panel, 360 points wide and the height of the search panel. The picture is aspect-fit, with the tile text below. `MemePreview.item(isOpen:isSteppingAside:tab:selected:)` is the rule: it hides on the other tabs, with no blue box, and when the panel hides (also for a ⌘V). `MemePreview.frame(panel:visibleFrame:)` puts it on the right, or on the left when the screen has no room on the right.
- **The preview window** (`MemePreviewController`) is a borderless, non-activating child window of the search panel. It ignores the mouse and cannot become key, so the search panel keeps the keyboard and does not close. It moves with a drag of the panel. Your meme loads from its file off the main thread (at most 1,200 pixels, the last 8 in memory). A KLIPY meme shows its paste file after 350 ms on it.

### Add many GIFs and memes from the Terminal (`--add-media`)

The bulk add: for many files at once, or from a script. Yaseen added 15 memes with it on 16 Oct 2026. Quit the app, then run the binary inside the app:

```bash
"/Applications/Yaseen Emoji.app/Contents/MacOS/YaseenEmoji" --add-media ~/Downloads/dance.gif ~/Downloads/fine.png --words "dance, party"
```

- Each file goes through the steps and the rules of the add window: the type check, MP4 and MOV to GIF, the 10 MB limit (`MediaImport.prepare`), then `LibraryStore.add`. It is not a second add path.
- The words: the `--words` text, split at spaces and commas (`Item.words(typed:)`, the rule of the words box). With none, a meme gets the words that Vision reads in it. With still none, the words come from the file name.
- The name (D15 of YAZ-2919, D25 of YAZ-3018): a new file gets the title of its file name as its name (`AddSource.title(fromName:)`, the rule of the Title box). An item that is there already keeps its file and gets only the new words.
- **Keywords for the files that Yaseen put in Finder:** run `--add-media "<path in memes/>" --words "word word"`. A file that is already in `gifs/` or `memes/` is not copied: only its words go into the list. Never edit `library-<Mac>.json` while the app runs.
- It prints one line for each file: `Added GIF <id> from <file>, title: …, words: …`, `Already there: …`, or the error.
- The command refuses to run while the app runs ("Quit Yaseen Emoji first."): the app keeps its list in memory and would write over the new items. It uses the prefs of the app, so run the binary inside the app, not `.build/debug/YaseenEmoji`.
- Exit codes: 0 done, 1 a file failed, 2 no file, 3 the app runs.

### Give the code-named files their real names (`--name-files`)

A one-time command of D26 on YAZ-3018. Run it on one Mac. Git syncs the renames to the other Mac. Quit the app, copy `gifs/` and `memes/` to a backup folder, then run:

```bash
"/Applications/Yaseen Emoji.app/Contents/MacOS/YaseenEmoji" --name-files
```

- Each file with a code name (16 or more hex characters) at the top of `gifs/` or `memes/` gets the title of its record, else its first 4 words, with the name rule of "Rename…" (`LibraryStore.nameCodeFiles`). With neither, it keeps its code name.
- It prints one line for each code-named file: `memes/<code>.png → memes/<name>.png`, or the reason for no change. A second run changes nothing.
- An old build hides the renamed items until it gets the new build. Install the new build on both Macs.
- Exit codes: 0 done, 1 a rename failed or the GIFs and memes folder is missing, 3 the app runs.

### Settings: the pages, and how to add a row (D19 of YAZ-2919)

The settings window has a list of pages on the left and the page on the right, in a fixed window of 680 × 480 points. A long page scrolls inside the window. The pages, in this order:

1. **General:** "Find an emoji" hotkey, "Default skin tone", "Start at login", Accessibility.
2. **Enter and paste:** "When you press Enter": Emojis, GIFs and Memes, each with Paste | Copy only and "Keep it on the clipboard after a paste" (D16), and the grey line of what Enter does now.
3. **GIFs and memes:** the KLIPY key (the locked row), "Search KLIPY in GIFs", "Search KLIPY in Memes", then the GIFs and memes folder with "Show in Finder".
4. **Your history:** "Hidden from Your most used" and "Forget learned words…".
5. **Sync folder:** the preferences folder with "Show in Finder", "Reset to Mac Default Folder…" and "Set preferences folder…".

The window opens on the page that you used last on this Mac (`yaseenEmoji.settingsPage`, not synced). A page change stops the hotkey recorder, the type-to-confirm box and "Change…" of the KLIPY key. Each change saves at once.

To add a row:

1. Add a case to `SettingsRow` (`SettingsPage.swift`).
2. Put the case in the `sections` of one page in `SettingsPage.sections`. The view draws each page only from this map.
3. Add the `case` to `SettingsView.row(_:)` (`SettingsWindow.swift`) with its view. The `switch` has no `default`, so the build fails until the row has a view.
4. Put the rules and the texts in `SettingsModel`, not in the view, so a test checks them. A setting that syncs is a `Dated` value in `You.Settings`, with `You.merge` and `SettingsModel.applySynced()` (D16). A setting of this Mac only is a key in `Prefs`.
5. The test `eachPageListsItsRows` checks that each row is on exactly one page. Add the row to its expected list.

To point the app at a folder without Settings, quit the app, then run `defaults write com.yaseenarshad.yaseenemoji yaseenEmoji.preferencesFolder -string "<folder>"`, then open the app.

## The code

- `Sources/EmojiKit`: all the code of the app, as a library. Thus the tests can import it.
- `Sources/YaseenEmoji/main.swift`: the executable. It runs `--import-uses`, `--add-media` or `--name-files`, or it calls `AppController.main()`.
- `Tests/EmojiKitTests`: the unit tests.
- The package uses the Swift 5 language mode. The compiler of CI can be older than the compiler on your Mac.

The parts of `EmojiKit`:

- `AppController`: the app shell. It loads the catalog off the main thread, and connects the hotkey, the menu, Settings and the panel. `AppParts` holds the parts that touch the system, so a test gives fakes.
- `StatusMenu`: the menu bar icon (the SF Symbol `face.smiling`, as a template image) and its five rows.
- `EmojiData.swift`: `Emoji` and `EmojiCatalog`, the loader of `emoji.json`.
- `DrawCheck`: hides each emoji that the Apple Color Emoji font of this Mac cannot draw as one picture.
- `Search`: the search and its order. The order is in one function, `Search.rank` (D5). A change of the order touches only that function and the table in `SearchTests`.
- `YouStore.swift`: `You` (the contents of one history file), `You.merge` (the history of all Macs), and `YouStore` (this Mac's file, the files of the other Macs, reload, atomic save, the 5,000 learned pairs, the hidden emojis of "Your most used", the synced settings, the bad file). `You.key` is the one key of an emoji: no U+FE0F and no skin tone mark.
- `PreferencesFolder`: the preferences folder (D16): the Mac name, the file names, the missing folder, and the first copy of this Mac's file.
- `MacFiles.swift`: the parts that `YouStore` and `LibraryStore` share: the load of this Mac's file with the move of a bad file, the atomic save, the JSON format, and `OtherMacFiles` (reads only the changed files of the other Macs).
- `Library.swift`: `Item` (one GIF or meme), `KlipyCard` (a KLIPY item that you used, D18), `LibraryFile` (one `library-<Mac name>.json`: items and cards), `LibraryStore` (this Mac's list, the lists of the other Macs, the scan of the files, the add of a file, "Rename…", the remove of a saved KLIPY item, the cards and their limit of 2,000, the missing files), and `MediaFolder` (the GIFs and memes folder and its move).
- `MediaScan.swift`: `MediaScan` (the listing of the full tree and the hashes), `FileCache` (the hash cache), and `MediaName` (the title of a file name, the folder words, and the name rule of a rename and an add) (D22 to D27 of YAZ-3018). The app never deletes a file of `gifs/` or `memes/`: you delete it in Finder.
- `MediaImport`: the add of a file (D5 and D8 of YAZ-2919): the kind from the bytes, MP4 and MOV to GIF, the 10 MB limit, the still picture of a tile, and the words of a meme with Vision. Each call runs off the main thread.
- `YouImport`: `--import-uses`, the import of the EmojiFinder history.
- `AddCommand`: `--add-media`, the add of GIFs and memes from the Terminal.
- `NameCommand`: `--name-files`, the one-time names of the code-named files (D26 of YAZ-3018).
- `AddWindow.swift`: the add window (D12 of YAZ-2919). `AddModel` holds the rows and their rules, with no view. `PasteReader` finds the best form on the clipboard through `PasteboardSource`, a protocol, so a test gives a fake clipboard. `FileDrop` reads a drop. `AddWindowController` is the non-activating panel with the SwiftUI view.
- `PickSession`: the rules of the panel with no window: the tab (Emoji, GIFs, Memes; each open starts on Emoji), the search text, the lines of the grid, the blue box, the keys, the picks, the default skin tone, "Add a word…" and "Rename…" (one `question` of the search box), the text below a tile (`label(of:)`), the items of the right-click menu (`menuActions(at:)`, `perform(_:)`) and "Hide from Your most used".
- `TileEntries.swift`: one grid item is a `PickItem`: an emoji, your own GIF or meme, or a KLIPY item. Its `key` is the key in `you-<Mac>.json`. `TileEntry` is the search entry of a GIF or meme, so the GIFs and Memes tabs use the same `Search` as the emojis (`Searchable`). `TileEntries` makes the entries of the tabs and holds the rules of which items show: your files, your saved KLIPY items, the cards, and the KLIPY items of an earlier build. It keeps the lists until the session calls `forget()`. `TileEntries.klipy(kind)` is the one way to KLIPY, nil when the switch of the tab is off.
- `OnlineResults.swift`: the place of KLIPY in the GIFs and Memes tabs. With no `OnlineResults`, the tabs show only your own files and no "From KLIPY" section.
- `KlipyResults.swift`: the real `OnlineResults`: the search after the pause, the pages, the lookup of saved and learned items by slug, the tiles of the cards (D18), the 300 ms prefetch, the 3 s wait of a paste file, the move of a picked file into the kept files, and the tile pictures. The network, the download, the kept files, the pause and the clock are parameters.
- `KlipyFiles.swift`: the files of the KLIPY items that you used (D18 of YAZ-2919), on this Mac only: the atomic move, the last use (the modification date), and the limits of 50 files and 200 MB.
- `Paster`: a pick. It writes the emoji or the file and posts ⌘V. Settings → "When you press Enter" (D16 of YAZ-2919) has, for each kind (`PickKind`: emojis, GIFs, memes), Paste | Copy only and "Keep it on the clipboard after a paste" (start values: Paste and Keep). With Keep, the item stays with no transient mark and no restore waits. With Keep off, it saves the clipboard first and puts the old clipboard back after 0.3 s (a file: 1.0 s), only if `changeCount` is still its own. Copy only, no Accessibility or a password field: copy only, and Keep has no effect. A file is one clipboard item (`ClipboardContents.fileItem`): the file URL, the file's own bytes in its own type, and the transient mark for a paste. No TIFF. `Clipboard`, `KeySender`, `PasteAccess` and `Later` are protocols, so a test posts no key and never waits.
- `PasteStrategy.swift`: a pick that stays open pastes with no flash (D21 of YAZ-2919). `PanelPaste` is the part of the search panel in the paste. The hidden pref `yaseenEmoji.pasteStrategy` (no Settings row, not synced) selects the way. The panel reads it at each pick:
  - `handBack` (the start value): the panel stays on the screen. It refuses the keyboard (`SearchPanel.refusesKey`) and activates the app that was in front when it opened, so that app's window takes the keyboard. Right before the ⌘V, `Paster` asks the panel where the ⌘V goes. If the panel still has the keyboard, it hides for this pick only, and the ⌘V waits `postDelay` one more time (the fallback). After `comeBackDelay` the panel takes the keyboard back with the search text selected. If it has no keyboard 0.15 s later, it hides and shows one time.
  - `hide`: the v0.2.0 way. The panel hides for the ⌘V and shows again.
  - `pid`: the panel keeps the keyboard. The ⌘V goes to the process of the app in front (`CGEvent.postToPid`).
  - The panel does not close on `windowDidResignKey` while it makes way (`PanelPaste.isMakingWay`). `PasteWindow` and `FrontApp` are protocols, so a test uses a fake window and a fake app. The fallback and the second try write a `notice` to the log, category `paste`.
  - Try a way: `defaults write com.yaseenarshad.yaseenemoji yaseenEmoji.pasteStrategy -string hide` (or `pid`, or `handBack`). `defaults delete com.yaseenarshad.yaseenemoji yaseenEmoji.pasteStrategy` gives the start value.
- `SearchPanel.swift`: the non-activating panel on the screen, and `PanelPlace` (where it opens). It turns keys into calls of `PickSession`: Tab and Shift+Tab go round the tabs, ⌘1 to ⌘3 go to a tab. `EditKeys` is the one map of the edit keys (⌘V, ⌘C, ⌘X, ⌘A, ⌘Z, ⇧⌘Z) for the search panel, the add window and the settings window, because the app has no main menu.
- `MemePreview.swift`: the big preview of the meme with the blue box (D15 of YAZ-2919). `MemePreview` is the pure rule (when, which item, which side). `MemePreviewController` is the thin window.
- `EmojiGrid.swift`: one view that draws only the lines on the screen (9 emojis or 3 tiles in a row with a line of text below each tile, `GridMetrics`), the right-click menu, and the drag of the panel (a move of more than 4 points, `EmojiGridView.isDrag(from:to:)`). Each GIF tile on the screen plays (D11 update on YAZ-2925): `GridMetrics.playing(in:items:)` gives the GIF tiles in the visible rect (at most 15), and the grid puts a `MovingTileView` of its pool (at most 15) over each one. The blue box of a tile is a border view above them. The panel hides: all stop. `GridMetrics.scrollRect(of:)` keeps the titles above the row of the blue box in sight.
- `MovingTiles.swift`: `MovingPictures` (the moving pictures of the tiles on the screen: at most 4 loads at a time in the order of the grid, a load for a tile that left the screen stops, at most 30 in memory; one for your own GIF files in the grid, one for the KLIPY previews in `KlipyResults`), `MovingTileView` (one moving view: round corners, aspect-fill, the "KLIPY" mark; it lets the mouse through).
- `Thumbnails`: the still pictures of the tiles. It loads at most 4 at a time, off the main thread, into an `NSCache` of at most 120 that `KlipyResults` uses too. At each open, it deletes the still picture of each item that does not show.
- `Prefs`: the settings in `UserDefaults`, with the prefix `yaseenEmoji.`.
- `SettingsModel` and `SettingsWindow.swift`: the rules of Settings with no window, and the SwiftUI view in a non-activating panel of 680 × 480 points: a list of pages on the left, and the page in a grouped form that scrolls (D19 of YAZ-2919).
- `SettingsPage.swift`: the pages, their sections and their rows (`SettingsRow`). The view draws each page only from `SettingsPage.sections`, and its `switch` over `SettingsRow` has no `default`. A test checks that each row is on exactly one page. A new row: add a case, put it on a page, and give it a view. The pref `yaseenEmoji.settingsPage` keeps the last page on this Mac (not synced). A page change stops the hotkey recorder, the type-to-confirm box and "Change…" of the KLIPY key.
- "Show in Finder" of the two folder rows: `SettingsModel.showPreferencesFolder()` and `showMediaFolder()` open the folder that the app uses now through `openInFinder` (a fake in a test). A missing folder is made first. A chosen folder that the app can't find is not made, and the button is off (the same rule as D4).
- `HotKey.swift`: the global hotkey (Carbon `RegisterEventHotKey`, no permission). `HotKeyRegistering` is a protocol, so a test uses a fake.
- `LoginItem.swift`: "Start at login" (`SMAppService`). `LoginItem` is a protocol, so a test uses a fake.
- `OnlineLibrary.swift`: KLIPY (D1 of YAZ-2919). `OnlineItem` (its `kind` is an `ItemKind`), the `OnlineLibrary` protocol, and `KlipyLibrary` (`URLSession`, a time-out of 5 s, 24 results a page, at most 96, KLIPY's order). The KLIPY ID of an item is its slug, because `gifs/items` takes slugs. `SearchDebouncer` starts a search 350 ms after the last change and cancels the old one. `PasteFiles` downloads the paste file to `<cache>/paste/<uuid>/<id>.<ext>` and deletes it after 5 minutes and at quit.
- `KeyStore.swift`: the KLIPY key (D2 of YAZ-2919). `KeyStore` is a protocol, so a test uses a fake. `KeychainKeyStore` keeps a generic password, service `com.yaseenarshad.yaseenemoji`, account `klipy`. An empty text removes it.

## Test

`swift test` runs the full set.

- A test opens no window and uses no mouse and no keyboard. A test posts no key event.
- A test never registers a real hotkey or a real login item. It uses a fake one.
- A test never reads or changes the real clipboard. It uses a fake one. The paste of the add window reads a `ClipboardContents` in the test.
- The videos and pictures of the import tests are made in the test.
- A test never makes a real network request. It uses `StubNetwork`, a `URLProtocol` stub. A test never touches the real Keychain. It uses `FakeKeyStore`. `KlipyRig` puts `KlipyResults` on a stub network with a `ManualSleep` for the pause and a `FakeLater` for the prefetch and the 3 s wait.
- A test writes only into a temporary folder: the preferences folder, the GIFs and memes folder, `thumbs/`, `paste/`, `klipy/` and the folder of a drop are all parameters. It never reads the real `you.json`, the real preferences folder, `yaseen-os` or the EmojiFinder database.
- Some tests print `TIMING` lines: the load of `emoji.json`, the draw check, the search of the emojis and of 2,000 made-up GIFs, the change of a 5 s MP4 to a GIF, and the load and the save of a list of 2,000 items and 2,000 KLIPY cards. `MEMORY` gives the memory of 120 still pictures and of that list. Run `swift test -c release -Xswiftc -enable-testing` for the numbers of a release build.
- The window parts (the panel, the grid, the menu on the screen) have no test. Check them on the real screen.

### The log

Read the log of the app with the full path of the tool (in some shells, `log` is a different command):

```bash
/usr/bin/log show --last 5m --predicate 'subsystem == "com.yaseenarshad.yaseenemoji"'
```

## Make the git history of yaseen-os small again

Yaseen's preferences folder is `yaseen-os/Sync/yaseen-emoji`, in a git repository. By default `gifs/` and `memes/` are in it (D4 of YAZ-2919), so git keeps each GIF and meme file forever, also after you delete it or move the folder. A move of the GIFs and memes folder out of `yaseen-os` (Settings → "Set GIFs and memes folder…") does not make the repository smaller. Only a rewrite of the history does. The steps are from the scope note "the git history can be cleaned later" on YAZ-2908.

What is in git and what is not:

- In git: `you-<Mac name>.json`, `library-<Mac name>.json` (with the KLIPY cards: small text), and your own files in `gifs/` and `memes/`.
- Never in git: the KLIPY files of D18 (`~/Library/Application Support/Yaseen Emoji/klipy/`), the still pictures and the paste files (`~/Library/Caches/Yaseen Emoji/`). They are not in the preferences folder (D18 update on YAZ-2919). Thus a rewrite never needs them.

The rewrite is a one-time job of about 15 minutes. It rewrites all of `yaseen-os` (Alfred and the other synced files too), so do it by hand, never from the app:

1. Stop the auto-sync of `yaseen-os` on both Macs.
2. Keep the files that you want. To keep your GIFs and memes outside git, first move them with Settings → "Set GIFs and memes folder…" on each Mac, or copy `gifs/` and `memes/` to a safe place. The rewrite removes these folders from every commit, also from the newest one.
3. On one Mac, make a backup of the repository, then check the size:

   ```bash
   cd ~/path/to/yaseen-os
   git clone --mirror . ../yaseen-os-backup.git
   git count-objects -vH
   ```

4. Install `git filter-repo` (`brew install git-filter-repo`) and remove the two folders from the history:

   ```bash
   git filter-repo --path Sync/yaseen-emoji/gifs --path Sync/yaseen-emoji/memes --invert-paths
   ```

   `git filter-repo` removes the `origin` remote. Add it again: `git remote add origin <the GitHub URL>`.
5. Check the new size with `git count-objects -vH`, then force-push:

   ```bash
   git push --force --all origin
   git push --force --tags origin
   ```

6. On the other Mac, clone `yaseen-os` again (or run `git fetch origin` and `git reset --hard origin/<branch>`, after you saved each change that is not pushed).
7. Start the auto-sync again on both Macs.

GitHub can keep the old objects for some time after a force-push. The repository on the Macs gets small at once. GitHub frees its space later.

## The signature

`scripts/bundle.sh` signs with the certificate "Yaseen Local Signing". With a fixed certificate, each build has the same signature, and macOS sees each build as the same app. This is important for Yaseen Emoji: macOS keeps the Accessibility permission only for the same signature. Set `SIGN_IDENTITY` to use a certificate with a different name.

If the keychain does not have the certificate, the script signs ad-hoc and prints this:

```
WARNING: the keychain does not have the certificate "Yaseen Local Signing". The signature will be ad-hoc. macOS sees each ad-hoc build as a different app.
```

Set `REQUIRE_SIGN_IDENTITY=1` to make that an error. Then the script stops before the build.

The app is not sandboxed. Accessibility needs no entitlement, so the app uses no entitlement file.

### Make the certificate (one time)

Yaseen Screenshot and Yaseen Screendraw use the same certificate. If you made the certificate for one of them, do not make it again.

1. Check if the keychain has the certificate:

   ```bash
   security find-identity -p codesigning
   ```

   If the list shows `"Yaseen Local Signing"`, go to step 3. The text `CSSMERR_TP_NOT_TRUSTED` next to it is normal for a self-signed certificate.
2. Run `scripts/make-signing-cert.sh`. The script changes your login keychain, so the owner of the Mac runs it. The certificate is self-signed and free. It is valid for 10 years.
3. Run `scripts/bundle.sh`. The first time, macOS can ask if `codesign` can use the key. Enter your login password and click "Always Allow".
4. Check the signature:

   ```bash
   codesign -d -r- "build/Yaseen Emoji.app"
   ```

   The output must name a certificate (`certificate leaf = H"…"`). It must not show `cdhash`.

Keep this certificate. A new certificate is a new signature.

### Give the certificate to GitHub (one time)

The release workflow signs with the same certificate. It reads two repository secrets. The secrets of the other Yaseen repositories do not apply to this repository. Add them here too.

1. Select a password for the `.p12` file. Then export the certificate and its private key:

   ```bash
   security export -k ~/Library/Keychains/login.keychain-db -t identities -f pkcs12 -P 'YOUR-P12-PASSWORD' -o ~/yaseen-local-signing.p12
   ```

   This command exports all the identities in the login keychain. If the keychain has other identities, use Keychain Access instead: select "Yaseen Local Signing" in "My Certificates", then File, Export Items, format "Personal Information Exchange (.p12)".
2. Add the two secrets with the GitHub CLI. Run these commands in the repository folder:

   ```bash
   base64 -i ~/yaseen-local-signing.p12 | gh secret set SIGN_CERT_P12_BASE64
   gh secret set SIGN_CERT_PASSWORD
   ```

   The second command asks for the value. Paste the password of the `.p12` file.
3. Delete the file:

   ```bash
   rm ~/yaseen-local-signing.p12
   ```

Without the two secrets, the release workflow signs ad-hoc. It writes a warning in its log, and the release page tells that the build is ad-hoc signed.

## Releases

- No release is cut automatically.
- Set the new version in `Support/Info.plist` (`CFBundleShortVersionString`) and merge it into `main`.
- Tag that commit `vX.Y.Z` and push the tag. `.github/workflows/release.yml` builds the `.dmg` and attaches it to the GitHub release of that tag. It makes the release if it does not exist.
- The workflow fails if the tag is not the version in `Support/Info.plist`.
- The workflow writes the kind of signature at the top of the release text: the certificate, or ad-hoc.
- You can also start the workflow by hand for a tag that exists. It builds the `.dmg` again and replaces the file of that release.
- `.github/workflows/ci.yml` runs `swift build` and `swift test` on each pull request.
- The two workflows run on the fixed runner `macos-26`. They select the newest Xcode of that runner that is not a beta or a release candidate. They print the tool versions in the log.

A change of the README or of `docs/` needs no new release.

## The license

The license is [MIT](../LICENSE).
