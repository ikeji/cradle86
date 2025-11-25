# V30 on Pico development Makefile

# --- Configuration ---
ASM       = nasm
PYTHON    = python3
RUNNER    = ./test_runner.py

SRC_ASM   = test.asm
TARGET_BIN= test.bin

# Adjust to your Pico's serial port. Use `ls /dev/ttyACM*` to find it.
PORT      = /dev/ttyACM0

# Adjust to your Pico's mass storage device and desired mount point when in bootloader mode.
MOUNT_DEVICE = /dev/sdb1
MOUNT_POINT  = /mnt/pico

.PHONY: all run clean flash

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
#       The device (/dev/sdb1) and mount point (/mnt) are examples and
#       may need to be adjusted for your system.
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
	cd build && cmake .. && make
	@echo "--- Firmware build complete. ---"
