; main.asm for mini-dos

bits 16
org 0

; --- Constants ---
LOG_PORT equ 0xE9   ; I/O port for logging (Bochs/QEMU debug port)
CHAR_OUT_PORT equ 0x3F8 ; I/O port for character output (COM1)

; --- Memory Layout ---
PSP_SEGMENT      equ 0x0100  ; Segment for the Program Segment Prefix (physical 0x1000)
COMMAND_OFFSET   equ 0x0100  ; .COM files start at offset 0x100 in their segment
COMMAND_PHYSICAL equ (PSP_SEGMENT * 16) + COMMAND_OFFSET ; Physical address 0x1100

OS_CODE_START    equ 0x1F000 ; Physical address where our OS code (handlers, etc.) starts
OS_CODE_SEGMENT  equ OS_CODE_START >> 4 ; 0x1F00

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
times OS_CODE_START - ($ - $$) db 0
os_code:

reset_handler:
    cli                         ; Disable interrupts
    
    ; --- Setup our own stack ---
    mov ax, OS_CODE_SEGMENT
    mov ss, ax
    mov sp, 0xFFF0              ; Stack at the top of our 64k segment

    ; --- Log that we have started ---
    mov ax, 0xDEAD
    out LOG_PORT, ax

    ; --- Setup Interrupt Vector Table (IVT) ---
    mov ax, 0
    mov es, ax
    xor di, di
    mov cx, 256
    mov ax, generic_isr         ; offset
    mov bx, OS_CODE_SEGMENT     ; segment
.setup_ivt_loop:
    mov [es:di], ax
    mov [es:di+2], bx
    add di, 4
    loop .setup_ivt_loop
    
    ; --- Setup specific handler for INT 21h ---
    mov ax, dos_api_handler     ; offset
    mov bx, OS_CODE_SEGMENT     ; segment
    mov word [es:0x21*4], ax
    mov word [es:0x21*4+2], bx

    ; --- Setup PSP for COMMAND.COM ---
    mov ax, PSP_SEGMENT
    mov es, ax
    
    xor di, di
    mov cx, 128
    xor ax, ax
    rep stosw ; Clear the 256-byte PSP area

    mov word [es:0x00], 0xCD20 ; INT 20h (Terminate)
    mov word [es:0x02], OS_CODE_SEGMENT ; Top of Memory (exclusive)
    
    ; Set default DTA to PSP+80h. We do this by calling our own INT 21h handler.
    mov ah, 0x1A
    mov dx, 0x80
    ; Set DS to PSP segment before calling INT 21h, as the handler might need it.
    push ds
    mov ds, ax
    int 0x21
    pop ds

    ; --- Prepare to launch COMMAND.COM ---
    sti ; Enable interrupts

    ; A .COM program expects: CS=DS=ES=SS=PSP_SEGMENT, SP=FFFEh (or so)
    ; and execution to start at offset 0x100.
    push word PSP_SEGMENT
    push word COMMAND_OFFSET

    retf ; Far return to start COMMAND.COM

; ---------------------------------
; Interrupt Handlers
; ---------------------------------

; --- Generic Interrupt Service Routine (ISR) ---
generic_isr:
    iret

; --- DOS API (INT 21h) Handler ---
dos_api_handler:
    ; Log AH value (function number) for debugging
    mov bx, ax
    mov ax, 0x2100
    or ah, bh
    out LOG_PORT, ax
    
    cmp ah, 0x02 ; Function 02h: Display Output
    je .dos_display_output
    cmp ah, 0x09 ; Function 09h: Print String
    je .dos_print_string
    cmp ah, 0x1A ; Function 1Ah: Set DTA
    je .dos_set_dta
    cmp ah, 0x30 ; Function 30h: Get DOS Version
    je .dos_get_version
    cmp ah, 0x4C ; Function 4Ch: Exit with return code
    je .dos_exit

    ; --- Unhandled function ---
    stc ; Set Carry Flag to indicate an error
    iret

.dos_display_output: ; AH=02h, DL=char
    mov dx, CHAR_OUT_PORT
    mov al, dl
    out dx, al
    clc
    iret

.dos_print_string: ; AH=09h, DS:DX -> string terminated by '$'
    mov bx, dx
    mov dx, CHAR_OUT_PORT
.print_loop:
    mov al, [ds:bx]
    cmp al, '$'
    je .print_done
    out dx, al
    inc bx
    jmp .print_loop
.print_done:
    clc
    iret

.dos_set_dta: ; AH=1Ah, DS:DX = new DTA
    mov [dta_address_offset], dx
    mov ax, ds
    mov [dta_address_segment], ax
    clc
    iret

.dos_get_version: ; AH=30h
    mov al, 3  ; Major version
    mov ah, 30 ; Minor version (3.30)
    xor bx, bx
    clc
    iret

.dos_exit: ; AH=4Ch, AL=return code
    mov ax, 0xCC00
    or al, [es:0x81] ; Exit code is in command line buffer
    out LOG_PORT, ax
    hlt ; Halt the system

; --- OS Data Area ---
dta_address_offset: dw 0x0080
dta_address_segment: dw PSP_SEGMENT

; ===================================================================
; Reset Vector
; Placed at 1FFF0h, which is mirrored to FFFF0h.
; ===================================================================
times 0x1FFF0 - ($ - $$) db 0
reset_vector:
    jmp OS_CODE_SEGMENT:(reset_handler - os_code)

; ===================================================================
; Padding to ensure the final image is exactly 128KB (0x20000 bytes)
; ===================================================================
times 0x20000 - ($ - $$) db 0