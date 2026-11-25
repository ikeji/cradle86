# Target boot image file
TARGET = boot.img

# Target boot disk
DISK_TARGET = disk.img

# Source system files
VM_IO = ../HIDOS/BUILD/BIN/VM_IO.SYS
MSDOS = ../HIDOS/BUILD/BIN/MSDOS.SYS
DISK_FILES = ../HIDOS/BUILD/BIN/COMMAND.COM \
						 ../HIDOS/BUILD/BIN/CHKDSK.COM \
						 ../HIDOS/BUILD/BIN/DEBUG.COM \
						 ../HIDOS/BUILD/BIN/DISKCOPY.COM \
						 ../HIDOS/BUILD/BIN/EDLIN.COM \
						 ../HIDOS/BUILD/BIN/EXE2BIN.EXE \
						 ../HIDOS/BUILD/BIN/FC.EXE \
						 ../HIDOS/BUILD/BIN/FIND.EXE \
						 ../HIDOS/BUILD/BIN/FORMAT.COM \
						 ../HIDOS/BUILD/BIN/HRDDRV.SYS \
						 ../HIDOS/BUILD/BIN/MORE.COM \
						 ../HIDOS/BUILD/BIN/PRINT.COM \
						 ../HIDOS/BUILD/BIN/PROFIL.COM \
						 ../HIDOS/BUILD/BIN/RECOVER.COM \
						 ../HIDOS/BUILD/BIN/SORT.EXE \
						 ../HIDOS/BUILD/BIN/SYS.COM \
						 ../HIDOS/BUILD/MASM.EXE \
						 ../HIDOS/BUILD/LINK.EXE \
						 SANITY.COM \
						 MANDEL.COM \
						 LIFE.COM \
						 ../tiny-vi-clone/vi.exe \
						 ../tiny-vi-clone/vi-quiet.exe \
						 ../sha1sum/sha1sum.exe \
						 ../sha1sum/crc32sum.exe

# --- Configuration based on idea.md ---

# Image size: 128KB
IMG_SIZE_BYTES = 131072

# Memory addresses (in decimal)
ADDR_VM_IO = 65536      # 0x10000

.PHONY: all clean bootdisk

all: bootimg bootdisk

bootimg: $(TARGET)
bootdisk: $(DISK_TARGET)

$(TARGET): $(VM_IO) $(MSDOS)
	@echo "Creating boot image: $(TARGET) (size: $(IMG_SIZE_BYTES) bytes)..."

	# 1. Create a 128KB zero-filled image file.
	dd if=/dev/zero of=$(TARGET) bs=1 count=0 seek=$(IMG_SIZE_BYTES)

	# 2. Place VM_IO.SYS at its designated address.
	@echo "  -> Placing $(VM_IO) at address 0x$(shell printf '%X' $(ADDR_VM_IO))"
	dd if=$(VM_IO) of=$(TARGET) bs=1 seek=$(ADDR_VM_IO) conv=notrunc

	# 3. Calculate the position for MSDOS.SYS and place it right after VM_IO.SYS.
	@VMSIZE=$$((`stat -c %s $(VM_IO)`)); \
	MSDOS_OFFSET=98304; \
	echo "  -> Placing $(MSDOS) at address 0x$$(printf '%X' $$MSDOS_OFFSET)"; \
	dd if=$(MSDOS) of=$(TARGET) bs=1 seek=$$MSDOS_OFFSET conv=notrunc

	# The reset JMP and the INT 86h handler are in the firmware's ROM at
	# FFFF0h, and the firmware sets the INT 86h vector (main.cpp hidos_rom).

	@echo "Boot image created successfully."

# --- Boot Disk Creation based on idea.md ---
$(DISK_TARGET): $(DISK_FILES)
	@echo "Creating boot disk: $(DISK_TARGET)..."
	# 1. Create a 1.44MB empty disk image.
	dd if=/dev/zero of=$(DISK_TARGET) bs=4096 count=256
	# 2. Format with FAT12 as per idea.md's hint.
	/sbin/mkfs.fat -S 4096 -F 12 $(DISK_TARGET)
	# 3. Copy system files to the image's root directory.
	#    Upper-case 8.3 names, so that mtools adds no long-name entries.
	for f in $(DISK_FILES); do \
		mcopy -i $(DISK_TARGET) $$f ::$$(basename $$f | tr a-z A-Z) || exit 1; \
	done
	@echo "Boot disk created successfully."

# cradle86 sanity check and demos (run on the DOS console)
SANITY.COM: sanity.asm
	nasm -f bin -o $@ $<

MANDEL.COM: mandel.asm
	nasm -f bin -o $@ $<

LIFE.COM: life.asm
	nasm -f bin -o $@ $<

# Prebuilt DOS tools from submodules (git submodule update --init)
../tiny-vi-clone/%.exe ../sha1sum/%.exe:
	git -C .. submodule update --init $(firstword $(subst /, ,$(patsubst ../%,%,$@)))

$(VM_IO):
	make -C ../HIDOS dos

../HIDOS/BUILD/BIN/COMMAND.COM:
	make -C ../HIDOS dos

clean:
	@echo "Cleaning up..."
	rm -f $(TARGET) $(DISK_TARGET) SANITY.COM MANDEL.COM LIFE.COM
	@echo "Done."
