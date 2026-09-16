; gateway86.asm
;
; Native V30 gateway for CP/M-80 on PC-9801.
; FDD A:..D:, 2DD/2HD auto detect, GVRAM write-back side-track cache,
; PC-98 CRT/keyboard, serial TTY, ANSI/VT100 local-screen renderer.
;
; Loaded by IPL at 3000:0000. Entered by V30 CALLN 61h.
;
; Service ABI:
;   AL=00h INIT
;       discovers FDD/HDD state and returns logical boot drive 0..5
;       (A:..F:), or FFh on error
;
;   AL=01h READ128
;   AL=02h WRITE128
;       current drive is established by the most recent successful SELECT
;       CH = logical side-track 0..159
;       CL = logical 128-byte record
;       DX = CP/M DMA offset in 4000:0000 8080 window
;       return AL=0 success, AL=1 error
;
;   AL=03h SELECT
;       BH = logical drive 0..5 (A:..F:)
;       DL bit0 = CP/M login flag (0=newly logged-in, 1=already logged-in)
;       returns AL=1 2DD, AL=2 2HD, AL=3 HDD, AL=FFh absent/error
;
;   AL=04h SYNC
;       flush all dirty cache runs
;       returns AL=0 success, AL=1 error
;
; FDD GVRAM cache layout:
;   A: A8000-A9DFF  15 x 512
;   B: A9E00-ABBFF  15 x 512
;   C: B0000-B1DFF  15 x 512
;   D: B1E00-B3BFF  15 x 512
;   metadata: B8000...
;
; Each drive owns one complete side-track window.  Dirty sectors are written
; as maximal contiguous runs with one ROM-BIOS multi-sector WRITE per run.
;
; NASM:
;   nasm -f bin gateway86.asm -o gateway86.bin
; Expected output size: exactly 8192 bytes.
; HDD extension: first two formatted type-70h partitions are packed into E:..F:.
; HDD 128-byte I/O uses an immediate 512-byte read/modify/write bounce sector;
; each HDD is limited to 8192 x 16-KiB blocks (128 MiB maximum).
; the existing GVRAM write-back cache remains dedicated to FDD A:..D:.
;

BITS 16
CPU 8086
ORG 0

GATEWAY_BYTES       equ 2000h
CPM_SEG             equ 4000h
CPM_BOOTDRV_ABI   equ 0F7FCh

BOOT_DAUA           equ 0584h
SYS_FLAG            equ 0501h

SER_DATA            equ 30h
SER_CTRL            equ 32h
PIT_CH2             equ 75h
PIT_CTRL            equ 77h

DISK_INT            equ 1Bh
DISK_READ           equ 56h
DISK_WRITE          equ 55h
DISK_RECAL          equ 07h
DISK_VERIFY         equ 51h
HDD_READ            equ 06h
HDD_WRITE           equ 05h
HDD_SENSE           equ 84h

SVC_INIT            equ 00h
SVC_READ128         equ 01h
SVC_WRITE128        equ 02h
SVC_SELECT          equ 03h
SVC_SYNC            equ 04h
SVC_SER_CONST       equ 05h
SVC_SER_GETC        equ 06h
SVC_SER_PUTC        equ 07h
SVC_LOCAL_CONST     equ 08h
SVC_LOCAL_GETC      equ 09h
SVC_SCREEN_PUTC     equ 0Ah
SVC_SER_OUTST       equ 0Bh
SVC_WBOOT_RELOAD    equ 0Ch
SVC_RAW_INT1B       equ 0Dh
SVC_CACHE_RESET     equ 0Eh
SVC_GET_FDD_INFO     equ 0Fh
SVC_HDD_CONFIG      equ 10h
SVC_GET_BOOT_SOURCE equ 11h
SVC_HDD_REMOUNT_REQUEST equ 12h

; v5+rawabi service map:
;   0Ch WBOOT_RELOAD (kept compatible with v5 CBIOS)
;   0Dh RAW_INT1B
;   0Eh CACHE_RESET
;   0Fh GET_FDD_INFO
;   10h HDD_CONFIG
;   11h GET_BOOT_SOURCE
;   12h HDD_REMOUNT_REQUEST
;
; Generic CP/M-80 -> native PC-98 ROM BIOS disk request frame in CPM_SEG.
; DX points to this frame on SVC_RAW_INT1B entry.
;   +00 AX   input/output (AH=function, AL=DA/UA)
;   +02 BX   input/output
;   +04 CX   input/output
;   +06 DX   input/output
;   +08 BP   CP/M-segment buffer offset used as ES:BP
;   +0A FL   output bit0=CF
RAW_AX               equ 0
RAW_BX               equ 2
RAW_CX               equ 4
RAW_DX               equ 6
RAW_BP               equ 8
RAW_FLAGS            equ 10
RAW_FRAME_SIZE       equ 12

GATEWAY_HINT_OFF     equ 1FC0h
HDD_FIRST_DRIVE     equ 4
HDD_MAX_DRIVES      equ 2
HDD_CPM_SYS         equ 70h
HDD_SCAN_BUF        equ 0C000h       ; INIT-only, before HDD ALVs are cleared
HDD_BOUNCE_OFF      equ 2000h        ; 3000:2000, below native stack at 4000h

CACHE_META_SEG      equ 0B800h
CACHE_META_SIZE     equ 16
CACHE_VALID         equ 0A5h
CM_VALID            equ 0
CM_HEAD             equ 1
CM_CX               equ 2
CM_FIRST            equ 4
CM_DIRTY            equ 6
CM_DIRTY_HI         equ 8
CACHE_SLOTS         equ 4
CACHE_MAX_SECTORS   equ 15

gateway_entry:
        push    bx
        push    cx
        push    dx
        push    si
        push    di
        push    bp
        push    ds
        push    es
        sti

        cmp     al,SVC_INIT
        je      svc_init
        cmp     al,SVC_READ128
        je      svc_read128
        cmp     al,SVC_WRITE128
        je      svc_write128
        cmp     al,SVC_SELECT
        je      svc_select
        cmp     al,SVC_SYNC
        je      svc_sync
        cmp     al,SVC_SER_CONST
        je      svc_ser_const
        cmp     al,SVC_SER_GETC
        je      svc_ser_getc
        cmp     al,SVC_SER_PUTC
        je      svc_ser_putc
        cmp     al,SVC_LOCAL_CONST
        je      svc_local_const
        cmp     al,SVC_LOCAL_GETC
        je      svc_local_getc
        cmp     al,SVC_SCREEN_PUTC
        je      svc_screen_putc
        cmp     al,SVC_SER_OUTST
        je      svc_ser_outst
        cmp     al,SVC_WBOOT_RELOAD
        je      svc_wboot_reload
        cmp     al,SVC_RAW_INT1B
        je      svc_raw_int1b
        cmp     al,SVC_CACHE_RESET
        je      svc_cache_reset
        cmp     al,SVC_GET_FDD_INFO
        je      svc_get_fdd_info
        cmp     al,SVC_HDD_CONFIG
        je      svc_hdd_config
        cmp     al,SVC_GET_BOOT_SOURCE
        je      svc_get_boot_source
        cmp     al,SVC_HDD_REMOUNT_REQUEST
        je      svc_hdd_remount_request
        mov     al,0FFh
        jmp     gateway_return

; ---------------------------------------------------------------------------
; INIT
; Discover FDD family and formatted CP/M-80 HDD partitions.
; Return AL = logical boot drive 0..7, or FFh.
; ---------------------------------------------------------------------------
svc_init:
        call    serial_init
        call    keyboard_init
        call    screen_init
        call    cache_clear

        mov     word [cs:fdd_media_map],0
        mov     word [cs:fdd_media_map+2],0
        mov     word [cs:fdd_daua_map],0
        mov     word [cs:fdd_daua_map+2],0
        mov     word [cs:fdd_boot_seed_map],0
        mov     word [cs:fdd_boot_seed_map+2],0
        mov     byte [cs:current_daua],0
        mov     byte [cs:current_kind],0
        mov     byte [cs:media_type],0
        mov     byte [cs:boot_kind],0
        mov     byte [cs:boot_hdd_idx],0FFh

        ; FDD command-family state.
        ; HDD boot cannot infer the active family from BOOT_DAUA, so start
        ; with 70h/F0h as a candidate and allow the first FDD SELDSK to try
        ; the alternate 10h/90h pair if needed.
        mov     byte [cs:fdd_2dd_base],70h
        mov     byte [cs:fdd_2hd_base],0F0h
        mov     byte [cs:fdd_if_known],0

        xor     ax,ax
        mov     ds,ax
        mov     al,[BOOT_DAUA]
        mov     [cs:boot_daua],al

        ; Seed the floppy interface only when booted from an FDD.
        mov     ah,al
        and     ah,0F0h
        cmp     ah,10h
        je      .boot_1mb_2dd
        cmp     ah,90h
        je      .boot_1mb_2hd
        cmp     ah,70h
        je      .boot_640k_2dd
        cmp     ah,0F0h
        je      .boot_640k_2hd
        jmp     .boot_hdd

.boot_1mb_2dd:
        mov     byte [cs:fdd_2dd_base],10h
        mov     byte [cs:fdd_2hd_base],90h
        mov     byte [cs:media_type],1
        jmp     .seed_fdd
.boot_1mb_2hd:
        mov     byte [cs:fdd_2dd_base],10h
        mov     byte [cs:fdd_2hd_base],90h
        mov     byte [cs:media_type],2
        jmp     .seed_fdd
.boot_640k_2dd:
        mov     byte [cs:fdd_2dd_base],70h
        mov     byte [cs:fdd_2hd_base],0F0h
        mov     byte [cs:media_type],1
        jmp     .seed_fdd
