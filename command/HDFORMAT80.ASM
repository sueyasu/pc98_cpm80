; HDFORMAT80.ASM
; PC-9801 CP/M-80 SCSI partition formatter for V30 8080-emulation CP/M 2.2.
;
; Usage:
;   HDFORMAT80 SCSI-ID:PARTITION [/S] [/M]
;
; SCSI-ID   0..6
; PARTITION 1..16
; /S        install bootable CP/M-80 system from the current boot source
; /M        force common MASTER IPL replacement; valid only with /S
;
; Format:
;   type 70h, 512-byte physical sectors only
;   16-KiB allocation blocks, BSH=7, BLM=127
;   maximum 8192 blocks (128 MiB usable filesystem)
;   DRM=511, AL0=80h, AL1=00h, CKS=0, OFF=1
;   first partition cylinder reserved for HDIPL + gateway16 + resident14
;   filesystem begins at start_cylinder+1
;
; Ordinary format writes CPM80FS1 metadata and leaves partition non-bootable.
; /S accepts either an FDD or HDD boot source and verifies source/target data.
; It installs a missing common CP/M-80/86 master IPL and automatically updates
; an older version of our "CPM8MIPL" master.  Foreign/NEC masters are preserved
; unless /M is specified, which forces replacement with the current master.
;
; All PC-98 ROM BIOS INT 1Bh operations use gateway SVC_RAW_INT1B.
;
; Build:
;   1. provide generated HDIPL80.INC and MASTERIPL80.INC
;   2. asm8080 HDFORMAT80.ASM
;
BDOS            EQU     0005H
CMDLEN          EQU     0080H
CMDTAIL         EQU     0081H
BOOTDRV_ABI     EQU     0F7FCH

CALLN_VEC       EQU     061H
SVC_RAW_INT1B   EQU     0DH
SVC_CACHE_RESET  EQU     0EH
SVC_GET_FDD_INFO EQU    0FH
SVC_GET_BOOT_SOURCE EQU   11H
SVC_HDD_REMOUNT_REQUEST EQU 12H

CPM_SYS         EQU     070H
SECTOR_SIZE     EQU     512
PART_SIZE       EQU     32
PART_COUNT      EQU     16
MAX_BLOCKS      EQU     8192
DIR_SECTORS     EQU     32
PAYLOAD_SECTORS EQU     30
MAX_RETRY       EQU     5
MASTER_MAGIC_OFF EQU    0100H
MASTER_VER_OFF  EQU     0108H
MASTER_IPL_VERSION EQU  4

                ORG     0100H

START:
                LXI     SP,STACK_TOP
                LXI     D,MSG_BANNER
                CALL    PUTS
                CALL    PARSE_ARGS
                JNC     ARGS_OK
                LXI     D,MSG_USAGE
                CALL    PUTS
                JMP     EXIT

ARGS_OK:
                ; HDFORMAT_0914 flushes and invalidates BIOS caches before raw I/O.
                MVI     A,SVC_CACHE_RESET
                DB      0EDH,0EDH,CALLN_VEC
                ORA     A
                JZ      HCACHE_READY
                LXI     D,MSG_CACHEERR
                CALL    PUTS
                JMP     EXIT
HCACHE_READY:
                LDA     SCSI_ID
                ORI     0A0H
                STA     DAUA
                CALL    SENSE
                JNC     HSENSE_OK
                LXI     D,MSG_NODISK
                CALL    PUTS
                JMP     EXIT
HSENSE_OK:
                LHLD    SEC_SIZE
                MOV     A,H
                CPI     02H
                JNZ     HBADSECTOR
                MOV     A,L
                ORA     A
                JNZ     HBADSECTOR

                CALL    CHECK_MASTER_IPL
                JC      MASTER_READ_FAIL
                LDA     MASTER_PRESENT
                ORA     A
                JNZ     MASTER_OK
                LDA     SYSTEM_FLAG
                ORA     A
                JNZ     MASTER_OK
                LXI     D,MSG_BADIPL
                CALL    PUTS
                JMP     EXIT
MASTER_READ_FAIL:
                LXI     D,MSG_MASTERREAD
                CALL    PUTS
                CALL    SHOW_STATUS
                JMP     EXIT
MASTER_OK:
                CALL    LOAD_TABLE
                JNC     HTABLE_OK
                LXI     D,MSG_READERR
                CALL    PUTS
                CALL    SHOW_STATUS
                JMP     EXIT
HBADSECTOR:
                LXI     D,MSG_BADSECTOR
                CALL    PUTS
                JMP     EXIT

HTABLE_OK:
                CALL    SELECT_ENTRY
                JNC     ENTRY_OK
                LXI     D,MSG_BADPART
                CALL    PUTS
                JMP     EXIT
ENTRY_OK:
                CALL    VALIDATE_ENTRY
                JNC     VALID_OK
                LXI     D,MSG_NOTCPM
                CALL    PUTS
                JMP     EXIT
VALID_OK:
                CALL    CALC_LAYOUT
                JNC     LAYOUT_OK
                LXI     D,MSG_SIZE
                CALL    PUTS
                JMP     EXIT

LAYOUT_OK:
                CALL    SHOW_PLAN
                LXI     D,MSG_WARN
                CALL    PUTS
                CALL    GETC
                CALL    UPPER
                CPI     'Y'
                JZ      DO_FORMAT
                CALL    CRLF
                LXI     D,MSG_ABORT
                CALL    PUTS
                JMP     EXIT

DO_FORMAT:
                CALL    GENERATE_FSID

                LDA     SYSTEM_FLAG
                ORA     A
                JZ      NORMAL_META
                CALL    PREPARE_SYSTEM
                JNC     SYSTEM_READY
                LXI     D,MSG_SYSFAIL
                CALL    PUTS
                JMP     EXIT
SYSTEM_READY:
                CALL    MASTER_UPDATE_NEEDED
                ORA     A
                JZ      WRITE_META
                LXI     D,MSG_MASTERINSTALL
                CALL    PUTS
                CALL    INSTALL_MASTER_IPL
                JNC     WRITE_META
                LXI     D,MSG_MASTERERR
                CALL    PUTS
                CALL    SHOW_STATUS
                JMP     EXIT
NORMAL_META:
                CALL    MAKE_METADATA
WRITE_META:
                CALL    WRITE_IPL_SECTOR
                JNC     META_OK
                LXI     D,MSG_METAERR
                CALL    PUTS
                CALL    SHOW_STATUS
                JMP     EXIT
META_OK:
                LDA     SYSTEM_FLAG
                ORA     A
                JZ      DIR_FORMAT
                CALL    WRITE_SYSTEM_PAYLOAD
                JNC     SYS_WRITTEN
                LXI     D,MSG_SYSWRITE
                CALL    PUTS
                CALL    SHOW_STATUS
                JMP     EXIT
SYS_WRITTEN:
                LXI     D,MSG_SYSVERIFY
                CALL    PUTS
                CALL    VERIFY_DEST_SYSTEM
                JNC     DIR_FORMAT
                LXI     D,MSG_SYSVERIFYERR
                CALL    PUTS
                CALL    SHOW_STATUS
                JMP     EXIT

DIR_FORMAT:
                LXI     D,MSG_DIR
                CALL    PUTS
                CALL    FORMAT_DIRECTORY
                JNC     SIG_UPDATE
                LXI     D,MSG_DIRERR
                CALL    PUTS
                CALL    SHOW_STATUS
                JMP     EXIT

