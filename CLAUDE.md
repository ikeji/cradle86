# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

cradle86 is a single-board computer built from a real NEC V30 (μPD70116, 8086-compatible) CPU driven at 3.3V by a Raspberry Pi Pico (RP2040). The Pico has no external RAM chip behind it: it **is** the memory and I/O system. It bit-bangs the V30 bus from Core 1 and serves reads/writes out of a 128KB array in Pico SRAM. The end goal is booting MS-DOS 2.11 (via the HIDOS submodule) on the V30.

Most docs and commit messages are in Japanese. Commit messages follow the `feat:` / `fix:` / `perf:` / `refactor:` prefix style, with the description in Japanese.

## Directory roles

- `monitor/`: Pico firmware. It is built with the Pico SDK via CMake into `v30_control.uf2`. `main.cpp` holds the bus engines, the HIDOS VM I/O and the monitor. `usb_ports.c`, `usb_descriptors.c` and `tusb_config.h` implement the 4-port USB CDC. The directory also holds the host-side test tooling (`test_runner.py`, expect scripts, small V30 test programs). `project.md` has the pin map and the monitor command list. `memaccess.md` explains the bus read/write algorithm. `gpio_clock.md` records the GPIO clock engine's measured V30 timing limits, benchmarks and overclock notes.
- `embedded-hidos/`: builds the two images that get embedded into the firmware. `boot.img` is the 128KB RAM image with VM_IO.SYS, MSDOS.SYS, the reset vector and the INT 86h trampoline. `disk.img` is a FAT12 disk with the DOS utilities and `SANITY.COM` (built from `sanity.asm`, a self-test to run on the DOS console). Its layout spec is in `idea.md`.
- `HIDOS/`: git submodule (`git@github.com:ikeji/HIDOS.git`), an MS-DOS 2.11 build that is cross-compiled on Linux. `make -C HIDOS dos` produces `HIDOS/BUILD/BIN/*.SYS/*.COM`. `HIDOS/hidosvm/` is the reference PC-side VM; its `common.c` is the origin of the I/O handlers in `main.cpp`.
- `mini-dos/`: an earlier, hand-written NASM mini DOS kernel (INT 21h stubs) for running COMMAND.COM. It can be run in QEMU. Superseded by the HIDOS path but still used as a test image (`make run-mini-dos*` in monitor).
- `com1test/`: tiny NASM boot sector for testing serial output under QEMU/Bochs.
- `cradle86pcb/`: KiCad project. `gen.py` generates `place.py`, a component-placement dict used by a layout plugin: `python3 gen.py > place.py`.
- `case/case.js`: JSCAD script for the enclosure.

## Build & run commands

Toolchain: `nasm`, `ndisasm`, `bcc`/`ld86` (dev86), `expect`, `lrzsz` (`sx`/`rx`), `mtools` and `mkfs.fat`, plus the Pico SDK (`PICO_SDK_PATH`, which defaults to `~/tmp/pico-sdk` in `monitor/Makefile`). HIDOS also needs `gcc-multilib` and `libx86emu-dev` (`make -C HIDOS init`).

Firmware (run from `monitor/`):
```
make build/v30_control.uf2     # builds embedded-hidos images (and HIDOS if needed), then cmake+make into build/
make flash                     # copies the uf2 to the mounted Pico (sudo mount; MOUNT_DEVICE is hardcoded for one board)
```
Instead of power-cycling with BOOTSEL held, use the monitor command `b` to reboot into BOOTSEL (or open the monitor port at 1200 baud).

HIDOS: `h` in the monitor, with a terminal on USB port 1 for the DOS console. For a read/write B: drive, run `make disk-server` (`disk_server.py`, needs pyserial; it creates an empty `b.img`). Use `DISK_IMG=<directory>` to serve a PC directory instead: the server builds a FAT12 image of it in memory and writes what DOS changes back to the files. Run `SANITY` in DOS to self-test the CPU, memory, clock, AUX, A: and B:. `SANITY.COM` can be checked without hardware in `HIDOS/hidosvm`.

Test programs run on real hardware. The Pico must be on `/dev/ttyACM0`:
```
make run            # nasm test.asm -> test.bin, upload via XMODEM, run, fetch full bus log
make run-c          # bcc test-c.c -> 64KB image with reset_vec.asm at 0xFFF0
make run-io-c       # same, I/O-only log
make run-mini-dos   # run ../mini-dos/mini-dos.img, COM2 log mode
python3 test_runner.py --binfile X.bin --mode {full,io,com,com2}
make disasm-asm / disasm-c
```
There is no unit-test suite. "Tests" mean running a binary on the physical V30 and reading the bus/I/O trace that `test_runner.py` prints.

Images:
```
make -C embedded-hidos all     # boot.img + disk.img (needs HIDOS built)
make -C HIDOS dos              # cross-build MS-DOS
make -C mini-dos run           # build mini-dos and run it in QEMU, decoding the serial log via tools/log_parser.py
```

## Firmware architecture (monitor/main.cpp)

