#!/usr/bin/env python3
import sys
import time
import struct
import serial
import argparse
from xmodem import XMODEM

def main():
    """
    Main function to run the V30 test automation.
    - Sends 'autotest' command to the Pico.
    - Uploads a binary file via XMODEM.
    - Receives a binary log back via XMODEM.
    - Decodes and prints the log.
    """
    parser = argparse.ArgumentParser(description='V30 Test Runner for Pico Monitor')
    parser.add_argument('--port', default='/dev/ttyACM0', help='Serial port for the Pico')
    parser.add_argument('--baud', default=115200, type=int, help='Serial baud rate')
    parser.add_argument('--binfile', required=True, help='V30 binary file to upload')
    args = parser.parse_args()

    try:
        ser = serial.Serial(args.port, args.baud, timeout=1)
    except serial.SerialException as e:
        print(f"Error: Could not open serial port {args.port}: {e}")
        sys.exit(1)

    xm = XMODEM(lambda size, timeout=1: ser.read(size) or None,
                lambda data, timeout=1: ser.write(data))

    print(f"--- V30 Auto Test System (Port: {args.port}) ---")

    # 1. Send 'autotest' command to Pico
    ser.reset_input_buffer()
    ser.write(b'\r\nautotest\r\n')
    ser.flush()
    print(">>> Sent 'autotest' command. Waiting for Pico to be ready...")

    # 2. Send the V30 binary file
    try:
        with open(args.binfile, 'rb') as f:
            print(f">>> Uploading {args.binfile}...")
            if not xm.send(f, quiet=False):
                print(">>> Upload Failed. Aborting.")
                ser.close()
                sys.exit(1)
            print(">>> Upload Success.")
    except FileNotFoundError:
        print(f"Error: Binary file not found at '{args.binfile}'")
        ser.close()
        sys.exit(1)

    # 3. Receive the binary log data
    print(">>> V30 is running... Waiting for binary log back...")
    log_buffer = bytearray()
    
    # Give Pico a moment to switch from Rx to Tx
    time.sleep(0.5) 
    
    if not xm.recv(lambda data: log_buffer.extend(data) or True, quiet=False):
        print(">>> Log Receive Failed. Pico may not have sent anything.")
    else:
        print(f">>> Log Received. Total bytes: {len(log_buffer)}")

    # 4. Decode and print the log
    print("\n=== Execution Log (Decoded on PC) ===")
    print(f"{ 'Cycle':<6} | { 'Address':<7} | { 'Type':<6} | { 'Data':<6} |")
    print("-" * 40)

    LOG_ENTRY_SIZE = 8  # sizeof(BusLog) in C++
    count = 0
    for i in range(0, len(log_buffer), LOG_ENTRY_SIZE):
        chunk = log_buffer[i:i+LOG_ENTRY_SIZE]
        if len(chunk) < LOG_ENTRY_SIZE:
            continue
        
        try:
            addr, data, btype, _ = struct.unpack('<IHBB', chunk)
        except struct.error:
            break
        
        type_str = ["MEM_RD", "MEM_WR", "IO_RD", "IO_WR"][btype & 0x03]
        print(f"{count:<6} | {addr:05X}   | {type_str:<6} | {data:04X}   |")
        count += 1
    
    print("-" * 40)
    print(f"Total cycles logged: {count}")
    ser.close()

if __name__ == "__main__":
    main()
