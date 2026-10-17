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
- **Synced settings:** `settings.hotKey`, `settings.pickMode` and `settings.defaultTone`, each with the time of the change. A Mac writes a setting only when you change it in Settings. `UserDefaults` keeps the value and the time that this Mac applied. A newer hotkey from a different Mac works at once. If macOS refuses it, the old key stays and Settings shows the red line.
- **Forget learned words:** writes `forgotAt`. Each Mac that sees a newer `forgotAt` clears its own learned and added words, and writes the time in `forgetApplied`.
- **Reload:** each time the panel or Settings opens, the app lists the folder and reads only the files with a new modification date.
- **The first start of D16:** if this Mac's file is missing, the app copies this Mac's file of the default folder, or else `you.json`. The source stays as a backup.
- **A missing folder:** the app uses the default folder, and Settings shows "Can't find the preferences folder. This Mac uses its own history."
- **The files:** sorted keys, one value on each line, atomic writes.

### GIFs and memes (D3 and D4 of YAZ-2919)

- **The list:** `library-<Mac name>.json` in the preferences folder, one file for each Mac, with the same Mac name as `you-<Mac name>.json`. For each `id`, the newest `changed` of all Macs wins. The same time: the delete wins. A remove keeps the item with `removed`, so a later add on any Mac can win.
- **The files:** `gifs/<id>.<ext>` and `memes/<id>.<ext>` in the GIFs and memes folder. The pref `yaseenEmoji.mediaFolder` stays on each Mac. "" is the preferences folder. The `id` is the first 16 hex characters of the SHA-256 of the file, so two Macs that add the same GIF write the same file.
- **Delete a GIF or meme:** right-click → "Show in Finder", then delete the file in Finder. The app has no "Move to Trash". At each open, `LibraryStore.reload()` lists `gifs/` and `memes/` one time each. An item with no file does not show in the panel, but it stays in the list. When the file comes back (a `git pull`), the item shows again at the next open.
- **The counts and the learned words** stay in `you-<Mac name>.json`, with the keys `gif:<id>`, `meme:<id>` and `klipy:<klipyID>`.
- **The still pictures:** `~/Library/Caches/Yaseen Emoji/thumbs/<id>.png`, 290 × 290 pixels. They are not synced. The panel makes a missing one when its tile shows, and deletes it when the item is removed, on this Mac or on a different Mac.
- **Settings → "GIFs and memes":** "Set GIFs and memes folder…" and "Reset to Same Folder…" (type "reset") call `LibraryStore.useMediaFolder(_:)`. "Set preferences folder…" and "Reset to Mac Default Folder…" also move `library-<Mac name>.json` (`LibraryStore.move(to:)`), and `gifs/` and `memes/` when the GIFs and memes folder is the preferences folder. If that file move fails, the files stay, and the GIFs and memes folder becomes the old folder.

### KLIPY (D1, D2, D7 of YAZ-2919)

- **The key:** Settings → "KLIPY key". Enter, a click outside the box, or a close of the window saves it into this Mac's Keychain (service `com.yaseenarshad.yaseenemoji`, account `klipy`). An empty box removes it. ⌘V works in the box: the settings window gives the edit keys to the box, because the app has no main menu.
- **The search:** 350 ms after the last key, 24 a page, the next page near the end of the grid, at most 96, in KLIPY's order, in "From KLIPY" below "Yours". The last 8 searches stay in memory. A failed search gives one grey line, and the next open tries again.
- **Saved and learned items:** "Yours" shows the saved KLIPY items and the KLIPY items that you picked for this text. The app gets the unknown slugs of one grid in one `items` call for each kind, and keeps at most 500 items in memory. An item that KLIPY deleted drops with no line.
- **The paste:** the paste file downloads when the blue box sits on a KLIPY tile for 300 ms. Enter waits up to 3 s with "Getting the GIF…". The file goes into `~/Library/Caches/Yaseen Emoji/paste/<uuid>/`. The app deletes the files older than 5 minutes at each open of the panel and each minute, and all of them at quit.
- **The pictures** of KLIPY tiles stay in memory only (120 stills, 30 moving `sm.gif` previews). The moving previews of the tiles on the screen load at most 4 at a time, in the order of the grid.

