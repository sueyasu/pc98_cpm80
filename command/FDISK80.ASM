; FDISK80.ASM
; PC-9801 CP/M-80 SCSI partition editor for V30 8080-emulation CP/M 2.2.
;
; Usage:
;   FDISK80 n
;     n = SCSI ID 0..6
;
; Commands:
;   P  print partition table
;   N  create CP/M-80 type-70h partition, 2..128 MiB
;   D  delete the physically last partition
;   B  toggle CP/M type-70h bootable marker (00h/95h)
;   W  write partition table and exit
;   X  erase master IPL sector immediately
;   Q  quit without writing
;   M  help
;
; PC-98 ROM BIOS INT 1Bh is never executed in 8080 mode directly.
; All SCSI SENSE/READ/WRITE requests use gateway SVC_RAW_INT1B.
;
; Partition-table sector: absolute C0/H0/S1, 16 entries x 32 bytes.
; New partitions are cylinder aligned, type 70h, initially non-bootable.
; HDFORMAT80 later installs "CP/M-80         " and boot metadata.
;
; Build:
;   asm8080 FDISK80.ASM
;
BDOS            EQU     0005H
CMDLEN          EQU     0080H
CMDTAIL         EQU     0081H

CALLN_VEC       EQU     061H
SVC_RAW_INT1B   EQU     0DH
SVC_CACHE_RESET  EQU     0EH
SVC_HDD_REMOUNT_REQUEST EQU 12H

CPM_SYS         EQU     070H
SECTOR_SIZE     EQU     512
PART_COUNT      EQU     16
PART_SIZE       EQU     32
MAX_MIB         EQU     128
MAX_RETRY       EQU     5

RAW_SIZE        EQU     12

                ORG     0100H

START:
                LXI     SP,STACK_TOP
                LXI     D,MSG_BANNER
                CALL    PUTS
                CALL    PARSE_ID
                JNC     ID_OK
                LXI     D,MSG_USAGE
                CALL    PUTS
                JMP     EXIT

ID_OK:
                ; FDISK_0914 flushes and invalidates BIOS caches before raw I/O.
                MVI     A,SVC_CACHE_RESET
                DB      0EDH,0EDH,CALLN_VEC
                ORA     A
                JZ      CACHE_READY
                LXI     D,MSG_CACHEERR
                CALL    PUTS
                JMP     EXIT
CACHE_READY:
                LDA     SCSI_ID
                ORI     0A0H
                STA     DAUA

                CALL    SENSE
                JNC     SENSE_OK
                LXI     D,MSG_NODISK
                CALL    PUTS
                JMP     EXIT
SENSE_OK:
                LHLD    SEC_SIZE
                MOV     A,H
                CPI     02H
                JNZ     BAD_SECSIZE
                MOV     A,L
                ORA     A
                JNZ     BAD_SECSIZE

                CALL    LOAD_TABLE
                JNC     TABLE_OK
                LXI     D,MSG_READERR
                CALL    PUTS
                CALL    SHOW_STATUS
                JMP     EXIT

BAD_SECSIZE:
                LXI     D,MSG_BADSECTOR
                CALL    PUTS
                JMP     EXIT

TABLE_OK:
                CALL    SHOW_SUMMARY
                CALL    LOAD_MASTER
                JC      MASTER_SHOW_READERR
                CALL    SHOW_MASTER
                JMP     CMD_LOOP

MASTER_SHOW_READERR:
                LXI     D,MSG_MASTER_READERR
                CALL    PUTS

CMD_LOOP:
                LXI     D,MSG_PROMPT
                CALL    PUTS
                CALL    READ_LINE
                LDA     LINEBUF+1
                ORA     A
                JZ      CMD_LOOP
                LDA     LINEBUF+2
                CALL    UPPER

                CPI     'P'
                JZ      CMD_P
                CPI     'N'
                JZ      CMD_N
                CPI     'D'
                JZ      CMD_D
                CPI     'B'
                JZ      CMD_B
                CPI     'W'
                JZ      CMD_W
                CPI     'X'
                JZ      CMD_X
                CPI     'Q'
                JZ      CMD_Q
                CPI     'M'
                JZ      CMD_M
                JMP     CMD_M

CMD_P:
                CALL    PRINT_PARTITIONS
                JMP     CMD_LOOP

CMD_N:
                CALL    NEW_PARTITION
                JMP     CMD_LOOP

CMD_D:
                CALL    DELETE_PARTITION
                JMP     CMD_LOOP

CMD_B:
                CALL    TOGGLE_BOOTABLE
                JMP     CMD_LOOP

CMD_X:
                CALL    ERASE_MASTER
                JMP     CMD_LOOP

CMD_M:
                LXI     D,MSG_HELP
                CALL    PUTS
                JMP     CMD_LOOP

CMD_Q:
                LDA     DIRTY
                ORA     A
                JZ      EXIT
                LXI     D,MSG_DISCARD
                CALL    PUTS
                JMP     EXIT

CMD_W:
                LDA     DIRTY
                ORA     A
                JNZ     DO_WRITE
                JMP     EXIT
DO_WRITE:
                CALL    SAVE_TABLE
                JNC     WRITE_OK
                LXI     D,MSG_WRITEERR
                CALL    PUTS
                CALL    SHOW_STATUS
                JMP     CMD_LOOP
WRITE_OK:
                LXI     D,MSG_WRITEOK
                CALL    PUTS
                CALL    REQUEST_HDD_REMOUNT

EXIT:
                MVI     C,0
                CALL    BDOS
                HLT

