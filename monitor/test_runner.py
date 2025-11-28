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

    # Wait for the specific "Ready to RECEIVE" message from the Pico
    # to ensure it's in the correct state.
    ready_message = b"Ready to RECEIVE XMODEM (CRC)..."
    full_response = b""
    # Set a timeout for the initial readiness check
    original_timeout = ser.timeout
    ser.timeout = 2 # 2-second timeout for readline

    for i in range(5): # Total timeout ~10s
        line = ser.readline()
        if line:
            # Print for debugging purposes
            sys.stdout.buffer.write(line)
            sys.stdout.buffer.flush()
            full_response += line
            if ready_message in full_response:
                print(">>> Pico is ready. Proceeding with XMODEM upload...")
                ser.reset_input_buffer() # Clear input buffer before starting XMODEM
                break
        else:
            # Timeout on readline
            print(f">>> Waiting for Pico... (attempt {i+1}/5)")
    
    ser.timeout = original_timeout # Restore original timeout

    if ready_message not in full_response:
        print("\n>>> Timeout or error: Pico did not become ready for XMODEM transfer.")
        ser.close()
        sys.exit(1)

    # 2. Send the V30 binary file
    try:
        with open(args.binfile, 'rb') as f:
            print(f">>> Uploading {args.binfile}...")
            # The xmodem library will now handle the 'C' handshake on a clean line.
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

    # Corresponds to enum LogType in C++
    type_map = {
        1: "MEM_RD",
        2: "MEM_WR",
        3: "IO_RD",
        4: "IO_WR",
    }

    LOG_ENTRY_SIZE = 8  # sizeof(BusLog) in C++
    count = 0
    for i in range(0, len(log_buffer), LOG_ENTRY_SIZE):
        chunk = log_buffer[i:i+LOG_ENTRY_SIZE]
        if len(chunk) < LOG_ENTRY_SIZE:
            continue
        
        try:
            # < = Little-endian, I = uint32, H = uint16, B = uint8
            addr, data, btype, _ = struct.unpack('<IHBB', chunk)
        except struct.error:
            break
        
        # Type 0 is an unused entry, so we can stop.
        if btype == 0:
            break

        type_str = type_map.get(btype, "???")
        print(f"{count:<6} | {addr:05X}   | {type_str:<6} | {data:04X}   |")
        count += 1
    
    print("-" * 40)
    print(f"Total valid cycles logged: {count}")

if __name__ == "__main__":
    main()