SIG_UPDATE:
                CALL    UPDATE_PARTITION_ENTRY
                JNC     SIG_OK
                LXI     D,MSG_PTWRITE
                CALL    PUTS
                CALL    SHOW_STATUS
                JMP     EXIT
SIG_OK:
DONE:
                LXI     D,MSG_DONE
                CALL    PUTS
                CALL    REQUEST_HDD_REMOUNT

EXIT:
                MVI     C,0
                CALL    BDOS
                HLT

; ----------------------------------------------------------------------
; Arguments: n:p [/S] [/M]
; /M forces replacement of C0/H0/S0 and is valid only with /S.
; ----------------------------------------------------------------------
PARSE_ARGS:
                XRA     A
                STA     SYSTEM_FLAG
                STA     MASTER_FORCE
                LDA     CMDLEN
                MOV     B,A
                LXI     H,CMDTAIL
PA_SKIP:
                MOV     A,B
                ORA     A
                JZ      PA_FAIL
                MOV     A,M
                CPI     ' '
                JNZ     PA_ID
                INX     H
                DCR     B
                JMP     PA_SKIP
PA_ID:
                CPI     '0'
                JC      PA_FAIL
                CPI     '7'
                JNC     PA_FAIL
                SUI     '0'
                STA     SCSI_ID
                INX     H
                DCR     B
                MOV     A,B
                ORA     A
                JZ      PA_FAIL
                MOV     A,M
                CPI     ':'
                JNZ     PA_FAIL
                INX     H
                DCR     B
                ; partition decimal 1..16
                LXI     D,0
PA_PART:
                MOV     A,B
                ORA     A
                JZ      PA_PART_DONE
                MOV     A,M
                CPI     ' '
                JZ      PA_PART_DONE
                CPI     '/'
                JZ      PA_PART_DONE
                CPI     '-'
                JZ      PA_PART_DONE
                CPI     '0'
                JC      PA_FAIL
                CPI     '9'+1
                JNC     PA_FAIL
                SUI     '0'
                STA     DIGIT
                ; DE=DE*10+digit, tiny value.
                MOV     A,E
                MOV     C,A
                ADD     A
                MOV     E,A
                ADD     A
                ADD     A
                ADD     C
                ADD     C
                MOV     E,A
                LDA     DIGIT
                ADD     E
                MOV     E,A
                INX     H
                DCR     B
                JMP     PA_PART
PA_PART_DONE:
                MOV     A,E
                ORA     A
                JZ      PA_FAIL
                CPI     17
                JNC     PA_FAIL
                STA     PART_NO
PA_OPTS:
                MOV     A,B
                ORA     A
                JZ      PA_OK
                MOV     A,M
                CPI     ' '
                JZ      PA_NEXT
                CPI     '/'
                JZ      PA_OPT
                CPI     '-'
                JNZ     PA_FAIL
PA_OPT:
                INX     H
                DCR     B
                MOV     A,B
                ORA     A
                JZ      PA_FAIL
                MOV     A,M
                CALL    UPPER
                CPI     'S'
                JZ      PA_SET_S
                CPI     'M'
                JZ      PA_SET_M
                JMP     PA_FAIL
PA_SET_S:
                MVI     A,1
                STA     SYSTEM_FLAG
                JMP     PA_OPT_CONSUME
PA_SET_M:
                MVI     A,1
                STA     MASTER_FORCE
PA_OPT_CONSUME:
                INX     H
                DCR     B
                JMP     PA_OPTS
PA_NEXT:
                INX     H
                DCR     B
                JMP     PA_OPTS
PA_OK:
                ; /M is intentionally dangerous and only valid with /S.
                LDA     MASTER_FORCE
                ORA     A
                JZ      PA_OK_RET
                LDA     SYSTEM_FLAG
                ORA     A
                JZ      PA_FAIL
PA_OK_RET:
                XRA     A
                RET
PA_FAIL:
                STC
                RET

SENSE:
                LDA     DAUA
                STA     RAW_AX
                MVI     A,084H
                STA     RAW_AX+1
                LXI     H,0A55AH
                SHLD    RAW_BX
                LXI     H,05AA5H
                SHLD    RAW_CX
                LXI     H,0C33CH
                SHLD    RAW_DX
                LXI     H,0
                SHLD    RAW_BP
                CALL    RAW_CALL
                RC
                LHLD    RAW_BX
                SHLD    SEC_SIZE
                LHLD    RAW_CX
                SHLD    CYL_LAST
                LDA     RAW_DX+1
                STA     HEADS
                LDA     RAW_DX
                STA     SPT
                ORA     A
                JZ      SENSE_FAIL
                LDA     HEADS
                ORA     A
                JZ      SENSE_FAIL
                XRA     A
                RET
SENSE_FAIL:
                STC
                RET

LOAD_TABLE:
                LXI     H,TABLE
                MVI     A,006H
                JMP     RAW_HDD_PT
SAVE_TABLE:
                LXI     H,TABLE
                MVI     A,005H
RAW_HDD_PT:
                STA     IO_FUNC
                MVI     A,MAX_RETRY
                STA     RETRY
RHP_LOOP:
                LDA     DAUA
                STA     RAW_AX
                LDA     IO_FUNC
                STA     RAW_AX+1
                LXI     H,SECTOR_SIZE
                SHLD    RAW_BX
                LXI     H,0
                SHLD    RAW_CX
                LXI     H,1
                SHLD    RAW_DX
                LXI     H,TABLE
                SHLD    RAW_BP
                CALL    RAW_CALL
                RNC
                LDA     RETRY
                DCR     A
                STA     RETRY
                JNZ     RHP_LOOP
                STC
                RET

SELECT_ENTRY:
                LDA     PART_NO
                DCR     A
                MOV     B,A
                LXI     H,TABLE
SE_LOOP:
                MOV     A,B
                ORA     A
                JZ      SE_DONE
                LXI     D,PART_SIZE
                DAD     D
                DCR     B
                JMP     SE_LOOP
SE_DONE:
                SHLD    ENTRY_PTR
                XRA     A
                RET

VALIDATE_ENTRY:
                LHLD    ENTRY_PTR
                INX     H
                MOV     A,M
                ANI     07FH
                CPI     CPM_SYS
                JNZ     VE_FAIL
                ; require H/S start and end = 0
                LHLD    ENTRY_PTR
                LXI     D,8
                DAD     D
                MOV     A,M
                ORA     A
                JNZ     VE_FAIL
                INX     H
                MOV     A,M
                ORA     A
                JNZ     VE_FAIL
                LHLD    ENTRY_PTR
                LXI     D,12
                DAD     D
                MOV     A,M
                ORA     A
                JNZ     VE_FAIL
                INX     H
                MOV     A,M
                ORA     A
                JNZ     VE_FAIL
                XRA     A
                RET
VE_FAIL:
                STC
                RET

