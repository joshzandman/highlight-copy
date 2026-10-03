# Highlight Copy

Highlight Copy is a macOS menu-bar app. Highlight text with the mouse or trackpad and, when you release, that text is copied to the clipboard. A small “copied” label appears at the end of the highlight.

It has no Dock icon. The menu-bar clipboard icon stays available while you work.

## What it copies

A highlight is a drag, including trackpad click-drag, tap-to-click drag, and three-finger drag, or a double-click or triple-click that selects a word or line.

These actions do not change the clipboard:

- A plain click
- A drag that does not change the existing selection
- Text in a password field
- A highlight made while holding the Option key. Holding it at any point during the drag, double-click, or triple-click skips the copy.

## Requirements

- macOS 13.0 or later
- Swift 5.9 or later to build from source (Xcode 15 or later)
- Accessibility access for Highlight Copy

Accessibility lets the app see the pointer release and read the selected text. On macOS 13 and 14, turn it on under **System Settings → Privacy & Security → Accessibility**. On newer macOS versions the same list is titled **Device Control and Data Access**. The menu item **Open Device Control and Data Access…** opens that list.

## Install

From this directory:

```sh
scripts/install.sh
```

That builds a release binary, signs it with a stable local certificate, and installs `~/Applications/HighlightCopy.app`. The certificate keeps the Accessibility permission attached to later rebuilds. The first build creates that certificate in your login keychains.

Launch at login is on by default. Pause, resume, and quit are in the menu-bar menu.
