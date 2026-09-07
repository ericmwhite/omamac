# Clipwatch

A small, private clipboard history for the Mac menu bar (text and images), with
optional two-way clipboard sync to a Linux machine over SSH. Built to replace Flycut with
something you can read in one sitting.

**Privacy is the whole point.** The app contains no network code, no analytics,
no update checker, and no dependencies. History is a JSON file in
`~/Library/Application Support/Clipwatch/` (mode 0600) that you can turn off or
clear from the menu. Anything a password manager marks as concealed or
transient is never recorded. Syncing, if you use it, rides on your own SSH
connection; the app never opens a socket.

Whole thing is one Swift file (`Sources/main.swift`) plus a shell script.

## Mac app

Requires macOS 13 or later and Xcode (or the Command Line Tools) to build.

```
./build.sh install
```

That compiles `Clipwatch.app`, ad-hoc signs it, copies it to `~/Applications`,
and starts it. A clipboard icon appears in the menu bar.

- Click the icon to see recent items in a menu.
- **Shift-Cmd-V** works like Flycut: an overlay shows the newest item, each further
  tap of V or the right arrow (with Cmd still held) moves one item older, the
  left arrow moves newer, and releasing Cmd pastes the one showing. Escape
  cancels.
- Images are recorded too (as PNG, up to 20 MB each). When a copy carries both
  an image and text, text wins unless the text is only a URL, which is what
  browsers attach to a copied picture.
- Picking from the menu copies the item. If
  you enable **Paste Directly** and grant Accessibility access, it is also
  pasted into the app you were using.
- **Pause Recording**, **Clear History**, **Remember History Across Restarts**,
  and **Launch at Login** are in the menu.

Defaults you can change with `defaults write it.letsponder.clipwatch <key> <value>`:

| key | default | meaning |
|---|---|---|
| `maxItems` | 100 | items kept in history |
| `maxImages` | 20 | images kept in history |
| `menuItems` | 30 | items shown in the menu |
| `persist` | true | save history to disk |

## Command-line modes

The same binary doubles as a clipboard tool, which is what the sync uses:

```
Clipwatch stream   # one line per clipboard change, forever: t:<base64 text> or i:<base64 png>
Clipwatch set      # stdin -> clipboard (UTF-8 text, or PNG bytes)
Clipwatch get      # clipboard -> stdout (text, or PNG bytes)
```

`stream` polls the pasteboard change counter in-process every 0.3 seconds
(macOS has no clipboard change notification; every clipboard manager does this)
and exits when its stdin closes, so a dropped SSH session leaves nothing behind.

## Linux sync (Wayland)

`linux/clipsync-mac` keeps the Linux clipboard and the Mac clipboard in step.
It needs `wl-clipboard` and passwordless SSH to the Mac (Tailscale works well).

- Linux to Mac: `wl-paste --watch` (one watcher for text, one for PNG) pushes
  each change to `Clipwatch set`.
- Mac to Linux: one long-lived SSH session runs `Clipwatch stream`, and each
  line is decoded into `wl-copy`. Nothing polls from the Linux side, so idle
  cost is effectively zero.
- A "last synced" file stops changes bouncing back and forth.
- Copies flagged as sensitive by a password manager stay on the machine they
  were made on.

Install:

```
cp linux/clipsync-mac ~/.local/bin/
cp linux/clipsync-mac.service ~/.config/systemd/user/
systemctl --user enable --now clipsync-mac
```

Set `CLIPSYNC_HOST` in the unit's `Environment=` if your Mac is not called
`erics-mac-mini`. Text and PNG images sync; other image formats do not.

## License

MIT. See `LICENSE`.