CALC_LAYOUT:
                ; start/end cylinders.
                LHLD    ENTRY_PTR
                LXI     D,10
                DAD     D
                MOV     E,M
                INX     H
                MOV     D,M
                XCHG
                SHLD    START_CYL

                LHLD    ENTRY_PTR
                LXI     D,14
                DAD     D
                MOV     E,M
                INX     H
                MOV     D,M
                XCHG
                SHLD    END_CYL

                ; total cylinders >=2 (one reserved + filesystem).
                XCHG
                LHLD    START_CYL
                MOV     A,E
                SUB     L
                MOV     E,A
                MOV     A,D
                SBB     H
                MOV     D,A
                XCHG
                INX     H
                SHLD    TOTAL_CYL
                DCX     H
                SHLD    FS_CYL
                MOV     A,H
                ORA     L
                JZ      CL_FAIL

                ; sectors/cyl = heads*spt.
                LDA     HEADS
                MOV     L,A
                MVI     H,0
                LDA     SPT
                MOV     E,A
                MVI     D,0
                CALL    MUL16
                LHLD    MUL_HI
                MOV     A,H
                ORA     L
                JNZ     CL_FAIL
                LHLD    MUL_LO
                SHLD    SPC

                ; Whole physical partition sectors = TOTAL_CYL * SPC.
                ; Keep this separate from BLOCKS, which describes only the
                ; filesystem after the reserved first cylinder (OFF=1).
                LHLD    TOTAL_CYL
                XCHG
                LHLD    SPC
                CALL    MUL16
                LHLD    MUL_LO
                SHLD    PART_TOTAL_LO
                LHLD    MUL_HI
                SHLD    PART_TOTAL_HI

                ; /S needs one complete reserved-cylinder system area:
                ; sector 0 HDIPL + sectors 1..30 payload.
                LDA     SYSTEM_FLAG
                ORA     A
                JZ      CL_ROOM_OK
                LHLD    SPC
                MOV     A,H
                ORA     A
                JNZ     CL_ROOM_OK
                MOV     A,L
                CPI     31
                JC      CL_FAIL
CL_ROOM_OK:

                ; usable sectors = FS_CYL * SPC.
                LHLD    FS_CYL
                XCHG
                LHLD    SPC
                CALL    MUL16
                ; blocks = sectors >> 5.
                LHLD    MUL_HI
                SHLD    BLK_HI
                LHLD    MUL_LO
                SHLD    BLK_LO
                MVI     B,5
CL_SHR:
                LHLD    BLK_HI
                MOV     A,H
                ORA     A
                RAR
                MOV     H,A
                MOV     A,L
                RAR
                MOV     L,A
                SHLD    BLK_HI
                LHLD    BLK_LO
                MOV     A,H
                RAR
                MOV     H,A
                MOV     A,L
                RAR
                MOV     L,A
                SHLD    BLK_LO
                DCR     B
                JNZ     CL_SHR
                LHLD    BLK_HI
                MOV     A,H
                ORA     L
                JNZ     CL_FAIL
                LHLD    BLK_LO
                SHLD    BLOCKS
                ; 1..8192
                MOV     A,H
                CPI     20H
                JC      CL_OK
                JNZ     CL_FAIL
                MOV     A,L
                ORA     A
                JNZ     CL_FAIL            ; 2000h exactly allowed
CL_OK:
                LHLD    BLOCKS
                ; Require at least 64 filesystem allocation blocks (1 MiB usable space).
                MOV     A,H
                ORA     A
                JNZ     CL_SIZE_OK
                MOV     A,L
                CPI     64
                JC      CL_FAIL
CL_SIZE_OK:
                XRA     A
                RET
CL_FAIL:
                STC
                RET

SHOW_PLAN:
                LXI     D,MSG_TARGET1
                CALL    PUTS
                LDA     SCSI_ID
                MOV     L,A
                MVI     H,0
                CALL    DEC16
                LXI     D,MSG_TARGET2
                CALL    PUTS
                LDA     PART_NO
                MOV     L,A
                MVI     H,0
                CALL    DEC16
                LXI     D,MSG_TARGET3
                CALL    PUTS
                LHLD    SEC_SIZE
                CALL    DEC16
                LXI     D,MSG_TARGET4
                CALL    PUTS
                CALL    PARTITION_MIB_CEIL
                CALL    DEC16
                LXI     D,MSG_MIB
                CALL    PUTS
                LXI     D,MSG_CHS1
                CALL    PUTS
                LHLD    START_CYL
                CALL    DEC16
                LXI     D,MSG_CHS_ZERO
                CALL    PUTS
                LXI     D,MSG_CHS2
                CALL    PUTS
                LHLD    END_CYL
                CALL    DEC16
                LXI     D,MSG_CHS_ZERO
                CALL    PUTS
                LXI     D,MSG_DPBHDR
                CALL    PUTS
                LHLD    SPC
                DAD     H
                DAD     H
                CALL    DEC16
                LXI     D,MSG_DPB1
                CALL    PUTS
                LHLD    BLOCKS
                DCX     H
                MOV     A,H
                ORA     A
                JNZ     SP_EXM7
                MVI     A,15
                JMP     SP_EXMOUT
SP_EXM7:
                MVI     A,7
SP_EXMOUT:
                MOV     L,A
                MVI     H,0
                CALL    DEC16
                LXI     D,MSG_DPB2
                CALL    PUTS
                LHLD    BLOCKS
                DCX     H
                CALL    DEC16
                LXI     D,MSG_DPB3
                CALL    PUTS
                RET

; ----------------------------------------------------------------------
; Return HL = ceil(whole physical partition sectors / 2048).
; This matches FDISK80's MiB display and includes the reserved first cylinder.
; ----------------------------------------------------------------------
PARTITION_MIB_CEIL:
                LHLD    PART_TOTAL_LO
                LXI     D,07FFH
                DAD     D
                SHLD    MIB_LO
                MVI     A,0
                ACI     0
                MOV     C,A
                LHLD    PART_TOTAL_HI
                MOV     A,L
                ADD     C
                MOV     L,A
                MOV     A,H
                ACI     0
                MOV     H,A
                SHLD    MIB_HI
                MVI     B,11
PMC_SHIFT:
                LHLD    MIB_HI
                MOV     A,H
                ORA     A
                RAR
                MOV     H,A
                MOV     A,L
                RAR
                MOV     L,A
                SHLD    MIB_HI
                LHLD    MIB_LO
                MOV     A,H
                RAR
                MOV     H,A
                MOV     A,L
                RAR
                MOV     L,A
                SHLD    MIB_LO
                DCR     B
                JNZ     PMC_SHIFT
                LHLD    MIB_LO
                RET

; ----------------------------------------------------------------------
; Generate stable 8-byte FSID from geometry/target. Not cryptographic.
; ----------------------------------------------------------------------
GENERATE_FSID:
                LHLD    START_CYL
                MOV     A,L
                STA     FSID+0
                MOV     A,H
                STA     FSID+1
                LHLD    END_CYL
                MOV     A,L
                STA     FSID+2
                MOV     A,H
                STA     FSID+3
                LDA     DAUA
                STA     FSID+4
                LDA     HEADS
                STA     FSID+5
                LDA     SPT
                STA     FSID+6
                LDA     PART_NO
                XRI     0A5H
                STA     FSID+7
                RET

; ----------------------------------------------------------------------
; /S: build HDIPL and obtain the 30-sector clean payload from the boot source.
; ----------------------------------------------------------------------
PREPARE_SYSTEM:
                LXI     H,HDIPL80
                LXI     D,IPLBUF
                MVI     B,2
PS_IPL_OUT:
                MVI     C,0
PS_IPL_LOOP:
                MOV     A,M
                STAX    D
                INX     H
                INX     D
                INR     C
                JNZ     PS_IPL_LOOP
                DCR     B
                JNZ     PS_IPL_OUT
                LXI     H,IPLBUF+01E0H
                LXI     D,FMT_SIG
                MVI     B,8
PS_SIG:
                LDAX    D
                CMP     M
                JNZ     PS_FAIL
                INX     H
                INX     D
                DCR     B
                JNZ     PS_SIG
                LXI     H,FSID
                LXI     D,IPLBUF+01E8H
                MVI     B,8
