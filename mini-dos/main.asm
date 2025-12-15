; main.asm for mini-dos

bits 16
cpu 8086
org 0

; --- Interrupt Vector Table (IVT) ---
%assign i 0
%rep 255
    dw isr_%+i - KERNEL_PHYSICAL
    dw KERNEL_SEGMENT
%assign i i+1
%endrep
; Fill the rest of the IVT with null pointers, up to 256 entries total
times (256 * 4) - ($ - $$) db 0


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

    ; --- Set up environment for COMMAND.COM ---
    mov ax, COMMAND_SEGMENT ; 0x0100
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0xFFFE          ; Standard stack pointer for .COM programs

    sti

    ; --- Jump to COMMAND.COM ---
    jmp COMMAND_COM_SEGMENT:COMMAND_COM_OFFSET

    ; --- Data ---
    boot_msg db "oBooting kernel...", 13, 10, 0
    current_psp dw 0


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
%macro GEN_INT_HANDLER 1
isr_%1:
    push ax
    push cx
    push dx
    push bx
    push sp
    push bp
    push si
    push di

    mov bp, sp ; Use BP for stack addressing

    ; Set segment register for logging
    mov ax, KERNEL_SEGMENT
    mov ds, ax

    ; Print "Interrupt 0xXX"
    mov si, msg_prefix - KERNEL_PHYSICAL
    call print_string_com1
    mov al, %1
    call print_al_hex

    %if %1 == 0x21
        ; For INT 21h, print AH
        mov si, msg_suffix_int21 - KERNEL_PHYSICAL ; " called, AH="
        call print_string_com1
        
        mov bl, byte [bp + 14 + 1] ; Original AH from stack
        mov al, bl
        call print_al_hex

        ; --- INT 21h sub-function handling ---
        cmp bl, 0x02
        je .int21_ah02

        cmp bl, 0x49
        je .int21_ah49

        cmp bl, 0x50
        je .int21_ah50
        
        jmp .int21_done ; Default: do nothing

    .int21_ah02:
        ; AH=02h: Log DL
        mov si, msg_dl_suffix - KERNEL_PHYSICAL ; ", DL="
        call print_string_com1
        mov bl, byte [bp + 10] ; Original DL from stack
        mov al, bl
        call print_al_hex
        jmp .int21_done

    .int21_ah49:
        ; AH=49h: Free Memory. ES has segment.
        ; No action needed for stub.
        jmp .int21_done

    .int21_ah50:
        ; AH=50h: Set PSP. BX has new PSP segment.
        mov ax, [bp + 8] ; Original BX from stack
        mov [current_psp - KERNEL_PHYSICAL], ax
        ; no jmp needed, falls through

    .int21_done:

    %else
        ; For other interrupts
        mov si, msg_suffix_general - KERNEL_PHYSICAL ; " called"
        call print_string_com1
    %endif

    ; Print CR+LF
    mov si, msg_crlf - KERNEL_PHYSICAL
    call print_string_com1

    ; Return success by clearing carry flag on stack
    and word [bp + 20], 0xFFFE

    pop di
    pop si
    pop bp
    pop sp
    pop bx
    pop dx
    pop cx
    pop ax
    iret
%endmacro

%assign i 0
%rep 255
  GEN_INT_HANDLER i
%assign i i+1
%endrep

; --- Interrupt handler helper functions and data ---
msg_prefix db 'oInterrupt 0x', 0
msg_suffix_general db ' called', 0
msg_suffix_int21 db ' called, AH=', 0
msg_dl_suffix db ', DL=', 0
msg_crlf db 13, 10, 0

print_al_hex:
    ; Prints AL as a two-digit hex number.
    ; Clobbers: none
    push ax
    push cx
    mov ah, al ; save original al

    ; high nibble
    mov cl, 4
    shr al, cl
    call print_nibble_from_al

    ; low nibble
    mov al, ah
    and al, 0x0f
    call print_nibble_from_al

    pop cx
    pop ax
    ret

print_nibble_from_al:
    ; Prints low nibble of AL as a hex character.
    ; Clobbers: none
    push ax
    cmp al, 10
    jl .is_digit
    ; it's a letter
    sub al, 10
    add al, 'A'
    jmp .print
.is_digit:
    add al, '0'
.print:
    call print_char_com1
    pop ax
    ret

print_char_com1:
    ; Prints character in AL to COM1.
    ; Clobbers: none
    push ax
    push dx
    mov ah, al ; save char

.wait:
    mov dx, COM1 + 5
    in al, dx
    test al, 0x20
    jz .wait

    mov al, ah ; restore char
    mov dx, COM1
    out dx, al

    pop dx
    pop ax
    ret


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