.boot_640k_2hd:
        mov     byte [cs:fdd_2dd_base],70h
        mov     byte [cs:fdd_2hd_base],0F0h
        mov     byte [cs:media_type],2

.seed_fdd:
        mov     byte [cs:fdd_if_known],1
        xor     bx,bx
        mov     bl,[cs:boot_daua]
        and     bl,3
        mov     [cs:boot_unit],bl
        mov     al,[cs:media_type]
        mov     [cs:fdd_media_map+bx],al
        mov     al,[cs:boot_daua]
        mov     [cs:fdd_daua_map+bx],al
        mov     byte [cs:fdd_boot_seed_map+bx],1
        mov     byte [cs:boot_kind],0
        call    hdd_init
        mov     al,[cs:boot_unit]
        jmp     gateway_return

.boot_hdd:
        mov     al,[cs:boot_daua]
        cmp     al,0A0h
        jb      .fail
        cmp     al,0A7h
        jae     .fail
        mov     byte [cs:boot_kind],1
        call    hdd_init

        ; HDIPL80 publishes DA/UA + partition start cylinder in the hint.
        cmp     word [cs:gateway_boot_hint+0],5043h
        jne     .fail
        cmp     word [cs:gateway_boot_hint+2],384Dh
        jne     .fail
        cmp     word [cs:gateway_boot_hint+4],4842h
        jne     .fail
        cmp     word [cs:gateway_boot_hint+6],3154h
        jne     .fail
        cmp     byte [cs:gateway_boot_hint+8],1
        jne     .fail

        xor     bx,bx
.find_boot_hdd:
        cmp     bl,[cs:hdd_count]
        jae     .fail
        mov     al,[cs:hdd_daua_map+bx]
        cmp     al,[cs:gateway_boot_hint+9]
        jne     .next_hdd
        mov     si,bx
        shl     si,1
        mov     ax,[cs:hdd_start_cyl_map+si]
        cmp     ax,[cs:gateway_boot_hint+10]
        je      .boot_hdd_found
.next_hdd:
        inc     bl
        jmp     .find_boot_hdd
.boot_hdd_found:
        mov     [cs:boot_hdd_idx],bl
        mov     al,bl
        add     al,HDD_FIRST_DRIVE
        jmp     gateway_return

.fail:
        mov     al,0FFh
        jmp     gateway_return

; ---------------------------------------------------------------------------
; SELECT
; BH=logical drive 0..7, DL bit0 0=new login, 1=already logged.
; Return AL: 1=2DD, 2=2HD, 3=HDD, FFh=absent.
; ---------------------------------------------------------------------------
svc_select:
        mov     [cs:select_login],dl
        xor     ax,ax
        mov     al,bh
        cmp     al,8
        jae     .bad

        cmp     al,HDD_FIRST_DRIVE
        jae     .hdd

        mov     si,ax
        ; FDD cache coherency: reset newly logged-in media only.
        test    byte [cs:select_login],1
        jnz     .login_done
        mov     bl,bh
        call    cache_reset_drive
        jc      .bad
.login_done:
        cmp     byte [cs:fdd_boot_seed_map+si],0
        je      .not_seeded
        mov     byte [cs:fdd_boot_seed_map+si],0
        jmp     .fdd_apply
.not_seeded:
        test    byte [cs:select_login],1
        jz      .detect
        cmp     byte [cs:fdd_media_map+si],0
        jne     .fdd_apply
.detect:
        call    fdd_detect_media
        jc      .bad_si
        mov     [cs:fdd_media_map+si],al
.fdd_apply:
        mov     al,[cs:fdd_daua_map+si]
        test    al,al
        jz      .bad_si
        mov     [cs:current_daua],al
        mov     byte [cs:current_kind],0
        mov     ax,si
        mov     [cs:current_drive],al
        mov     al,[cs:fdd_media_map+si]
        cmp     al,1
        je      gateway_return
        cmp     al,2
        je      gateway_return
.bad_si:
        mov     byte [cs:fdd_media_map+si],0
        mov     byte [cs:fdd_daua_map+si],0
        jmp     .bad

.hdd:
        sub     al,HDD_FIRST_DRIVE
        cmp     al,[cs:hdd_count]
        jae     .bad
        xor     ah,ah
        mov     si,ax
        mov     al,[cs:hdd_daua_map+si]
        mov     [cs:current_daua],al
        mov     byte [cs:current_kind],1
        mov     al,bh
        mov     [cs:current_drive],al
        mov     al,[cs:hdd_heads_map+si]
        mov     [cs:hdd_heads_cur],al
        mov     al,[cs:hdd_spt_map+si]
        mov     [cs:hdd_spt_cur],al
        shl     si,1
        mov     ax,[cs:hdd_start_cyl_map+si]
        mov     [cs:hdd_start_cyl_cur],ax
        mov     al,3
        jmp     gateway_return

.bad:
        mov     al,0FFh
        jmp     gateway_return

; ---------------------------------------------------------------------------
; READ/WRITE through cache.
; ---------------------------------------------------------------------------
svc_read128:
        mov     byte [cs:rw_write],0
        jmp     rw_common

svc_write128:
        mov     byte [cs:rw_write],1

rw_common:
        cmp     byte [cs:current_kind],1
        je      hdd_rw_common
        call    snapshot_request
        jc      .error
        call    window_prepare_current
        jc      .error

        ; AX = segment containing selected cached 512-byte sector.
        xor     ax,ax
        mov     al,[cs:win_index]
        mov     cl,5
        shl     ax,cl
        add     ax,[cs:win_seg]

        ; BX = selected 128-byte quarter.
        xor     bx,bx
        mov     bl,[cs:svc_quarter]
        mov     cl,7
        shl     bx,cl

        cmp     byte [cs:rw_write],0
        jne     .write

        mov     ds,ax
        mov     si,bx
        mov     ax,CPM_SEG
        mov     es,ax
        mov     di,[cs:svc_dma]
        mov     cx,64
        cld
        rep     movsw
        xor     al,al
        jmp     gateway_return

.write:
        mov     es,ax
        mov     di,bx
        mov     ax,CPM_SEG
        mov     ds,ax
        mov     si,[cs:svc_dma]
        mov     cx,64
        cld
        rep     movsw
        call    window_mark_dirty
        xor     al,al
        jmp     gateway_return

.error:
        mov     al,1
        jmp     gateway_return

; ---------------------------------------------------------------------------
; HDD 128-byte I/O.  BX=track, CX=record, DX=DMA on entry.
; Uses 3000:2000 as one DMA-safe 512-byte native bounce sector.
; HDD sectors are zero-based for PC-98 SCSI BIOS AH=06h/05h.
; ---------------------------------------------------------------------------
hdd_rw_common:
        mov     [cs:hdd_rw_track],bx
        mov     [cs:hdd_rw_record],cx
        mov     [cs:hdd_rw_dma],dx
        mov     al,cl
        and     al,3
        mov     [cs:hdd_rw_quarter],al

        ; One BIOS track = one HDD cylinder. DPB OFF=1 is already reflected
        ; in the track supplied by BDOS, so add the absolute partition start.
        mov     ax,bx
        add     ax,[cs:hdd_start_cyl_cur]
        mov     [cs:hdd_rw_cyl],ax

        ; physical ordinal in cylinder = logical record / 4.
        mov     ax,cx
        shr     ax,1
        shr     ax,1
        xor     dx,dx
        xor     bx,bx
        mov     bl,[cs:hdd_spt_cur]
        test    bx,bx
        jz      .error
        div     bx                      ; AX=head, DX=zero-based sector
        cmp     al,[cs:hdd_heads_cur]
        jae     .error
        mov     [cs:hdd_rw_head],al
        mov     [cs:hdd_rw_sector],dl

        call    hdd_read_bounce
        jc      .error

        cmp     byte [cs:rw_write],0
        jne     .write

        push    cs
        pop     ds
        mov     si,HDD_BOUNCE_OFF
        xor     ax,ax
        mov     al,[cs:hdd_rw_quarter]
        mov     cl,7
        shl     ax,cl
        add     si,ax
        mov     ax,CPM_SEG
        mov     es,ax
        mov     di,[cs:hdd_rw_dma]
        mov     cx,64
        cld
        rep     movsw
        xor     al,al
        jmp     gateway_return

.write:
        mov     ax,CPM_SEG
        mov     ds,ax
        mov     si,[cs:hdd_rw_dma]
        push    cs
        pop     es
        mov     di,HDD_BOUNCE_OFF
        xor     ax,ax
        mov     al,[cs:hdd_rw_quarter]
        mov     cl,7
        shl     ax,cl
        add     di,ax
        mov     cx,64
        cld
        rep     movsw
        call    hdd_write_bounce
        jc      .error
        xor     al,al
        jmp     gateway_return
.error:
        mov     al,1
        jmp     gateway_return

hdd_read_bounce:
        mov     byte [cs:hdd_rw_retry],3
.retry:
        push    cs
        pop     es
        mov     bp,HDD_BOUNCE_OFF
        mov     bx,512
        mov     cx,[cs:hdd_rw_cyl]
        mov     dh,[cs:hdd_rw_head]
        mov     dl,[cs:hdd_rw_sector]
        mov     al,[cs:current_daua]
        mov     ah,HDD_READ
        push    ds
        int     DISK_INT
        pop     ds
        jnc     .ok
        dec     byte [cs:hdd_rw_retry]
        jnz     .retry
        stc
        ret
.ok:
        clc
        ret

hdd_write_bounce:
        mov     byte [cs:hdd_rw_retry],3
