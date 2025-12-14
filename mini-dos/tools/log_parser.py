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

LOG_FILE = "qemu.log"

DECODE_MAP = {
    'B': "Booting MBR",
    '1': "Start relocating",
    '2': "Finish relocating",
    'S': "Booting relocated MBR",
    'L': "Check discs",
    'R': "Read sectors",
    '4': "Disk Read Error", # Assuming '4C' means '4' followed by 'C' (Continue or another code)
    'C': "Continue/Another code for disk operation",
    'E': "Execution failed",
    'F': "Formatting disk",
    '0': "Success (or other code 0)",
    # Add more mappings as needed from the bootloader's output
}

def main():
    """Main function to parse and display the log file."""
    if not os.path.exists(LOG_FILE):
        print(f"Log file '{LOG_FILE}' not found.", file=sys.stderr)
        return 1

    try:
        with open(LOG_FILE, "r") as f:
            log_content = f.read().strip() # Read as text and remove leading/trailing whitespace

            print(f"--- Log entries from '{LOG_FILE}' ---")
            if not log_content:
                print("(empty log)")
            else:
                for line in log_content.splitlines(): # 改行ごとに分割
                    line = line.strip() # 行の先頭と末尾の空白文字を削除
                    if not line: # 空行はスキップ
                        continue
                    
                    for char in line: # 行内の全ての文字をデコード対象とする
                        decoded_message = DECODE_MAP.get(char, f"Unknown code: {char}")
                        print(f"{char}: {decoded_message}")
            print(f"--- End of log ---")

    except IOError as e:
        print(f"Error reading log file '{LOG_FILE}': {e}", file=sys.stderr)
        return 1

    return 0

if __name__ == "__main__":
    sys.exit(main())
