#!/usr/bin/env bash
# Install the Linux half of omamac as a systemd user service.
#   linux/install.sh <mac-ssh-host>     install or update, syncing with that Mac
#   linux/install.sh --uninstall        stop and remove it
set -euo pipefail
cd "$(dirname "$0")"

if [ "${1:-}" = "--uninstall" ]; then
  systemctl --user disable --now omamac 2>/dev/null || true
  rm -f ~/.config/systemd/user/omamac.service ~/.local/bin/omamac
  systemctl --user daemon-reload
  echo "omamac removed"
  exit 0
fi

HOST="${1:-}"
if [ -z "$HOST" ]; then
  echo "usage: $0 <mac-ssh-host>   (or --uninstall)" >&2
  exit 1
fi
command -v wl-paste >/dev/null || { echo "omamac needs wl-clipboard (wl-paste/wl-copy)" >&2; exit 1; }
if ! ssh -o BatchMode=yes -o ConnectTimeout=8 "$HOST" 'test -x Applications/OmaMac.app/Contents/MacOS/OmaMac'; then
  echo "cannot reach '$HOST' over passwordless SSH, or ~/Applications/OmaMac.app is not installed there" >&2
  exit 1
fi

mkdir -p ~/.local/bin ~/.config/systemd/user
install -m 755 omamac ~/.local/bin/omamac
sed "s|^Environment=OMAMAC_HOST=.*|Environment=OMAMAC_HOST=$HOST|" omamac.service \
  > ~/.config/systemd/user/omamac.service
systemctl --user daemon-reload
systemctl --user enable --now omamac
systemctl --user restart omamac
echo "omamac is running and syncing with $HOST"
echo "check it with: systemctl --user status omamac"