.retry:
        push    cs
        pop     es
        mov     bp,HDD_BOUNCE_OFF
        mov     bx,512
        mov     cx,[cs:hdd_rw_cyl]
        mov     dh,[cs:hdd_rw_head]
        mov     dl,[cs:hdd_rw_sector]
        mov     al,[cs:current_daua]
        mov     ah,HDD_WRITE
        push    ds
        int     DISK_INT
        pop     ds
        jnc     .ok
        dec     byte [cs:hdd_rw_retry]
        jnz     .retry
        stc
        ret
.ok:
        clc
        ret

svc_sync:
        call    cache_sync
        jc      .error
        xor     al,al
        jmp     gateway_return
.error:
        mov     al,1
        jmp     gateway_return

; ---------------------------------------------------------------------------
; Physical console services. IOBYTE routing remains in the 8080 CBIOS.
; Output character is passed in CL so AL remains the service selector on entry.
; ---------------------------------------------------------------------------
svc_ser_const:
        call    serial_const
        jmp     gateway_return

svc_ser_getc:
        call    serial_getc
        jmp     gateway_return

svc_ser_putc:
        mov     al,cl
        call    serial_putc
        xor     al,al
        jmp     gateway_return

svc_local_const:
        call    local_const
        jmp     gateway_return

svc_local_getc:
        call    local_getc
        jmp     gateway_return

svc_screen_putc:
        mov     al,cl
        call    screen_putc
        xor     al,al
        jmp     gateway_return

svc_ser_outst:
        call    serial_outst
        jmp     gateway_return

; ---------------------------------------------------------------------------
; Warm-boot reload of CCP+BDOS. SID/DDT may overlay the CCP.
; Boot-image payload sectors 17..27 = 11 x 512 bytes = 1600h -> 4000:DC00..F1FF.
; AL=0 success, AL=1 error, AL=2 success after deferred HDD remount.
; ---------------------------------------------------------------------------
svc_wboot_reload:
        call    cache_sync
        jc      .error
        mov     byte [cs:wboot_remounted],0
        cmp     byte [cs:hdd_remount_pending],0
        je      .mapping_ready
        call    cache_clear
        call    hdd_init
        cmp     byte [cs:boot_kind],1
        jne     .remount_done
        call    resolve_boot_hdd_after_scan
        jc      .error
.remount_done:
        mov     byte [cs:hdd_remount_pending],0
        mov     byte [cs:wboot_remounted],1
.mapping_ready:

        cmp     byte [cs:boot_kind],1
        je      .hdd

        ; FDD boot: resident starts at physical LBA17.
        mov     al,[cs:boot_daua]
        test    al,al
        jz      .error
        mov     [cs:wb_daua],al
        mov     al,[cs:media_type]
        cmp     al,1
        je      .start_2dd
        cmp     al,2
        je      .start_2hd
        jmp     .error
.start_2dd:
        mov     byte [cs:wb_cyl],1
        mov     byte [cs:wb_head],0
        mov     byte [cs:wb_sector],2
        mov     byte [cs:wb_spt],8
        jmp     .fdd_start
.start_2hd:
        mov     byte [cs:wb_cyl],0
        mov     byte [cs:wb_head],1
        mov     byte [cs:wb_sector],3
        mov     byte [cs:wb_spt],15
.fdd_start:
        mov     word [cs:wb_dest],0DC00h
        mov     byte [cs:wb_count],11
.fdd_next:
        mov     byte [cs:wb_retry],10
.fdd_retry:
        mov     ax,CPM_SEG
        mov     es,ax
        mov     bp,[cs:wb_dest]
        mov     bx,512
        xor     cx,cx
        mov     cl,[cs:wb_cyl]
        mov     ch,2
        mov     dh,[cs:wb_head]
        mov     dl,[cs:wb_sector]
        mov     al,[cs:wb_daua]
        mov     ah,DISK_READ
        push    ds
        int     DISK_INT
        pop     ds
        jnc     .fdd_ok
        mov     al,[cs:wb_daua]
        mov     ah,DISK_RECAL
        push    ds
        int     DISK_INT
        pop     ds
        dec     byte [cs:wb_retry]
        jnz     .fdd_retry
        jmp     .error
.fdd_ok:
        add     word [cs:wb_dest],512
        inc     byte [cs:wb_sector]
        mov     al,[cs:wb_sector]
        cmp     al,[cs:wb_spt]
        jbe     .fdd_chs_done
        mov     byte [cs:wb_sector],1
        xor     byte [cs:wb_head],1
        cmp     byte [cs:wb_head],0
        jne     .fdd_chs_done
        inc     byte [cs:wb_cyl]
.fdd_chs_done:
        dec     byte [cs:wb_count]
        jnz     .fdd_next
        cmp     byte [cs:wboot_remounted],0
        je      .success0
        mov     al,2
        jmp     gateway_return
.success0:
        xor     al,al
        jmp     gateway_return

.hdd:
        xor     bx,bx
        mov     bl,[cs:boot_hdd_idx]
        cmp     bl,[cs:hdd_count]
        jae     .error
        mov     al,[cs:hdd_daua_map+bx]
        mov     [cs:wb_hdd_daua],al
        mov     al,[cs:hdd_heads_map+bx]
        mov     [cs:wb_hdd_heads],al
        mov     al,[cs:hdd_spt_map+bx]
        mov     [cs:wb_hdd_spt],al
        shl     bx,1
        mov     ax,[cs:hdd_start_cyl_map+bx]
        mov     [cs:wb_hdd_cyl],ax
        mov     byte [cs:wb_hdd_head],0
        mov     byte [cs:wb_hdd_sector],0

        ; Skip HDIPL sector0 and gateway sectors1..16.
        mov     cx,17
.hdd_skip:
        call    wb_hdd_advance
        loop    .hdd_skip

        mov     word [cs:wb_dest],0DC00h
        mov     byte [cs:wb_count],11
.hdd_next:
        mov     byte [cs:wb_retry],3
.hdd_retry:
        mov     ax,CPM_SEG
        mov     es,ax
        mov     bp,[cs:wb_dest]
        mov     bx,512
        mov     cx,[cs:wb_hdd_cyl]
        mov     dh,[cs:wb_hdd_head]
        mov     dl,[cs:wb_hdd_sector]
        mov     al,[cs:wb_hdd_daua]
        mov     ah,HDD_READ
        push    ds
        int     DISK_INT
        pop     ds
        jnc     .hdd_ok
        dec     byte [cs:wb_retry]
        jnz     .hdd_retry
        jmp     .error
.hdd_ok:
        add     word [cs:wb_dest],512
        call    wb_hdd_advance
        dec     byte [cs:wb_count]
        jnz     .hdd_next
        cmp     byte [cs:wboot_remounted],0
        je      .success0_hdd
        mov     al,2
        jmp     gateway_return
.success0_hdd:
        xor     al,al
        jmp     gateway_return

.error:
        mov     al,1
        jmp     gateway_return

wb_hdd_advance:
        inc     byte [cs:wb_hdd_sector]
        mov     al,[cs:wb_hdd_sector]
        cmp     al,[cs:wb_hdd_spt]
        jb      .done
        mov     byte [cs:wb_hdd_sector],0
        inc     byte [cs:wb_hdd_head]
        mov     al,[cs:wb_hdd_head]
        cmp     al,[cs:wb_hdd_heads]
        jb      .done
        mov     byte [cs:wb_hdd_head],0
        inc     word [cs:wb_hdd_cyl]
.done:
        ret

; ---------------------------------------------------------------------------
; Generic raw PC-98 ROM BIOS disk call for CP/M-80 transient utilities.
; Input: DX = offset of RAW_FRAME in the 4000h CP/M segment.
; The transfer buffer is always ES=CPM_SEG, BP=frame.RAW_BP.
; Output registers and CF are written back to the same frame.
; AL returns 0 after the frame has been updated.
; ---------------------------------------------------------------------------
svc_raw_int1b:
        mov     [cs:raw_frame_off],dx

        mov     ax,CPM_SEG
        mov     ds,ax
        mov     si,dx
        mov     ax,[si+RAW_AX]
        mov     bx,[si+RAW_BX]
        mov     cx,[si+RAW_CX]
        mov     dx,[si+RAW_DX]
        mov     bp,[si+RAW_BP]
        mov     di,CPM_SEG
        mov     es,di

        push    ds
        int     DISK_INT
        pop     ds

        mov     [cs:raw_ret_ax],ax
        mov     [cs:raw_ret_bx],bx
        mov     [cs:raw_ret_cx],cx
        mov     [cs:raw_ret_dx],dx
        pushf
        pop     ax
        and     ax,1
        mov     [cs:raw_ret_flags],ax

        mov     ax,CPM_SEG
        mov     ds,ax
        mov     si,[cs:raw_frame_off]
        mov     ax,[cs:raw_ret_ax]
        mov     [si+RAW_AX],ax
        mov     ax,[cs:raw_ret_bx]
        mov     [si+RAW_BX],ax
        mov     ax,[cs:raw_ret_cx]
        mov     [si+RAW_CX],ax
        mov     ax,[cs:raw_ret_dx]
        mov     [si+RAW_DX],ax
        mov     ax,[cs:raw_ret_flags]
        mov     [si+RAW_FLAGS],ax
        xor     al,al
        jmp     gateway_return

; Flush and invalidate one normal FDD cache slot before/after raw media work.
; BH = CP/M physical FDD index 0..3.  AL=0 success, AL=1 failure.
svc_cache_reset:
        mov     bl,bh
        cmp     bl,CACHE_SLOTS
        jae     .bad
        call    cache_reset_drive
        jc      .bad
        xor     al,al
        jmp     gateway_return
.bad:
        mov     al,1
        jmp     gateway_return

