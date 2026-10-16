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

SwiftPM puts the resources of `EmojiKit` into `YaseenEmoji_EmojiKit.bundle`, next to the binary. `scripts/bundle.sh` copies each `*.bundle` of the build into `Contents/Resources` of the app. A file at the top of the `.app` breaks the signature. With no resource, the script copies nothing.

## Install and the EmojiFinder history

`scripts/install.sh` does these steps:

1. It quits Yaseen Emoji if it runs.
2. It puts `build/Yaseen Emoji.app` in `/Applications`.
3. The first time, it imports your history from EmojiFinder (D6). See below.
4. It opens the app.
5. If EmojiFinder runs, it prints a warning. EmojiFinder also uses ⌘E. Quit it and remove it from your login items.

The import runs only if both of these are true:

- `~/Library/Containers/com.marioiannotta.searchmoji/Data/Documents/Database.sqlite` exists.
- `~/Library/Application Support/Yaseen Emoji/you.json` does not exist.

The script copies the EmojiFinder database into a temporary folder and reads the copy with `sqlite3 -json`. Thus the EmojiFinder database never changes. It sends the rows to `YaseenEmoji --import-uses <path to you.json>`. The app writes `you.json` and exits. If the import fails, the script prints a warning and continues. The next run tries the import again.

## The code

- `Sources/EmojiKit`: all the code of the app, as a library. Thus the tests can import it.
- `Sources/YaseenEmoji`: the executable. It calls `AppController.main()`.
- `Tests/EmojiKitTests`: the unit tests.
- `AppController`: the app shell. It starts the app, and puts the menu bar icon on the screen.
- `StatusMenu`: the menu bar icon (the SF Symbol `face.smiling`, as a template image) and its rows.
- `HotKey.swift`: the global hotkey (Carbon `RegisterEventHotKey`, no permission). `HotKeyRegistering` is a protocol, so a test uses a fake.
- `LoginItem.swift`: "Start at login" (`SMAppService`). `LoginItem` is a protocol, so a test uses a fake.
- The package uses the Swift 5 language mode. The compiler of CI can be older than the compiler on your Mac.

## Test

`swift test` runs the full set.

- A test opens no window and uses no mouse and no keyboard. A test posts no key event.
- A test never registers a real hotkey or a real login item. It uses a fake one.
- A test writes only into a temporary folder.

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