PS_FSID:
                MOV     A,M
                STAX    D
                INX     H
                INX     D
                DCR     B
                JNZ     PS_FSID
                LHLD    START_CYL
                MOV     A,L
                STA     IPLBUF+01F0H
                MOV     A,H
                STA     IPLBUF+01F1H

                LXI     D,BOOT_SOURCE
                MVI     A,SVC_GET_BOOT_SOURCE
                DB      0EDH,0EDH,CALLN_VEC
                ORA     A
                JNZ     PS_FAIL
                LDA     BOOT_SOURCE+0
                STA     SRC_TYPE
                LDA     BOOT_SOURCE+1
                STA     SRC_DAUA
                LDA     SRC_TYPE
                ORA     A
                JZ      PS_FDD
                CPI     1
                JNZ     PS_FAIL
                CALL    FIND_SOURCE_HDD_PARTITION
                RC
                JMP     PS_READ_FIRST
PS_FDD:
                LDA     SRC_DAUA
                ANI     0F0H
                CPI     10H
                JZ      PS_FDD_8
                CPI     70H
                JZ      PS_FDD_8
                CPI     90H
                JZ      PS_FDD_15
                CPI     0F0H
                JZ      PS_FDD_15
                JMP     PS_FAIL
PS_FDD_8:
                MVI     A,8
                STA     SRC_SPT2
                JMP     PS_READ_FIRST
PS_FDD_15:
                MVI     A,15
                STA     SRC_SPT2
PS_READ_FIRST:
                LXI     D,MSG_SRCREAD
                CALL    PUTS
                LXI     H,SYSBUF
                CALL    READ_SOURCE_SYSTEM
                RC
                LXI     D,MSG_SRCVERIFY
                CALL    PUTS
                LXI     H,SYSBUF
                CALL    VERIFY_SOURCE_SYSTEM
                RC
                LXI     H,SYSBUF+01FC0H
                MVI     B,64
                XRA     A
PS_CLEAN_HINT:
                MOV     M,A
                INX     H
                DCR     B
                JNZ     PS_CLEAN_HINT
                XRA     A
                RET
PS_FAIL:
                STC
                RET

READ_SOURCE_SYSTEM:
                SHLD    SRC_DST
                CALL    RESET_SOURCE_CHS
                MVI     B,PAYLOAD_SECTORS
RSS_LOOP:
                PUSH    B
                LHLD    SRC_DST
                CALL    READ_SOURCE_SECTOR
                POP     B
                RC
                LHLD    SRC_DST
                LXI     D,SECTOR_SIZE
                DAD     D
                SHLD    SRC_DST
                CALL    ADV_SOURCE_CHS
                DCR     B
                JNZ     RSS_LOOP
                XRA     A
                RET

VERIFY_SOURCE_SYSTEM:
                SHLD    SRC_DST
                CALL    RESET_SOURCE_CHS
                MVI     B,PAYLOAD_SECTORS
VSS_LOOP:
                PUSH    B
                CALL    READ_SOURCE_TO_TEMP
                POP     B
                RC
                LHLD    SRC_DST
                LXI     D,SRC_SECTOR
                PUSH    B
                CALL    CMP512
                POP     B
                RC
                LHLD    SRC_DST
                LXI     D,SECTOR_SIZE
                DAD     D
                SHLD    SRC_DST
                CALL    ADV_SOURCE_CHS
                DCR     B
                JNZ     VSS_LOOP
                XRA     A
                RET

RESET_SOURCE_CHS:
                LDA     SRC_TYPE
                ORA     A
                JNZ     RSC_HDD
                XRA     A
                STA     SRC_CYL
                STA     SRC_CYL+1
                STA     SRC_HEAD
                MVI     A,2
                STA     SRC_SEC
                RET
RSC_HDD:
                LHLD    SRC_START_CYL
                SHLD    SRC_CYL
                XRA     A
                STA     SRC_HEAD
                MVI     A,1
                STA     SRC_SEC
                RET

READ_SOURCE_SECTOR:
                SHLD    SRC_DST_TMP
                CALL    READ_SOURCE_TO_TEMP
                RC
                LXI     H,SRC_SECTOR
                XCHG
                LHLD    SRC_DST_TMP
                XCHG
                MVI     B,2
RSSC_OUTER:
                MVI     C,0
RSSC_BYTE:
                MOV     A,M
                STAX    D
                INX     H
                INX     D
                INR     C
                JNZ     RSSC_BYTE
                DCR     B
                JNZ     RSSC_OUTER
                XRA     A
                RET

READ_SOURCE_TO_TEMP:
                LDA     SRC_TYPE
                ORA     A
                JNZ     RST_HDD
                JMP     READ_SRC_FDD_TEMP
RST_HDD:
                JMP     READ_SRC_HDD_TEMP

READ_SRC_FDD_TEMP:
                MVI     A,MAX_RETRY
                STA     RETRY
RSFT_RETRY:
                LDA     SRC_DAUA
                STA     RAW_AX
                MVI     A,056H
                STA     RAW_AX+1
                LXI     H,SECTOR_SIZE
                SHLD    RAW_BX
                LDA     SRC_CYL
                STA     RAW_CX
                MVI     A,2
                STA     RAW_CX+1
                LDA     SRC_SEC
                STA     RAW_DX
                LDA     SRC_HEAD
                STA     RAW_DX+1
                LXI     H,SRC_SECTOR
                SHLD    RAW_BP
                CALL    RAW_CALL
                RNC
                LDA     RETRY
                DCR     A
                STA     RETRY
                JNZ     RSFT_RETRY
                STC
                RET

READ_SRC_HDD_TEMP:
                MVI     A,MAX_RETRY
                STA     RETRY
RSHT_RETRY:
                LDA     SRC_DAUA
                STA     RAW_AX
                MVI     A,006H
                STA     RAW_AX+1
                LXI     H,SECTOR_SIZE
                SHLD    RAW_BX
                LHLD    SRC_CYL
                SHLD    RAW_CX
                LDA     SRC_SEC
                STA     RAW_DX
                LDA     SRC_HEAD
                STA     RAW_DX+1
                LXI     H,SRC_SECTOR
                SHLD    RAW_BP
                CALL    RAW_CALL
                RNC
                LDA     RETRY
                DCR     A
                STA     RETRY
                JNZ     RSHT_RETRY
                STC
                RET

ADV_SOURCE_CHS:
                ; Callers use B as the remaining-sector loop count.
                ; Preserve it while using B as a temporary CHS value.
                PUSH    B
                LDA     SRC_TYPE
                ORA     A
                JNZ     ASC_HDD
                LDA     SRC_SEC
                INR     A
                MOV     B,A
                LDA     SRC_SPT2
                INR     A
                CMP     B
                JNZ     ASC_FDD_STORE
                MVI     A,1
                STA     SRC_SEC
                LDA     SRC_HEAD
                XRI     1
                STA     SRC_HEAD
                ORA     A
                JNZ     ASC_DONE
                LHLD    SRC_CYL
                INX     H
                SHLD    SRC_CYL
                JMP     ASC_DONE
ASC_FDD_STORE:
                MOV     A,B
                STA     SRC_SEC
                JMP     ASC_DONE
ASC_HDD:
                LDA     SRC_SEC
                INR     A
                MOV     B,A
                LDA     SRC_SPT2
                CMP     B
                JNZ     ASC_HDD_SEC
                XRA     A
                STA     SRC_SEC
                LDA     SRC_HEAD
                INR     A
                MOV     B,A
                LDA     SRC_HEADS
                CMP     B
                JNZ     ASC_HDD_HEAD
                XRA     A
                STA     SRC_HEAD
                LHLD    SRC_CYL
                INX     H
                SHLD    SRC_CYL
                JMP     ASC_DONE
