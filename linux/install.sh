#!/usr/bin/env bash
# Install the Linux half of clipspan as a systemd user service.
#   linux/install.sh <mac-ssh-host>     install or update, syncing with that Mac
#   linux/install.sh --uninstall        stop and remove it
set -euo pipefail
cd "$(dirname "$0")"

if [ "${1:-}" = "--uninstall" ]; then
  systemctl --user disable --now clipspan 2>/dev/null || true
  rm -f ~/.config/systemd/user/clipspan.service ~/.local/bin/clipspan
  systemctl --user daemon-reload
  echo "clipspan removed"
  exit 0
fi

HOST="${1:-}"
if [ -z "$HOST" ]; then
  echo "usage: $0 <mac-ssh-host>   (or --uninstall)" >&2
  exit 1
fi
command -v wl-paste >/dev/null || { echo "clipspan needs wl-clipboard (wl-paste/wl-copy)" >&2; exit 1; }
if ! ssh -o BatchMode=yes -o ConnectTimeout=8 "$HOST" 'test -x Applications/Clipspan.app/Contents/MacOS/Clipspan'; then
  echo "cannot reach '$HOST' over passwordless SSH, or ~/Applications/Clipspan.app is not installed there" >&2
  exit 1
fi

mkdir -p ~/.local/bin ~/.config/systemd/user
install -m 755 clipspan ~/.local/bin/clipspan
sed "s|^Environment=CLIPSPAN_HOST=.*|Environment=CLIPSPAN_HOST=$HOST|" clipspan.service \
  > ~/.config/systemd/user/clipspan.service
systemctl --user daemon-reload
systemctl --user enable --now clipspan
systemctl --user restart clipspan
echo "clipspan is running and syncing with $HOST"
echo "check it with: systemctl --user status clipspan"