; ---------------------------------------------------------------------------
; Return FDD-family information needed by CP/M-80 raw-media utilities.
; Input: DX = offset of 4-byte result structure in CPM_SEG.
; Output structure:
;   +0  2DD DA/UA base (10h or 70h)
;   +1  2HD DA/UA base (90h or F0h)
;   +2  boot DA/UA
;   +3  boot media (1=2DD, 2=2HD, 0=unknown/non-FDD)
; AL=0.
; ---------------------------------------------------------------------------
svc_get_fdd_info:
        mov     ax,CPM_SEG
        mov     ds,ax
        mov     si,dx
        mov     al,[cs:fdd_2dd_base]
        mov     [si+0],al
        mov     al,[cs:fdd_2hd_base]
        mov     [si+1],al
        mov     al,[cs:boot_daua]
        mov     [si+2],al
        mov     al,[cs:media_type]
        mov     [si+3],al
        xor     al,al
        jmp     gateway_return

; ---------------------------------------------------------------------------
; Build the two static CBIOS HDD DPBs and clear their fixed 1-KiB ALVs.
; Input DX -> two entries in CPM_SEG: {dpb_word, alv_word}.
; ---------------------------------------------------------------------------
svc_get_boot_source:
        mov     ax,CPM_SEG
        mov     es,ax
        mov     di,dx
        push    di
        xor     ax,ax
        mov     cx,8
        rep     stosw
        pop     di
        mov     al,[cs:boot_kind]
        mov     [es:di+0],al
        mov     al,[cs:boot_daua]
        mov     [es:di+1],al
        cmp     byte [cs:boot_kind],1
        je      .hdd
        mov     al,[cs:boot_unit]
        mov     [es:di+12],al
        xor     al,al
        jmp     gateway_return
.hdd:
        mov     ax,[cs:gateway_boot_hint+10]
        mov     [es:di+2],ax
        ; Source FSID lives in the resident gateway image, not the CP/M
        ; segment supplied by the caller.  REP MOVSW therefore needs DS=CS.
        push    ds
        push    cs
        pop     ds
        mov     si,gateway_boot_hint+12
        push    di
        add     di,4
        mov     cx,4
        rep     movsw
        pop     di
        pop     ds
        mov     al,[cs:boot_hdd_idx]
        add     al,HDD_FIRST_DRIVE
        mov     [es:di+12],al
        xor     al,al
        jmp     gateway_return

svc_hdd_remount_request:
        mov     byte [cs:hdd_remount_pending],1
        xor     al,al
        jmp     gateway_return

svc_hdd_config:
        mov     ax,CPM_SEG
        mov     ds,ax
        mov     si,dx
        xor     bx,bx
.cfg_loop:
        cmp     bl,HDD_MAX_DRIVES
        jae     .done
        mov     di,[si+2]                 ; ALV
        push    si
        mov     es,ax
        xor     ax,ax
        mov     cx,512
        cld
        rep     stosw                     ; clear fixed 1 KiB ALV
        pop     si

        mov     di,[si]                   ; DPB
        push    si
        push    di                         ; preserve DPB base across REP STOSB
        mov     cx,15
        xor     ax,ax
        rep     stosb
        pop     di                         ; restore DPB base for field writes
        pop     si

        cmp     bl,[cs:hdd_count]
        jae     .next

        ; DPB SPT = heads * sectors/head * 4 logical records.
        xor     ax,ax
        mov     al,[cs:hdd_heads_map+bx]
        xor     dx,dx
        mov     dl,[cs:hdd_spt_map+bx]
        mul     dx
        shl     ax,1
        shl     ax,1
        mov     [di+0],ax
        mov     byte [di+2],7
        mov     byte [di+3],127

        push    bx
        shl     bx,1
        mov     ax,[cs:hdd_blocks_map+bx]
        pop     bx
        dec     ax
        mov     [di+5],ax
        cmp     ax,255
        jbe     .small_exm
        mov     byte [di+4],7
        jmp     .exm_done
.small_exm:
        mov     byte [di+4],15
.exm_done:
        mov     word [di+7],511
        mov     byte [di+9],80h
        mov     byte [di+10],0
        mov     word [di+11],0            ; fixed disk: no CSV
        mov     word [di+13],1            ; reserve partition cylinder 0
.next:
        add     si,4
        inc     bl
        mov     ax,CPM_SEG
        mov     es,ax
        jmp     .cfg_loop
.done:
        xor     al,al
        jmp     gateway_return

; Scan SCSI ID0..6 and pack the first two formatted CP/M-80 partitions E:..F:.
; Partition table entry must be type70h, cylinder-aligned, and sysm="CP/M-80".
resolve_boot_hdd_after_scan:
        cmp     word [cs:gateway_boot_hint+0],5043h
        jne     .fail
        cmp     word [cs:gateway_boot_hint+2],384Dh
        jne     .fail
        cmp     word [cs:gateway_boot_hint+4],4842h
        jne     .fail
        cmp     word [cs:gateway_boot_hint+6],3154h
        jne     .fail
        cmp     byte [cs:gateway_boot_hint+8],1
        jne     .fail
        xor     bx,bx
.loop:
        cmp     bl,[cs:hdd_count]
        jae     .fail
        mov     al,[cs:hdd_daua_map+bx]
        cmp     al,[cs:gateway_boot_hint+9]
        jne     .next
        mov     si,bx
        shl     si,1
        mov     ax,[cs:hdd_start_cyl_map+si]
        cmp     ax,[cs:gateway_boot_hint+10]
        je      .found
.next:
        inc     bl
        jmp     .loop
.found:
        mov     [cs:boot_hdd_idx],bl
        ; The logical boot drive may shift when a newly formatted earlier
        ; partition enters E:/F:.  Keep the resident CBIOS BOOTDRV byte in sync.
        mov     al,bl
        add     al,HDD_FIRST_DRIVE
        push    ax
        mov     ax,CPM_SEG
        mov     es,ax
        pop     ax
        mov     [es:CPM_BOOTDRV_ABI],al
        clc
        ret
.fail:
        stc
        ret

hdd_init:
        mov     byte [cs:hdd_count],0
        mov     byte [cs:hdd_scan_id],0
.id_loop:
        cmp     byte [cs:hdd_scan_id],7
        jae     .done
        mov     al,[cs:hdd_scan_id]
        add     al,0A0h
        mov     [cs:hdd_scan_daua],al

        mov     bx,0A55Ah
        mov     cx,05AA5h
        mov     dx,0C33Ch
        mov     ah,HDD_SENSE
        push    ds
        int     DISK_INT
        pop     ds
        jc      .next_id
        cmp     bx,512
        jne     .next_id
        test    cx,cx
        jz      .next_id
        test    dh,dh
        jz      .next_id
        test    dl,dl
        jz      .next_id
        mov     [cs:hdd_scan_cylast],cx
        mov     [cs:hdd_scan_heads],dh
        mov     [cs:hdd_scan_spt],dl

        ; Absolute partition table C0/H0/S1 -> 4000:C000.
        mov     ax,CPM_SEG
        mov     es,ax
        mov     bp,HDD_SCAN_BUF
        mov     bx,512
        xor     cx,cx
        xor     dx,dx
        mov     dl,1
        mov     al,[cs:hdd_scan_daua]
        mov     ah,HDD_READ
        push    ds
        int     DISK_INT
        pop     ds
        jc      .next_id

        mov     ax,CPM_SEG
        mov     ds,ax
        mov     si,HDD_SCAN_BUF
        mov     byte [cs:hdd_scan_part],0
.part_loop:
        cmp     byte [cs:hdd_scan_part],16
        jae     .next_id
        mov     al,[si+1]
        and     al,7Fh
        cmp     al,HDD_CPM_SYS
        jne     .part_next

        ; Exact printable formatted marker.
        push    si
        push    ds
        push    cs
        pop     es
        add     si,16
        mov     di,hdd_fs_label
        mov     cx,16
        cld
        repe    cmpsb
        pop     ds
        pop     si
        jne     .part_next

        cmp     byte [si+8],0
        jne     .part_next
        cmp     byte [si+9],0
        jne     .part_next
        cmp     byte [si+12],0
        jne     .part_next
        cmp     byte [si+13],0
        jne     .part_next

        mov     ax,[si+10]                ; start cylinder
        mov     dx,[si+14]                ; inclusive end cylinder
        cmp     dx,ax
        jbe     .part_next                ; need >=2 cylinders (OFF=1)
        cmp     dx,[cs:hdd_scan_cylast]
        ja      .part_next
        mov     [cs:hdd_tmp_start],ax
        sub     dx,ax                     ; filesystem data cylinders
        mov     ax,dx

        ; sectors = data_cyl * heads * spt (32-bit DX:AX).
        xor     bx,bx
        mov     bl,[cs:hdd_scan_heads]
        mul     bx
        xor     bx,bx
        mov     bl,[cs:hdd_scan_spt]
        call    hdd_mul32_16
        mov     cl,5                      ; /32 sectors per 16-KiB block
.shift5:
        shr     dx,1
        rcr     ax,1
        dec     cl
        jnz     .shift5
        test    dx,dx
        jnz     .part_next
        test    ax,ax
        jz      .part_next
        cmp     ax,8192
        ja      .part_next
        mov     [cs:hdd_tmp_blocks],ax

        mov     al,[cs:hdd_count]
        cmp     al,HDD_MAX_DRIVES
        jae     .done
        xor     ah,ah
        mov     bx,ax
        mov     al,[cs:hdd_scan_daua]
        mov     [cs:hdd_daua_map+bx],al
        mov     al,[cs:hdd_scan_heads]
        mov     [cs:hdd_heads_map+bx],al
        mov     al,[cs:hdd_scan_spt]
        mov     [cs:hdd_spt_map+bx],al
        shl     bx,1
        mov     ax,[cs:hdd_tmp_start]
        mov     [cs:hdd_start_cyl_map+bx],ax
        mov     ax,[cs:hdd_tmp_blocks]
        mov     [cs:hdd_blocks_map+bx],ax
        inc     byte [cs:hdd_count]

