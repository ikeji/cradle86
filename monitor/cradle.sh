#!/bin/bash
# All cradle86 consoles in one tmux session:
#   top:          DOS console (USB port 1), Shift_JIS shown as UTF-8 via luit
#   bottom left:  monitor (USB port 0)
#   bottom right: disk server for B: (USB port 3)
# Each pane waits for its port and reconnects after a reboot or flash.
#
#   ./cradle.sh [IMAGE_OR_DIR]   start (default b.img) or attach
#   ./cradle.sh -k               stop the session
#
# picocom: C-a C-x quits a pane's terminal (it reconnects after a second).
# tmux: C-b d detaches; the mouse selects and resizes panes. Run from inside
# tmux, it switches the client to the session instead.

SESSION=v30
HERE=$(cd "$(dirname "$0")" && pwd)

# Find and wait for a cradle86 USB CDC interface (e.g. "if00").
# Sets PORT to the resolved device path.
wait_port() {
  local ifname=$1
  local label waited=0
  local -a matches
  if [ -n "$CRADLE_DEV" ]; then
    label="$CRADLE_DEV-$ifname"
  else
    label="/dev/serial/by-id/usb-cradle86_*-$ifname"
  fi
  while true; do
    if [ -n "$CRADLE_DEV" ]; then
      if [ -e "$CRADLE_DEV-$ifname" ]; then
        PORT="$CRADLE_DEV-$ifname"
        break
      fi
    else
      matches=(/dev/serial/by-id/usb-cradle86_*-"$ifname")
      if [ -e "${matches[0]}" ]; then
        PORT="${matches[0]}"
        break
      fi
    fi
    if [ "$waited" -eq 0 ]; then
      echo "--- waiting for $label"
      waited=1
    fi
    sleep 0.5
  done
  echo "--- connected to $PORT"
}

# One pane's loop (run by tmux as "cradle.sh _pane NAME [ARG]").
pane() {
  while true; do
    case $1 in
    con)
      wait_port if02
      luit -encoding SJIS -- picocom -q "$PORT"
      ;;
    mon)
      wait_port if00
      picocom -q "$PORT"
      ;;
    disk)
      wait_port if06
      python3 "$HERE/disk_server.py" --port "$PORT" "$2"
      ;;
    esac
    echo "--- disconnected"
    sleep 1
  done
}

case $1 in
_pane)
  shift
  pane "$@"
  exit
  ;;
-k)
  tmux kill-session -t "$SESSION"
  exit
  ;;
-h | --help)
  sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'
  exit
  ;;
esac

if ! tmux has-session -t "$SESSION" 2>/dev/null; then
  DISK=$(realpath "${1:-$HERE/b.img}")
  if [ ! -e "$DISK" ]; then
    if [ -n "$1" ]; then
      echo "$DISK: not found" >&2
      exit 1
    fi
    make -C "$HERE" b.img >/dev/null || exit 1
  fi
  env_prefix=""
  if [ -n "$CRADLE_DEV" ]; then
    env_prefix="CRADLE_DEV=$(printf %q "$CRADLE_DEV") "
  fi
  self="${env_prefix}$(printf %q "$HERE/cradle.sh")"
  con=$(tmux new-session -d -P -F '#{pane_id}' -s "$SESSION" -n cradle86 \
    -x "$(tput cols)" -y "$(tput lines)" "$self _pane con")
  tmux set-option -t "$SESSION" mouse on
  tmux set-option -t "$SESSION" pane-border-status top
  tmux set-option -w -t "$con" allow-set-title off
  tmux select-pane -t "$con" -T "DOS console (SJIS)"
  mon=$(tmux split-window -P -F '#{pane_id}' -v -l 12 -t "$con" "$self _pane mon")
  tmux select-pane -t "$mon" -T monitor
  disk=$(tmux split-window -P -F '#{pane_id}' -h -t "$mon" \
    "$self _pane disk $(printf %q "$DISK")")
  tmux select-pane -t "$disk" -T "B: $DISK"
  tmux select-pane -t "$con"
fi
if [ -n "$TMUX" ]; then
  exec tmux switch-client -t "$SESSION"
fi
exec tmux attach -t "$SESSION"
