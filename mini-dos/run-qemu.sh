#!/bin/sh

set -e

FINAL_IMAGE="bootable.img"
LOG_FILE="qemu.log"
LOG2_FILE="qemu2.log"

if [ ! -f "$FINAL_IMAGE" ]; then
    echo "Error: $FINAL_IMAGE not found. Please build it first with 'make'."
    exit 1
fi

rm -f $LOG_FILE
rm -f $LOG2_FILE

echo "Starting QEMU. Log will be written to $LOG_FILE."

qemu-system-i386 \
    -drive format=raw,file=$FINAL_IMAGE \
    -serial file:$LOG_FILE \
    -serial file:$LOG2_FILE \
    -monitor none \
    -display none \
    -device isa-debug-exit,iobase=0x501,iosize=1 & # Run in background
QEMU_PID=$! # Get PID of QEMU

echo "QEMU PID: $QEMU_PID"
WAIT_SEC=1
echo "Waiting for ${WAIT_SEC} seconds to collect logs..."
sleep ${WAIT_SEC}
echo "Killing QEMU process (PID: $QEMU_PID)..."
kill $QEMU_PID || true # Kill QEMU
wait $QEMU_PID || true # Wait for QEMU to actually exit

echo "QEMU run finished. Decoded contents of $LOG_FILE:"
if [ -f "$LOG_FILE" ]; then
    python3 tools/log_parser.py
else
    echo "(log file not found)"
fi
