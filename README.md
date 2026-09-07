# OmaMac

One clipboard across a Linux desktop and a Mac. Copy on either machine, paste
on the other. Text and images. If your Mac and iPhone share an Apple ID,
Universal Clipboard carries it on to the phone for free.

It is deliberately small and private:

- **No cloud, no accounts, no server.** The two machines talk over your own
  SSH connection. Tailscale makes that work from anywhere; a LAN works too.
- **No network code in the Mac app.** It only ever touches the pasteboard and
  a local history file. Read the one Swift file and you have read it all.
- **Password-manager copies never leave the machine** they were made on.
  Anything a manager marks as concealed is also kept out of history.
- The Mac app doubles as a **menu-bar clipboard history**, with the
  Flycut-style Shift-Cmd-V cycle-and-paste, so you can retire Flycut.

Built for [Omarchy](https://omarchy.org) (Hyprland on Wayland), but any
Wayland desktop with `wl-clipboard` should work.

## How it works

```
 Linux (Wayland)                         Mac
 ─────────────────                       ──────────────────────────
 wl-paste --watch ──── ssh "OmaMac set" ───▶ pasteboard
 wl-copy ◀──── ssh "OmaMac stream" ───────── pasteboard change counter
```

- Linux to Mac: `wl-paste --watch` fires on every clipboard change and pushes
  the content to the Mac over SSH.
- Mac to Linux: one long-lived SSH session runs `OmaMac stream`, which
  prints a line whenever the Mac clipboard changes. Nothing polls from the
  Linux side, so idle CPU is effectively zero on both machines.
- A "last synced" file stops changes bouncing back and forth.

## Requirements

- **Mac:** macOS 13 or later, and Xcode or the Command Line Tools to build.
- **Linux:** a Wayland desktop, `wl-clipboard`, `ssh`, and `systemd` user
  sessions (Omarchy has all of these).
- **Passwordless SSH from Linux to the Mac.** Turn on Remote Login in the
  Mac's Sharing settings, then from Linux:

  ```
  ssh-keygen -t ed25519            # if you have no key yet
  ssh-copy-id you@your-mac
  ssh your-mac true                # must succeed without a prompt
  ```

  Give the Mac a stable name in `~/.ssh/config` or use its Tailscale name.

## Install

### 1. Mac

```
git clone https://github.com/ericmwhite/omamac.git ~/dev/omamac
~/dev/omamac/build.sh install
```

That compiles `OmaMac.app`, signs it, copies it to `~/Applications`, and
starts it. A clipboard icon appears in the menu bar. Optional, but worth
doing from that menu:

- **Paste Directly** lets Shift-Cmd-V paste into the app you are using. It
  needs Accessibility permission, which macOS will prompt for.
- **Launch at Login** keeps it running.

The build signs with a "Developer ID Application" or "Apple Development"
certificate if you have one, otherwise ad-hoc. macOS ties the Accessibility
grant to the signature, so an ad-hoc-signed app must be re-granted after
every rebuild. With a certificate the grant sticks.

### 2. Linux

```
git clone https://github.com/ericmwhite/omamac.git ~/Projects/omamac
~/Projects/omamac/linux/install.sh your-mac
```

`your-mac` is whatever you type after `ssh`. The installer checks the
connection, copies the script to `~/.local/bin/omamac`, and enables a
systemd user service called `omamac`. Copy something on either machine and
paste on the other.

## Using the Mac app

- Click the menu-bar icon for the recent items. Pick one to copy it (and paste
  it, if Paste Directly is on). Keys 1 to 9 pick while the menu is open.
- **Shift-Cmd-V** works like Flycut: an overlay shows the newest item. With
  Cmd still held, tap V or the right arrow to move older, the left arrow to
  move newer. Release Cmd to paste the one showing. Escape cancels.
- Images are recorded and shown in the overlay, with thumbnails in the menu.
- **Pause Recording**, **Clear History**, and **Remember History Across
  Restarts** are in the menu. History lives in
  `~/Library/Application Support/OmaMac/` with owner-only permissions.
  Turn "Remember" off and nothing is written to disk.

Settings, changed with `defaults write it.letsponder.omamac <key> <value>`:

| key | default | meaning |
|---|---|---|
| `maxItems` | 100 | items kept in history |
| `maxImages` | 20 | images kept in history |
| `menuItems` | 30 | items shown in the menu |
| `persist` | true | save history to disk |

## What syncs

| Copied | Result |
|---|---|
| Plain text, any length | Syncs exactly |
| Rich text | Syncs as plain text; formatting dropped |
| Screenshot or copied image | Syncs as PNG, up to 20 MB |
| Image with a URL attached (browser copies) | The image wins |
| Password-manager copies | Stay local |
| Files, folders, video, audio | Do not sync (the clipboard only holds a path) |

When a copy carries both an image and text, text wins unless the text is only
a URL. That keeps spreadsheet cells syncing as text rather than as a picture.

## Command-line modes

The Mac binary is also a small clipboard tool, which is what the sync uses:

```
OmaMac stream   # one line per clipboard change, forever: t:<base64 text> or i:<base64 png>
OmaMac set      # stdin -> clipboard (UTF-8 text, or PNG bytes)
OmaMac get      # clipboard -> stdout (text, or PNG bytes)
```

`stream` checks the pasteboard change counter in-process every 0.3 seconds
(macOS has no clipboard change notification; every clipboard manager does
this) and exits when its stdin closes, so a dropped SSH session leaves
nothing behind.

## Troubleshooting

```
systemctl --user status omamac          # is the Linux side running?
journalctl --user -u omamac -n 50       # what did it say?
ssh your-mac Applications/OmaMac.app/Contents/MacOS/OmaMac get   # can Linux reach the Mac app?
```

- Nothing syncs Mac to Linux, but Linux to Mac works: the stream session
  died. The service reconnects within about ten seconds of the Mac being
  reachable again; restart it with `systemctl --user restart omamac`.
- Shift-Cmd-V shows the overlay but does not paste: turn on Paste Directly
  and grant Accessibility. If you rebuilt an ad-hoc-signed app, remove
  OmaMac from Accessibility in System Settings and grant it again.
- The Mac is asleep: nothing syncs until it wakes. Set the Mac to never
  sleep if it is a desktop.

## Uninstall

- Linux: `linux/install.sh --uninstall`
- Mac: quit OmaMac from its menu, delete `~/Applications/OmaMac.app` and
  `~/Library/Application Support/OmaMac/`, and remove it from Login Items
  if you enabled that.

## License

MIT. See `LICENSE`.
