# Yaseen Emoji

Press ⌘E in any app, type a word, and the correct emoji comes up. Enter puts it where your cursor is.

This is a work in progress. Today the app is a menu bar icon (a smiley) with one row: "Quit Yaseen Emoji". The search panel and Settings come next.

- macOS 14 or later, Apple Silicon.
- No Dock icon. The app lives in the menu bar.
- No network use and no tracking.

## Build and install

You need Xcode. The package has no outside dependency.

```bash
scripts/bundle.sh     # makes build/Yaseen Emoji.app, signed
scripts/install.sh    # puts it in /Applications and opens it
```

The first `scripts/install.sh` also brings your history from EmojiFinder, if you have it. The details are in [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md).

## License

[MIT](LICENSE).