; ----------------------------------------------------------------------
; Command tail: one decimal digit 0..6, optional spaces.
; ----------------------------------------------------------------------
PARSE_ID:
                LDA     CMDLEN
                MOV     B,A
                LXI     H,CMDTAIL
PID_SKIP:
                MOV     A,B
                ORA     A
                JZ      PID_FAIL
                MOV     A,M
                CPI     ' '
                JNZ     PID_DIGIT
                INX     H
                DCR     B
                JMP     PID_SKIP
PID_DIGIT:
                CPI     '0'
                JC      PID_FAIL
                CPI     '7'
                JNC     PID_FAIL
                SUI     '0'
                STA     SCSI_ID
                INX     H
                DCR     B
PID_TRAIL:
                MOV     A,B
                ORA     A
                JZ      PID_OK
                MOV     A,M
                CPI     ' '
                JNZ     PID_FAIL
                INX     H
                DCR     B
                JMP     PID_TRAIL
PID_OK:
                XRA     A
                RET
PID_FAIL:
                STC
                RET

; ----------------------------------------------------------------------
; AH=84h NEW SENSE. DA/UA A0h..A6h.
; Output SEC_SIZE, CYL_LAST, HEADS, SPT.
; ----------------------------------------------------------------------
SENSE:
                LHLD    DAUA_WORD
                ; request frame
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
                MVI     B,1               ; C0/H0/S1 partition table
                MVI     A,006H
                JMP     HDD_IO_BUFFER
SAVE_TABLE:
                LXI     H,TABLE
                MVI     B,1
                MVI     A,005H
                JMP     HDD_IO_BUFFER

LOAD_MASTER:
                LXI     H,MASTERBUF
                MVI     B,0               ; C0/H0/S0 master IPL
                MVI     A,006H
                JMP     HDD_IO_BUFFER
SAVE_MASTER:
                LXI     H,MASTERBUF
                MVI     B,0
                MVI     A,005H

; A=ROM BIOS function, B=sector, HL=512-byte buffer.
HDD_IO_BUFFER:
                STA     IO_FUNC
                MOV     A,B
                STA     IO_SECTOR
                SHLD    IO_BUFFER
                MVI     A,MAX_RETRY
                STA     RETRY
HIT_RETRY:
                LDA     DAUA
                STA     RAW_AX
                LDA     IO_FUNC
                STA     RAW_AX+1
                LXI     H,SECTOR_SIZE
                SHLD    RAW_BX
                LXI     H,0
                SHLD    RAW_CX
                LDA     IO_SECTOR
                MOV     L,A
                MVI     H,0
                SHLD    RAW_DX            ; DH=0, DL=sector
                LHLD    IO_BUFFER
                SHLD    RAW_BP
                CALL    RAW_CALL
                RNC
                LDA     RETRY
                DCR     A
                STA     RETRY
                JNZ     HIT_RETRY
                STC
                RET

; ----------------------------------------------------------------------
; Master IPL status / erase.
; Marker used by the common project master IPL:
;   offset 0100h: "CPM8MIPL"
;   offset 0108h: version word, little endian.
; ----------------------------------------------------------------------
SHOW_MASTER:
                LXI     D,MSG_MASTER_PREFIX
                CALL    PUTS

                ; Treat an all-zero 512-byte sector as no master IPL.
                LXI     H,MASTERBUF
                LXI     B,512
SM_ZERO_LOOP:
                MOV     A,M
                ORA     A
                JNZ     SM_NOT_ZERO
                INX     H
                DCX     B
                MOV     A,B
                ORA     C
                JNZ     SM_ZERO_LOOP
                LXI     D,MSG_MASTER_NONE
                CALL    PUTS
                RET

SM_NOT_ZERO:
                LXI     H,MASTERBUF+0100H
                LXI     D,MASTER_MARKER
                MVI     B,8
SM_MARK_LOOP:
                LDAX    D
                CMP     M
                JNZ     SM_FOREIGN
                INX     D
                INX     H
                DCR     B
                JNZ     SM_MARK_LOOP

                LXI     D,MSG_MASTER_OURS
                CALL    PUTS
                LHLD    MASTERBUF+0108H
                CALL    DEC16
                CALL    CRLF
                RET

SM_FOREIGN:
                LXI     D,MSG_MASTER_FOREIGN
                CALL    PUTS
                RET

ERASE_MASTER:
                LXI     D,MSG_MASTER_CONFIRM
                CALL    PUTS
                CALL    READ_LINE
                LDA     LINEBUF+1
                ORA     A
                RZ
                LDA     LINEBUF+2
                CALL    UPPER
                CPI     'Y'
                RNZ

                ; Do not disturb the in-memory partition table.
                LXI     H,MASTERBUF
                LXI     B,512
EM_ZERO_LOOP:
                MVI     M,0
                INX     H
                DCX     B
                MOV     A,B
                ORA     C
                JNZ     EM_ZERO_LOOP

                CALL    SAVE_MASTER
                JNC     EM_OK
                LXI     D,MSG_MASTER_WRITEERR
                CALL    PUTS
                CALL    SHOW_STATUS
                RET
EM_OK:
                LXI     D,MSG_MASTER_ERASED
                CALL    PUTS
                RET

MASTER_MARKER:  DB 'CPM8MIPL'