.part_next:
        add     si,32
        inc     byte [cs:hdd_scan_part]
        jmp     .part_loop
.next_id:
        inc     byte [cs:hdd_scan_id]
        jmp     .id_loop
.done:
        push    cs
        pop     ds
        ret

; DX:AX *= BX, low 32-bit result in DX:AX.
hdd_mul32_16:
        push    cx
        push    si
        mov     si,dx
        mul     bx
        mov     cx,dx
        mov     dx,si
        push    ax
        mov     ax,dx
        mul     bx
        add     ax,cx
        mov     dx,ax
        pop     ax
        pop     si
        pop     cx
        ret

gateway_return:
        pop     es
        pop     ds
        pop     bp
        pop     di
        pop     si
        pop     dx
        pop     cx
        pop     bx
        iret

; ---------------------------------------------------------------------------
; Request -> CHS/index.
; ---------------------------------------------------------------------------
snapshot_request:
        mov     al,[cs:current_daua]
        test    al,al
        jz      .bad

        mov     [cs:svc_track],bx
        mov     [cs:svc_sector],cx
        mov     [cs:svc_dma],dx

        mov     al,cl
        and     al,3
        mov     [cs:svc_quarter],al

        ; FDD: BIOS track is a logical side-track.
        mov     ax,bx
        mov     dl,al
        and     dl,1
        mov     [cs:svc_head],dl
        shr     ax,1
        mov     [cs:svc_cyl],al

        mov     ax,cx
        shr     ax,1
        shr     ax,1
        inc     al
        mov     [cs:svc_physsec],al
        clc
        ret
.bad:
        stc
        ret

; ---------------------------------------------------------------------------
; Prepare current drive's complete side-track cache window.
; ---------------------------------------------------------------------------
window_prepare_current:
        xor     bx,bx
        mov     bl,[cs:current_drive]
        cmp     bl,CACHE_SLOTS
        jae     .error
        mov     [cs:win_slot],bl
        shl     bx,1
        mov     ax,[cs:cache_slot_segs+bx]
        mov     [cs:win_seg],ax

        ; FDD cache key = cylinder(size code in CH) + head; first sector=1.
        xor     cx,cx
        mov     cl,[cs:svc_cyl]
        mov     ch,2
        mov     [cs:win_cx],cx
        mov     al,[cs:svc_head]
        mov     [cs:win_head],al
        mov     byte [cs:win_first],1

        mov     al,[cs:svc_physsec]
        dec     al
        mov     [cs:win_index],al

        xor     bx,bx
        mov     bl,[cs:current_drive]
        mov     al,[cs:fdd_media_map+bx]
        mov     byte [cs:win_count],8
        cmp     al,1
        je      .key_ready
        cmp     al,2
        jne     .error
        mov     byte [cs:win_count],15

.key_ready:
        mov     ax,CACHE_META_SEG
        mov     es,ax
        xor     ax,ax
        mov     al,[cs:win_slot]
        mov     cl,4
        shl     ax,cl
        mov     di,ax

        cmp     byte [es:di+CM_VALID],CACHE_VALID
        jne     .miss
        mov     al,[cs:win_head]
        cmp     [es:di+CM_HEAD],al
        jne     .miss
        mov     ax,[cs:win_cx]
        cmp     [es:di+CM_CX],ax
        jne     .miss
        mov     al,[cs:win_first]
        cmp     [es:di+CM_FIRST],al
        jne     .miss
        clc
        ret

.miss:
        mov     bl,[cs:win_slot]
        call    cache_flush_slot
        jc      .error

        mov     ax,CACHE_META_SEG
        mov     es,ax
        xor     ax,ax
        mov     al,[cs:win_slot]
        mov     cl,4
        shl     ax,cl
        mov     di,ax

        mov     byte [es:di+CM_VALID],0
        mov     al,[cs:win_head]
        mov     [es:di+CM_HEAD],al
        mov     ax,[cs:win_cx]
        mov     [es:di+CM_CX],ax
        mov     al,[cs:win_first]
        mov     [es:di+CM_FIRST],al
        mov     word [es:di+CM_DIRTY],0
        mov     byte [es:di+CM_DIRTY_HI],0

        xor     si,si
        xor     di,di
        mov     dl,[cs:win_count]
        xor     dh,dh
        mov     di,dx
        xor     al,al
        mov     bl,[cs:win_slot]
        call    cache_io_run
        jc      .error

        mov     ax,CACHE_META_SEG
        mov     es,ax
        xor     bx,bx
        mov     bl,[cs:win_slot]
        mov     cl,4
        shl     bx,cl
        mov     byte [es:bx+CM_VALID],CACHE_VALID
        clc
        ret

.error:
        stc
        ret

window_mark_dirty:
        mov     ax,CACHE_META_SEG
        mov     es,ax
        xor     bx,bx
        mov     bl,[cs:win_slot]
        mov     cl,4
        shl     bx,cl
        xor     ax,ax
        mov     al,[cs:win_index]
        mov     cl,al
        mov     ax,1
        shl     ax,cl
        or      [es:bx+CM_DIRTY],ax
        ret

cache_dirty_test:
        mov     ax,1
        mov     cx,si
        shl     ax,cl
        test    [es:di+CM_DIRTY],ax
        jz      .clean
        stc
        ret
.clean:
        clc
        ret

cache_clear_run:
        xor     ax,ax
        mov     al,[cs:flush_start]
        mov     si,ax
        xor     ax,ax
        mov     al,[cs:flush_count]
        add     ax,si
.loop:
        cmp     si,ax
        jae     .done
        push    ax
        mov     ax,1
        mov     cx,si
        shl     ax,cl
        not     ax
        and     [es:di+CM_DIRTY],ax
        pop     ax
        inc     si
        jmp     .loop
.done:
        ret

; ---------------------------------------------------------------------------
; Flush one drive slot. Maximal contiguous dirty run -> one BIOS WRITE.
; ---------------------------------------------------------------------------
cache_flush_slot:
        push    bx
        push    es

        cmp     bl,CACHE_SLOTS
        jae     .clean
        mov     [cs:flush_slot],bl
        mov     ax,CACHE_META_SEG
        mov     es,ax
        xor     bh,bh
        mov     di,bx
        mov     cl,4
        shl     di,cl

        cmp     byte [es:di+CM_VALID],CACHE_VALID
        jne     .clean
        mov     ax,[es:di+CM_DIRTY]
        test    ax,ax
        jz      .clean

        xor     si,si
.scan:
        cmp     si,CACHE_MAX_SECTORS
        jae     .clean
        call    cache_dirty_test
        jc      .run_start
        inc     si
        jmp     .scan

.run_start:
        mov     ax,si
        mov     [cs:flush_start],al
.find_end:
        inc     si
        cmp     si,CACHE_MAX_SECTORS
        jae     .run_ready
        call    cache_dirty_test
        jc      .find_end
.run_ready:
        mov     ax,si
        sub     al,[cs:flush_start]
        mov     [cs:flush_count],al

        xor     si,si
        mov     al,[cs:flush_start]
        xor     ah,ah
        mov     si,ax
        xor     di,di
        mov     al,[cs:flush_count]
        xor     ah,ah
        mov     di,ax
        mov     al,1
        mov     bl,[cs:flush_slot]
        call    cache_io_run
        jc      .error

        mov     ax,CACHE_META_SEG
        mov     es,ax
        xor     di,di
        mov     al,[cs:flush_slot]
        xor     ah,ah
        mov     cl,4
        shl     ax,cl
        mov     di,ax
        call    cache_clear_run
        xor     si,si
        jmp     .scan

.clean:
        clc
        jmp     .done
.error:
        stc
.done:
        pop     es
        pop     bx
        ret

; ---------------------------------------------------------------------------
; Multi-sector PC-98 ROM BIOS I/O for cache.
; BL=slot, SI=start index, DI=count, AL=0 READ / 1 WRITE.
; ---------------------------------------------------------------------------
cache_io_run:
        mov     [cs:io_write],al
        mov     [cs:io_slot],bl
        mov     ax,si
        mov     [cs:io_start],al
        mov     ax,di
        mov     [cs:io_count],al

        mov     ax,CACHE_META_SEG
        mov     es,ax
        xor     bh,bh
        mov     di,bx
        mov     cl,4
        shl     di,cl
        mov     ax,[es:di+CM_CX]
        mov     [cs:io_cx],ax
        mov     al,[es:di+CM_HEAD]
        mov     [cs:io_head],al
        mov     al,[es:di+CM_FIRST]
        add     al,[cs:io_start]
        mov     [cs:io_sector],al

        xor     bx,bx
        mov     bl,[cs:io_slot]
        mov     al,[cs:fdd_daua_map+bx]
        test    al,al
        jz      .fail
        mov     [cs:io_daua],al
        mov     byte [cs:io_retry],10
        mov     ah,DISK_READ
        sub     ah,[cs:io_write]
        mov     [cs:io_cmd],ah

.retry:
        xor     bx,bx
        mov     bl,[cs:io_slot]
        shl     bx,1
        mov     ax,[cs:cache_slot_segs+bx]
        xor     bx,bx
        mov     bl,[cs:io_start]
        mov     cl,5
        shl     bx,cl
        add     ax,bx
        mov     es,ax
        xor     bp,bp

        xor     bx,bx
        mov     bl,[cs:io_count]
        mov     cl,9
        shl     bx,cl

        mov     al,[cs:io_daua]
        mov     ah,[cs:io_cmd]
        mov     cx,[cs:io_cx]
        mov     dh,[cs:io_head]
        mov     dl,[cs:io_sector]
        push    ds
        int     DISK_INT
        pop     ds
        jnc     .ok

        mov     al,[cs:io_daua]
        mov     ah,DISK_RECAL
        push    ds
        int     DISK_INT
        pop     ds

        dec     byte [cs:io_retry]
        jnz     .retry
