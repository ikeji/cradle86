bits 16

; --- Constants used in macro ---
COM1                    equ 0x3F8

; --- Macro for logging to COM1 ---
%macro print_char 1
    mov al, %1
    mov dx, COM1
    out dx, al
%endmacro

org 0x7C00

; --- Other Constants ---
BOOTLOADER_RELOCATE_SEG equ 0x9000
STACK_SEG               equ 0x9000
STACK_PTR               equ 0xFC00

MINIDOS_TEMP_LOAD_SEG   equ 0x2000 ; Physical 0x20000
MINIDOS_FINAL_LOAD_SEG  equ 0x0000 ; Physical 0x00000
MINIDOS_LOAD_OFF        equ 0x0000
MINIDOS_SECTORS_TO_READ equ 1 ; Test with a single sector first
MINIDOS_START_SECTOR    equ 2
FLOPPY_DRIVE_NUMBER     equ 0x00

OS_JUMP_SEG             equ 0x1FFF
OS_JUMP_OFF             equ 0x0000

; ==============================================================================
; Execution starts here
; ==============================================================================
start:
    print_char 'B' ; Booting

    ; Ensure DS points to the bootloader's load address (0x7C00).
    mov ax, 0x07C0
    mov ds, ax
    
    ; --- Step 2: Relocate bootloader to 0x90000 ---
    print_char '1'
    mov ax, BOOTLOADER_RELOCATE_SEG
    mov es, ax
    xor di, di
    xor si, si
    mov cx, 256
    rep movsw
    print_char '2'

    ; Jump to the relocated code.
    jmp BOOTLOADER_RELOCATE_SEG:(relocated_code - start)

; ==============================================================================
; Code runs from the new address (0x90000)
; ==============================================================================
relocated_code:
    ; --- Step 1: Initialize stack ---
    print_char 'S'
    
    cli
    print_char 'c' ; cli done

    mov ax, BOOTLOADER_RELOCATE_SEG
    mov ds, ax
    print_char 'd' ; ds set

    mov es, ax
    print_char 'e' ; es set

    mov ss, ax
    mov sp, STACK_PTR
    print_char 's' ; ss:sp set

    sti
    print_char 'i' ; sti done

    ; --- Step 3: Load mini-dos.img to temporary location ---
    print_char 'L'
    mov ah, 0x02
    mov al, MINIDOS_SECTORS_TO_READ
    mov ch, 0
    mov cl, MINIDOS_START_SECTOR
    mov dh, 0
    mov dl, FLOPPY_DRIVE_NUMBER
    mov bx, MINIDOS_TEMP_LOAD_SEG ; Load to 0x20000
    mov es, bx
    mov bx, MINIDOS_LOAD_OFF
    
    int 0x13
    jc load_error
    print_char 'C' ; Load Complete

    ; --- Step 3.5: Copy from temporary to final location ---
    print_char 'M' ; Move Start
    mov ax, MINIDOS_TEMP_LOAD_SEG
    mov ds, ax
    mov si, MINIDOS_LOAD_OFF
    
    mov ax, MINIDOS_FINAL_LOAD_SEG
    mov es, ax
    mov di, MINIDOS_LOAD_OFF

    mov cx, 0 ; For 16-bit, 0 means 65536 iterations for rep
    rep movsw ; Copy 128KB (65536 words)
    print_char 'D' ; Move Done

    ; Restore DS to our code segment before continuing
    mov ax, BOOTLOADER_RELOCATE_SEG
    mov ds, ax

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
    mov dx, COM1
    out dx, al
    jmp print_err_loop

halt_system:
    cli
    hlt

err_msg: db ':LOAD', 0

; --- Padding and Boot Signature ---
times 510 - ($ - $$) db 0
dw 0xAA55