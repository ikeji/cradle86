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
times COMMAND_COM_PHYSICAL - ($ - $$) db 0
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
    mov ax, COMMAND_PSP_SEGMENT ; 0x0100
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0xFFFE

    ; --- Initialize PSP ---
    ; Clear the PSP area (256 bytes)
    xor ax, ax
    mov di, COMMAND_PSP_OFFSET
    mov cx, 128 ; 128 words = 256 bytes
    rep stosw

    ; INT 20h (Program Terminate) at offset 0
    mov word [es:COMMAND_PSP_OFFSET + 0x00], 0x20CD

    ; Command line at offset 0x80: length=0, terminator=CR
    mov byte [es:COMMAND_PSP_OFFSET + 0x80], 0
    mov byte [es:COMMAND_PSP_OFFSET + 0x81], 0x0D

    sti

    ; --- Jump to COMMAND.COM ---
    jmp COMMAND_COM_SEGMENT:COMMAND_COM_OFFSET

    ; --- Data ---
    boot_msg db "oBooting kernel...", 13, 10, 0
    current_psp dw 0
    saved_ss dw 0
    saved_sp dw 0


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
    cli
    push ax
    push cx
    push dx
    push bx
    push sp
    push bp
    push si
    push di
    push ds
    push es

    ; Set DS to kernel segment to access kernel variables
    mov ax, KERNEL_SEGMENT
    mov ds, ax

    ; Save user stack pointer into kernel memory
    mov [saved_ss - KERNEL_PHYSICAL], ss
    mov [saved_sp - KERNEL_PHYSICAL], sp
    
    ; Switch to kernel stack
    mov ss, ax ; ax still contains KERNEL_SEGMENT
    mov sp, KERNEL_STACK_INIT_OFFSET

    ; Use ES to access user stack
    mov ax, [saved_ss - KERNEL_PHYSICAL]
    mov es, ax
    mov bp, [saved_sp - KERNEL_PHYSICAL]

    ; Print "Interrupt 0xXX"
    mov si, msg_prefix - KERNEL_PHYSICAL
    call print_string_com1
    mov al, %1
    call print_al_hex

    %if %1 == 0x21
        ; For INT 21h, print AH
        mov si, msg_suffix_int21 - KERNEL_PHYSICAL ; " called, AH="
        call print_string_com1
        
        mov bl, byte [es:bp + 18 + 1] ; Original AH from stack
        mov al, bl
        call print_al_hex

        ; --- INT 21h sub-function handling ---
                cmp bl, 0x02
                je .int21_ah02
        
                cmp bl, 0x3D
                je .int21_ah3d
        
                cmp bl, 0x49
                je .int21_ah49
        
                cmp bl, 0x50
                je .int21_ah50
                
                jmp .int21_done ; Default: do nothing
        
            .int21_ah02:
                ; AH=02h: Log DL
                mov si, msg_dl_suffix - KERNEL_PHYSICAL ; ", DL="
                call print_string_com1
                mov bl, byte [es:bp + 14] ; Original DL from stack
                mov al, bl
                call print_al_hex
        
                ; Check if DL is a printable ASCII character (0x20-0x7E)
                mov al, bl ; Restore original DL to AL for comparison
                cmp al, 0x20
                jl .int21_ah02_ascii_done ; Less than space, not printable
                cmp al, 0x7E
                jg .int21_ah02_ascii_done ; Greater than tilde, not printable
        
                ; It's a printable character, print its ASCII representation
                mov si, msg_ascii_suffix - KERNEL_PHYSICAL
                call print_string_com1
                mov al, bl ; DL is still in bl
                call print_char_com1
                mov si, msg_quote - KERNEL_PHYSICAL
                call print_string_com1
        
            .int21_ah02_ascii_done:
                jmp .int21_done
    .int21_ah3d:
        ; AH=3Dh: Open file. DS:DX points to filename.
        mov si, msg_filename_suffix - KERNEL_PHYSICAL
        call print_string_com1

        ; Temporarily switch DS to print filename from user space
        push ds
        mov ds, [es:bp + 2]  ; caller's DS
        mov si, [es:bp + 14] ; caller's DX
        call print_string_com1
        pop ds

        jmp .int21_done

    .int21_ah49:
        ; AH=49h: Free Memory. ES has segment.
        ; No action needed for stub.
        jmp .int21_done

    .int21_ah50:
        ; AH=50h: Set PSP. BX has new PSP segment.
        mov ax, [es:bp + 12] ; Original BX from stack
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
    and word [es:bp + 24], 0xFFFE

    ; Restore user stack before popping registers
    mov ss, [saved_ss - KERNEL_PHYSICAL]
    mov sp, [saved_sp - KERNEL_PHYSICAL]

    pop es
    pop ds
    pop di
    pop si
    pop bp
    add sp, 2   ; Skip pop sp
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
msg_filename_suffix db ', file=', 0
msg_ascii_suffix db ', ASCII="', 0
msg_quote db '"', 0
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
;    mov ah, al ; save char
;
;.wait:
;    mov dx, COM1 + 5
;    in al, dx
;    test al, 0x20
;    jz .wait
;
;    mov al, ah ; restore char
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
