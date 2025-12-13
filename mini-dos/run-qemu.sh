#!/bin/sh

set -e

FINAL_IMAGE="bootable.img"
LOG_FILE="qemu.log"

if [ ! -f "$FINAL_IMAGE" ]; then
    echo "Error: $FINAL_IMAGE not found. Please build it first with 'make'."
    exit 1
fi

# Clean up old log file
rm -f $LOG_FILE

echo "Starting QEMU for 2 seconds. Log will be written to $LOG_FILE."

# Run QEMU and redirect serial output to a file.
# timeout is used to ensure QEMU exits, as our bootloader might loop indefinitely.
timeout 2s qemu-system-i386 \
    -drive format=raw,file=$FINAL_IMAGE \
    -serial file:$LOG_FILE \
    -monitor none \
    -display none \
    -device isa-debug-exit,iobase=0x501,iosize=1 > /dev/null 2>&1 || true

echo "QEMU run finished. Contents of $LOG_FILE:"
if [ -f "$LOG_FILE" ]; then
    cat "$LOG_FILE"
else
    echo "(log file not found)"
fi
