; boot.asm
; PC-XT compatible boot sector
; Sends "Hello World" to COM1 (0x3F8)

BITS 16
ORG 0x7C00

%define COM1 0x3F8

start:
    cli
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0x7C00
    sti

    mov si, msg
.send:
    lodsb
    test al, al
    jz .done
    call uart_putc
    jmp .send

.done:
    mov dx, 0x501     ; QEMU exit
    mov al, 0
    out dx, al

    cli
    hlt
    jmp .done

; -------------------------
; Send one character (AL)
; -------------------------
uart_putc:
    mov cl, al
    mov dx, COM1+5          ; LSR
.wait:
    in  al, dx
    test al, 20h            ; THR empty?
    jz .wait

    mov dx, COM1
    mov al, cl
    out dx, al
    ret

msg:
    db "Hello World", 13, 10, 0

; -------------------------
; Boot sector signature
; -------------------------
times 510-($-$$) db 0
dw 0xAA55
