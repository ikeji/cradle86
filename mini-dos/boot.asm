bits 16
org 0x7C00

; --- Constants ---
COM1                    equ 0x3F8
BOOTLOADER_RELOCATE_SEG equ 0x9000
STACK_SEG               equ 0x9000
STACK_PTR               equ 0xFC00

MINIDOS_LOAD_SEG        equ 0x0000
MINIDOS_LOAD_OFF        equ 0x0000
MINIDOS_SECTORS_TO_READ equ 255
MINIDOS_START_SECTOR    equ 2
FLOPPY_DRIVE_NUMBER     equ 0x00

OS_JUMP_SEG             equ 0x1FFF
OS_JUMP_OFF             equ 0x0000

; --- Macro for logging to COM1 ---
; Port address must be in DX for 16-bit ports
%macro print_char 1
    mov al, %1
    mov dx, COM1
    out dx, al
%endmacro

; ==============================================================================
; Execution starts here
; ==============================================================================
start:
    print_char 'B' ; Booting

    ; Ensure DS points to the bootloader's load address (0x7C00).
    ; Many BIOS setups initialize CS=0x0000, IP=0x7C00, so CS might be 0x0000.
    ; Explicitly setting DS ensures correct source for relocation.
    mov ax, 0x07C0
    mov ds, ax
    
    ; ES will be set later for relocation destination, no need to init here.

    ; --- Step 2: Relocate bootloader to 0x90000 ---
    print_char '1'    mov ax, BOOTLOADER_RELOCATE_SEG
    mov es, ax
    xor di, di
    xor si, si
    mov cx, 256
    rep movsw
    print_char '2'

    ; Jump to the relocated code. The offset must be relative to the start
    ; of the bootloader (0x7C00), so we calculate it relative to 'start'.
    jmp BOOTLOADER_RELOCATE_SEG:(relocated_code - start)

; ==============================================================================
; Code runs from the new address (0x90000)
; ==============================================================================
relocated_code:
    ; --- Step 1: Initialize stack ---
    print_char 'S'
    cli
    mov ax, BOOTLOADER_RELOCATE_SEG
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, STACK_PTR
    sti

    ; --- Step 3: Load mini-dos.img ---
    print_char 'L'
    mov ah, 0x02
    mov al, MINIDOS_SECTORS_TO_READ
    mov ch, 0
    mov cl, MINIDOS_START_SECTOR
    mov dh, 0
    mov dl, FLOPPY_DRIVE_NUMBER
    mov bx, MINIDOS_LOAD_SEG
    mov es, bx
    mov bx, MINIDOS_LOAD_OFF
    
    int 0x13
    jc load_error

    ; --- Step 4: Jump to the OS ---
    print_char 'J'
    push word OS_JUMP_SEG
    push word OS_JUMP_OFF
    retf

; --- Error handling routine ---
load_error:
    print_char 'E'
    mov si, err_msg
print_err_loop:
    lodsb
    or al, al
    jz halt_system
    mov dx, COM1 ; Port address must be in DX for 16-bit ports
    out dx, al
    jmp print_err_loop

halt_system:
    cli
    hlt

err_msg: db ':LOAD', 0

; --- Padding and Boot Signature ---
times 510 - ($ - $$) db 0
dw 0xAA55