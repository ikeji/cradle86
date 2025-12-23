# Target boot image file
TARGET = boot.img

# Source system files
VM_IO = VM_IO.SYS
MSDOS = MSDOS.SYS

# --- Configuration based on idea.md ---

# Image size: 128KB
IMG_SIZE_BYTES = 131072

# Memory addresses (in decimal)
ADDR_VM_IO = 65536      # 0x10000
ADDR_JMP = 131056        # 0x1FFF0
ADDR_HANDLER = 131061    # 0x1FFF5
ADDR_VECTOR = 536        # 0x86 * 4

# Machine code sequences
# JMP 1000H:0000H -> EA 00 00 00 10
CODE_JMP = b'\xea\x00\x00\x00\x10'
# OUT 86H, AX; IRET -> E7 86; CF
CODE_HANDLER = b'\xe7\x86\xcf'
# Interrupt vector for INT 86H pointing to 1FFF:0005 (0x1FFF5) -> 05 00 FF 1F
CODE_VECTOR = b'\x05\x00\xff\x1f'


.PHONY: all clean

all: $(TARGET)

$(TARGET): $(VM_IO) $(MSDOS)
	@echo "Creating boot image: $(TARGET) (size: $(IMG_SIZE_BYTES) bytes)..."

	# 1. Create a 128KB zero-filled image file.
	dd if=/dev/zero of=$(TARGET) bs=1 count=0 seek=$(IMG_SIZE_BYTES)

	# 2. Place VM_IO.SYS at its designated address.
	@echo "  -> Placing $(VM_IO) at address 0x$(shell printf '%X' $(ADDR_VM_IO))"
	dd if=$(VM_IO) of=$(TARGET) bs=1 seek=$(ADDR_VM_IO) conv=notrunc

	# 3. Calculate the position for MSDOS.SYS and place it right after VM_IO.SYS.
	@VMSIZE=$$((`stat -c %s $(VM_IO)`)); \
	MSDOS_OFFSET=$$(( $(ADDR_VM_IO) + VMSIZE )); \
	echo "  -> Placing $(MSDOS) at address 0x$$(printf '%X' $$MSDOS_OFFSET)"; \
	dd if=$(MSDOS) of=$(TARGET) bs=1 seek=$$MSDOS_OFFSET conv=notrunc

	# 4. Write the far jump instruction to the reset vector location.
	@echo "  -> Writing JMP instruction at 0x$(shell printf '%X' $(ADDR_JMP))"
	@echo -ne "$(CODE_JMP)" | dd of=$(TARGET) bs=1 seek=$(ADDR_JMP) conv=notrunc

	# 5. Write the interrupt handler (OUT + IRET).
	@echo "  -> Writing INT 86h handler at 0x$(shell printf '%X' $(ADDR_HANDLER))"
	@echo -ne "$(CODE_HANDLER)" | dd of=$(TARGET) bs=1 seek=$(ADDR_HANDLER) conv=notrunc

	# 6. Set the interrupt vector for INT 86h to point to the handler.
	@echo "  -> Writing INT 86h vector at 0x$(shell printf '%X' $(ADDR_VECTOR))"
	@echo -ne "$(CODE_VECTOR)" | dd of=$(TARGET) bs=1 seek=$(ADDR_VECTOR) conv=notrunc

	@echo "Boot image created successfully."

clean:
	@echo "Cleaning up..."
	rm -f $(TARGET)
	@echo "Done."