.fail:
        stc
        ret
.ok:
        clc
        ret

cache_sync:
        push    bx
        xor     bx,bx
.loop:
        call    cache_flush_slot
        jc      .done
        inc     bl
        cmp     bl,CACHE_SLOTS
        jb      .loop
.done:
        pop     bx
        ret

; BL=drive. Flush and invalidate only this slot.
cache_reset_drive:
        push    bx
        push    es
        call    cache_flush_slot
        jc      .done

        mov     ax,CACHE_META_SEG
        mov     es,ax
        xor     bh,bh
        mov     di,bx
        mov     cl,4
        shl     di,cl
        mov     byte [es:di+CM_VALID],0
        mov     word [es:di+CM_DIRTY],0
        mov     byte [es:di+CM_DIRTY_HI],0
        clc
.done:
        pop     es
        pop     bx
        ret

cache_clear:
        push    ax
        push    cx
        push    di
        push    es
        mov     ax,CACHE_META_SEG
        mov     es,ax
        xor     ax,ax
        xor     di,di
        mov     cx,(CACHE_SLOTS*CACHE_META_SIZE)/2
        cld
        rep     stosw
        pop     es
        pop     di
        pop     cx
        pop     ax
        clc
        ret

; ---------------------------------------------------------------------------
; FDD media detection.
; ---------------------------------------------------------------------------

; Detect media in physical FDD unit SI (0..3).
;
; When booted from FDD, INIT already knows the active PC-98 command family
; from BOOT_DAUA and fdd_if_known=1, so only that family is tested.
;
; When booted from HDD, BOOT_DAUA identifies the SCSI device instead.
; fdd_if_known remains 0: try 70h/F0h first, then 10h/90h.  The family that
; successfully verifies becomes the active family for subsequent selects.
;
; If no media is inserted, keep fdd_if_known=0 so a later insertion can be
; detected on the next new-login SELDSK.
;
; Return: AL=1 for 2DD, AL=2 for 2HD/2HC; CF set if absent/unrecognized.
fdd_detect_media:
        push    bx
        push    cx
        push    dx
        push    si

        call    fdd_detect_active_family
        jnc     .found

        cmp     byte [cs:fdd_if_known],0
        jne     .absent

        cmp     byte [cs:fdd_2dd_base],70h
        jne     .try_640k_family

        mov     byte [cs:fdd_2dd_base],10h
        mov     byte [cs:fdd_2hd_base],90h
        jmp     .try_alternate

.try_640k_family:
        mov     byte [cs:fdd_2dd_base],70h
        mov     byte [cs:fdd_2hd_base],0F0h

.try_alternate:
        call    fdd_detect_active_family
        jnc     .found

        ; No media / neither family worked.  Leave the family unknown and
        ; restore the historical first candidate for a later insertion.
        mov     byte [cs:fdd_2dd_base],70h
        mov     byte [cs:fdd_2hd_base],0F0h

.absent:
        xor     al,al
        stc
        jmp     .done

.found:
        mov     byte [cs:fdd_if_known],1
        clc

.done:
        pop     si
        pop     dx
        pop     cx
        pop     bx
        ret

fdd_detect_active_family:
        mov     ax,si
        add     al,[cs:fdd_2hd_base]
        mov     ah,DISK_RECAL
        push    ds
        push    si
        int     DISK_INT
        pop     si
        pop     ds
        jc      .try_2dd

        mov     ax,si
        add     al,[cs:fdd_2hd_base]
        mov     ah,DISK_VERIFY
        mov     bx,512
        xor     cx,cx
        mov     ch,2
        xor     dx,dx
        mov     dl,1
        push    ds
        push    si
        int     DISK_INT
        pop     si
        pop     ds
        jnc     .is_2hd

.try_2dd:
        mov     ax,si
        add     al,[cs:fdd_2dd_base]
        mov     ah,DISK_RECAL
        push    ds
        push    si
        int     DISK_INT
        pop     si
        pop     ds
        jc      .absent

        mov     ax,si
        add     al,[cs:fdd_2dd_base]
        mov     ah,DISK_VERIFY
        mov     bx,512
        xor     cx,cx
        mov     ch,2
        xor     dx,dx
        mov     dl,1
        push    ds
        push    si
        int     DISK_INT
        pop     si
        pop     ds
        jnc     .is_2dd

.absent:
        xor     al,al
        stc
        ret
.is_2dd:
        mov     ax,si
        add     al,[cs:fdd_2dd_base]
        mov     [cs:fdd_daua_map+si],al
        mov     al,1
        clc
        ret
.is_2hd:
        mov     ax,si
        add     al,[cs:fdd_2hd_base]
        mov     [cs:fdd_daua_map+si],al
        mov     al,2
        clc
        ret

; ---------------------------------------------------------------------------
; PC-98 local keyboard / CRT and ANSI/VT100 renderer.
; Logical IOBYTE dispatch is intentionally
; not here; this module implements only physical device operations.
; ---------------------------------------------------------------------------
TEXT_SEG        equ 0xA000
ATTR_SEG        equ 0xA200
SCREEN_COLS     equ 80
SCREEN_ROWS     equ 25
ROW_BYTES       equ 160
DEFAULT_ATTR    equ 0xE1

keyboard_init:
    push bx
    push cx

    mov ah, 0x03
    int 0x18

    ; A master-IPL menu key can still be queued (or repeated) while the
    ; system image is starting.  Drain a bounded number of pending local
    ; keystrokes here so the selection key cannot become the first CCP
    ; command character.  AH=01h senses without consuming; AH=00h consumes.
    mov cx, 16
.flush:
    push cx
    mov ah, 0x01
    int 0x18
    pop cx
    test bh, bh
    jz .done
    push cx
    mov ah, 0x00
    int 0x18
    pop cx
    loop .flush
.done:
    pop cx
    pop bx
    ret

screen_init:
    push ax
    push dx

    ; Configure the PC-98 CRT for 80 columns and 25 text rows.
    mov ax, 0x0A00              ; 80 columns, 25 lines
    int 0x18

    mov ah, 0x0D                ; stop text display while reconfiguring
    int 0x18

    mov dx, 0xE120              ; E1h attribute + ASCII space
    mov ah, 0x16                ; clear text/attribute VRAM
    int 0x18

    xor dx, dx                  ; display starts at A000:0000
    mov ah, 0x0E
    int 0x18

    mov ah, 0x0C                ; enable text display
    int 0x18

    mov byte [cs:screen_col], 0
    mov byte [cs:screen_row], 0
    mov byte [cs:esc_state], 0
    mov byte [cs:current_attr], DEFAULT_ATTR
    mov byte [cs:csi_arg1], 0
    mov byte [cs:csi_arg2], 0
    mov byte [cs:saved_screen_col], 0
    mov byte [cs:saved_screen_row], 0
    call screen_update_cursor

    mov ah, 0x11                ; show cursor
    int 0x18

    pop dx
    pop ax
    ret

; ----------------------------------------------------------------------

local_const:
    push bx
    mov ah, 0x01
    int 0x18
    test bh, bh
    jz .none
    mov al, 0xff                ; CP/M convention: input ready
    pop bx
    ret
.none:
    xor al, al
    pop bx
    ret

local_getc:
    mov ah, 0x00
    int 0x18                    ; AL=ANK character, AH=key code
    ret

; UC1 console input combines the local keyboard and RS-232C.

screen_putc:
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    push es

    cmp byte [cs:esc_state], 0
    jne .ansi_feed

    cmp al, 0x1B
    jne .normal
    mov byte [cs:esc_state], 1
    jmp .done

.ansi_feed:
    call ansi_feed
    jmp .done

.normal:
    cmp al, 0x07
    je .bel
    cmp al, 0x0D
    je .cr
    cmp al, 0x0A
    je .lf
    cmp al, 0x0C
    je .ff
    cmp al, 0x08
    je .bs
    cmp al, 0x09
    je .tab
    cmp al, 0x20
    jb .done

    ; Store one ANK character with the current SGR-derived attribute.
    mov bl, al
    call screen_calc_offset      ; DI = byte address of current cell

    mov ax, TEXT_SEG
    mov es, ax
    xor ax, ax
    mov al, bl
    stosw                        ; A000:DI, then DI += 2

    sub di, 2                    ; same cell in the attribute plane
    mov ax, ATTR_SEG
    mov es, ax
    xor ax, ax
    mov al, [cs:current_attr]
    stosw                        ; A200:DI

    inc byte [cs:screen_col]
    cmp byte [cs:screen_col], SCREEN_COLS
    jb .cursor
    mov byte [cs:screen_col], 0
    inc byte [cs:screen_row]
    jmp .check_scroll

.bel:
    mov ah, 0x17
    int 0x18
    xor cx, cx
.bel_delay1:
    loop .bel_delay1
    xor cx, cx
.bel_delay2:
    loop .bel_delay2
    mov ah, 0x18
    int 0x18
    jmp .done

.ff:
    mov dx, 0xE120              ; E1h attribute + ASCII space
    mov ah, 0x16
    int 0x18
    mov byte [cs:screen_col], 0
    mov byte [cs:screen_row], 0
    jmp .cursor

.cr:
    mov byte [cs:screen_col], 0
    jmp .cursor

.lf:
    inc byte [cs:screen_row]