; ----------------------------------------------------------------------
; Table display.
; ----------------------------------------------------------------------
SHOW_SUMMARY:
                LXI     D,MSG_DISK
                CALL    PUTS
                LDA     SCSI_ID
                CALL    HEXDIG
                LXI     D,MSG_COLON
                CALL    PUTS
                CALL    CALC_SPC
                JC      SS_ZERO
                LHLD    CYL_LAST
                INX     H
                CALL    CYLS_TO_MIB
                JMP     SS_OUT
SS_ZERO:
                LXI     H,0
SS_OUT:
                CALL    DEC16
                LXI     D,MSG_MIB_SECTOR
                CALL    PUTS
                LHLD    SEC_SIZE
                CALL    DEC16
                LXI     D,MSG_BYTES
                CALL    PUTS
                RET

ENTRY_EMPTY:
                ; Same criterion as FDISK_0914: MID/SID plus start/end cylinder.
                PUSH    H
                MOV     A,M
                INX     H
                ORA     M
                JNZ     EE_USED
                POP     H
                PUSH    H
                LXI     D,10
                DAD     D
                MOV     E,M
                INX     H
                MOV     D,M
                POP     H
                PUSH    H
                LXI     B,14
                DAD     B
                MOV     A,M
                INX     H
                ORA     M
                ORA     D
                ORA     E
                POP     H
                RET
EE_USED:
                POP     H
                MVI     A,1
                ORA     A
                RET

PRINT_PARTITIONS:
                LXI     D,MSG_PHEAD
                CALL    PUTS
                LXI     H,TABLE
                SHLD    CUR_PTR
                XRA     A
                STA     CUR_INDEX
                STA     PP_USED
PP_LOOP:
                LDA     CUR_INDEX
                CPI     PART_COUNT
                JZ      PP_DONE
                LHLD    CUR_PTR
                CALL    ENTRY_EMPTY
                JZ      PP_NEXT
                LDA     PP_USED
                INR     A
                STA     PP_USED
                LDA     CUR_INDEX
                INR     A
                CALL    DEC2
                MVI     B,6
PP_PAD:
                MVI     A,' '
                CALL    PCHAR
                DCR     B
                JNZ     PP_PAD
                LHLD    CUR_PTR
                MOV     A,M
                ANI     080H
                JZ      PP_NB
                MVI     A,'*'
                JMP     PP_BOUT
PP_NB:
                MVI     A,'-'
PP_BOUT:
                CALL    PCHAR
                MVI     A,' '
                CALL    PCHAR
                MVI     A,' '
                CALL    PCHAR
                LHLD    CUR_PTR
                INX     H
                MOV     A,M
                ANI     07FH
                CALL    PRINT_TYPE
                MVI     A,' '
                CALL    PCHAR
                MVI     A,' '
                CALL    PCHAR
                ; Load start cylinder into DE.
                LHLD    CUR_PTR
                LXI     B,10
                DAD     B
                MOV     E,M
                INX     H
                MOV     D,M

                ; Load end cylinder into BC before reusing HL for arithmetic.
                ; Do not overwrite L while HL is still the table pointer.
                LHLD    CUR_PTR
                LXI     B,14
                DAD     B
                MOV     C,M
                INX     H
                MOV     B,M

                ; HL = end - start + 1 cylinders.
                MOV     A,C
                SUB     E
                MOV     L,A
                MOV     A,B
                SBB     D
                MOV     H,A
                JC      PP_SZ0
                INX     H
                CALL    CYLS_TO_MIB
                JMP     PP_SZOUT
PP_SZ0:
                LXI     H,0
PP_SZOUT:
                CALL    DEC16S5
                LXI     D,MSG_MIB_SHORT
                CALL    PUTS
                LXI     D,MSG_NAME_SEP
                CALL    PUTS

                ; Partition sysm/name is entry +10h..+1Fh (16 bytes).
                ; Print printable ASCII as-is, replace control/non-ASCII bytes
                ; with spaces so an unformatted/foreign entry cannot corrupt
                ; the terminal display.
                LHLD    CUR_PTR
                LXI     D,16
                DAD     D
                MVI     B,16
PP_NAME_LOOP:
                MOV     A,M
                CPI     20H
                JC      PP_NAME_SPACE
                CPI     7FH
                JNC     PP_NAME_SPACE
                JMP     PP_NAME_OUT
PP_NAME_SPACE:
                MVI     A,' '
PP_NAME_OUT:
                CALL    PCHAR
                INX     H
                DCR     B
                JNZ     PP_NAME_LOOP
                CALL    CRLF
PP_NEXT:
                LHLD    CUR_PTR
                LXI     D,PART_SIZE
                DAD     D
                SHLD    CUR_PTR
                LDA     CUR_INDEX
                INR     A
                STA     CUR_INDEX
                JMP     PP_LOOP
PP_DONE:
                LDA     PP_USED
                ORA     A
                RNZ
                LXI     D,MSG_EMPTY
                CALL    PUTS
                RET

CYLS_TO_MIB:
                XCHG
                LHLD    SPC
                XCHG
                CALL    MUL16

                ; Round displayed MiB upward: ceil(sectors / 2048).
                ; Add 2047 to the 32-bit sector count before shifting right 11.
                LHLD    MUL_LO
                LXI     D,2047
                DAD     D
                SHLD    MUL_LO
                JNC     CTM_ROUND_OK
                LHLD    MUL_HI
                INX     H
                SHLD    MUL_HI
CTM_ROUND_OK:
                MVI     B,11
