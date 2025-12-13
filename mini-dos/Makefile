# Makefile for mini-dos

# Tools
NASM = nasm
CAT = cat

# Source Files
BOOT_SRC = boot.asm
KERNEL_SRC = main.asm
COMMAND_COM = COMMAND.COM

# Target Files
BOOT_BIN = boot.bin
MINIDOS_IMG = mini-dos.img  # This is the OS kernel + COMMAND.COM
FINAL_IMAGE = bootable.img  # The final bootable floppy image

# Build Options
NASM_FLAGS = -f bin
IMAGE_SIZE = 131072 # 128KB

# Default target
all: $(FINAL_IMAGE)

# Final bootable image
$(FINAL_IMAGE): $(BOOT_BIN) $(MINIDOS_IMG)
	$(CAT) $(BOOT_BIN) $(MINIDOS_IMG) > $(FINAL_IMAGE)

# Bootloader binary
$(BOOT_BIN): $(BOOT_SRC)
	$(NASM) $(NASM_FLAGS) -o $(BOOT_BIN) -l boot.lst $(BOOT_SRC)

# mini-dos image (kernel + command.com)
# This part remains unchanged as requested.
$(MINIDOS_IMG): $(KERNEL_SRC) $(COMMAND_COM)
	$(NASM) $(NASM_FLAGS) -o $(MINIDOS_IMG) -l mini-dos.lst $(KERNEL_SRC)
	@# Pad the image to 128KB if it's smaller
	@truncate -s $(IMAGE_SIZE) $(MINIDOS_IMG)

# Run with QEMU
run: $(FINAL_IMAGE)
	./run-qemu.sh
# Clean up
clean:
	rm -f $(BOOT_BIN) boot.lst $(MINIDOS_IMG) mini-dos.lst $(FINAL_IMAGE) qemu.log

# phony targets
.PHONY: all run clean

