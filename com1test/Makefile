NASM = nasm
QEMU = qemu-system-i386

all: boot.bin

boot.bin: boot.asm
	$(NASM) -f bin boot.asm -o boot.bin

run-qemu: boot.bin
	$(QEMU) \
		-drive format=raw,file=boot.bin \
		-serial stdio \
		-monitor none \
		-display none \
		-device isa-debug-exit,iobase=0x501,iosize=1 ; \
	status=$$? ; \
	code=$$((status >> 1)) ; \
	echo "QEMU exit raw=$$status decoded=$$code" ; \
	exit $$code

clean:
	rm -f boot.bin

