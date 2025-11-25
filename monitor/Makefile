# V30 on Pico development Makefile

# --- Configuration ---
ASM       = nasm
PYTHON    = python3
RUNNER    = ./test_runner.py

SRC_ASM   = test.asm
TARGET_BIN= test.bin

# Path to the Pico SDK. Adjust if necessary, or set it as an environment variable.
# The '?=' operator allows this to be overridden from the command line (e.g., make PICO_SDK_PATH=/path/to/sdk)
PICO_SDK_PATH ?= $(HOME)/tmp/pico-sdk

# Adjust to your Pico's serial port. Use `ls /dev/ttyACM*` to find it.
PORT      = /dev/ttyACM0

# Adjust to your Pico's mass storage device and desired mount point when in bootloader mode.
MOUNT_DEVICE = /dev/sdb1
MOUNT_POINT  = /mnt/pico

.PHONY: all run clean flash demo

# --- Main Targets ---

# Default target: build the assembly file
all: $(TARGET_BIN)

# Assemble the source file into a raw binary
$(TARGET_BIN): $(SRC_ASM)
	@echo "--- Assembling $< ---"
	$(ASM) -f bin $(SRC_ASM) -o $(TARGET_BIN)
	@echo "--- Created $@ ---"

# Build and run the full test cycle: upload binary, execute on Pico, get log back
run: $(TARGET_BIN)
	@echo "--- Starting Test Runner ---"
	$(PYTHON) $(RUNNER) --port $(PORT) --binfile $(TARGET_BIN)

# Clean up build artifacts from both the test program and the firmware
clean:
	rm -f $(TARGET_BIN)
	rm -rf build
	@echo "--- Cleaned all build artifacts ---"


# --- Pico Firmware Flashing (Helper) ---

# This target flashes the C++ firmware. If the firmware is not built yet,
# it will be compiled automatically.
# Usage: make flash
# NOTE: The user running 'make' needs sudo permissions for mount/umount.
#       The device and mount point are configured via the MOUNT_DEVICE
#       and MOUNT_POINT variables at the top of this file.
flash: build/v30_control.uf2
	@echo "--- Flashing V30 monitor firmware ---"
	mkdir -p $(MOUNT_POINT)
	sudo mount $(MOUNT_DEVICE) $(MOUNT_POINT) || true
	cp build/v30_control.uf2 $(MOUNT_POINT)
	sudo umount $(MOUNT_POINT) || true
	@echo "--- Flash complete. ---"

# This target builds the firmware if it is missing or if its sources have changed.
build/v30_control.uf2: main.cpp CMakeLists.txt
	@echo "--- Firmware not found or source changed, building... ---"
	mkdir -p build
	cd build && cmake -DPICO_SDK_PATH=$(PICO_SDK_PATH) .. && make
	@echo "--- Firmware build complete. ---"

# --- Demo Target ---
# Runs a sequence of monitor commands directly via serial port.
# Does not load firmware.
DEMO_PORT ?= /dev/ttyACM0
DEMO_BAUD ?= 115200

demo:
	@echo ">>> Starting Demo Sequence on $(DEMO_PORT)"
	@echo ">>> NOTE: If you get permission denied, run 'sudo chmod a+rw $(DEMO_PORT)'"
	@bash -c '\
		exec 3<>$(DEMO_PORT); \
		stty -F $(DEMO_PORT) $(DEMO_BAUD) raw -echo; \
		trap "kill $$CAT_PID 2>/dev/null; exec 3<&-" EXIT; \
		cat <&3 & \
		CAT_PID=$$!; \
		sleep 2; \
		echo -e "\r\na 100\r" >&3; \
		sleep 0.3; echo -e "mov cx, 10\r" >&3; \
		sleep 0.3; echo -e "mov ax, 1\r" >&3; \
		sleep 0.3; echo -e "mov bx, 0\r" >&3; \
		sleep 0.3; echo -e "add ax, bx\r" >&3; \
		sleep 0.3; echo -e "xchg ax, bx\r" >&3; \
		sleep 0.3; echo -e "loop 109\r" >&3; \
		sleep 0.3; echo -e "mov [200], ax\r" >&3; \
		sleep 0.3; echo -e "jmp 111\r" >&3; \
		sleep 0.3; echo -e ".\r" >&3; \
		sleep 0.3; echo -e "\r\nd 100 20\r" >&3; \
		sleep 0.3; echo -e "\r\nl 100 20\r" >&3; \
		sleep 0.5; echo -e "\r\ng\r" >&3; \
		sleep 1; \
		echo -e " \r" >&3; \
		sleep 0.5; echo -e "\r\nd 200 2\r" >&3; \
        sleep 2; \
	'
	@echo ">>> Demo Finished."
