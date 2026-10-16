# Yaseen Emoji

Press ⌘E in any app, type a word, and the correct emoji comes up. Enter puts it where your cursor is.

- About 10 search words for each of the 1,914 emojis of Emoji 17, from three free word lists. "haha", "praise" and "launch" all find their emoji.
- It learns: the emoji that you pick for a word comes first the next time. Right-click an emoji to add a word of your own.
- A word with no match still shows "Your most used" and all the groups. Pick any emoji there, and the word finds it the next time.
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
| Right-click | "Add a word…" and "Copy only". In "Your most used", also "Hide from Your most used". |
| Press and drag | Move the panel, from any part. The text in the search box still selects. The next open puts the panel in the middle again. |

## Settings

The menu bar icon (a smiley) has "Find an emoji", "Settings…", "Start at login" and "Quit Yaseen Emoji". Settings has the hotkey, "When you pick" (Paste or Copy only), the default skin tone (the only skin tone choice), "Start at login", the Accessibility state, "Hidden from Your most used" with "Show them again", "Forget learned words", and the preferences folder. Each change saves at once.

To paste for you, the app needs the Accessibility permission. It asks one time, at the first start. Without it, a pick copies the emoji only.

Your history is in the preferences folder. The default is `~/Library/Application Support/Yaseen Emoji`. Each Mac writes its own file there, `you-<Mac name>.json`.

To share your history and settings between Macs, point each Mac at one folder that syncs, for example a folder in a git repository. Use Settings → "Set preferences folder…". Each Mac adds up the files of all Macs: your uses, your learned and added words, the hidden emojis, and the hotkey, "When you pick" and the default skin tone. The newest change of a setting wins. "Start at login", Accessibility and the folder path stay on each Mac. "Reset to Mac Default Folder" goes back to the default folder.

## Build and install

You need Xcode. The package has no outside dependency.

```bash
scripts/bundle.sh     # makes build/Yaseen Emoji.app, signed
scripts/install.sh    # puts it in /Applications and opens it
```

The first `scripts/install.sh` also brings your history from EmojiFinder, if you have it. The details are in [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md).

## License

[MIT](LICENSE).