ASC_HDD_HEAD:
                MOV     A,B
                STA     SRC_HEAD
                JMP     ASC_DONE
ASC_HDD_SEC:
                MOV     A,B
                STA     SRC_SEC
ASC_DONE:
                POP     B
                RET

FIND_SOURCE_HDD_PARTITION:
                LDA     SRC_DAUA
                STA     RAW_AX
                MVI     A,084H
                STA     RAW_AX+1
                LXI     H,0A55AH
                SHLD    RAW_BX
                LXI     H,05AA5H
                SHLD    RAW_CX
                LXI     H,0C33CH
                SHLD    RAW_DX
                LXI     H,0
                SHLD    RAW_BP
                CALL    RAW_CALL
                RC
                LHLD    RAW_BX
                MOV     A,H
                CPI     2
                JNZ     FSHP_FAIL
                MOV     A,L
                ORA     A
                JNZ     FSHP_FAIL
                LDA     RAW_DX+1
                STA     SRC_HEADS
                LDA     RAW_DX
                STA     SRC_SPT2
                ORA     A
                JZ      FSHP_FAIL
                LDA     SRC_HEADS
                ORA     A
                JZ      FSHP_FAIL
                XRA     A
                STA     SRC_PART_INDEX
FSHP_SCAN:
                LDA     SRC_PART_INDEX
                CPI     PART_COUNT
                JNC     FSHP_FAIL

                ; Re-read the partition table for every candidate.  The
                ; candidate sector-0 probe below also uses SRC_SECTOR and
                ; therefore destroys the previous table image.
                XRA     A
                STA     SRC_CYL
                STA     SRC_CYL+1
                STA     SRC_HEAD
                MVI     A,1
                STA     SRC_SEC
                CALL    READ_SRC_HDD_TEMP
                RC

                LDA     SRC_PART_INDEX
                MOV     B,A
                LXI     H,SRC_SECTOR
FSHP_PTR:
                MOV     A,B
                ORA     A
                JZ      FSHP_PTR_OK
                LXI     D,PART_SIZE
                DAD     D
                DCR     B
                JMP     FSHP_PTR
FSHP_PTR_OK:
                SHLD    SRC_ENTRY_PTR
                INX     H
                MOV     A,M
                ANI     07FH
                CPI     CPM_SYS
                JNZ     FSHP_NEXT
                LHLD    SRC_ENTRY_PTR
                LXI     D,8
                DAD     D
                MOV     A,M
                ORA     A
                JNZ     FSHP_NEXT
                INX     H
                MOV     A,M
                ORA     A
                JNZ     FSHP_NEXT
                INX     H
                MOV     E,M
                INX     H
                MOV     D,M
                XCHG
                SHLD    SRC_START_CYL
                SHLD    SRC_CYL
                XRA     A
                STA     SRC_HEAD
                STA     SRC_SEC
                CALL    READ_SRC_HDD_TEMP
                JC      FSHP_NEXT
                LXI     H,SRC_SECTOR+01E0H
                LXI     D,FMT_SIG
                MVI     B,8
FSHP_SIG:
                LDAX    D
                CMP     M
                JNZ     FSHP_NEXT
                INX     D
                INX     H
                DCR     B
                JNZ     FSHP_SIG
                LXI     H,SRC_SECTOR+01E8H
                LXI     D,BOOT_SOURCE+4
                MVI     B,8
FSHP_ID:
                LDAX    D
                CMP     M
                JNZ     FSHP_NEXT
                INX     D
                INX     H
                DCR     B
                JNZ     FSHP_ID
                XRA     A
                RET
FSHP_NEXT:
                LDA     SRC_PART_INDEX
                INR     A
                STA     SRC_PART_INDEX
                JMP     FSHP_SCAN
FSHP_FAIL:
                STC
                RET

MAKE_METADATA:
                LXI     H,IPLBUF
                LXI     B,SECTOR_SIZE
                XRA     A
MM_ZERO:
                MVI     A,0
                MOV     M,A
                INX     H
                DCX     B
                MOV     A,B
                ORA     C
                JNZ     MM_ZERO
                LXI     H,FMT_SIG
                LXI     D,IPLBUF+01E0H
                MVI     B,8
MM_SIG:
                MOV     A,M
                STAX    D
                INX     H
                INX     D
                DCR     B
                JNZ     MM_SIG
                LXI     H,FSID
                LXI     D,IPLBUF+01E8H
                MVI     B,8
MM_FSID:
                MOV     A,M
                STAX    D
                INX     H
                INX     D
                DCR     B
                JNZ     MM_FSID
                LHLD    START_CYL
                MOV     A,L
                STA     IPLBUF+01F0H
                MOV     A,H
                STA     IPLBUF+01F1H
                MVI     A,055H
                STA     IPLBUF+01FEH
                MVI     A,0AAH
                STA     IPLBUF+01FFH
                RET

CHECK_MASTER_IPL:
                LXI     H,SECTORBUF
                XRA     A
                STA     IO_CYL
                STA     IO_CYL+1
                STA     IO_HEAD
                STA     IO_SEC
                MVI     A,006H
                CALL    HDD_IO
                RC
                XRA     A
                STA     MASTER_PRESENT
                STA     MASTER_OURS
                STA     MASTER_VERSION
                STA     MASTER_VERSION+1
                LDA     SECTORBUF+00FEH
                CPI     055H
                JNZ     CMI_DONE
                LDA     SECTORBUF+00FFH
                CPI     0AAH
                JNZ     CMI_DONE
                MVI     A,1
                STA     MASTER_PRESENT

                ; Identify only our versioned MASTER IPL.
                LXI     H,SECTORBUF+MASTER_MAGIC_OFF
                LXI     D,MASTER_MAGIC
                MVI     B,8
CMI_MAGIC:
                LDAX    D
                CMP     M
                JNZ     CMI_DONE
                INX     H
                INX     D
                DCR     B
                JNZ     CMI_MAGIC
                MVI     A,1
                STA     MASTER_OURS
                LHLD    SECTORBUF+MASTER_VER_OFF
                SHLD    MASTER_VERSION
CMI_DONE:
                XRA     A
                RET

MASTER_UPDATE_NEEDED:
                ; Return A=1 to install/update, A=0 to preserve.
                LDA     MASTER_FORCE
                ORA     A
                JNZ     MUN_YES

                LDA     MASTER_PRESENT
                ORA     A
                JZ      MUN_YES

                LDA     MASTER_OURS
                ORA     A
                JZ      MUN_NO

                ; Automatically update only if our on-disk version is older.
                LHLD    MASTER_VERSION
                MOV     A,H
                ORA     A
                JNZ     MUN_NO
                MOV     A,L
                CPI     MASTER_IPL_VERSION
                JC      MUN_YES
MUN_NO:
                XRA     A
                RET
MUN_YES:
                MVI     A,1
                RET

INSTALL_MASTER_IPL:
                LXI     H,MASTERIPL80
                LXI     D,SECTORBUF
                MVI     B,2
IMI_COPY_OUT:
                MVI     C,0
