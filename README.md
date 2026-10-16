# Yaseen Emoji

Press ⌘E in any app, type a word, and the correct emoji comes up. Enter puts it where your cursor is.

- About 10 search words for each of the 1,914 emojis of Emoji 17, from three free word lists. "haha", "praise" and "launch" all find their emoji.
- It learns: the emoji that you pick for a word comes first the next time. Right-click an emoji to add a word of your own.
- It pastes for you, then puts your old clipboard back.
- macOS 14 or later, Apple Silicon. No Dock icon: the app lives in the menu bar.
- No network use and no tracking.

## The keys

| Key | What it does |
| - | - |
| ⌘E | Open the panel. Press it again to close the panel. You can change this key in Settings. |
| Enter, or a click | Paste the emoji with the blue box, and close. |
| Shift+Enter | Paste, and keep the panel open. |
| ⌘C | Copy the emoji only, and close. |
| Arrow keys | Move the blue box. |
| Esc | Close, with no paste. |
| Right-click | The skin tones of that emoji, "Add a word…", and "Copy only". |

## Settings

The menu bar icon (a smiley) has "Find an emoji", "Settings…", "Start at login" and "Quit Yaseen Emoji". Settings has the hotkey, "When you pick" (Paste or Copy only), the default skin tone, "Start at login", the Accessibility state, and "Forget learned words". Each change saves at once.

To paste for you, the app needs the Accessibility permission. It asks one time, at the first start. Without it, a pick copies the emoji only.

Your history is in `~/Library/Application Support/Yaseen Emoji/you.json`.

## Build and install

You need Xcode. The package has no outside dependency.

```bash
scripts/bundle.sh     # makes build/Yaseen Emoji.app, signed
scripts/install.sh    # puts it in /Applications and opens it
```

The first `scripts/install.sh` also brings your history from EmojiFinder, if you have it. The details are in [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md).

## License

[MIT](LICENSE).
