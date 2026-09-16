; fdipl80.asm
;
; PC-9801 CP/M 2.2 IPL for NEC V30 8080 emulation mode
; NASM syntax, 8086/V30 native mode, exactly 512 bytes.
;
; Disk layout, common to 2DD and 2HD:
;   LBA 0      : this IPL
;   LBA 1..16  : native gateway, 8192 bytes -> 3000:0000
;   LBA 17..30 : 62K CP/M-80 resident image, 0x1C00 bytes -> 4000:DC00
;
; CP/M-80 address space:
;   4000:0000..FFFF -> 8080 0000h..FFFFh
;   CCP  = DC00h
;   BDOS = E406h
;   BIOS = F200h
;
; Boot media is selected from PC-98 BIOS work area 0000:0584h:
;   10h/70h family = 2DD, 8 x 512 bytes / side
;   90h/F0h family = 2HD, 15 x 512 bytes / side
;
; Build:
;   nasm -f bin fdipl80.asm -o FDIPL80.BIN
;

BITS 16
CPU 8086
ORG 0

GATEWAY_SEG         equ 3000h
GATEWAY_BYTES       equ 2000h
GATEWAY_SECTORS     equ GATEWAY_BYTES / 512

CPM_SEG             equ 4000h
CPM_LOAD_OFF        equ 0DC00h
CPM_LOAD_BYTES      equ 01C00h
CPM_LOAD_SECTORS    equ CPM_LOAD_BYTES / 512
BIOS_BOOT           equ 0F200h

NATIVE_STACK_TOP    equ 4000h

BOOT_DAUA           equ 0584h
DISK_INT            equ 1Bh
DISK_READ           equ 56h
SECTOR_SIZE_CODE    equ 2
SECTOR_BYTES        equ 512

BRKEM_VECTOR        equ 60h
CALLN_VECTOR        equ 61h
BRKEM_IVT           equ BRKEM_VECTOR * 4
CALLN_IVT           equ CALLN_VECTOR * 4

start:
        cli
        push    cs
        pop     ds

        ; Native stack remains in the gateway segment after BRKEM.
        mov     ax,GATEWAY_SEG
        mov     ss,ax
        mov     sp,NATIVE_STACK_TOP
        sti
        cld

        ; Read the exact ROM-BIOS DA/UA used for this boot.
        xor     ax,ax
        mov     es,ax
        mov     al,[es:BOOT_DAUA]
        mov     [boot_daua],al

        ; Derive sectors per physical side from DA/UA upper nibble.
        mov     ah,al
        and     ah,0F0h
        cmp     ah,10h
        je      .media_2dd
        cmp     ah,70h
        je      .media_2dd
        cmp     ah,90h
        je      .media_2hd
        cmp     ah,0F0h
        je      .media_2hd
        jmp     disk_error

.media_2dd:
        mov     byte [sectors_per_side],8
        jmp     short .media_ready
.media_2hd:
        mov     byte [sectors_per_side],15

.media_ready:
        ; Load 8 KiB native gateway from LBA 1..16.
        mov     word [lba],1
        mov     ax,GATEWAY_SEG
        mov     es,ax
        xor     bp,bp
        mov     si,GATEWAY_SECTORS
        call    load_sectors
        jc      disk_error

        ; Load the 62K resident CP/M image DC00h..F7FFh from LBA 17..30.
        mov     ax,CPM_SEG
        mov     es,ax
        mov     bp,CPM_LOAD_OFF
        mov     si,CPM_LOAD_SECTORS
        call    load_sectors
        jc      disk_error

        ; Install BRKEM 60h -> CP/M BIOS and CALLN 61h -> native gateway.
        cli
        xor     ax,ax
        mov     es,ax
        mov     word [es:BRKEM_IVT],BIOS_BOOT
        mov     word [es:BRKEM_IVT+2],CPM_SEG
        mov     word [es:CALLN_IVT],0000h
        mov     word [es:CALLN_IVT+2],GATEWAY_SEG

        ; Flat 8080 program/data window.  SS intentionally remains GATEWAY_SEG;
        ; V30 8080-mode SP is BP, while CALLN uses the native SS:SP stack.
        mov     ax,CPM_SEG
        mov     ds,ax
        mov     es,ax
        xor     bp,bp
        cld

        ; NEC V20/V30 BRKEM 60h.
        db      0Fh,0FFh,BRKEM_VECTOR

        ; RETEM from the resident system is not expected.
.returned:
        cli
        hlt
        jmp     .returned

; ---------------------------------------------------------------------------
; Load SI sectors beginning at [lba] to ES:BP.
; Every transfer is rebuilt from the linear LBA and retried five times.
; ---------------------------------------------------------------------------
load_sectors:
.next:
        push    si
        mov     di,5
.retry:
        push    di
        push    es
        push    bp

        call    make_chs
        mov     al,[boot_daua]
        mov     ah,DISK_READ
        mov     bx,SECTOR_BYTES
        int     DISK_INT

        pop     bp
        pop     es
        pop     di
        jnc     .ok

        ; Recalibrate after a failed read before retrying.
        push    di
        mov     al,[boot_daua]
        mov     ah,07h
        int     DISK_INT
        pop     di

        dec     di
        jnz     .retry

        pop     si
        stc
        ret

.ok:
        add     bp,SECTOR_BYTES
        inc     word [lba]
        pop     si
        dec     si
        jnz     .next
        clc
        ret

; LBA -> CH/CL/DH/DL for 80-cylinder, two-head FDD.
; CL=cylinder, CH=2 (512-byte size code), DH=head, DL=sector 1-based.
make_chs:
        mov     ax,[lba]
        xor     dx,dx
        xor     bx,bx
        mov     bl,[sectors_per_side]
        shl     bx,1
        div     bx                      ; AX=cylinder, DX=index in cylinder
        mov     cl,al

        mov     ax,dx
        xor     dx,dx
        xor     bx,bx
        mov     bl,[sectors_per_side]
        div     bx                      ; AX=head, DX=sector index
        mov     dh,al
        mov     dl,dl                   ; low remainder already in DL
        inc     dl
        mov     ch,SECTOR_SIZE_CODE
        ret

disk_error:
        ; Visible diagnostic without requiring serial initialization.
        mov     ax,0A000h
        mov     es,ax
        mov     word [es:0],0045h       ; 'E'
        cli
.hang:
        hlt
        jmp     .hang

boot_daua        db 0
sectors_per_side db 8
lba              dw 0

times 510-($-$$) db 0
dw 0AA55h