IMI_COPY:
                MOV     A,M
                STAX    D
                INX     H
                INX     D
                INR     C
                JNZ     IMI_COPY
                DCR     B
                JNZ     IMI_COPY_OUT
                XRA     A
                STA     IO_CYL
                STA     IO_CYL+1
                STA     IO_HEAD
                STA     IO_SEC
                LXI     H,SECTORBUF
                MVI     A,005H
                CALL    HDD_IO
                RC
                LXI     H,MASTER_VERIFY
                MVI     A,006H
                CALL    HDD_IO
                RC
                LXI     H,MASTERIPL80
                LXI     D,MASTER_VERIFY
                CALL    CMP512
                RC
                MVI     A,1
                STA     MASTER_PRESENT
                STA     MASTER_OURS
                LXI     H,MASTER_IPL_VERSION
                SHLD    MASTER_VERSION
                XRA     A
                RET

WRITE_IPL_SECTOR:
                LHLD    START_CYL
                SHLD    IO_CYL
                XRA     A
                STA     IO_HEAD
                STA     IO_SEC
                LXI     H,IPLBUF
                MVI     A,005H
                JMP     HDD_IO

WRITE_SYSTEM_PAYLOAD:
                LHLD    START_CYL
                SHLD    IO_CYL
                XRA     A
                STA     IO_HEAD
                STA     IO_SEC
                CALL    ADV_HDD_CHS         ; sector 1
                LXI     H,SYSBUF
                MVI     B,PAYLOAD_SECTORS
WSP_LOOP:
                PUSH    B
                PUSH    H
                MVI     A,005H
                CALL    HDD_IO
                POP     H
                POP     B
                RC
                LXI     D,SECTOR_SIZE
                DAD     D
                CALL    ADV_HDD_CHS
                DCR     B
                JNZ     WSP_LOOP
                XRA     A
                RET

VERIFY_DEST_SYSTEM:
                LHLD    START_CYL
                SHLD    IO_CYL
                XRA     A
                STA     IO_HEAD
                STA     IO_SEC
                LXI     H,SECTORBUF
                MVI     A,006H
                CALL    HDD_IO
                RC
                LXI     H,IPLBUF
                LXI     D,SECTORBUF
                CALL    CMP512
                RC
                LHLD    START_CYL
                SHLD    IO_CYL
                XRA     A
                STA     IO_HEAD
                STA     IO_SEC
                CALL    ADV_HDD_CHS
                LXI     H,SYSBUF
                SHLD    VERIFY_PTR
                MVI     B,PAYLOAD_SECTORS
VDS_LOOP:
                PUSH    B
                LXI     H,SECTORBUF
                MVI     A,006H
                CALL    HDD_IO
                POP     B
                RC
                LHLD    VERIFY_PTR
                LXI     D,SECTORBUF
                PUSH    B
                CALL    CMP512
                POP     B
                RC
                LHLD    VERIFY_PTR
                LXI     D,SECTOR_SIZE
                DAD     D
                SHLD    VERIFY_PTR
                CALL    ADV_HDD_CHS
                DCR     B
                JNZ     VDS_LOOP
                XRA     A
                RET

CMP512:
                MVI     B,2
C512_OUT:
                MVI     C,0
C512_BYTE:
                LDAX    D
                CMP     M
                JNZ     C512_BAD
                INX     D
                INX     H
                INR     C
                JNZ     C512_BYTE
                DCR     B
                JNZ     C512_OUT
                XRA     A
                RET
C512_BAD:
                MVI     A,0FBH
                STA     LAST_STATUS
                STC
                RET

REQUEST_HDD_REMOUNT:
                MVI     A,SVC_HDD_REMOUNT_REQUEST
                DB      0EDH,0EDH,CALLN_VEC
                RET

FORMAT_DIRECTORY:
                LHLD    START_CYL
                INX     H
                SHLD    IO_CYL
                XRA     A
                STA     IO_HEAD
                STA     IO_SEC
                LXI     H,SECTORBUF
                LXI     B,SECTOR_SIZE
                MVI     A,0E5H
FD_FILL:
                MVI     A,0E5H
                MOV     M,A
                INX     H
                DCX     B
                MOV     A,B
                ORA     C
                JNZ     FD_FILL
                MVI     B,DIR_SECTORS
FD_LOOP:
                PUSH    B
                LXI     H,SECTORBUF
                MVI     A,005H
                CALL    HDD_IO
                POP     B
                RC
                CALL    ADV_HDD_CHS
                DCR     B
                JNZ     FD_LOOP
                XRA     A
                RET

UPDATE_PARTITION_ENTRY:
                ; reload table to avoid stale data.
                CALL    LOAD_TABLE
                RC
                CALL    SELECT_ENTRY
                LHLD    ENTRY_PTR

                ; IPL CHS = partition start, H/S=0.
                PUSH    H
                LXI     D,4
                DAD     D
                XRA     A
                MOV     M,A
                INX     H
                MOV     M,A
                INX     H
                XCHG
                LHLD    START_CYL
                XCHG
                MOV     M,E
                INX     H
                MOV     M,D
                POP     H

                ; Boot representation used by the common CP/M master IPL:
                ; MID byte 95h, SID high bit set, low 7 bits remain type 70h.
                LDA     SYSTEM_FLAG
                ORA     A
                JZ      UPE_NONBOOT
                MVI     M,095H
                INX     H
                MOV     A,M
                ORI     080H
                MOV     M,A
                DCX     H
                JMP     UPE_LABEL
UPE_NONBOOT:
                MVI     M,000H
                INX     H
                MOV     A,M
                ANI     07FH
                MOV     M,A
                DCX     H
UPE_LABEL:
                LXI     D,16
                DAD     D
                LXI     D,FS_LABEL
                MVI     B,16
UPE_L:
                LDAX    D
                MOV     M,A
                INX     D
                INX     H
                DCR     B
                JNZ     UPE_L
                CALL    SAVE_TABLE
                RET

VERIFY_FORMAT:
                ; directory
                LHLD    START_CYL
                INX     H
                SHLD    IO_CYL
                XRA     A
                STA     IO_HEAD
                STA     IO_SEC
                MVI     B,DIR_SECTORS
VF_SEC:
                PUSH    B
                LXI     H,SECTORBUF
                MVI     A,006H
                CALL    HDD_IO
                POP     B
                RC
                LXI     H,SECTORBUF
                LXI     D,SECTOR_SIZE
VF_BYTE:
                MOV     A,M
                CPI     0E5H
                JNZ     VF_FAIL
                INX     H
                DCX     D
                MOV     A,D
                ORA     E
                JNZ     VF_BYTE
                CALL    ADV_HDD_CHS
                DCR     B
                JNZ     VF_SEC

                ; metadata sector signature/fsid
                LHLD    START_CYL
                SHLD    IO_CYL
                XRA     A
                STA     IO_HEAD
                STA     IO_SEC
                LXI     H,SECTORBUF
                MVI     A,006H
                CALL    HDD_IO
                RC
                LXI     H,SECTORBUF+01E0H
                LXI     D,FMT_SIG
                MVI     B,8
VF_SIG:
                LDAX    D
                CMP     M
                JNZ     VF_FAIL
                INX     D
                INX     H
                DCR     B
                JNZ     VF_SIG
                LXI     H,SECTORBUF+01E8H
                LXI     D,FSID
                MVI     B,8