CTM_SHIFT:
                LHLD    MUL_HI
                MOV     A,H
                ORA     A
                RAR
                MOV     H,A
                MOV     A,L
                RAR
                MOV     L,A
                SHLD    MUL_HI
                LHLD    MUL_LO
                MOV     A,H
                RAR
                MOV     H,A
                MOV     A,L
                RAR
                MOV     L,A
                SHLD    MUL_LO
                DCR     B
                JNZ     CTM_SHIFT
                LHLD    MUL_LO
                RET

DEC2:
                MVI     B,'0'
D2_LOOP:
                CPI     10
                JC      D2_OUT
                SUI     10
                INR     B
                JMP     D2_LOOP
D2_OUT:
                PUSH    PSW
                MOV     A,B
                CALL    PCHAR
                POP     PSW
                ADI     '0'
                CALL    PCHAR
                RET

PRINT_TYPE:
                CPI     01H
                JZ      PT_FAT12
                CPI     06H
                JZ      PT_N88
                CPI     11H
                JZ      PT_FAT16
                CPI     21H
                JZ      PT_FAT16
                CPI     44H
                JZ      PT_BSD
                CPI     61H
                JZ      PT_FAT32
                CPI     62H
                JZ      PT_LINUX
                CPI     CPM_SYS
                JZ      PT_CPM
                LXI     D,TYPE_OTHER
                JMP     PUTS
PT_FAT12:
                LXI     D,TYPE_FAT12
                JMP     PUTS
PT_FAT16:
                LXI     D,TYPE_FAT16
                JMP     PUTS
PT_FAT32:
                LXI     D,TYPE_FAT32
                JMP     PUTS
PT_N88:
                LXI     D,TYPE_N88
                JMP     PUTS
PT_BSD:
                LXI     D,TYPE_BSD
                JMP     PUTS
PT_LINUX:
                LXI     D,TYPE_LINUX
                JMP     PUTS
PT_CPM:
                LXI     D,TYPE_CPM
                JMP     PUTS

; ----------------------------------------------------------------------
; New partition. Appends after highest used entry/end cylinder.
; Size is 2..128 MiB. 512-byte sectors only.
; ----------------------------------------------------------------------
NEW_PARTITION:
                CALL    FIND_APPEND
                JNC     NP_HAVE
                LXI     D,MSG_FULL
                CALL    PUTS
                RET
NP_HAVE:
                SHLD    NEW_ENTRY_PTR
                MOV     A,E
                STA     NEW_INDEX

                ; NEXT_CYL already set by FIND_APPEND.
                LHLD    NEXT_CYL
                XCHG
                LHLD    CYL_LAST
                MOV     A,H
                CMP     D
                JC      NP_NOSPACE
                JNZ     NP_ASK
                MOV     A,L
                CMP     E
                JC      NP_NOSPACE

NP_ASK:
                LXI     D,MSG_NEWSIZE
                CALL    PUTS
                CALL    READ_LINE
                CALL    PARSE_UINT
                JC      NP_BAD
                MOV     A,H
                ORA     A
                JNZ     NP_BAD
                MOV     A,L
                CPI     2
                JC      NP_BAD
                CPI     MAX_MIB+1
                JNC     NP_BAD
                STA     REQ_MIB

                CALL    CALC_SPC
                JC      NP_BAD
                ; Numerator sectors = MiB * 2048 = value << 11.
                ; 32-bit NUM_HI:NUM_LO.
                LDA     REQ_MIB
                MOV     L,A
                MVI     H,0
                SHLD    NUM_LO
                LXI     H,0
                SHLD    NUM_HI
                MVI     B,11
NP_SHL:
                LHLD    NUM_LO
                DAD     H
                SHLD    NUM_LO
                LHLD    NUM_HI
                MOV     A,L
                RAL
                MOV     L,A
                MOV     A,H
                RAL
                MOV     H,A
                SHLD    NUM_HI
                DCR     B
                JNZ     NP_SHL

                CALL    DIV32_BY_SPC
                ; quotient = CYL_COUNT
                LHLD    CYL_COUNT
                MOV     A,H
                ORA     L
                JZ      NP_BAD

                ; end = start + count - 1
                DCX     H
                XCHG
                LHLD    NEXT_CYL
                DAD     D
                SHLD    NEW_END
                ; ensure <= CYL_LAST
                XCHG
                LHLD    CYL_LAST
                MOV     A,H
                CMP     D
                JC      NP_NOSPACE
                JNZ     NP_BUILD
                MOV     A,L
                CMP     E
                JC      NP_NOSPACE

NP_BUILD:
                LHLD    NEW_ENTRY_PTR
                PUSH    H
                MVI     B,PART_SIZE
                XRA     A
NP_ZERO:
                MOV     M,A
                INX     H
                DCR     B
                JNZ     NP_ZERO
                POP     H
                INX     H
                MVI     M,CPM_SYS

                ; IPL CHS + start CHS cylinder.
                ; restore pointer cleanly
                LHLD    NEW_ENTRY_PTR
                LXI     D,6
                DAD     D
                XCHG
                LHLD    NEXT_CYL
                XCHG
                MOV     M,E
                INX     H
                MOV     M,D

                LHLD    NEW_ENTRY_PTR
                LXI     D,10
                DAD     D
                XCHG
                LHLD    NEXT_CYL
                XCHG
                MOV     M,E
                INX     H
                MOV     M,D

                LHLD    NEW_ENTRY_PTR
                LXI     D,14
                DAD     D
                XCHG
                LHLD    NEW_END
                XCHG
                MOV     M,E
                INX     H
                MOV     M,D

                ; sysm = spaces.
                LHLD    NEW_ENTRY_PTR
                LXI     D,16
                DAD     D
                MVI     B,16
                MVI     A,' '
