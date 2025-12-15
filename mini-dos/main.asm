; main.asm for mini-dos

bits 16
cpu 8086
org 0

; --- Constants ---
COM1 equ 0x3F8 ; I/O port for character output (COM1)

; --- Memory Layout ---
; Interrupt Vector Table (IVT)
IVT_PHYSICAL_ADDRESS     equ 0x00000
IVT_START_SEGMENT        equ 0x0000
IVT_START_OFFSET         equ 0x0000

; COMMAND.COM Memory Layout
COMMAND_PHYSICAL         equ 0x01000
COMMAND_SEGMENT          equ 0x0100
COMMAND_OFFSET           equ  0x0000

COMMAND_PSP_PHYSICAL     equ 0x01000
COMMAND_PSP_SEGMENT      equ 0x0100
COMMAND_PSP_OFFSET       equ  0x0000

COMMAND_COM_PHYSICAL     equ 0x01100
COMMAND_COM_SEGMENT      equ 0x0100
COMMAND_COM_OFFSET       equ  0x0100

; Kernel Memory Layout
KERNEL_PHYSICAL          equ 0x11000
KERNEL_SEGMENT           equ 0x1100
KERNEL_OFFSET            equ  0x0000
KERNEL_STACK_INIT_OFFSET equ  0xEFF0

; ===================================================================
; This is the start of the 128KB image file.
; First, we pad until the physical address for COMMAND.COM
; ===================================================================
times COMMAND_PHYSICAL - ($ - $$) db 0
incbin "COMMAND.COM"
COMMAND_COM_END:


; ===================================================================
; OS Code Section
; Placed at 0x1F000, which is where the reset_vector jumps.
; ===================================================================
times KERNEL_PHYSICAL - ($ - $$) db 0
kernel:

reset_handler:
    cli                         ; Disable interrupts

    ; --- Setup our own stack ---
    mov ax, KERNEL_SEGMENT
    mov ss, ax
    mov sp, KERNEL_STACK_INIT_OFFSET

    ; --- Print booting message ---
    mov ax, KERNEL_SEGMENT
    mov ds, ax
    mov si, boot_msg - KERNEL_PHYSICAL
    call print_string_com1

hang:
    jmp hang ; Infinite loop to halt CPU

    ; --- Data ---
    boot_msg db "oBooting kernel...", 0

print_string_com1:
    push ax
    push si
    push dx
    push bx ; Save bx as well

.loop:
    lodsb                   ; Load byte from DS:SI into AL, increment SI
    test al, al             ; Check if AL is null terminator
    jz .done                ; If null, string is finished
    mov bl, al              ; Save the character in BL

.wait_for_com1:
    mov dx, COM1 + 5        ; Load the correct port number into dx
    in al, dx               ; Get Line Status Register (LSR)
    test al, 0x20           ; Check if Transmitter Holding Register Empty (THRE) bit (bit 5) is set
    jz .wait_for_com1       ; If not set, wait

    mov dx, COM1
    mov al, bl              ; Restore the character to AL
    out dx, al              ; Output character to COM1 data port
    jmp .loop

.done:
    pop bx ; Restore bx
    pop dx
    pop si
    pop ax
    ret

; ---------------------------------
; Interrupt Handlers
; ---------------------------------


; ===================================================================
; Reset Vector
; Placed at 1FFF0h, which is mirrored to FFFF0h.
; ===================================================================
times 0x1FFF0 - ($ - $$) db 0
reset_vector:
    jmp KERNEL_SEGMENT:KERNEL_OFFSET

; ===================================================================
; Padding to ensure the final image is exactly 128KB (0x20000 bytes)
; ===================================================================
times 0x20000 - ($ - $$) db 0