.check_scroll:
    cmp byte [cs:screen_row], SCREEN_ROWS
    jb .cursor
    call screen_scroll
    mov byte [cs:screen_row], SCREEN_ROWS - 1
    jmp .cursor

.bs:
    cmp byte [cs:screen_col], 0
    je .cursor
    dec byte [cs:screen_col]
    jmp .cursor

.tab:
.tab_loop:
    mov al, ' '
    call screen_putc
    mov al, [cs:screen_col]
    test al, 7
    jnz .tab_loop
    jmp .done

.cursor:
    call screen_update_cursor
.done:
    pop es
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; Feed AL to the ANSI parser.  esc_state values:
;   1 = after ESC
;   2 = CSI first argument
;   3 = CSI second argument
; Cursor/erase commands need at most two numeric arguments.  SGR also
; accepts one or two parameters for SGR.
ansi_feed:
    mov bl, al
    mov al, [cs:esc_state]
    cmp al, 1
    jne .csi

    cmp bl, '7'
    je ansi_save
    cmp bl, '8'
    je ansi_restore
    cmp bl, '['
    jne ansi_abort
    mov byte [cs:esc_state], 2
    mov byte [cs:csi_arg1], 0
    mov byte [cs:csi_arg2], 0
    ret

.csi:
    mov al, bl
    sub al, '0'
    cmp al, 10
    jb ansi_digit

    cmp bl, ';'
    je ansi_semicolon
    cmp bl, 'm'
    jne .not_sgr
    jmp ansi_sgr
.not_sgr:
    cmp bl, 'A'
    je ansi_up
    cmp bl, 'B'
    je ansi_down
    cmp bl, 'C'
    je ansi_right
    cmp bl, 'D'
    je ansi_left
    cmp bl, 'E'
    je ansi_nextline
    cmp bl, 'F'
    je ansi_prevline
    cmp bl, 'G'
    je ansi_col
    cmp bl, 'J'
    je ansi_erase_display
    cmp bl, 'K'
    je ansi_erase_line
    cmp bl, 'H'
    je ansi_position
    cmp bl, 'f'
    je ansi_position
    cmp bl, 'd'
    je ansi_row
    cmp bl, 's'
    je ansi_save
    cmp bl, 'u'
    je ansi_restore
    jmp ansi_abort

ansi_digit:
    ; BL still contains the original character.  Convert it to 0..9 in DL.
    mov dl, bl
    sub dl, '0'
    mov al, [cs:esc_state]
    cmp al, 2
    je .arg1
    cmp al, 3
    jne ansi_abort
    mov si, csi_arg2
    jmp .accumulate
.arg1:
    mov si, csi_arg1
.accumulate:
    mov al, [cs:si]
    cmp al, 25                  ; saturate rather than overflow above 255
    ja .saturate
    jne .calc
    cmp dl, 5
    ja .saturate
.calc:
    xor ah, ah
    mov cl, al
    shl al, 1                   ; old * 2
    mov ah, al
    shl al, 1                   ; old * 4
    shl al, 1                   ; old * 8
    add al, ah                  ; old * 10
    add al, dl
    mov [cs:si], al
    ret
.saturate:
    mov byte [cs:si], 0xFF
    ret

ansi_semicolon:
    cmp byte [cs:esc_state], 2
    jne ansi_abort
    mov byte [cs:esc_state], 3
    ret

; AL <- first argument, with ANSI default 1 for zero/omitted.
ansi_count:
    mov al, [cs:csi_arg1]
    test al, al
    jnz .done
    mov al, 1
.done:
    ret

ansi_up:
    call ansi_count
    mov bl, al
    mov al, [cs:screen_row]
    sub al, bl
    jnc .store
    xor al, al
.store:
    mov [cs:screen_row], al
    jmp ansi_move_finish

ansi_down:
    call ansi_count
    mov bl, al
    mov al, [cs:screen_row]
    add al, bl
    jc .max
    cmp al, SCREEN_ROWS
    jb .store
.max:
    mov al, SCREEN_ROWS - 1
.store:
    mov [cs:screen_row], al
    jmp ansi_move_finish

ansi_right:
    call ansi_count
    mov bl, al
    mov al, [cs:screen_col]
    add al, bl
    jc .max
    cmp al, SCREEN_COLS
    jb .store
.max:
    mov al, SCREEN_COLS - 1
.store:
    mov [cs:screen_col], al
    jmp ansi_move_finish

ansi_left:
    call ansi_count
    mov bl, al
    mov al, [cs:screen_col]
    sub al, bl
    jnc .store
    xor al, al
.store:
    mov [cs:screen_col], al
    jmp ansi_move_finish

ansi_nextline:
    call ansi_count
    mov bl, al
    mov al, [cs:screen_row]
    add al, bl
    jc .max
    cmp al, SCREEN_ROWS
    jb .row_ok
.max:
    mov al, SCREEN_ROWS - 1
.row_ok:
    mov [cs:screen_row], al
    mov byte [cs:screen_col], 0
    jmp ansi_move_finish

ansi_prevline:
    call ansi_count
    mov bl, al
    mov al, [cs:screen_row]
    sub al, bl
    jnc .row_ok
    xor al, al
.row_ok:
    mov [cs:screen_row], al
    mov byte [cs:screen_col], 0
    jmp ansi_move_finish

ansi_col:
    mov al, [cs:csi_arg1]
    test al, al
    jnz .nonzero
    mov al, 1
.nonzero:
    cmp al, SCREEN_COLS + 1
    jb .range_ok
    mov al, SCREEN_COLS
.range_ok:
    dec al
    mov [cs:screen_col], al
    jmp ansi_move_finish

ansi_row:
    mov al, [cs:csi_arg1]
    test al, al
    jnz .nonzero
    mov al, 1
.nonzero:
    cmp al, SCREEN_ROWS + 1
    jb .range_ok
    mov al, SCREEN_ROWS
.range_ok:
    dec al
    mov [cs:screen_row], al
    jmp ansi_move_finish

ansi_position:
    mov al, [cs:csi_arg1]
    test al, al
    jnz .row_nonzero
    mov al, 1
.row_nonzero:
    cmp al, SCREEN_ROWS + 1
    jb .row_ok
    mov al, SCREEN_ROWS
.row_ok:
    dec al
    mov [cs:screen_row], al

    mov al, [cs:csi_arg2]
    test al, al
    jnz .col_nonzero
    mov al, 1
.col_nonzero:
    cmp al, SCREEN_COLS + 1
    jb .col_ok
    mov al, SCREEN_COLS
.col_ok:
    dec al
    mov [cs:screen_col], al
    jmp ansi_move_finish

ansi_save:
    mov al, [cs:screen_col]
    mov [cs:saved_screen_col], al
    mov al, [cs:screen_row]
    mov [cs:saved_screen_row], al
    jmp ansi_finish

ansi_restore:
    mov al, [cs:saved_screen_col]
    cmp al, SCREEN_COLS
    jb .col_ok
    mov al, SCREEN_COLS - 1
.col_ok:
    mov [cs:screen_col], al
    mov al, [cs:saved_screen_row]
    cmp al, SCREEN_ROWS
    jb .row_ok
    mov al, SCREEN_ROWS - 1
.row_ok:
    mov [cs:screen_row], al
    jmp ansi_move_finish

ansi_erase_display:
    mov al, [cs:csi_arg1]
    cmp al, 0
    je .mode0
    cmp al, 1
    je .mode1
    cmp al, 2
    je .mode2
    jmp ansi_abort

.mode0:
    ; Current cell through bottom-right.
    call screen_calc_offset
    mov bx, di
    mov ax, SCREEN_ROWS * SCREEN_COLS
    mov dx, di
    shr dx, 1
    sub ax, dx
    mov cx, ax
    mov di, bx
    call screen_blank_cells
    jmp ansi_move_finish

.mode1:
    ; Top-left through current cell.
    call screen_calc_offset
    shr di, 1
    inc di
    mov cx, di
    xor di, di
    call screen_blank_cells
    jmp ansi_move_finish

.mode2:
    xor di, di
    mov cx, SCREEN_ROWS * SCREEN_COLS
    call screen_blank_cells
    jmp ansi_move_finish

ansi_erase_line:
    mov al, [cs:csi_arg1]
    cmp al, 0
    je .mode0
    cmp al, 1
    je .mode1
    cmp al, 2
    je .mode2
    jmp ansi_abort

.mode0:
    call screen_calc_offset
    mov bx, di
    xor ax, ax
    mov al, [cs:screen_col]
    mov cx, SCREEN_COLS
    sub cx, ax
    mov di, bx
    call screen_blank_cells
    jmp ansi_move_finish

.mode1:
    call screen_calc_offset
    xor ax, ax
    mov al, [cs:screen_col]
    inc ax
    mov cx, ax
    xor ax, ax
    mov al, [cs:screen_row]
    mov bx, ROW_BYTES
    mul bx
    mov di, ax
    call screen_blank_cells
    jmp ansi_move_finish

.mode2:
    xor ax, ax
    mov al, [cs:screen_row]
    mov bx, ROW_BYTES
    mul bx
    mov di, ax
    mov cx, SCREEN_COLS
    call screen_blank_cells
    jmp ansi_move_finish

ansi_sgr:
    ; Apply parameter 1.  Omitted parameter is zero, i.e. SGR reset.
    mov al, [cs:csi_arg1]
    call ansi_sgr_apply

    ; esc_state==3 means a semicolon introduced parameter 2.  An omitted
    ; second parameter is also zero, matching ANSI's empty-parameter rule.
    cmp byte [cs:esc_state], 3
    jne ansi_finish
    mov al, [cs:csi_arg2]
    call ansi_sgr_apply
    jmp ansi_finish