NP_SPACES:
                MOV     M,A
                INX     H
                DCR     B
                JNZ     NP_SPACES

                MVI     A,1
                STA     DIRTY
                LXI     D,MSG_NEWOK1
                CALL    PUTS
                LDA     NEW_INDEX
                INR     A
                MOV     L,A
                MVI     H,0
                CALL    DEC16
                LXI     D,MSG_NEWOK2
                CALL    PUTS
                RET

NP_BAD:
                LXI     D,MSG_BADSIZE
                CALL    PUTS
                RET
NP_NOSPACE:
                LXI     D,MSG_NOSPACE
                CALL    PUTS
                RET

; FIND_APPEND: HL=entry ptr, E=index, NEXT_CYL=max(end)+1 or 1, CF=1 full.
FIND_APPEND:
                LXI     H,TABLE
                SHLD    CUR_PTR
                XRA     A
                STA     CUR_INDEX
                STA     APPEND_INDEX
                LXI     H,0
                SHLD    MAX_END
FA_LOOP:
                LDA     CUR_INDEX
                CPI     PART_COUNT
                JZ      FA_DONE
                LHLD    CUR_PTR
                CALL    ENTRY_EMPTY
                JZ      FA_NEXT

                LDA     CUR_INDEX
                INR     A
                STA     APPEND_INDEX

                LHLD    CUR_PTR
                LXI     D,14
                DAD     D
                MOV     E,M
                INX     H
                MOV     D,M
                XCHG
                SHLD    END_TMP

                LHLD    MAX_END
                XCHG                    ; DE=max end
                LHLD    END_TMP         ; HL=this end
                MOV     A,H
                CMP     D
                JC      FA_NEXT
                JNZ     FA_SETMAX
                MOV     A,L
                CMP     E
                JC      FA_NEXT
                JZ      FA_NEXT
FA_SETMAX:
                SHLD    MAX_END

FA_NEXT:
                LHLD    CUR_PTR
                LXI     D,PART_SIZE
                DAD     D
                SHLD    CUR_PTR
                LDA     CUR_INDEX
                INR     A
                STA     CUR_INDEX
                JMP     FA_LOOP

FA_DONE:
                LDA     APPEND_INDEX
                CPI     PART_COUNT
                JNC     FA_FAIL

                ; HL = TABLE + index*32
                ; DE is used as the addend here, so do not return the index
                ; in E until the pointer calculation has finished.
                LXI     H,TABLE
                MOV     B,A
FA_PTR:
                MOV     A,B
                ORA     A
                JZ      FA_PTR_DONE
                LXI     D,PART_SIZE
                DAD     D
                DCR     B
                JMP     FA_PTR
FA_PTR_DONE:
                LDA     APPEND_INDEX
                MOV     E,A             ; return index in E
                PUSH    H
                LHLD    MAX_END
                MOV     A,H
                ORA     L
                JNZ     FA_PLUS
                LXI     H,1
                JMP     FA_STORE
FA_PLUS:
                INX     H
FA_STORE:
                SHLD    NEXT_CYL
                POP     H
                XRA     A
                RET
FA_FAIL:
                STC
                RET

DELETE_PARTITION:
                LXI     D,MSG_DELASK
                CALL    PUTS
                CALL    READ_LINE
                CALL    PARSE_UINT
                JC      DP_BAD
                MOV     A,H
                ORA     A
                JNZ     DP_BAD
                MOV     A,L
                ORA     A
                JZ      DP_BAD
                CPI     PART_COUNT+1
                JNC     DP_BAD
                DCR     A
                STA     DEL_INDEX
                LXI     H,TABLE
                MOV     B,A
DP_PTR:
                MOV     A,B
                ORA     A
                JZ      DP_PTR_OK
                LXI     D,PART_SIZE
                DAD     D
                DCR     B
                JMP     DP_PTR
DP_PTR_OK:
                SHLD    DEL_PTR
                CALL    ENTRY_EMPTY
                JZ      DP_EMPTY
                LHLD    DEL_PTR
                LXI     D,14
                DAD     D
                MOV     E,M
                INX     H
                MOV     D,M
                XCHG
                SHLD    LAST_END
                LXI     H,TABLE
                SHLD    CUR_PTR
                XRA     A
                STA     CUR_INDEX
DP_SCAN:
                LDA     CUR_INDEX
                CPI     PART_COUNT
                JZ      DP_LAST_OK
                LHLD    CUR_PTR
                CALL    ENTRY_EMPTY
                JZ      DP_SCAN_NEXT
                LHLD    CUR_PTR
                LXI     D,14
                DAD     D
                MOV     E,M
                INX     H
                MOV     D,M
                XCHG
                PUSH    H
                LHLD    LAST_END
                XCHG
                POP     H
                MOV     A,H
                CMP     D
                JC      DP_NOT_LAST
                JNZ     DP_SCAN_NEXT
                MOV     A,L
                CMP     E
                JC      DP_NOT_LAST
DP_SCAN_NEXT:
                LHLD    CUR_PTR
                LXI     D,PART_SIZE
                DAD     D
                SHLD    CUR_PTR
                LDA     CUR_INDEX
                INR     A
                STA     CUR_INDEX
                JMP     DP_SCAN
DP_LAST_OK:
                LHLD    DEL_PTR
                MVI     B,PART_SIZE
                XRA     A
