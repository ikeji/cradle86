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
    "A":"Boot disk from bios",
    "B":"Start MBR",
    "C":"Relocated MBR",
    "D":"Start relocated MBR",
    "E":"Setup start segment",
    "F":"Reset Disk",
    "G":"Check status",
    "H":"Read sector",
    "I":"Read sector2",
    "J":"Relocate DOS",
    "K":"Jump to DOS",
    "Z":"",
    "Z":"",
    "r":"Return code",
    "e":"Error code",
    "s":"Success code",
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
                for line_content in log_content.splitlines(): # 改行ごとに分割
                    line_content = line_content.strip() # 行の先頭と末尾の空白文字を削除
                    if not line_content: # 空行はスキップ
                        continue
                    
                    log_type = line_content[0]
                    log_code = line_content[1:] # 種類に続く残りの文字列をコードとする

                    type_description = DECODE_MAP.get(log_type, f"Unknown Type: {log_type}")

                    if log_code: # コードがある場合
                        # コードが数字の場合は0埋め2桁の16進数として表示
                        # 現在のlog_alの出力はR00やE11のようにアルファベットと2桁の16進数なので、
                        # log_codeがそのまま16進数として扱える
                        decoded_string = f"{log_type} : {type_description} (code: {log_code})"
                    else: # コードがない場合
                        decoded_string = f"{log_type} : {type_description}"
                    
                    print(decoded_string)
            print(f"--- End of log ---")

    except IOError as e:
        print(f"Error reading log file '{LOG_FILE}': {e}", file=sys.stderr)
        return 1

    return 0

if __name__ == "__main__":
    sys.exit(main())
