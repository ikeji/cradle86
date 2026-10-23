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
DEV=${CRADLE_DEV:-/dev/serial/by-id/usb-cradle86_cradle86_V30_E6639436874A4C2B}
HERE=$(cd "$(dirname "$0")" && pwd)

wait_port() {
  if [ ! -e "$1" ]; then
    echo "--- waiting for $1"
    until [ -e "$1" ]; do sleep 0.5; done
  fi
  echo "--- connected to $1"
}

# One pane's loop (run by tmux as "cradle.sh _pane NAME [ARG]").
pane() {
  while true; do
    case $1 in
    con)
      wait_port "$DEV-if02"
      luit -encoding SJIS -- picocom -q "$DEV-if02"
      ;;
    mon)
      wait_port "$DEV-if00"
      picocom -q "$DEV-if00"
      ;;
    disk)
      wait_port "$DEV-if06"
      python3 "$HERE/disk_server.py" --port "$DEV-if06" "$2"
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
  self=$(printf %q "$HERE/cradle.sh")
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