DP_ZERO:
                MOV     M,A
                INX     H
                DCR     B
                JNZ     DP_ZERO
                MVI     A,1
                STA     DIRTY
                LXI     D,MSG_DELOK1
                CALL    PUTS
                LDA     DEL_INDEX
                INR     A
                MOV     L,A
                MVI     H,0
                CALL    DEC16
                LXI     D,MSG_DELOK2
                CALL    PUTS
                RET
DP_BAD:
                LXI     D,MSG_DELBAD
                CALL    PUTS
                RET
DP_EMPTY:
                LXI     D,MSG_DELEMPTY
                CALL    PUTS
                RET
DP_NOT_LAST:
                LXI     D,MSG_DELLAST
                CALL    PUTS
                RET

; ----------------------------------------------------------------------
; Toggle bootable marker on a CP/M type-70h partition.
; ----------------------------------------------------------------------
TOGGLE_BOOTABLE:
                LXI     D,MSG_BOOTASK
                CALL    PUTS
                CALL    READ_LINE
                CALL    PARSE_UINT
                JC      TB_BAD
                MOV     A,H
                ORA     A
                JNZ     TB_BAD
                MOV     A,L
                ORA     A
                JZ      TB_BAD
                CPI     PART_COUNT+1
                JNC     TB_BAD
                DCR     A
                STA     TB_INDEX
                LXI     H,TABLE
                MOV     B,A
TB_PTR:
                MOV     A,B
                ORA     A
                JZ      TB_PTR_OK
                LXI     D,PART_SIZE
                DAD     D
                DCR     B
                JMP     TB_PTR
TB_PTR_OK:
                SHLD    TB_PTR_SAVE
                CALL    ENTRY_EMPTY
                JZ      TB_EMPTY
                LHLD    TB_PTR_SAVE
                INX     H
                MOV     A,M
                ANI     07FH
                CPI     CPM_SYS
                JNZ     TB_NOTCPM
                DCX     H
                MOV     A,M
                CPI     095H
                JZ      TB_CLEAR
                MVI     M,095H
                LXI     D,MSG_BOOTSET1
                CALL    PUTS
                JMP     TB_NUM
TB_CLEAR:
                MVI     M,000H
                LXI     D,MSG_BOOTCLR1
                CALL    PUTS
TB_NUM:
                LDA     TB_INDEX
                INR     A
                MOV     L,A
                MVI     H,0
                CALL    DEC16
                LXI     D,MSG_BOOTDONE
                CALL    PUTS
                MVI     A,1
                STA     DIRTY
                RET
TB_BAD:
                LXI     D,MSG_BOOTBAD
                CALL    PUTS
                RET
TB_EMPTY:
                LXI     D,MSG_DELEMPTY
                CALL    PUTS
                RET
TB_NOTCPM:
                LXI     D,MSG_BOOTNOTCPM
                CALL    PUTS
                RET

REQUEST_HDD_REMOUNT:
                MVI     A,SVC_HDD_REMOUNT_REQUEST
                DB      0EDH,0EDH,CALLN_VEC
                RET

; ----------------------------------------------------------------------
; Arithmetic.
; ----------------------------------------------------------------------
CALC_SPC:
                LDA     HEADS
                MOV     L,A
                MVI     H,0
                LDA     SPT
                MOV     E,A
                MVI     D,0
                CALL    MUL16
                ; result MUL_HI:MUL_LO; require <= FFFF and nonzero.
                LHLD    MUL_HI
                MOV     A,H
                ORA     L
                JNZ     CSP_FAIL
                LHLD    MUL_LO
                MOV     A,H
                ORA     L
                JZ      CSP_FAIL
                SHLD    SPC
                XRA     A
                RET
CSP_FAIL:
                STC
                RET

; HL * DE -> MUL_HI:MUL_LO
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

; Repeated-subtraction 32-bit numerator / 16-bit SPC -> CYL_COUNT.
DIV32_BY_SPC:
                LXI     H,0
                SHLD    CYL_COUNT
D32_LOOP:
                LHLD    NUM_HI
                MOV     A,H
                ORA     L
                JNZ     D32_SUB
                ; high zero: compare low with SPC
                LHLD    NUM_LO
                XCHG
                LHLD    SPC
                MOV     A,D
                CMP     H
                JC      D32_DONE
                JNZ     D32_SUB
                MOV     A,E
                CMP     L
                JC      D32_DONE
D32_SUB:
                ; NUM -= SPC
                LHLD    NUM_LO
                XCHG
                LHLD    SPC
                MOV     A,E
                SUB     L
                MOV     E,A
                MOV     A,D
                SBB     H
                MOV     D,A
                XCHG
                SHLD    NUM_LO
                JNC     D32_INC
                LHLD    NUM_HI
                DCX     H
                SHLD    NUM_HI
D32_INC:
                LHLD    CYL_COUNT
                INX     H
                SHLD    CYL_COUNT
                JMP     D32_LOOP
D32_DONE:
                RET

PARSE_UINT:
                LDA     LINEBUF+1
                MOV     B,A
                LXI     H,LINEBUF+2
PU_SKIP:
                MOV     A,B
                ORA     A
                JZ      PU_FAIL
                MOV     A,M
                CPI     ' '
                JNZ     PU_DIGITS
                INX     H
                DCR     B
                JMP     PU_SKIP
PU_DIGITS:
                LXI     D,0
                MVI     C,0