### The add window (D12 of YAZ-2919)

"Add a GIF or meme…" in the menu bar or in the right-click menu of the GIFs and Memes tabs opens the add window. A drop of files on the search panel also opens it, with the files. It is a non-activating panel, like Settings, and it stays open until you close it.

- **Ways to add:** drop files on the window, "Choose files…" (more than one file), "Paste", or ⌘V.
- **The paste** reads the best form on the clipboard, in this order: a file URL, GIF bytes, video bytes (MP4, MOV), then still image bytes (PNG, JPEG, HEIC, HEIF, TIFF). The first form that any clipboard item has wins, and each item with that form gives one row. A still picture shows the grey line "This came in as a still picture. To keep it moving, save the file and drag it in."
- **A drop** takes files, then file promises (a drag from a browser or from Telegram, received into a temp folder), then the same bytes as a paste.
- **Each row:** "Getting it ready…" while `MediaImport.prepare` runs off the main thread. Then the preview, GIF / Meme, the words box, "Add" and "Remove". A meme gets its read words (D8). "Add" needs one word ("Type one word first."). A duplicate says "You have this one already." and adds only its new words.
- **The add:** the file goes into `gifs/` or `memes/` off the main thread (`LibraryStore.writeMediaFile`). Then `LibraryStore.add` saves the list on the main thread, because the panel reads the list there.
- **A close** with rows that wait asks "Close and drop N files?" in the window. A refused row does not count.

### Add GIFs and memes from the Terminal

For a fast test with many files, quit the app, then run the binary inside the app:

```bash
"/Applications/Yaseen Emoji.app/Contents/MacOS/YaseenEmoji" --add-media ~/Downloads/dance.gif ~/Downloads/fine.png --words "dance party"
```

- Each file goes through the same steps as the add window: the type check, MP4 and MOV to GIF, the 10 MB limit (`MediaImport.prepare`), then `LibraryStore.add`.
- The words: the `--words` text. With none, a meme gets the words that Vision reads in it. With still none, the words come from the file name.
- The command refuses to run while the app runs. It uses the prefs of the app, so run the binary inside the app, not `.build/debug/YaseenEmoji`.
- Exit codes: 0 done, 1 a file failed, 2 no file, 3 the app runs.

To point the app at a folder without Settings, quit the app, then run `defaults write com.yaseenarshad.yaseenemoji yaseenEmoji.preferencesFolder -string "<folder>"`, then open the app.

## The code