VF_ID:
                LDAX    D
                CMP     M
                JNZ     VF_FAIL
                INX     D
                INX     H
                DCR     B
                JNZ     VF_ID

                ; Partition-table entry must still describe this formatted volume.
                CALL    LOAD_TABLE
                JC      VF_FAIL
                CALL    SELECT_ENTRY
                LHLD    ENTRY_PTR
                INX     H
                MOV     A,M
                ANI     07FH
                CPI     CPM_SYS
                JNZ     VF_FAIL

                ; Check boot bits according to /S.
                LHLD    ENTRY_PTR
                LDA     SYSTEM_FLAG
                ORA     A
                JZ      VF_NONBOOT
                MOV     A,M
                ANI     080H
                JZ      VF_FAIL
                INX     H
                MOV     A,M
                ANI     080H
                JZ      VF_FAIL
                JMP     VF_LABEL
VF_NONBOOT:
                MOV     A,M
                ANI     080H
                JNZ     VF_FAIL
                INX     H
                MOV     A,M
                ANI     080H
                JNZ     VF_FAIL
VF_LABEL:
                LHLD    ENTRY_PTR
                LXI     D,16
                DAD     D
                LXI     D,FS_LABEL
                MVI     B,16
VF_LABLOOP:
                LDAX    D
                CMP     M
                JNZ     VF_FAIL
                INX     D
                INX     H
                DCR     B
                JNZ     VF_LABLOOP
                XRA     A
                RET
VF_FAIL:
                STC
                RET

; ----------------------------------------------------------------------
; Raw I/O.
; HDD sectors are zero-based. FDD source sectors are one-based.
; ----------------------------------------------------------------------
HDD_IO:
                STA     IO_FUNC
                SHLD    IO_PTR
                MVI     A,MAX_RETRY
                STA     RETRY
HIO_RETRY:
                LDA     DAUA
                STA     RAW_AX
                LDA     IO_FUNC
                STA     RAW_AX+1
                LXI     H,SECTOR_SIZE
                SHLD    RAW_BX
                LHLD    IO_CYL
                SHLD    RAW_CX
                LDA     IO_SEC
                STA     RAW_DX
                LDA     IO_HEAD
                STA     RAW_DX+1
                LHLD    IO_PTR
                SHLD    RAW_BP
                CALL    RAW_CALL
                RNC
                LDA     RETRY
                DCR     A
                STA     RETRY
                JNZ     HIO_RETRY
                STC
                RET

READ_SRC_FDD:
                ; HL destination.
                SHLD    IO_PTR
                MVI     A,MAX_RETRY
                STA     RETRY
RSF_RETRY:
                LDA     SRC_DAUA
                STA     RAW_AX
                MVI     A,056H
                STA     RAW_AX+1
                LXI     H,SECTOR_SIZE
                SHLD    RAW_BX
                XRA     A
                STA     RAW_CX
                LDA     SRC_SIDE
                ANI     1
                JZ      RSF_HEAD0
                MVI     A,1
                STA     RAW_DX+1
                JMP     RSF_CYL
RSF_HEAD0:
                XRA     A
                STA     RAW_DX+1
RSF_CYL:
                LDA     SRC_SIDE
                RRC
                ANI     07FH
                STA     RAW_CX
                MVI     A,2
                STA     RAW_CX+1
                LDA     SRC_SEC
                STA     RAW_DX
                LHLD    IO_PTR
                SHLD    RAW_BP
                CALL    RAW_CALL
                RNC
                LDA     RETRY
                DCR     A
                STA     RETRY
                JNZ     RSF_RETRY
                STC
                RET

ADV_SRC_FDD:
                LDA     SRC_SEC
                INR     A
                MOV     B,A
                ; boot media SPS from boot DAUA family.
                LDA     SRC_DAUA
                ANI     0F0H
                CPI     090H
                JZ      ASF_15
                CPI     0F0H
                JZ      ASF_15
                MVI     A,9             ; max+1 for 8 sectors
                JMP     ASF_CMP
ASF_15:
                MVI     A,16
ASF_CMP:
                CMP     B
                JNZ     ASF_STORE
                MVI     A,1
                STA     SRC_SEC
                LDA     SRC_SIDE
                INR     A
                STA     SRC_SIDE
                RET
ASF_STORE:
                MOV     A,B
                STA     SRC_SEC
                RET

ADV_HDD_CHS:
                ; Callers use B as the remaining-sector loop count.
                ; Preserve it while using B as a temporary CHS value.
                PUSH    B
                LDA     IO_SEC
                INR     A
                MOV     B,A
                LDA     SPT
                CMP     B
                JNZ     AHC_SEC
                XRA     A
                STA     IO_SEC
                LDA     IO_HEAD
                INR     A
                MOV     B,A
                LDA     HEADS
                CMP     B
                JNZ     AHC_HEAD
                XRA     A
                STA     IO_HEAD
                LHLD    IO_CYL
                INX     H
                SHLD    IO_CYL
                JMP     AHC_DONE
AHC_HEAD:
                MOV     A,B
                STA     IO_HEAD
                JMP     AHC_DONE
AHC_SEC:
                MOV     A,B
                STA     IO_SEC
AHC_DONE:
                POP     B
                RET

RAW_CALL:
                LXI     D,RAW_FRAME
                MVI     A,SVC_RAW_INT1B
                DB      0EDH,0EDH,CALLN_VEC
                LDA     RAW_AX+1
                STA     LAST_STATUS
                LDA     RAW_FLAGS
                ANI     1
                JZ      RC_OK
                STC
                RET
RC_OK:
                XRA     A
                RET

; HL*DE -> 32-bit MUL_HI:MUL_LO (repeated addition; sufficient for formatter).
MUL16:
                SHLD    M_A
                XCHG
                SHLD    M_B
                LXI     H,0
                SHLD    MUL_LO
                SHLD    MUL_HI
M16_LOOP:
                LHLD    M_B
                MOV     A,H
                ORA     L
                RZ
                DCX     H
                SHLD    M_B

                LHLD    MUL_LO
                XCHG
                LHLD    M_A
                DAD     D
                SHLD    MUL_LO
                JNC     M16_LOOP
                LHLD    MUL_HI
                INX     H
                SHLD    MUL_HI
                JMP     M16_LOOP

; ----------------------------------------------------------------------
; Console.
; ----------------------------------------------------------------------
PUTS:
                MVI     C,9
                CALL    BDOS
                RET
GETC:
                MVI     C,1
                CALL    BDOS
                RET
CRLF:
                LXI     D,MSG_CRLF
                JMP     PUTS
UPPER:
                CPI     'a'
                RC
                CPI     'z'+1
                RNC
                SUI     20H
                RET
PCHAR:
                ; CP/M BDOS function 2 is not assumed to preserve registers.
                ; DEC16 keeps the current remainder in HL while printing each
                ; digit, so preserve all registers it relies on across BDOS.
                PUSH    B
                PUSH    D
                PUSH    H
                MOV     E,A
                MVI     C,2
                CALL    BDOS
                POP     H
                POP     D
                POP     B
                RET
HEX8:
                PUSH    PSW
                RRC
                RRC
                RRC
                RRC
                ANI     0FH
                CALL    HEXD
                POP     PSW
                ANI     0FH
HEXD:
                CPI     10
                JC      HXNUM
                ADI     'A'-10
                JMP     PCHAR
HXNUM:
                ADI     '0'
                JMP     PCHAR
DEC16:
                ; small decimal routine by repeated subtraction of powers.
                XRA     A
                STA     DEC_STARTED
                PUSH    B
                PUSH    D
                PUSH    H
                LXI     D,10000
                CALL    D16_DIG
                LXI     D,1000
                CALL    D16_DIG
                LXI     D,100
                CALL    D16_DIG
                LXI     D,10
                CALL    D16_DIG
                MOV     A,L
                ADI     '0'
                CALL    PCHAR
                POP     H
                POP     D
                POP     B
                RET