PU_LOOP:
                MOV     A,B
                ORA     A
                JZ      PU_DONE
                MOV     A,M
                CPI     ' '
                JZ      PU_TRAIL
                CPI     '0'
                JC      PU_FAIL
                CPI     '9'+1
                JNC     PU_FAIL
                SUI     '0'
                STA     DIGIT
                ; DE = DE*10 + digit, reject overflow.
                PUSH    H
                MOV     H,D
                MOV     L,E
                DAD     H
                SHLD    PU_X2
                DAD     H
                DAD     H            ; x8
                XCHG
                LHLD    PU_X2
                DAD     D            ; x10
                JC      PU_FAIL_POP
                LDA     DIGIT
                MOV     E,A
                MVI     D,0
                DAD     D
                JC      PU_FAIL_POP
                XCHG
                POP     H
                INR     C
                INX     H
                DCR     B
                JMP     PU_LOOP
PU_TRAIL:
                MOV     A,C
                ORA     A
                JZ      PU_FAIL
PU_TLOOP:
                MOV     A,B
                ORA     A
                JZ      PU_DONE
                MOV     A,M
                CPI     ' '
                JNZ     PU_FAIL
                INX     H
                DCR     B
                JMP     PU_TLOOP
PU_DONE:
                MOV     A,C
                ORA     A
                JZ      PU_FAIL
                XCHG
                XRA     A
                RET
PU_FAIL_POP:
                POP     H
PU_FAIL:
                STC
                RET

; ----------------------------------------------------------------------
; Gateway RAW service.
; ----------------------------------------------------------------------
RAW_CALL:
                LXI     D,RAW_FRAME
                MVI     A,SVC_RAW_INT1B
                DB      0EDH,0EDH,CALLN_VEC
                LDA     RAW_AX+1
                STA     LAST_STATUS
                LDA     RAW_FLAGS
                ANI     1
                JZ      RAW_OK
                STC
                RET
RAW_OK:
                XRA     A
                RET

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
READ_LINE:
                MVI     A,63
                STA     LINEBUF
                XRA     A
                STA     LINEBUF+1
                LXI     D,LINEBUF
                MVI     C,10
                CALL    BDOS
                CALL    CRLF
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

HEX8:
                PUSH    PSW
                RRC
                RRC
                RRC
                RRC
                ANI     0FH
                CALL    HEXDIG
                POP     PSW
                ANI     0FH
HEXDIG:
                CPI     10
                JC      HD_NUM
                ADI     'A'-10
                JMP     PCHAR
HD_NUM:
                ADI     '0'
PCHAR:
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

DEC16:
                XRA     A
                STA     DEC_STARTED
                JMP     DEC16_BODY
; Fixed-width 5-digit decimal, space padded ("    0".."65535").
DEC16S5:
                XRA     A
                STA     DEC_STARTED
                PUSH    B
                PUSH    D
                PUSH    H
                LXI     D,10000
                CALL    D16S_DIG
                LXI     D,1000
                CALL    D16S_DIG
                LXI     D,100
                CALL    D16S_DIG
                LXI     D,10
                CALL    D16S_DIG
                MOV     A,L
                ADI     '0'
                CALL    PCHAR
                POP     H
                POP     D
                POP     B
                RET

D16S_DIG:
                MVI     B,'0'
D16S_SUB:
                MOV     A,L
                SUB     E
                MOV     C,A
                MOV     A,H
                SBB     D
                JC      D16S_OUTD
                MOV     L,C
                MOV     H,A
                INR     B
                JMP     D16S_SUB
D16S_OUTD:
                MOV     A,B
                CPI     '0'
                JNZ     D16S_PRINT
                LDA     DEC_STARTED
                ORA     A
                JNZ     D16S_ZERO
                MVI     A,' '
                CALL    PCHAR
                RET
D16S_ZERO:
                MVI     A,'0'
D16S_PRINT:
                CALL    PCHAR
                MVI     A,1
                STA     DEC_STARTED
                RET

DEC16_BODY:
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
                JNZ     D16_PRINT
                LDA     DEC_STARTED
                ORA     A
                RZ
                MOV     A,B
D16_PRINT:
                CALL    PCHAR
                MVI     A,1
                STA     DEC_STARTED
                RET

SHOW_STATUS:
                LDA     LAST_STATUS
                CALL    HEX8
                CALL    CRLF
                RET

; ----------------------------------------------------------------------
; Data.
; ----------------------------------------------------------------------
MSG_BANNER:     DB 13,10,'PC-98 SCSI FDISK',13,10
                DB 'Changes are written only by command w.',13,10,'$'
MSG_USAGE:      DB 13,10,'Usage: FDISK SCSI-ID',13,10
                DB '       SCSI-ID = 0..6',13,10
                DB 'Example: FDISK 0',13,10,'$'
MSG_NODISK:     DB 13,10,'No usable SCSI HDD.',13,10,'$'
MSG_BADSECTOR:  DB 13,10,'Only 512-byte SCSI sectors are supported.',13,10,'$'
MSG_CACHEERR:   DB 13,10,'BIOS cache flush failed, direct disk I/O not started.',13,10,'$'
MSG_READERR:    DB 13,10,'Partition table read error, status=$'
MSG_WRITEERR:   DB 13,10,'Partition table write error, status=$'
MSG_WRITEOK:    DB 13,10,'Partition table written.',13,10,'$'
MSG_DISCARD:    DB 13,10,'Changes discarded.',13,10,'$'
MSG_PROMPT:     DB 13,10,'Command (m for help): $'
MSG_HELP:       DB 13,10,'Commands:',13,10
                DB '  m  print this help',13,10
                DB '  p  print partition table',13,10
                DB '  n  create CP/M-80 partition (2..128 MiB, rounded down)',13,10
                DB '  d  delete physically last partition',13,10
                DB '  b  toggle CP/M type-70h bootable flag (00h/95h)',13,10
                DB '  w  write table to disk and exit',13,10
                DB '  x  erase master IPL sector immediately',13,10
                DB '  q  quit without saving',13,10,'$'
