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
COM2 equ 0x2F8 ; I/O port for character output (COM2)

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

; This is the top of the 64KB user memory area
COMMAND_END_PHYSICAL     equ 0x10FFF
COMMAND_END_SEGMENT      equ 0x10FF

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

    ; PSP: Segment address of the first free paragraph after program's allocation
    mov ax, COMMAND_END_SEGMENT
    add ax, 1
    mov word [es:COMMAND_PSP_OFFSET + 0x0002], ax

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
    free_mem_start_segment dw COMMAND_END_SEGMENT
    file_seek_pointer_42 dd 0 ; 32-bit file pointer for handle 42
    canned_input_state dw 0 ; State for canned input for INT 21h, AH=0Ah

in_memory_command_com:
    incbin "COMMAND.COM"
in_memory_command_com_end:
IN_MEMORY_COMMAND_COM_SIZE equ in_memory_command_com_end - in_memory_command_com



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
    push ax                     ; [es:bp + 18]
    push cx                     ; [es:bp + 16]
    push dx                     ; [es:bp + 14]
    push bx                     ; [es:bp + 12]
    push sp                     ; [es:bp + 10]
    push bp                     ; [es:bp + 8]
    push si                     ; [es:bp + 6]
    push di                     ; [es:bp + 4]
    push ds                     ; [es:bp + 2]
    push es                     ; [es:bp + 0]

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

    ; Default to success by clearing carry flag.
    ; INT 21h handlers can override this by setting it.
    and word [es:bp + 24], 0xFFFE

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
        
                cmp bl, 0x09
                je .int21_ah09
        
                cmp bl, 0x0A
                je .int21_ah0a
        
                cmp bl, 0x3D
                je .int21_ah3d
        
                cmp bl, 0x3E
                je .int21_ah3e
        
                cmp bl, 0x3F
                je .int21_ah3f
        
                cmp bl, 0x42
                je .int21_ah42
        
                cmp bl, 0x48
                je .int21_ah48
        
                cmp bl, 0x49
                je .int21_ah49
        
                cmp bl, 0x4A
                je .int21_ah4a
        
                cmp bl, 0x25
                je .int21_ah25

                cmp bl, 0x30
                je .int21_ah30

                cmp bl, 0x50
                je .int21_ah50
                
                jmp .int21_done ; Default: do nothing
        
            .int21_ah09:
                ; AH=09h: Print $-terminated string
                ; Log DS and DX
                mov si, msg_ds_suffix - KERNEL_PHYSICAL
                call print_string_com1
                mov ax, [es:bp + 2] ; Original DS
                call print_ax_hex
                mov si, msg_dx_suffix - KERNEL_PHYSICAL
                call print_string_com1
                mov ax, [es:bp + 14] ; Original DX
                call print_ax_hex

                ; Log string content to COM1
                mov si, msg_string_content_suffix - KERNEL_PHYSICAL
                call print_string_com1
                
                push ds
                push si
                mov ds, [es:bp + 2]  ; user's DS
                mov si, [es:bp + 14] ; user's DX
            .log_loop:
                lodsb
                cmp al, '$'
                je .log_loop_done
                ; Check if AL is a printable ASCII character (0x20-0x7E)
                cmp al, 0x20
                jl .skip_log_char ; Less than space, not printable
                cmp al, 0x7E
                jg .skip_log_char ; Greater than tilde, not printable
                call print_char_com1
            .skip_log_char:
                jmp .log_loop
            .log_loop_done:
                mov si, msg_quote - KERNEL_PHYSICAL
                call print_string_com1
                
                ; Output string to COM2
                mov si, [es:bp + 14] ; reset pointer to user's DX
            .com2_loop:
                lodsb
                cmp al, '$'
                je .com2_loop_done
                push dx
                mov dx, COM2
                out dx, al
                pop dx
                jmp .com2_loop
            .com2_loop_done:

                pop si
                pop ds
                jmp .int21_done

            .int21_ah0a:
                ; AH=0Ah: Buffered Input. We provide canned input.
                ; Log DS:DX
                mov si, msg_ds_suffix - KERNEL_PHYSICAL
                call print_string_com1
                mov ax, [es:bp + 2] ; Original DS
                call print_ax_hex
                mov si, msg_dx_suffix - KERNEL_PHYSICAL
                call print_string_com1
                mov ax, [es:bp + 14] ; Original DX
                call print_ax_hex

                ; Get user buffer pointer to ES:DI
                push es
                mov es, [es:bp + 2]  ; user's DS
                mov di, [es:bp + 14] ; user's DX

                ; Check state to decide which string to use
                mov ax, [canned_input_state - KERNEL_PHYSICAL]
                cmp ax, 0
                je .use_input_0

            .use_input_1:
                ; Use "r"
                mov byte [es:di+1], 1 ; Actual length
                mov byte [es:di+2], 'r'
                mov byte [es:di+3], 0x0D
                mov word [canned_input_state - KERNEL_PHYSICAL], 0 ; Reset state
                jmp .ah0a_done

            .use_input_0:
                ; Use "u"
                mov byte [es:di+1], 1 ; Actual length
                mov byte [es:di+2], 'u'
                mov byte [es:di+3], 0x0D
                mov word [canned_input_state - KERNEL_PHYSICAL], 1 ; Next state is 1
                ; jmp .ah0a_done (fallthrough)

            .ah0a_done:
                pop es
                jmp .int21_done

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
                ; Also output to COM2
                mov al, bl ; Original DL is still in bl
                push dx
                mov dx, COM2
                out dx, al
                pop dx
                jmp .int21_done
    .int21_ah3d:
        ; AH=3Dh: Open file.
        ; Log AL
        mov si, msg_al_suffix - KERNEL_PHYSICAL
        call print_string_com1
        mov al, byte [es:bp + 18] ; Original AL from stack
        call print_al_hex

        ; Log filename
        mov si, msg_filename_suffix - KERNEL_PHYSICAL
        call print_string_com1
        push ds
        mov ds, [es:bp + 2]  ; caller's DS
        mov si, [es:bp + 14] ; caller's DX
        call print_string_com1
        pop ds

        ; Return file handle 42 in AX
        mov word [es:bp + 18], 42
        jmp .int21_done

    .int21_ah3e:
        ; AH=3Eh: Close file.
        mov si, msg_bx_suffix - KERNEL_PHYSICAL
        call print_string_com1
        mov ax, [es:bp + 12] ; Original BX
        call print_ax_hex
        jmp .int21_done

    .int21_ah3f:
        ; AH=3Fh: Read from file/device
        ; Log stuff first
        mov si, msg_bx_suffix - KERNEL_PHYSICAL
        call print_string_com1
        mov ax, [es:bp + 12] ; Original BX
        call print_ax_hex
        mov si, msg_cx_suffix - KERNEL_PHYSICAL
        call print_string_com1
        mov ax, [es:bp + 16] ; Original CX
        call print_ax_hex
        mov si, msg_ds_suffix - KERNEL_PHYSICAL
        call print_string_com1
        mov ax, [es:bp + 2] ; Original DS
        call print_ax_hex
        mov si, msg_dx_suffix - KERNEL_PHYSICAL
        call print_string_com1
        mov ax, [es:bp + 14] ; Original DX
        call print_ax_hex

        ; Check if file handle is 42
        mov ax, [es:bp + 12] ; Original BX
        cmp ax, 42
        jne .read_default

    .read_handle_42:
        cld ; Ensure forward string operations
        
        ; Set source DS:SI to kernel data location
        ; DS is already KERNEL_SEGMENT from ISR entry
        mov si, [file_seek_pointer_42 - KERNEL_PHYSICAL]
        add si, in_memory_command_com - KERNEL_PHYSICAL
        ; TODO: Handle 32-bit pointer if file > 64k

        ; Set destination ES:DI to user buffer
        push es
        mov es, [es:bp + 2]  ; User's DS
        mov di, [es:bp + 14] ; User's DX
        
        ; Set count CX
        mov cx, [es:bp + 16]
        
        ; Copy data
        rep movsb
        
        ; Update file pointer
        mov ax, [es:bp + 16] ; CX (bytes read)
        add [file_seek_pointer_42 - KERNEL_PHYSICAL], ax
        adc word [file_seek_pointer_42 + 2 - KERNEL_PHYSICAL], 0
        
        pop es
        ; Fall through to default behavior to set return AX

    .read_default:
        ; Default logic: return requested bytes (CX) in AX
        mov ax, [es:bp + 16]
        mov word [es:bp + 18], ax
        jmp .int21_done

    .int21_ah42:
        ; AH=42h: LSEEK
        ; Log stuff first
        mov si, msg_al_suffix - KERNEL_PHYSICAL
        call print_string_com1
        mov al, byte [es:bp + 18]
        call print_al_hex
        mov si, msg_bx_suffix - KERNEL_PHYSICAL
        call print_string_com1
        mov ax, [es:bp + 12] ; Original BX
        call print_ax_hex
        mov si, msg_cxdx_suffix - KERNEL_PHYSICAL
        call print_string_com1
        mov ax, [es:bp + 16] ; Original CX
        call print_ax_hex
        mov ax, [es:bp + 14] ; Original DX
        call print_ax_hex

        ; Check if file handle is 42
        mov ax, [es:bp + 12] ; Original BX
        cmp ax, 42
        jne .lseek_default

    .lseek_handle_42:
        ; Get offset from CX:DX
        mov ax, [es:bp + 14] ; old DX (low word of offset)
        mov dx, [es:bp + 16] ; old CX (high word of offset)
        
        ; Get seek mode from AL
        mov cl, byte [es:bp + 18]

        ; Calculate new pointer based on mode
        cmp cl, 0
        je .seek_from_start
        cmp cl, 1
        je .seek_from_current
        cmp cl, 2
        je .seek_from_end
        
        ; Invalid mode, jump to default which does nothing smart
        jmp .lseek_default

    .seek_from_start:
        ; new_ptr = offset, so DX:AX already holds it.
        jmp .lseek_update_return
        
    .seek_from_current:
        ; new_ptr = current + offset
        add ax, [file_seek_pointer_42 - KERNEL_PHYSICAL]
        adc dx, [file_seek_pointer_42 + 2 - KERNEL_PHYSICAL]
        jmp .lseek_update_return
        
    .seek_from_end:
        ; new_ptr = size + offset
        add ax, IN_MEMORY_COMMAND_COM_SIZE
        adc dx, 0
        jmp .lseek_update_return
        
    .lseek_update_return:
        ; Save new pointer
        mov [file_seek_pointer_42 - KERNEL_PHYSICAL], ax
        mov [file_seek_pointer_42 + 2 - KERNEL_PHYSICAL], dx
        
        ; Return new pointer in DX:AX
        mov [es:bp + 14], dx ; set return DX
        mov [es:bp + 18], ax ; set return AX
        jmp .int21_done

    .lseek_default:
        ; Default logic for other handles (just swaps cx:dx to dx:ax)
        mov ax, [es:bp + 16] ; old CX
        mov bx, [es:bp + 14] ; old DX
        mov [es:bp + 14], ax ; new DX on stack = old CX
        mov [es:bp + 18], bx ; new AX on stack = old DX
        jmp .int21_done

    .int21_ah48:
        ; AH=48h: Allocate Memory
        mov si, msg_bx_suffix - KERNEL_PHYSICAL
        call print_string_com1
        mov ax, [es:bp + 12] ; Original BX (requested size in paragraphs)
        call print_ax_hex

        ; --- Separator for arguments and return values ---
        mov si, msg_separator - KERNEL_PHYSICAL
        call print_string_com1

        ; Calculate available memory in paragraphs. Top of memory is defined by COMMAND_END_SEGMENT.
        mov dx, COMMAND_END_SEGMENT
        sub dx, [free_mem_start_segment - KERNEL_PHYSICAL]

        ; Compare requested size (AX, from original BX) with available size (DX)
        cmp ax, dx
        ja .alloc_fail ; Unsigned compare: if requested > available, fail

        ; --- Success Path ---
        ; Get current free segment for the allocated block
        mov cx, [free_mem_start_segment - KERNEL_PHYSICAL]
        mov [es:bp + 18], cx ; Set return AX to allocated segment

        ; Advance the free memory pointer
        add [free_mem_start_segment - KERNEL_PHYSICAL], ax ; ax still has original BX

        ; Log return values
        mov si, msg_ax_suffix - KERNEL_PHYSICAL
        call print_string_com1
        mov ax, [es:bp + 18]
        call print_ax_hex

        jmp .int21_done

    .alloc_fail:
        ; --- Failure Path ---
        ; Set carry flag to indicate error
        or word [es:bp + 24], 1

        ; Return error code 8 (Insufficient Memory) in AX
        mov word [es:bp + 18], 8

        ; Return max available block size in BX (which is in DX)
        mov [es:bp + 12], dx

        ; Log return values
        mov si, msg_ax_suffix - KERNEL_PHYSICAL
        call print_string_com1
        mov ax, [es:bp + 18]
        call print_ax_hex
        mov si, msg_bx_suffix - KERNEL_PHYSICAL
        call print_string_com1
        mov ax, [es:bp + 12]
        call print_ax_hex

        jmp .int21_done

    .int21_ah49:
        ; AH=49h: Free Memory. ES has segment.
        ; No action needed for stub.
        jmp .int21_done

    .int21_ah4a:
        ; AH=4Ah: Resize Memory Block
        mov si, msg_es_suffix - KERNEL_PHYSICAL
        call print_string_com1
        mov ax, [es:bp + 0] ; Original ES
        call print_ax_hex
        
        mov si, msg_bx_suffix - KERNEL_PHYSICAL
        call print_string_com1
        mov ax, [es:bp + 12] ; Original BX (new size)
        call print_ax_hex

        ; Update free memory pointer = block_segment + new_size
        mov cx, [es:bp + 0]  ; Original ES (block segment)
        add cx, ax ; ax has new size
        mov [free_mem_start_segment - KERNEL_PHYSICAL], cx

        ; Return max available block size in BX
        mov dx, COMMAND_END_SEGMENT
        sub dx, [free_mem_start_segment - KERNEL_PHYSICAL]
        mov [es:bp + 12], dx ; set return BX

        jmp .int21_done

    .int21_ah50:
        ; AH=50h: Set PSP. BX has new PSP segment.
        mov ax, [es:bp + 12] ; Original BX from stack
        mov [current_psp - KERNEL_PHYSICAL], ax
        jmp .int21_done

    .int21_ah30:
        ; AH=30h: Get DOS Version
        ; AL=major=2, AH=minor=11 (0Bh)
        mov word [es:bp + 18], 0x0B02 ; Return AX=0x0B02 (v2.11)
        mov word [es:bp + 12], 0x0000 ; Return BX=0
        mov word [es:bp + 16], 0x0000 ; Return CX=0
        jmp .int21_done

    .int21_ah25:
        ; AH=25h: Set Interrupt Vector
        ; Log AL, DS, DX
        mov si, msg_al_suffix - KERNEL_PHYSICAL
        call print_string_com1
        mov al, byte [es:bp + 18] ; Original AL from stack
        call print_al_hex

        mov si, msg_ds_suffix - KERNEL_PHYSICAL
        call print_string_com1
        mov ax, [es:bp + 2] ; Original DS from stack
        call print_ax_hex

        mov si, msg_dx_suffix - KERNEL_PHYSICAL
        call print_string_com1
        mov ax, [es:bp + 14] ; Original DX from stack
        call print_ax_hex

        ; Get values before changing ES
        mov al, byte [es:bp + 18] ; Interrupt number
        mov dx, [es:bp + 14]      ; New handler offset
        mov cx, [es:bp + 2]       ; New handler segment

        push es ; Save user's SS (currently in ES)
        
        ; Calculate IVT offset in DI
        xor ah, ah
        mov bh, 4
        mul bh    ; ax = al * 4
        mov di, ax
        
        ; Set ES to 0 for IVT access
        xor ax, ax
        mov es, ax
        
        ; Write new vector (Offset then Segment)
        mov [es:di], dx
        mov [es:di+2], cx
        
        pop es ; Restore user's SS to ES
        jmp .int21_done

    .int21_done:

    %else
        ; For other interrupts
        mov si, msg_suffix_general - KERNEL_PHYSICAL ; " called"
        call print_string_com1
    %endif

    ; Print CR+LF
    mov si, msg_crlf - KERNEL_PHYSICAL
    call print_string_com1

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
msg_al_suffix db ', AL=', 0
msg_bx_suffix db ', BX=', 0
msg_cx_suffix db ', CX=', 0
msg_dx_suffix db ', DX=', 0
msg_cxdx_suffix db ', CX:DX=', 0
msg_ds_suffix db ', DS=', 0
msg_es_suffix db ', ES=', 0
msg_ax_suffix db ', AX=', 0
msg_separator db ' - ', 0
msg_dl_suffix db ', DL=', 0
msg_filename_suffix db ', file=', 0
msg_ascii_suffix db ', ASCII="', 0
msg_quote db '"', 0
msg_string_content_suffix db ', string="', 0
msg_crlf db 13, 10, 0

print_ax_hex:
    ; Prints AX as a four-digit hex number.
    push ax
    mov al, ah
    call print_al_hex
    pop ax
    call print_al_hex
    ret

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