- **Dual core split.** Core 0 runs the monitor REPL (`main()`) and all USB work. Core 1 (`core1_entry`) blocks on the multicore FIFO for a `CMD_RUN_*` command, runs the V30 until it stops, sets `core1_exit` and pushes a completion word back. Core 0 waits with `wait_core1()`, never `multicore_fifo_pop_blocking()`, so USB keeps being serviced.
- **USB is core-0 only, without IRQs.** `pico_stdio_usb` is disabled. `usb_ports.c` registers its own stdio driver on CDC port 0, and `tud_task()` runs from `usb_background()`, which is called whenever stdio waits for input. That loop also drives `hidos_service()`. TinyUSB is not thread safe, so **core 1 must never printf**. Report through `core1_exit` instead.
- **Two bus engines** (`clock_mode`, monitor command `c`):
  - `CLOCK_GPIO` (default): core 1 generates CLK itself and walks each bus cycle with straight-line code, T1 to T4 (READY is tied high). HIDOS mode runs the hand-scheduled assembly copy `gpio_hidos.S` (~10MHz; each phase's instruction cycles are listed as `W=` there and must match `gpio_asm_work[]` in main.cpp, so changing the asm means recounting), and the logging modes run the C `gpio_bus_run()`. It latches the address at T1, drives read data at T3, latches write data at T3 and releases the bus at the T4 falling edge (holding it longer fights the V30). The clock stretches while the Pico is busy, so it can never miss a cycle. `c g addr low high` sets the minimum CLK widths in ns (the asm pads each phase to exactly that, the C engine adds them on top); `c p` overrides one asm phase's spin count for tuning. The measured V30 limits are in `monitor/gpio_clock.md`. `c s <MHz>` overclocks the Pico (boot2 runs flash at sys/4, and the core voltage is raised above 250MHz). The engine runs from RAM, with one `__not_in_flash_func` wrapper per mode.
  - `CLOCK_PWM` (legacy), `pwm_bus_run()` / `pwm_hidos_cpu()`: free-running PWM clock with a polling loop. It needs the `sleep_us(3)`/`tiny_delay()` before driving the bus (the board browns out without it).
  - Read cycles drive the word-aligned 16-bit value and let the CPU pick bytes via A0/BHE#. Writes honor A0/BHE#. Keep printf and SDK calls out of the hot loops.
- **Address mirroring.** `map_address()` masks with `RAM_SIZE-1` (128KB), so RAM repeats across the 1MB space. The reset vector at FFFF0h is therefore served from 1FFF0h. Every image (mini-dos, boot.img, test-c.bin) relies on this and places its reset `JMP` at the end of its image.
- **Logging modes.** FULL, IO, COM (only port 0x2F8 = COM2) and NOLOG fill `trace_log[MAX_CYCLES]`, which `xl`/`autotest` send back over XMODEM. `test_runner.py` drives `autotest` and decodes the log.
- **HIDOS VM mode** (monitor `h [loglevel]` starts it in the background, `s` stops it). It loads the embedded `boot.img` into RAM, and core 1 runs the bus engine in HIDOS mode. The guest's VM_IO.SYS calls `INT 86h`, whose trampoline at 1FFF5h does `OUT 86h, AX` with the paragraph address of a request block, then polls `IN 88h` until it reads 0. Core 1 hands the value to core 0 through `io_value`/`io_running`. Core 0's `hidos_service()` runs `vmio()`, which dispatches on 2-char device/cmd codes (`IN`, `DI`, `CO`, `AU`, `CL`, `PR`) mirroring `HIDOS/hidosvm/common.c` (spec in `HIDOS/hidosvm/hidosvm.txt`). It clears `io_running` when the request is done; a request may stay pending across calls.
- **USB ports:** 0 is the monitor; 1 is `CO` (DOS console); 2 is `AU` (AUX/COM); 3 is the disk server. A: is always the read-only embedded `disk.img`. B: is always the disk served by `disk_server.py` on port 3 (an image file, or a directory turned into an in-memory FAT12 image whose changes it syncs back; this is all on the PC side) (async state machine `disk_poll()`; the protocol is documented in both files). Without the server, B: is not ready, but its boot sector read is answered from A:, because VM_IO.SYS halts at boot if any drive's BPB can't be read. The server connecting or disconnecting is reported to DOS as a media change on B:. MSDOS.SYS's load address is fixed at 0x18000. If you change it, `embedded-hidos/Makefile` (`MSDOS_OFFSET`) and `io_init` must stay in sync.
- **Embedded images.** `CMakeLists.txt` copies `disk.img` and `boot.img` into the build dir and converts them with `arm-none-eabi-objcopy` into `_binary_*_img_start/_end` symbols linked into the firmware.

## Hardware notes

- Pin map (also in `project.md`): GP0-15 = AD0-15, GP16 ALE, GP17 RD#, GP18 WR#, GP19 IO/M#, GP20 BHE#, GP21 CLK out (PWM, `c` command, `freq_table`), GP22 RESET, GP26-29 = A16-19. The V30 runs in minimum mode with READY tied high, and NMI/INTR/HOLD are tied low. There are no hardware interrupts, so the HIDOS console is polled.
- The Pico must never drive the AD bus outside the RD# phase, or it will fight the V30. 330Ω series resistors are on the AD lines for protection.