; Apply one SGR parameter in AL.
; Supported:
;   0        reset all attributes
;   4 / 24   underline on/off
;   5 / 25   blink on/off
;   7 / 27   reverse on/off
;   30..37   ANSI foreground colors
;   39       default foreground color
; Other SGR parameters (for example bold/intensity) are silently ignored.
;
; PC-98 text attribute low bits used here:
;   bit 3 = underline, bit 2 = reverse, bit 1 = blink, bit 0 = display enable.
; DEFAULT_ATTR keeps bit 0 set, and decoration changes preserve it.
ansi_sgr_apply:
    test al, al
    jz .reset

    cmp al, 4
    je .underline_on
    cmp al, 5
    je .blink_on
    cmp al, 7
    je .reverse_on

    cmp al, 24
    je .underline_off
    cmp al, 25
    je .blink_off
    cmp al, 27
    je .reverse_off

    cmp al, 30
    jb .done
    cmp al, 37
    jbe .color
    cmp al, 39
    je .default_color
    jmp .done

.reset:
    mov byte [cs:current_attr], DEFAULT_ATTR
    ret

.underline_on:
    or byte [cs:current_attr], 0x08
    ret
.underline_off:
    and byte [cs:current_attr], 0xF7
    ret

.blink_on:
    or byte [cs:current_attr], 0x02
    ret
.blink_off:
    and byte [cs:current_attr], 0xFD
    ret

.reverse_on:
    or byte [cs:current_attr], 0x04
    ret
.reverse_off:
    and byte [cs:current_attr], 0xFB
    ret

.default_color:
    mov al, [cs:current_attr]
    and al, 0x1F                  ; preserve decoration/control bits
    or al, (DEFAULT_ATTR & 0xE0)  ; default foreground = white
    mov [cs:current_attr], al
    ret

.color:
    sub al, 30
    xor bh, bh
    mov bl, al
    mov al, [cs:ansi_color_bits + bx]
    mov ah, [cs:current_attr]
    and ah, 0x1F                  ; preserve decoration/control bits
    or al, ah
    mov [cs:current_attr], al
.done:
    ret

ansi_move_finish:
    call screen_update_cursor
ansi_finish:
    mov byte [cs:esc_state], 0
    ret

ansi_abort:
    mov byte [cs:esc_state], 0
    ret

; Blank CX cells beginning at byte offset DI in both text and attribute VRAM.
; The cursor position is not changed.
screen_blank_cells:
    push ax
    push bx
    push cx
    push dx
    push di
    push es

    mov bx, di
    mov dx, cx
    mov ax, TEXT_SEG
    mov es, ax
    mov ax, 0x0020
    cld
    rep stosw

    mov di, bx
    mov cx, dx
    mov ax, ATTR_SEG
    mov es, ax
    mov ax, DEFAULT_ATTR
    rep stosw

    pop es
    pop di
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; Return DI = row*160 + col*2.
screen_calc_offset:
    ; Preserve BX.  screen_putc keeps the character in BL while calling
    ; this routine; clobbering BX here would replace it with A0h
    ; (ROW_BYTES = 160).
    push bx
    xor ax, ax
    mov al, [cs:screen_row]
    mov bx, ROW_BYTES
    mul bx
    mov di, ax
    xor ax, ax
    mov al, [cs:screen_col]
    shl ax, 1
    add di, ax
    pop bx
    ret

screen_update_cursor:
    push ax
    push bx
    push dx
    push di
    call screen_calc_offset
    mov dx, di
    mov ah, 0x13
    int 0x18
    pop di
    pop dx
    pop bx
    pop ax
    ret

; Scroll one text row upward, including attributes, and clear the bottom.
screen_scroll:
    push ax
    push cx
    push si
    push di
    push ds
    push es

    cld

    ; Character plane: rows 1..24 -> rows 0..23.
    mov ax, TEXT_SEG
    mov ds, ax
    mov es, ax
    mov si, ROW_BYTES
    xor di, di
    mov cx, (SCREEN_ROWS - 1) * SCREEN_COLS
    rep movsw

    mov ax, 0x0020              ; blank final row with spaces
    mov cx, SCREEN_COLS
    rep stosw

    ; Attribute plane: move rows and restore default attribute on last row.
    mov ax, ATTR_SEG
    mov ds, ax
    mov es, ax
    mov si, ROW_BYTES
    xor di, di
    mov cx, (SCREEN_ROWS - 1) * SCREEN_COLS
    rep movsw

    mov ax, DEFAULT_ATTR
    mov cx, SCREEN_COLS
    rep stosw

    pop es
    pop ds
    pop di
    pop si
    pop cx
    pop ax
    ret

; BDA 0000:0501 bit7 selects the system-clock family.

; ---------------------------------------------------------------------------
; Serial initialization.
; ---------------------------------------------------------------------------
serial_init:
        push    ax
        push    ds
        xor     ax,ax
        mov     ds,ax
        mov     al,0B6h
        out     PIT_CTRL,al
        mov     ax,16
        test    byte [SYS_FLAG],80h
        jz      .pit_set
        mov     ax,13
.pit_set:
        out     PIT_CH2,al
        mov     al,ah
        out     PIT_CH2,al
        pop     ds

        xor     al,al
        out     SER_CTRL,al
        out     SER_CTRL,al
        out     SER_CTRL,al
        mov     al,40h
        out     SER_CTRL,al
        mov     al,4Eh
        out     SER_CTRL,al
        mov     al,37h
        out     SER_CTRL,al
        pop     ax
        ret


serial_const:
    in al, SER_CTRL
    test al, 0x02                 ; RxRDY
    jz .none
    mov al, 0xff
    ret
.none:
    xor al, al
    ret

serial_outst:
    in al, SER_CTRL
    test al, 0x01                 ; TxRDY
    jz .none
    mov al, 0xff
    ret
.none:
    xor al, al
    ret

serial_getc:
.wait:
    in al, SER_CTRL
    test al, 0x02                 ; RxRDY
    jz .wait
    in al, SER_DATA
    ret

serial_putc:
    push ax
.wait:
    in al, SER_CTRL
    test al, 0x01                 ; TxRDY
    jz .wait
    pop ax
    out SER_DATA, al
    ret

; ---------------------------------------------------------------------------
; State.
; ---------------------------------------------------------------------------
wb_daua         db 0
wb_cyl          db 0
wb_head         db 0
wb_sector       db 0
wb_spt          db 0
wb_count        db 0
wb_retry        db 0
wb_dest         dw 0
wb_hdd_daua     db 0
wb_hdd_heads    db 0
wb_hdd_spt      db 0
wb_hdd_head     db 0
wb_hdd_sector   db 0
wb_hdd_cyl      dw 0

boot_daua       db 0
boot_unit       db 0
media_type      db 0
boot_kind       db 0
hdd_remount_pending db 0
wboot_remounted db 0
boot_hdd_idx    db 0FFh
fdd_2dd_base    db 70h
fdd_2hd_base    db 0F0h
fdd_if_known    db 0             ; 0=probe both families, 1=family fixed
fdd_media_map   times 4 db 0
fdd_daua_map    times 4 db 0
fdd_boot_seed_map times 4 db 0

current_drive   db 0
current_daua    db 0
current_kind    db 0
select_login    db 0

svc_track       dw 0
svc_sector      dw 0
svc_quarter     db 0
svc_cyl         db 0
svc_head        db 0
svc_physsec     db 1
svc_dma         dw 0080h
rw_write        db 0

hdd_count          db 0
hdd_scan_id        db 0
hdd_scan_part      db 0
hdd_scan_daua      db 0
hdd_scan_heads     db 0
hdd_scan_spt       db 0
hdd_scan_cylast    dw 0
hdd_tmp_start      dw 0
hdd_tmp_blocks     dw 0
hdd_daua_map       times 2 db 0
hdd_heads_map      times 2 db 0
hdd_spt_map        times 2 db 0
hdd_start_cyl_map  times 2 dw 0
hdd_blocks_map     times 2 dw 0
hdd_heads_cur      db 0
hdd_spt_cur        db 0
hdd_start_cyl_cur  dw 0
hdd_rw_track       dw 0
hdd_rw_record      dw 0
hdd_rw_dma         dw 0
hdd_rw_cyl         dw 0
hdd_rw_head        db 0
hdd_rw_sector      db 0
hdd_rw_quarter     db 0
hdd_rw_retry       db 0
hdd_fs_label       db 'CP/M-80         '

win_slot        db 0
win_index       db 0
win_count       db 0
win_head        db 0
win_first       db 1
win_cx          dw 0
win_seg         dw 0

flush_slot      db 0
flush_start     db 0
flush_count     db 0

io_write        db 0
io_slot         db 0
io_start        db 0
io_count        db 0
io_head         db 0
io_sector       db 1
io_daua         db 0
io_cmd          db 0
io_retry        db 0
io_cx           dw 0

raw_frame_off   dw 0
raw_ret_ax      dw 0
raw_ret_bx      dw 0
raw_ret_cx      dw 0
raw_ret_dx      dw 0
raw_ret_flags   dw 0

; Local screen / ANSI state.
screen_col       db 0
screen_row       db 0
current_attr     db DEFAULT_ATTR
esc_state        db 0
csi_arg1         db 0
csi_arg2         db 0
saved_screen_col db 0
saved_screen_row db 0
ansi_color_bits  db 00h,40h,80h,0C0h,20h,60h,0A0h,0E0h

; FDD GVRAM cache slot segments.
cache_slot_segs:
        dw 0A800h,0A9E0h,0B000h,0B1E0h

; 64-byte private boot hint reserved for HDIPL80/HDD-aware gateway code.
; FDD IPL leaves this area zero.
times GATEWAY_HINT_OFF-($-$$) db 0
gateway_boot_hint:
        times 40h db 0
