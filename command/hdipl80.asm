; hdipl80.asm
; PC-9801 SCSI HDD partition IPL for CP/M-80 on NEC V30.
; NASM syntax, exactly 512 bytes.
;
; Partition layout:
;   rel cyl 0, H0/S0 : this IPL
;   next 16 sectors  : native V30 gateway, 2000h bytes -> 3000:0000
;   next 14 sectors  : 62K CP/M-80 resident, 1C00h bytes -> 4000:DC00
;   rest of cylinder : reserved
;   rel cyl 1 onward : CP/M filesystem (DPB OFF=1)
;
; Metadata:
;   01E0h..01E7h : "CPM80FS1"
;   01E8h..01EFh : 64-bit filesystem ID
;   01F0h..01F1h : absolute partition start cylinder
;   01FEh..01FFh : 55AAh
;
; HDD boot hint:
;   written into the loaded gateway at 3000:1FC0.
;   The HDD-aware gateway must reserve 1FC0h..1FFFh for this private ABI.
;
; Build:
;   nasm -f bin hdipl80.asm -o HDIPL80.BIN

bits 16
cpu 8086
org 0x8000

GATEWAY_SEG         equ 0x3000
GATEWAY_SECTORS     equ 16
GATEWAY_HINT_OFF    equ 0x1fc0

CPM_SEG             equ 0x4000
CPM_LOAD_OFF        equ 0xdc00
CPM_SECTORS         equ 14
BIOS_BOOT           equ 0xf200

NATIVE_STACK_TOP    equ 0x4000

BRKEM_VECTOR        equ 0x60
CALLN_VECTOR        equ 0x61
BRKEM_IVT           equ BRKEM_VECTOR*4
CALLN_IVT           equ CALLN_VECTOR*4

BOOT_DAUA           equ 0x0584
SECTOR_BYTES        equ 512

start:
        cli
        push    cs
        pop     ds
        xor     si,si
        xor     ax,ax
        mov     es,ax
        mov     di,0x8000
        mov     cx,256
        cld
        rep     movsw
        jmp     0x0000:relocated

relocated:
        xor     ax,ax
        mov     ds,ax
        mov     es,ax
        mov     ss,ax
        mov     sp,0x9000
        sti
        cld

        mov     al,[BOOT_DAUA]
        mov     [boot_drive],al

        ; Geometry of the SCSI unit selected by the PC-98 HDD boot path.
        mov     al,[boot_drive]
        mov     ah,0x84                  ; NEW SENSE
        mov     bx,0xa55a
        mov     cx,0x5aa5
        mov     dx,0xc33c
        push    ds
        int     0x1b
        pop     ds
        jc      read_error
        cmp     bx,SECTOR_BYTES
        jne     read_error
        or      dh,dh
        jz      read_error
        or      dl,dl
        jz      read_error
        mov     [heads],dh
        mov     [spt],dl

        ; First sector immediately following this partition IPL.
        mov     ax,[ipl_start_cyl]
        mov     [cylinder],ax
        mov     byte [head],0
        mov     byte [sector],1

        ; 16 sectors -> 3000:0000.
        mov     word [dest_seg],GATEWAY_SEG
        mov     word [dest_off],0
        mov     cx,GATEWAY_SECTORS
        call    load_sectors
        jc      read_error

        ; 14 sectors -> 4000:DC00.
        mov     word [dest_seg],CPM_SEG
        mov     word [dest_off],CPM_LOAD_OFF
        mov     cx,CPM_SECTORS
        call    load_sectors
        jc      read_error

        ; Publish boot source and persistent filesystem ID.
        mov     ax,GATEWAY_SEG
        mov     es,ax
        mov     di,GATEWAY_HINT_OFF
        xor     ax,ax
        mov     cx,32
        rep     stosw

        mov     word [es:GATEWAY_HINT_OFF+0],0x5043 ; "CP"
        mov     word [es:GATEWAY_HINT_OFF+2],0x384d ; "M8"
        mov     word [es:GATEWAY_HINT_OFF+4],0x4842 ; "BH"
        mov     word [es:GATEWAY_HINT_OFF+6],0x3154 ; "T1"
        mov     byte [es:GATEWAY_HINT_OFF+8],1      ; HDD
        mov     al,[boot_drive]
        mov     [es:GATEWAY_HINT_OFF+9],al
        mov     ax,[ipl_start_cyl]
        mov     [es:GATEWAY_HINT_OFF+10],ax
        mov     si,ipl_fsid
        mov     di,GATEWAY_HINT_OFF+12
        mov     cx,4
        rep     movsw

        ; Native CALLN stack.
        mov     ax,GATEWAY_SEG
        mov     ss,ax
        mov     sp,NATIVE_STACK_TOP

        ; V30 BRKEM/CALLN vectors.
        xor     ax,ax
        mov     es,ax
        mov     word [es:BRKEM_IVT],BIOS_BOOT
        mov     word [es:BRKEM_IVT+2],CPM_SEG
        mov     word [es:CALLN_IVT],0
        mov     word [es:CALLN_IVT+2],GATEWAY_SEG

        mov     ax,CPM_SEG
        mov     ds,ax
        mov     es,ax
        xor     bp,bp
        cld

        db      0x0f,0xff,BRKEM_VECTOR

.returned:
        cli
        hlt
        jmp     .returned

; CX sectors from current CHS to [dest_seg]:[dest_off].
load_sectors:
.next:
        push    cx
        mov     di,5
.retry:
        mov     ax,[dest_seg]
        mov     es,ax
        mov     bp,[dest_off]
        mov     bx,SECTOR_BYTES
        mov     cx,[cylinder]
        mov     dh,[head]
        mov     dl,[sector]
        mov     al,[boot_drive]
        mov     ah,0x06                  ; SCSI READ

        push    di
        push    ds
        int     0x1b
        pop     ds
        pop     di
        jnc     .ok

        dec     di
        jnz     .retry
        pop     cx
        stc
        ret

.ok:
        add     word [dest_off],SECTOR_BYTES
        call    advance_chs
        pop     cx
        loop    .next
        clc
        ret

advance_chs:
        inc     byte [sector]
        mov     al,[sector]
        cmp     al,[spt]
        jb      .done
        mov     byte [sector],0
        inc     byte [head]
        mov     al,[head]
        cmp     al,[heads]
        jb      .done
        mov     byte [head],0
        inc     word [cylinder]
.done:
        ret

read_error:
        mov     ax,0xa000
        mov     es,ax
        mov     word [es:0],0x0045       ; 'E'
        cli
.hang:
        hlt
        jmp     .hang

boot_drive      db 0
heads           db 0
spt             db 0
cylinder        dw 0
head            db 0
sector          db 1
dest_seg        dw 0
dest_off        dw 0

times 0x1e0 - ($ - $$) db 0
ipl_signature   db 'CPM80FS1'
ipl_fsid        times 8 db 0
ipl_start_cyl   dw 0
times 510 - ($ - $$) db 0
dw 0xaa55
