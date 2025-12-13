#!/usr/bin/env python3
#
# log_parser.py - A simple script to parse and display logs from mini-dos.
#
# The emulator is expected to capture I/O writes to the LOG_PORT and append
# them to a binary file, e.g., 'log.bin'.
# This script reads that binary file, interprets the data as a sequence of
# 16-bit words (little-endian), and prints them in hex format.

import sys
import os

LOG_FILE = "log.bin"

def main():
    """Main function to parse and display the log file."""
    if not os.path.exists(LOG_FILE):
        print(f"Log file '{LOG_FILE}' not found.", file=sys.stderr)
        return 1

    try:
        with open(LOG_FILE, "rb") as f:
            log_words = []
            while True:
                word_bytes = f.read(2)
                if not word_bytes:
                    break
                if len(word_bytes) < 2:
                    print(f"Warning: Log file has an odd number of bytes. Ignoring last byte.", file=sys.stderr)
                    break
                
                # Interpret the 2 bytes as a little-endian unsigned short
                word = int.from_bytes(word_bytes, 'little')
                log_words.append(word)

            print(f"--- Log entries from '{LOG_FILE}' ---")
            for i, word in enumerate(log_words):
                print(f"[{i:04d}]: 0x{word:04X}")
            print(f"--- End of log ---")

    except IOError as e:
        print(f"Error reading log file '{LOG_FILE}': {e}", file=sys.stderr)
        return 1

    return 0

if __name__ == "__main__":
    sys.exit(main())