MSG_DISK:       DB 13,10,'Disk A$'
MSG_COLON:      DB ': $'
MSG_MIB_SECTOR: DB ' MiB, sector size $'
MSG_BYTES:      DB ' bytes',13,10,'$'
MSG_PHEAD:      DB 13,10,'Device  B  Type              Size      Name',13,10
                DB '------  -  ----------------  --------  ----------------',13,10,'$'
MSG_EMPTY:      DB 'No partitions.',13,10,'$'
TYPE_FAT12:     DB 'MS-DOS FAT12    $'
TYPE_FAT16:     DB 'MS-DOS FAT16    $'
TYPE_FAT32:     DB 'Windows FAT32   $'
TYPE_N88:       DB 'N88-BASIC       $'
TYPE_BSD:       DB 'FreeBSD/NetBSD  $'
TYPE_LINUX:     DB 'Linux/98        $'
TYPE_CPM:       DB 'CP/M            $'
TYPE_OTHER:     DB 'Other           $'
MSG_NEWSIZE:    DB 13,10,'Size in MiB: $'
MSG_FULL:       DB 13,10,'No free partition table entry.',13,10,'$'
MSG_NOSPACE:    DB 13,10,'Not enough free cylinders.',13,10,'$'
MSG_BADSIZE:    DB 13,10,'Invalid size.',13,10,'$'
MSG_NEWOK1:     DB 13,10,'Created partition $'
MSG_NEWOK2:     DB ' in memory. Use w to write.',13,10,'$'
MSG_DELASK:     DB 13,10,'Partition number to delete: $'
MSG_DELBAD:     DB 13,10,'Invalid partition number.',13,10,'$'
MSG_DELEMPTY:   DB 13,10,'That partition entry is unused.',13,10,'$'
MSG_DELLAST:    DB 13,10,'Only the physically last partition can be deleted.',13,10,'$'
MSG_DELOK1:     DB 13,10,'Deleted partition $'
MSG_DELOK2:     DB ' in memory. Use w to write.',13,10,'$'
MSG_BOOTASK:    DB 13,10,'Partition number to toggle bootable: $'
MSG_BOOTBAD:    DB 13,10,'Invalid partition number.',13,10,'$'
MSG_BOOTNOTCPM: DB 13,10,'That partition is not CP/M type 70h.',13,10,'$'
MSG_BOOTSET1:   DB 13,10,'Bootable (95h) set on partition $'
MSG_BOOTCLR1:   DB 13,10,'Bootable cleared on partition $'
MSG_BOOTDONE:   DB '. Use w to write.',13,10,'$'
MSG_MASTER_PREFIX: DB 'Master IPL: $'
MSG_MASTER_NONE: DB 'none',13,10,'$'
MSG_MASTER_OURS: DB 'CP/M common v$'
MSG_MASTER_FOREIGN: DB 'foreign or unknown',13,10,'$'
MSG_MASTER_READERR: DB 'Master IPL: read error',13,10,'$'
MSG_MASTER_CONFIRM: DB 13,10,'Erase master IPL sector? (Y/N): $'
MSG_MASTER_ERASED: DB 13,10,'Master IPL erased.',13,10,'$'
MSG_MASTER_WRITEERR: DB 13,10,'Master IPL erase failed, status=$'
MSG_CRLF:       DB 13,10,'$'
MSG_MIB_SHORT:  DB 'MiB$'
MSG_NAME_SEP:   DB '  $'

SCSI_ID:        DB 0
DAUA:           DB 0
DAUA_WORD:      DW 0
SEC_SIZE:       DW 0
CYL_LAST:       DW 0
HEADS:          DB 0
SPT:            DB 0
DIRTY:          DB 0
RETRY:          DB 0
IO_FUNC:        DB 0
IO_SECTOR:      DB 0
IO_BUFFER:      DW 0
LAST_STATUS:    DB 0

RAW_FRAME:
RAW_AX:         DW 0
RAW_BX:         DW 0
RAW_CX:         DW 0
RAW_DX:         DW 0
RAW_BP:         DW 0
RAW_FLAGS:      DW 0

REQ_MIB:        DB 0
SPC:            DW 0
NUM_LO:         DW 0
NUM_HI:         DW 0
CYL_COUNT:      DW 0
NEXT_CYL:       DW 0
NEW_END:        DW 0
NEW_ENTRY_PTR:  DW 0
NEW_INDEX:      DB 0
DEL_PTR:        DW 0
DEL_INDEX:      DB 0FFH
MAX_END:        DW 0
LAST_END:       DW 0
LAST_PTR:       DW 0
TMPPTR:         DW 0
CUR_PTR:        DW 0
CUR_INDEX:      DB 0
APPEND_INDEX:   DB 0
END_TMP:        DW 0
NAME_COUNT:     DB 0
PP_USED:        DB 0
TB_INDEX:       DB 0
TB_PTR_SAVE:    DW 0
DEC_STARTED:    DB 0

M_A:            DW 0
M_B:            DW 0
MUL_LO:         DW 0
MUL_HI:         DW 0
PU_X2:          DW 0
DIGIT:          DB 0
DEC_BUF:        DS 6

LINEBUF:        DS 66
TABLE:          DS 512
MASTERBUF:      DS 512
STACK_AREA:     DS 256
STACK_TOP       EQU $
                END START