- `Sources/EmojiKit`: all the code of the app, as a library. Thus the tests can import it.
- `Sources/YaseenEmoji/main.swift`: the executable. It runs `--import-uses` or `--add-media`, or it calls `AppController.main()`.
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
- `Library.swift`: `Item` (one GIF or meme), `LibraryFile` (one `library-<Mac name>.json`), `LibraryStore` (this Mac's list, the lists of the other Macs, the add of a file, the remove of a saved KLIPY item, the missing files), and `MediaFolder` (the GIFs and memes folder and its move). The app never deletes a file of `gifs/` or `memes/`: you delete it in Finder.
- `MediaImport`: the add of a file (D5 and D8 of YAZ-2919): the kind from the bytes, MP4 and MOV to GIF, the 10 MB limit, the still picture of a tile, and the words of a meme with Vision. Each call runs off the main thread.
- `YouImport`: `--import-uses`, the import of the EmojiFinder history.
- `AddCommand`: `--add-media`, the add of GIFs and memes from the Terminal.
- `AddWindow.swift`: the add window (D12 of YAZ-2919). `AddModel` holds the rows and their rules, with no view. `PasteReader` finds the best form on the clipboard through `PasteboardSource`, a protocol, so a test gives a fake clipboard. `FileDrop` reads a drop. `AddWindowController` is the non-activating panel with the SwiftUI view.
- `PickSession`: the rules of the panel with no window: the tab (Emoji, GIFs, Memes; each open starts on Emoji), the search text, the lines of the grid, the blue box, the keys, the picks, the default skin tone, "Add a word…", the items of the right-click menu (`menuActions(at:)`, `perform(_:)`) and "Hide from Your most used". One grid item is a `PickItem`: an emoji, your own GIF or meme, or a KLIPY item. Its `key` is the key in `you-<Mac>.json`. The GIFs and Memes tabs use the same `Search` as the emojis (`Searchable`, `TileEntry`).
- `OnlineResults.swift`: the place of KLIPY in the GIFs and Memes tabs. With no `OnlineResults`, the tabs show only your own files and no "From KLIPY" section.
- `KlipyResults.swift`: the real `OnlineResults`: the search after the pause, the pages, the lookup of saved and learned items by slug, the 300 ms prefetch, the 3 s wait of a paste file, and the tile pictures. The network, the download, the pause and the clock are parameters.
- `Paster`: a pick. It saves the clipboard, writes the emoji or the file, posts ⌘V, and puts the old clipboard back after 0.3 s (a file: 1.0 s). A file is one clipboard item (`ClipboardContents.fileItem`): the file URL, the file's own bytes in its own type, and the transient mark for a paste. No TIFF. `Clipboard`, `KeySender`, `PasteAccess` and `Later` are protocols, so a test posts no key and never waits.
- `SearchPanel.swift`: the non-activating panel on the screen, and `PanelPlace` (where it opens). It turns keys into calls of `PickSession`: Tab and Shift+Tab go round the tabs, ⌘1 to ⌘3 go to a tab.
- `EmojiGrid.swift`: one view that draws only the lines on the screen (9 emojis or 3 tiles in a row, `GridMetrics`), the right-click menu, and the drag of the panel (a move of more than 4 points, `EmojiGridView.isDrag(from:to:)`). Each GIF tile on the screen plays (D11 update on YAZ-2925): `GridMetrics.playing(in:items:)` gives the GIF tiles in the visible rect (at most 15), and the grid puts a `MovingTileView` of its pool (at most 15) over each one. The blue box of a tile is a border view above them. The panel hides: all stop. `GridMetrics.scrollRect(of:)` keeps the titles above the row of the blue box in sight.
- `MovingTiles.swift`: `MovingPictures` (the moving pictures of the tiles on the screen: at most 4 loads at a time in the order of the grid, a load for a tile that left the screen stops, at most 30 in memory; one for your own GIF files in the grid, one for the KLIPY previews in `KlipyResults`), `MovingTileView` (one moving view: round corners, aspect-fill, the "KLIPY" mark; it lets the mouse through).
- `Thumbnails`: the still pictures of the tiles. It loads at most 4 at a time, off the main thread, into an `NSCache` of at most 120. It deletes the still picture of a removed item.
- `Prefs`: the settings in `UserDefaults`, with the prefix `yaseenEmoji.`.
- `SettingsModel` and `SettingsWindow.swift`: the rules of Settings with no window, and the SwiftUI form in a non-activating panel.
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
- A test writes only into a temporary folder. It never reads the real `you.json` or the EmojiFinder database.
- Some tests print `TIMING` lines: the load of `emoji.json`, the draw check, the search of the emojis and of 2,000 made-up GIFs, and the change of a 5 s MP4 to a GIF. A `MEMORY` line gives the memory of 120 still pictures. Run `swift test -c release -Xswiftc -enable-testing` for the numbers of a release build.
- The window parts (the panel, the grid, the menu on the screen) have no test. Check them on the real screen.

### The log

Read the log of the app with the full path of the tool (in some shells, `log` is a different command):

```bash
/usr/bin/log show --last 5m --predicate 'subsystem == "com.yaseenarshad.yaseenemoji"'
```

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