D16_DIG:
                MVI     B,'0'
D16_SUB:
                MOV     A,L
                SUB     E
                MOV     C,A
                MOV     A,H
                SBB     D
                JC      D16_OUTD
                MOV     L,C
                MOV     H,A
                INR     B
                JMP     D16_SUB
D16_OUTD:
                MOV     A,B
                CPI     '0'
                JZ      D16_SUPPRESS
                CALL    PCHAR
                MVI     A,1
                STA     DEC_STARTED
                RET
D16_SUPPRESS:
                LDA     DEC_STARTED
                ORA     A
                RZ
                MOV     A,B
                CALL    PCHAR
                RET
SHOW_STATUS:
                LDA     LAST_STATUS
                CALL    HEX8
                CALL    CRLF
                RET

; ----------------------------------------------------------------------
; Messages/data.
; ----------------------------------------------------------------------
MSG_BANNER:     DB 13,10,'PC-9801 CP/M-80 HDFORMAT',13,10,'$'
MSG_USAGE:      DB 13,10,'Usage: HDFORMAT SCSI-ID:PARTITION [/S] [/M]',13,10
                DB '       SCSI-ID   = 0..6',13,10
                DB '       PARTITION = 1..16',13,10
                DB '       /M = force common MASTER IPL replacement, requires /S',13,10
                DB 'Example: HDFORMAT 0:2 /S',13,10,'$'
MSG_CACHEERR:   DB 13,10,'BIOS cache flush failed, direct disk I/O not started.',13,10,'$'
MSG_NODISK:     DB 13,10,'No usable SCSI device.',13,10,'$'
MSG_BADIPL:     DB 13,10,'PC-98 extended-format IPL signature not found.',13,10,'$'
MSG_MASTERREAD: DB 13,10,'Master IPL read error, status=$'
MSG_BADSECTOR:  DB 13,10,'Only 512-byte SCSI sectors are supported.',13,10,'$'
MSG_READERR:    DB 13,10,'Partition table read error, status=$'
MSG_BADPART:    DB 13,10,'Specified partition does not exist.',13,10,'$'
MSG_NOTCPM:     DB 13,10,'Specified partition is not CP/M-80 type 70h.',13,10,'$'
MSG_SIZE:       DB 13,10,'Partition is outside the supported CP/M-80 size range.',13,10,'$'
MSG_TARGET1:    DB 13,10,'Target: SCSI ID $'
MSG_TARGET2:    DB ', partition $'
MSG_TARGET3:    DB 13,10,'Physical sector size: $'
MSG_TARGET4:    DB ' bytes',13,10,'Partition size: $'
MSG_MIB:        DB ' MiB',13,10,'$'
MSG_CHS1:       DB 'Start CHS: $'
MSG_CHS2:       DB '   End CHS: $'
MSG_CHS_ZERO:   DB '/0/0$'
MSG_DPBHDR:     DB 13,10,'Calculated CP/M-80 DPB:',13,10,'  SPT=$'
MSG_DPB1:       DB 13,10,'  BSH=7  BLM=127  EXM=$'
MSG_DPB2:       DB 13,10,'  DSM=$'
MSG_DPB3:       DB 13,10,'  DRM=511  AL0=80h  AL1=00h',13,10
                DB '  CKS=0  OFF=1',13,10,'$'
MSG_WARN:       DB 13,10,'WARNING: Formatting destroys all files in this partition.',13,10
                DB 'Proceed (Y/N)? $'
MSG_ABORT:      DB 13,10,'Cancelled.',13,10,'$'
MSG_SRCREAD:    DB 13,10,'Reading source resident image... $'
MSG_SRCVERIFY:  DB 13,10,'Verifying source resident image... $'
MSG_SYSFAIL:    DB 13,10,'System source read/verify failed.',13,10,'$'
MSG_MASTERINSTALL: DB 'Installing/updating common MASTER IPL... $'
MSG_MASTERERR:  DB 13,10,'Master IPL write/verify failed, status=$'
MSG_METAERR:    DB 13,10,'Partition metadata/HDIPL write failed, status=$'
MSG_SYSWRITE:   DB 13,10,'System-area write failed, status=$'
MSG_SYSVERIFY:  DB 'Verifying written partition IPL and resident image... $'
MSG_SYSVERIFYERR: DB 13,10,'System destination verify failed, status=$'
MSG_DIR:        DB 13,10,'Formatting directory area... $'
MSG_DIRERR:     DB 13,10,'Directory write failed, status=$'
MSG_PTWRITE:    DB 13,10,'Partition signature write error, status=$'
MSG_DONE:       DB 13,10,'Format complete.',13,10,'$'
MSG_CRLF:       DB 13,10,'$'

FMT_SIG:        DB 'CPM80FS1'
FS_LABEL:       DB 'CP/M-80         '
MASTER_MAGIC:   DB 'CPM8MIPL'

SCSI_ID:        DB 0
PART_NO:        DB 0
SYSTEM_FLAG:    DB 0
MASTER_FORCE:   DB 0
DAUA:           DB 0
SEC_SIZE:       DW 0
CYL_LAST:       DW 0
HEADS:          DB 0
SPT:            DB 0
ENTRY_PTR:      DW 0
START_CYL:      DW 0
END_CYL:        DW 0
TOTAL_CYL:      DW 0
FS_CYL:         DW 0
SPC:            DW 0
PART_TOTAL_LO:  DW 0
PART_TOTAL_HI:  DW 0
BLOCKS:         DW 0
BLK_LO:         DW 0
BLK_HI:         DW 0
MIB_LO:         DW 0
MIB_HI:         DW 0
FSID:           DS 8

IO_CYL:         DW 0
IO_HEAD:        DB 0
IO_SEC:         DB 0
IO_PTR:         DW 0
IO_FUNC:        DB 0
RETRY:          DB 0
LAST_STATUS:    DB 0
SRC_DAUA:       DB 0
MASTER_PRESENT:  DB 0
MASTER_OURS:     DB 0
MASTER_VERSION:  DW 0
BOOT_SOURCE:     DS 16
SRC_TYPE:        DB 0
SRC_HEADS:       DB 0
SRC_SPT2:        DB 0
SRC_CYL:         DW 0
SRC_HEAD:        DB 0
SRC_START_CYL:   DW 0
SRC_PART_INDEX:  DB 0
SRC_ENTRY_PTR:   DW 0
SRC_DST:         DW 0
SRC_DST_TMP:     DW 0
VERIFY_PTR:      DW 0
SRC_SIDE:       DB 0
SRC_SEC:        DB 1
FDD_INFO:       DS 4

RAW_FRAME:
RAW_AX:         DW 0
RAW_BX:         DW 0
RAW_CX:         DW 0
RAW_DX:         DW 0
RAW_BP:         DW 0
RAW_FLAGS:      DW 0

M_A:            DW 0
M_B:            DW 0
MUL_LO:         DW 0
MUL_HI:         DW 0
DIGIT:          DB 0
DEC_STARTED:    DB 0

TABLE:          DS 512
SECTORBUF:      DS 512
SRC_SECTOR:     DS 512
MASTER_VERIFY:  DS 512
IPLBUF:         DS 512
SYSBUF:         DS 15360          ; 30 x 512

; Embedded 512-byte partition IPL and common master IPL templates.
                INCLUDE HDIPL80.INC
                INCLUDE MASTERIPL80.INC

STACK_AREA:     DS 512
STACK_TOP       EQU $
                END START
