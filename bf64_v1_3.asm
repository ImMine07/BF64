[BITS 16]

; =========================================================================
; BF64 v1.3 - XP-STYLE SETUP + CONSOLE POST + BF64TUI + 32KB OPT VM OS
; 컴파일: nasm -f bin bf64inst.asm -o bf64inst.img
;
; [.img 섹터 구성 - 1.44MB 플로피 규격 (8086-Safe Multi-Track CHS 로더)]
;   LBA 0       (1섹터,    512B) : 설치기 Stage 1 ("bf64exec" 헤더, RAM 0x7C00)
;   LBA 1 ~ 30  (30섹터, 15360B) : 진단 + XP 설치기 Stage 2 (RAM 0x7E00)
;   LBA 31      (1섹터,    512B) : HDD용 MBR 템플릿 (RAM 0xBA00)
;   LBA 32 ~ 63 (32섹터, 16384B) : HDD용 BF64 v1.3 OS 본체 (RAM 0xBC00)
;   LBA 64 ~ 끝                  : 1.44MB 규격 패딩
; =========================================================================

MAX_TARGET_SECTORS equ 2100000
LOAD_SECTORS       equ 63       ; inst_s2(30) + hdd_mbr(1) + hdd_os(32)

; =========================================================================
; SECTION 1 : 설치기 STAGE 1 - 8086-Safe Multi-Track CHS 로더 (512B)
; =========================================================================
section .inst_s1 vstart=0x7C00 align=4

    jmp short inst_stage1
    nop
    db "bf64exec"

inst_stage1:
    cli
    cld
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0x7C00
    sti

    mov [s1_drive], dl

    ; 드라이브 지오메트리 조회 (순수 16비트 명령어 사용)
    push es
    mov ah, 0x08
    mov dl, [s1_drive]
    xor di, di
    int 0x13
    pop es
    jc .use_default_geom
    and cx, 0x003F
    jz .use_default_geom
    mov [s1_spt], cx
    mov al, dh
    xor ah, ah
    inc ax
    mov [s1_heads], ax
.use_default_geom:

    mov word [s1_lba], 1
    mov word [s1_buf], 0x7E00
    mov word [s1_left], LOAD_SECTORS

.load_next:
    mov si, 3
.retry:
    mov ax, [s1_lba]
    xor dx, dx
    div word [s1_spt]           ; AX = track, DX = sector - 1
    mov cl, dl
    inc cl                      ; CL = 1-based sector
    xor dx, dx
    div word [s1_heads]         ; AX = cylinder, DX = head
    mov ch, al
    push cx
    mov cl, 6
    shl ah, cl
    pop cx
    or cl, ah
    mov dh, dl

    mov ax, 0x0201              ; AH=02, AL=1섹터
    mov dl, [s1_drive]
    mov bx, [s1_buf]
    int 0x13
    jnc .sec_ok

    xor ah, ah
    mov dl, [s1_drive]
    int 0x13
    dec si
    jnz .retry

    mov si, s1_err
.err_loop:
    lodsb
    test al, al
    jz .halt
    mov ah, 0x0E
    int 0x10
    jmp .err_loop
.halt:
    cli
    hlt
    jmp .halt

.sec_ok:
    inc word [s1_lba]
    add word [s1_buf], 512
    dec word [s1_left]
    jnz .load_next

    mov dl, [s1_drive]
    jmp 0x0000:0x7E00

s1_drive db 0
s1_spt   dw 18
s1_heads dw 2
s1_lba   dw 1
s1_buf   dw 0x7E00
s1_left  dw LOAD_SECTORS
s1_err   db "Disk read error. Press Ctrl+Alt+Del to restart.", 0

times 510 - ($ - $$) db 0
dw 0xAA55


; =========================================================================
; SECTION 2 : 자가 진단 + XP 스타일 설치기 STAGE 2 (15,360B = 30 Sectors)
; =========================================================================
section .inst_s2 vstart=0x7E00 follows=.inst_s1 align=4

INST_SCRATCH    equ 0x0600
HDD_MBR_SRC     equ 0xBA00
HDD_OS_SRC      equ 0xBC00
RAM_TEST_B_ADDR equ 0xFC00      ; 0xFC00..0xFFFF (1,024B, 0xBC00+16384 이후)
WIPE_SEG        equ 0x1000
NUM_PAGES       equ 6

; 자가 진단 실패 플래그 비트
FAIL_CPU        equ 0x01
FAIL_RAM_CAP    equ 0x02
FAIL_RAM_INT    equ 0x04
FAIL_LBA        equ 0x08
FAIL_HDD        equ 0x10

; VGA 컬러 속성
ATTR_BLACK      equ 0x07        ; 검은 배경 + 회색 글씨
ATTR_CON_HDR    equ 0x0F        ; 검은 배경 + 밝은 흰색
ATTR_CON_OK     equ 0x0A        ; 검은 배경 + 밝은 초록 ([OK])
ATTR_CON_FAIL   equ 0x0C        ; 검은 배경 + 밝은 빨강 ([FAIL])
ATTR_CON_SKIP   equ 0x0E        ; 검은 배경 + 노랑 ([SKIP])
ATTR_XP_TEXT    equ 0x17        ; XP 파란 배경 + 밝은 회색 글씨
ATTR_XP_HDR     equ 0x1F        ; XP 파란 배경 + 밝은 흰색 글씨
ATTR_XP_YEL     equ 0x1E        ; XP 파란 배경 + 노란색 (진행 바/경고)
ATTR_XP_RED     equ 0x1C        ; XP 파란 배경 + 밝은 빨간색 (재부팅 바)
ATTR_XP_BAR     equ 0x70        ; 밝은 회색 배경 + 검은 글씨 (상태바/선택항목)

inst_stage2:
    mov [inst_boot_drv], dl
    mov byte [inst_target_drv], 0x80
    cmp dl, 0x80
    jne .drv_ready
    mov byte [inst_target_drv], 0x81
.drv_ready:

    ; 1. 80x25 VGA 텍스트 모드 설정 및 커서 숨김
    mov ax, 0x0003
    int 0x10
    mov ah, 0x01
    mov cx, 0x2607
    int 0x10
    call vga_clear_black

.flush_kbd:
    mov ah, 0x01
    int 0x16
    jz .start_wait
    xor ah, ah
    int 0x16
    jmp .flush_kbd

    ; 2. 검은 화면에서 10초간 키보드 입력 대기 (182틱, 순수 16비트)
.start_wait:
    mov ax, [0x046C]
    mov [last_tick], ax
    mov word [elapsed_ticks], 0
    mov word [last_sec_shown], 99

.wait_loop:
    mov ax, [elapsed_ticks]
    cmp ax, 182
    jae inst_chainload_hdd

    mov ax, 181
    sub ax, [elapsed_ticks]
    xor dx, dx
    mov bx, 18
    div bx
    inc ax
    cmp ax, 10
    jbe .sec_ok
    mov ax, 10
.sec_ok:
    cmp ax, [last_sec_shown]
    je .check_key
    mov [last_sec_shown], ax

    push ax
    xor dx, dx
    mov bl, ATTR_BLACK
    mov si, msg_wait_1
    call vga_print_at
    pop ax
    call u16_to_str
    call vga_print_at
    mov si, msg_wait_2
    call vga_print_at

.check_key:
    mov ah, 0x01
    int 0x16
    jnz .key_pressed

    hlt
    mov ax, [0x046C]
    cmp ax, [last_tick]
    je .wait_loop
    mov [last_tick], ax
    inc word [elapsed_ticks]
    jmp .wait_loop

.key_pressed:
    xor ah, ah
    int 0x16
    jmp inst_run_diagnostics

; ---------------------------------------------------------
; 하드디스크로 부팅 인계 (Chainload)
; ---------------------------------------------------------
inst_chainload_hdd:
    mov ax, 0x0003
    int 0x10
    mov ah, 0x01
    mov cx, 0x0607
    int 0x10

    xor dx, dx
    mov bl, ATTR_BLACK
    mov si, msg_boot_hdd
    call vga_print_at

    mov si, 3
.hdd_retry:
    mov ax, 0x0201
    mov cx, 0x0001
    xor dh, dh
    mov dl, [inst_target_drv]
    mov bx, 0x7C00
    int 0x13
    jnc .hdd_loaded

    xor ah, ah
    mov dl, [inst_target_drv]
    int 0x13
    dec si
    jnz .hdd_retry

    mov dx, 0x0200
    mov bl, ATTR_BLACK
    mov si, msg_no_hdd
    call vga_print_at
    jmp inst_halt

.hdd_loaded:
    cmp word [0x7DFE], 0xAA55
    je .jump_hdd
    mov dx, 0x0200
    mov bl, ATTR_BLACK
    mov si, msg_no_boot_sig
    call vga_print_at
    jmp inst_halt

.jump_hdd:
    mov dl, [inst_target_drv]
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0x7C00
    jmp 0x0000:0x7C00

; =========================================================
; 0단계: 설치 전 콘솔 최저사양 & 무결성 자가 진단 (POST)
; =========================================================
inst_run_diagnostics:
    mov byte [diag_flags], 0
    call vga_clear_black

    mov dx, 0x0000
    mov bl, ATTR_CON_HDR
    mov si, msg_diag_hdr
    call vga_print_at

    mov dx, 0x0100
    mov bl, ATTR_BLACK
    mov si, msg_diag_sep
    call vga_print_at

    ; --- [1/4] CPU(80386+) 판별 & OS 사용 명령어 실동작 검증 ---
    mov dx, 0x0300
    mov bl, ATTR_BLACK
    mov si, msg_chk_cpu
    call vga_print_at

    call diag_test_cpu_ops
    jc .cpu_bad
    mov bl, ATTR_CON_OK
    mov si, msg_tag_ok
    call vga_print_at
    jmp .chk_ram_cap
.cpu_bad:
    or byte [diag_flags], FAIL_CPU
    mov bl, ATTR_CON_FAIL
    mov si, msg_tag_fail
    call vga_print_at

    ; --- [2/4] 컨벤셔널 RAM 용량 검사 (INT 12h >= 128 KB) ---
.chk_ram_cap:
    mov dx, 0x0400
    mov bl, ATTR_BLACK
    mov si, msg_chk_ram
    call vga_print_at

    int 0x12
    mov [detected_ram_kb], ax
    call u16_to_str
    call vga_print_at
    mov si, msg_kb_sp
    call vga_print_at

    cmp word [detected_ram_kb], 128
    jb .ram_cap_bad
    mov bl, ATTR_CON_OK
    mov si, msg_tag_ok
    call vga_print_at
    jmp .chk_ram_int
.ram_cap_bad:
    or byte [diag_flags], FAIL_RAM_CAP
    mov bl, ATTR_CON_FAIL
    mov si, msg_tag_fail
    call vga_print_at

    ; --- [3/4] 컨벤셔널 RAM 다중 연산 무결성 검사 (설치기 점유 제외 최대 640KB 전체) ---
.chk_ram_int:
    mov dx, 0x0500
    mov bl, ATTR_BLACK
    mov si, msg_chk_mem
    call vga_print_at

    test byte [diag_flags], FAIL_RAM_CAP
    jz .run_mem_test
    mov bl, ATTR_CON_SKIP
    mov si, msg_tag_skip
    call vga_print_at
    jmp .chk_hdd

.run_mem_test:
    ; 영역 A: 0000:0500 ~ 0000:77FF (29,440B)
    xor ax, ax
    mov si, 0x0500
    mov cx, 0x7300
    call ram_test_region
    jc .ram_int_bad

    ; 영역 B: 0000:FC00 ~ 0000:FFFF (1,024B, 64KB 경계 끝까지)
    xor ax, ax
    mov si, RAM_TEST_B_ADDR
    mov cx, 0x0400
    call ram_test_region
    jc .ram_int_bad

    ; 영역 C: 1000:0000 ~ INT 12h 상한(최대 640KB)까지 1KB 단위 전수 검사
    mov ax, [detected_ram_kb]
    cmp ax, 640
    jbe .ram_cap_ok
    mov ax, 640
.ram_cap_ok:
    mov cl, 6
    shl ax, cl
    mov bx, ax

    mov ax, WIPE_SEG
    xor si, si
    mov cx, 0x0400
.ram_c_loop:
    cmp ax, bx
    jae .ram_c_done
    call ram_test_region
    jc .ram_int_bad
    add ax, 0x0040
    jmp .ram_c_loop
.ram_c_done:

    mov bl, ATTR_CON_OK
    mov si, msg_tag_ok
    call vga_print_at
    jmp .chk_hdd
.ram_int_bad:
    or byte [diag_flags], FAIL_RAM_INT
    mov bl, ATTR_CON_FAIL
    mov si, msg_tag_fail
    call vga_print_at

    ; --- [4/4] 하드디스크 LBA 지원 및 최소 용량(>= 59 섹터) 검사 ---
.chk_hdd:
    mov dx, 0x0600
    mov bl, ATTR_BLACK
    mov si, msg_chk_hdd
    call vga_print_at

    mov ah, 0x41
    mov bx, 0x55AA
    mov dl, [inst_target_drv]
    int 0x13
    jc .lba_bad
    cmp bx, 0xAA55
    jne .lba_bad

    mov di, edd_buf
    mov cx, 30
    xor al, al
    cld
    rep stosb
    mov word [edd_buf], 0x001E

    mov ah, 0x48
    mov dl, [inst_target_drv]
    mov si, edd_buf
    int 0x13
    jc .hdd_bad

    mov ax, [edd_buf + 18]
    or ax, [edd_buf + 20]
    or ax, [edd_buf + 22]
    jnz .hdd_ok
    cmp word [edd_buf + 16], 67
    jb .hdd_bad

.hdd_ok:
    mov bl, ATTR_CON_OK
    mov si, msg_tag_ok
    call vga_print_at
    jmp .diag_finish

.lba_bad:
    or byte [diag_flags], FAIL_LBA
    mov bl, ATTR_CON_FAIL
    mov si, msg_tag_fail
    call vga_print_at
    jmp .diag_finish

.hdd_bad:
    or byte [diag_flags], FAIL_HDD
    mov bl, ATTR_CON_FAIL
    mov si, msg_tag_fail
    call vga_print_at

.diag_finish:
    mov dx, 0x0800
    cmp byte [diag_flags], 0
    jne .diag_failed_msg

    mov bl, ATTR_CON_HDR
    mov si, msg_diag_pass
    call vga_print_at
    call diag_brief_pause
    mov byte [cur_page], 0
    jmp inst_show_tour

.diag_failed_msg:
    mov bl, ATTR_CON_FAIL
    mov si, msg_diag_fail
    call vga_print_at
    call diag_brief_pause
    jmp inst_req_failed

diag_brief_pause:
    push ax
    push cx
    mov ax, [0x046C]
    mov [last_tick], ax
    mov cx, 9
.p_loop:
    hlt
    mov ax, [0x046C]
    cmp ax, [last_tick]
    je .p_loop
    mov [last_tick], ax
    loop .p_loop
    pop cx
    pop ax
    ret

diag_test_cpu_ops:
    push bx
    push cx
    push dx
    push si
    push di

    pushf
    pop bx
    mov ax, bx
    and ax, 0x0FFF
    push ax
    popf
    pushf
    pop ax
    push bx
    popf
    and ax, 0xF000
    cmp ax, 0xF000
    je .fail

    mov ax, bx
    or ax, 0x7000
    push ax
    popf
    pushf
    pop ax
    push bx
    popf
    and ax, 0x7000
    jz .fail

    mov dl, 0xFE
    movzx eax, dl
    cmp eax, 0x000000FE
    jne .fail

    mov eax, 0x00012345
    shl eax, 5
    cmp eax, 0x002468A0
    jne .fail
    add eax, 17
    xor edx, edx
    mov ebx, 32
    div ebx
    cmp eax, 0x00012345
    jne .fail
    cmp edx, 17
    jne .fail

    cld
    mov si, diag_str_pat
    mov di, INST_SCRATCH
    mov cx, 8
    rep movsb

    std
    mov si, INST_SCRATCH + 7
    mov di, INST_SCRATCH + 11
    mov cx, 8
    rep movsb
    cld

    mov si, diag_str_pat
    mov di, INST_SCRATCH + 4
    mov cx, 8
    repe cmpsb
    jne .fail

    mov byte [INST_SCRATCH], 0xFF
    inc byte [INST_SCRATCH]
    cmp byte [INST_SCRATCH], 0x00
    jne .fail
    dec byte [INST_SCRATCH]
    cmp byte [INST_SCRATCH], 0xFF
    jne .fail

    mov di, 0x7FFF
    inc di
    and di, 0x7FFF
    test di, di
    jnz .fail
    dec di
    and di, 0x7FFF
    cmp di, 0x7FFF
    jne .fail

    clc
    jmp .done
.fail:
    stc
.done:
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    ret

ram_test_region:
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    push es

    mov es, ax
    mov bx, cx
    cld

    mov di, si
    mov cx, bx
    mov al, 0x55
    rep stosb

    mov di, si
    mov cx, bx
.p1_not:
    not byte [es:di]
    inc di
    loop .p1_not

    mov di, si
    mov cx, bx
    mov al, 0xAA
    repe scasb
    jne .fail

    mov dx, es
    xor dl, dh
    mov di, si
    mov cx, bx
.p2_write:
    mov ax, di
    xor al, ah
    xor al, dl
    mov [es:di], al
    xor byte [es:di], 0x5A
    add byte [es:di], 0x33
    inc di
    loop .p2_write

    mov di, si
    mov cx, bx
.p2_verify:
    mov ax, di
    xor al, ah
    xor al, dl
    xor al, 0x5A
    add al, 0x33
    cmp [es:di], al
    jne .fail
    inc di
    loop .p2_verify

    mov di, si
    mov cx, bx
    xor al, al
    rep stosb

    mov di, si
    mov cx, bx
    xor al, al
    repe scasb
    jne .fail

    clc
    jmp .done
.fail:
    stc
.done:
    pop es
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; ---------------------------------------------------------
; 최저사양 미충족 시 XP Setup 첫 화면 UI로 설치 불가 안내
; ---------------------------------------------------------
inst_req_failed:
    mov si, msg_st_req_fail
    call xp_draw_base
    call xp_draw_dialog_frame

    mov dx, 0x090D
    mov bl, ATTR_XP_YEL
    mov si, msg_req_hdr
    call vga_print_at

    mov dx, 0x0A0D
    mov bl, ATTR_XP_HDR
    mov si, msg_req_sub
    call vga_print_at

    mov dh, 0x0B

    test byte [diag_flags], FAIL_CPU
    jz .f_ram_cap
    mov dl, 0x0D
    mov bl, ATTR_XP_TEXT
    mov si, msg_fail_cpu
    call vga_print_at
    inc dh

.f_ram_cap:
    test byte [diag_flags], FAIL_RAM_CAP
    jz .f_ram_int
    mov dl, 0x0D
    mov bl, ATTR_XP_TEXT
    mov si, msg_fail_ram
    call vga_print_at
    inc dh

.f_ram_int:
    test byte [diag_flags], FAIL_RAM_INT
    jz .f_lba
    mov dl, 0x0D
    mov bl, ATTR_XP_TEXT
    mov si, msg_fail_mem
    call vga_print_at
    inc dh

.f_lba:
    test byte [diag_flags], FAIL_LBA
    jz .f_hdd
    mov dl, 0x0D
    mov bl, ATTR_XP_TEXT
    mov si, msg_fail_lba
    call vga_print_at
    inc dh

.f_hdd:
    test byte [diag_flags], FAIL_HDD
    jz .f_done
    mov dl, 0x0D
    mov bl, ATTR_XP_TEXT
    mov si, msg_fail_hdd
    call vga_print_at

.f_done:
    mov dx, 0x110D
    mov bl, ATTR_XP_HDR
    mov si, msg_req_quit
    call vga_print_at

.req_wait:
    xor ah, ah
    int 0x16
    cmp al, 0x1B
    je inst_chainload_hdd
    cmp al, 0x0D
    je inst_chainload_hdd
    jmp .req_wait

; ---------------------------------------------------------
; 1단계: XP 스타일 6페이지 상세 OS 설명 투어
; ---------------------------------------------------------
inst_show_tour:
.draw_page:
    mov si, msg_st_tour
    cmp byte [cur_page], NUM_PAGES - 1
    jne .st_ok
    mov si, msg_st_tour_last
.st_ok:
    call xp_draw_base

    mov dx, 0x0046
    mov bl, ATTR_XP_HDR
    mov si, msg_page_lbl
    call vga_print_at
    mov al, [cur_page]
    xor ah, ah
    inc ax
    call u16_to_str
    call vga_print_at
    mov si, msg_page_of
    call vga_print_at

    mov bl, [cur_page]
    xor bh, bh
    shl bx, 1
    mov si, [page_table + bx]
    mov dx, 0x0300
    mov bl, ATTR_XP_TEXT
    call vga_print_at

.tour_key:
    xor ah, ah
    int 0x16

    cmp al, 0x1B
    je inst_chainload_hdd
    cmp al, 'S'
    je inst_after_tour
    cmp al, 's'
    je inst_after_tour

    cmp al, ' '
    je .next_page
    cmp al, 0x0D
    je .next_page
    cmp ah, 0x4D
    je .next_page

    cmp al, 0x08
    je .prev_page
    cmp ah, 0x4B
    je .prev_page
    jmp .tour_key

.next_page:
    cmp byte [cur_page], NUM_PAGES - 1
    jae inst_after_tour
    inc byte [cur_page]
    jmp .draw_page

.prev_page:
    cmp byte [cur_page], 0
    je .tour_key
    dec byte [cur_page]
    jmp .draw_page

; ---------------------------------------------------------
; 1.5단계: 디스크 0 기존 BF64 OS & 슈퍼블록 감지 -> 업그레이드/클린설치/제거 선택
; ---------------------------------------------------------
inst_after_tour:
    call inst_detect_existing_bf64
    cmp byte [existing_bf64], 0
    je inst_ask_confirm

inst_existing_menu:
    mov byte [exist_sel], 0
    cmp byte [existing_bf64], 2
    je .redraw
    mov byte [exist_sel], 1     ; OS 파티션 공간 부족 시 기본 포커스를 클린 설치로

.redraw:
    mov si, msg_st_exist
    call xp_draw_base
    call xp_draw_dialog_frame

    mov dh, 9
    mov bl, ATTR_XP_YEL
    mov si, msg_ex_hdr
    call vga_print_center

    ; [1] Upgrade / Repair (파티션 1만 포맷, C: 데이터 보존)
    mov bl, ATTR_XP_TEXT
    cmp byte [exist_sel], 0
    jne .o0_a
    mov bl, ATTR_XP_BAR
.o0_a:
    mov cx, 0x0B0D
    mov dx, 0x0B42
    mov al, ' '
    call vga_fill_rect
    mov dx, 0x0B0D
    mov si, msg_ex_opt1
    cmp byte [existing_bf64], 2
    je .o0_p
    mov si, msg_ex_opt1_no
.o0_p:
    call vga_print_at

    ; [2] Clean Install (디스크 전체 초기화 후 새로 설치)
    mov bl, ATTR_XP_TEXT
    cmp byte [exist_sel], 1
    jne .o1_a
    mov bl, ATTR_XP_BAR
.o1_a:
    mov cx, 0x0C0D
    mov dx, 0x0C42
    mov al, ' '
    call vga_fill_rect
    mov dx, 0x0C0D
    mov si, msg_ex_opt2
    call vga_print_at

    ; [3] Uninstall BF64 OS (2단계 더블 체크 후 제거)
    mov bl, ATTR_XP_TEXT
    cmp byte [exist_sel], 2
    jne .o2_a
    mov bl, ATTR_XP_BAR
.o2_a:
    mov cx, 0x0D0D
    mov dx, 0x0D42
    mov al, ' '
    call vga_fill_rect
    mov dx, 0x0D0D
    mov si, msg_ex_opt3
    call vga_print_at

    ; 선택된 항목 설명
    mov dx, 0x0F0D
    mov bl, ATTR_XP_YEL
    cmp byte [exist_sel], 0
    jne .chk_d1
    mov si, msg_ex_desc1
    cmp byte [existing_bf64], 2
    je .p_desc
    mov si, msg_ex_desc1_no
    jmp .p_desc
.chk_d1:
    cmp byte [exist_sel], 1
    jne .d2
    mov si, msg_ex_desc2
    jmp .p_desc
.d2:
    mov si, msg_ex_desc3
.p_desc:
    call vga_print_at

    mov dx, 0x110D
    mov bl, ATTR_XP_TEXT
    mov si, msg_ex_hint
    call vga_print_at

.ex_key:
    xor ah, ah
    int 0x16
    cmp ah, 0x48                ; UP
    je .up
    cmp ah, 0x50                ; DOWN
    je .dn
    cmp al, '1'
    je .pick1
    cmp al, '2'
    je .pick2
    cmp al, '3'
    je .pick3
    cmp al, 0x0D                ; ENTER
    je .go_sel
    cmp al, 0x1B                ; ESC -> 기존 OS로 부팅
    je inst_chainload_hdd
    cmp al, 0x08                ; BACKSPACE -> 투어 복귀
    jne .ex_key
    mov byte [cur_page], NUM_PAGES - 1
    jmp inst_show_tour

.up:
    cmp byte [exist_sel], 0
    je .ex_key
    dec byte [exist_sel]
    jmp .redraw
.dn:
    cmp byte [exist_sel], 2
    jae .ex_key
    inc byte [exist_sel]
    jmp .redraw
.pick1:
    mov byte [exist_sel], 0
    jmp .go_sel
.pick2:
    mov byte [exist_sel], 1
    jmp .go_sel
.pick3:
    mov byte [exist_sel], 2
.go_sel:
    cmp byte [exist_sel], 0
    je .try_upg
    cmp byte [exist_sel], 1
    je inst_ask_confirm
    jmp inst_uninstall_chk1
.try_upg:
    cmp byte [existing_bf64], 2
    jne .redraw                 ; OS 파티션 용량 부족 시 업그레이드 차단
    jmp inst_upgrade_confirm

; --- 업그레이드 확인 및 실행 (파티션 1만 포맷·검증·교체, 파티션 2 데이터 보존) ---
inst_upgrade_confirm:
    mov si, msg_st_upg_conf
    call xp_draw_base
    call xp_draw_dialog_frame

    mov dh, 10
    mov bl, ATTR_XP_YEL
    mov si, msg_upg_hdr
    call vga_print_center

    mov dx, 0x0C0D
    mov bl, ATTR_XP_TEXT
    mov si, msg_upg_p1
    call vga_print_at

    mov dx, 0x0D0D
    mov bl, ATTR_XP_TEXT
    mov si, msg_upg_p2
    call vga_print_at

    mov dx, 0x100D
    mov bl, ATTR_XP_HDR
    mov si, msg_upg_ask
    call vga_print_at

.upg_key:
    xor ah, ah
    int 0x16
    cmp al, 'Y'
    je inst_do_upgrade
    cmp al, 'y'
    je inst_do_upgrade
    cmp al, 'N'
    je inst_existing_menu
    cmp al, 'n'
    je inst_existing_menu
    cmp al, 0x1B
    je inst_existing_menu
    cmp al, 0x08
    je inst_existing_menu
    jmp .upg_key

inst_do_upgrade:
    mov si, msg_st_upgrading
    call xp_draw_base
    mov dx, 0x0303
    mov bl, ATTR_XP_TEXT
    mov si, msg_upg_wait
    call vga_print_at
    mov cx, 0x0B09
    mov dx, 0x1346
    mov bl, ATTR_XP_TEXT
    mov bh, ATTR_XP_TEXT
    call vga_draw_box
    call xp_draw_bar_frame

    ; 1. 파티션 1(OS 영역)만 0x00 포맷 및 읽기 검증 (파티션 2 절대 침범 안 함)
    mov dx, 0x0C0C
    mov bl, ATTR_XP_HDR
    mov si, msg_upg_fmt
    call vga_print_at

    mov cx, 15
    mov bl, ATTR_XP_YEL
    call xp_draw_bar_blocks

    mov eax, [exist_p1_lba]
    mov edx, [exist_p1_cnt]
    mov ecx, [exist_p2_lba]
    sub ecx, eax
    cmp edx, ecx
    jbe .upg_cnt_ok
    mov edx, ecx
.upg_cnt_ok:
    call inst_zero_and_verify

    mov cx, 35
    mov bl, ATTR_XP_YEL
    call xp_draw_bar_blocks

    ; 2. 새 MBR 부트코드(기존 파티션 테이블 보존) + 새 BF64 v1.3 커널(32섹터) 기록
    mov cx, 0x0C0C
    mov dx, 0x0C44
    mov al, ' '
    mov bl, ATTR_XP_TEXT
    call vga_fill_rect
    mov dx, 0x0C0C
    mov bl, ATTR_XP_HDR
    mov si, msg_copying
    call vga_print_at

    mov si, HDD_MBR_SRC
    mov di, INST_SCRATCH
    mov cx, 512
    cld
    rep movsb

    mov si, saved_ptbl
    mov di, INST_SCRATCH + 0x1BE
    mov cx, 64
    rep movsb
    mov word [INST_SCRATCH + 0x1FE], 0xAA55

    xor eax, eax
    mov bx, INST_SCRATCH
    xor dx, dx
    mov cx, 1
    mov byte [inst_disk_op], 0x43
    call inst_lba_rw
    jc inst_disk_fail

    mov eax, [exist_p1_lba]
    mov bx, HDD_OS_SRC
    xor dx, dx
    mov cx, 32
    mov byte [inst_disk_op], 0x43
    call inst_lba_rw
    jc inst_disk_fail

    mov cx, 50
    mov bl, ATTR_XP_YEL
    call xp_draw_bar_blocks

    mov si, msg_upg_done
    jmp inst_show_complete

; --- OS 제거 2단계 더블 체크 (1차 확인 -> 2차 최종 확인 -> 제거) ---
inst_uninstall_chk1:
    mov si, msg_st_uni_conf
    call xp_draw_base
    call xp_draw_dialog_frame

    mov dh, 10
    mov bl, ATTR_XP_YEL
    mov si, msg_uni_hdr1
    call vga_print_center

    mov dx, 0x0C0D
    mov bl, ATTR_XP_TEXT
    mov si, msg_uni_info1
    call vga_print_at

    mov dx, 0x0D0D
    mov bl, ATTR_XP_TEXT
    mov si, msg_uni_info2
    call vga_print_at

    mov dx, 0x0E0D
    mov bl, ATTR_XP_TEXT
    mov si, msg_uni_info3
    call vga_print_at

    mov dx, 0x100D
    mov bl, ATTR_XP_HDR
    mov si, msg_uni_ask1
    call vga_print_at

.u1_key:
    xor ah, ah
    int 0x16
    cmp al, 'Y'
    je inst_uninstall_chk2
    cmp al, 'y'
    je inst_uninstall_chk2
    cmp al, 'N'
    je inst_existing_menu
    cmp al, 'n'
    je inst_existing_menu
    cmp al, 0x1B
    je inst_existing_menu
    cmp al, 0x08
    je inst_existing_menu
    jmp .u1_key

inst_uninstall_chk2:
    mov si, msg_st_uni_conf
    call xp_draw_base
    call xp_draw_dialog_frame

    mov dh, 10
    mov bl, ATTR_XP_RED
    mov si, msg_uni_hdr2
    call vga_print_center

    mov dx, 0x0C0D
    mov bl, ATTR_XP_YEL
    mov si, msg_uni_warn1
    call vga_print_at

    mov dx, 0x0D0D
    mov bl, ATTR_XP_TEXT
    mov si, msg_uni_warn2
    call vga_print_at

    mov dx, 0x100D
    mov bl, ATTR_XP_HDR
    mov si, msg_uni_ask2
    call vga_print_at

.u2_key:
    xor ah, ah
    int 0x16
    cmp al, 'Y'
    je inst_do_uninstall
    cmp al, 'y'
    je inst_do_uninstall
    cmp al, 'N'
    je inst_existing_menu
    cmp al, 'n'
    je inst_existing_menu
    cmp al, 0x1B
    je inst_existing_menu
    cmp al, 0x08
    je inst_existing_menu
    jmp .u2_key

inst_do_uninstall:
    mov si, msg_st_uninst
    call xp_draw_base
    mov dx, 0x0303
    mov bl, ATTR_XP_TEXT
    mov si, msg_uni_wait
    call vga_print_at
    mov cx, 0x0B09
    mov dx, 0x1346
    mov bl, ATTR_XP_TEXT
    mov bh, ATTR_XP_TEXT
    call vga_draw_box
    call xp_draw_bar_frame

    mov dx, 0x0C0C
    mov bl, ATTR_XP_HDR
    mov si, msg_uni_run
    call vga_print_at

    ; 1. LBA 0 (MBR/파티션 테이블) + 파티션 1 (OS 커널) 0x00 제거 & 검증
    xor eax, eax
    mov edx, 1
    cmp dword [exist_p1_cnt], 0
    je .uni_p1_go
    mov edx, [exist_p1_cnt]
    cmp edx, 63
    jbe .uni_add_mbr
    mov edx, 63
.uni_add_mbr:
    inc edx                     ; MBR(LBA 0) + OS 커널 섹터
.uni_p1_go:
    call inst_zero_and_verify

    mov cx, 30
    mov bl, ATTR_XP_YEL
    call xp_draw_bar_blocks

    ; 2. 파티션 2 슈퍼블록(BF64FS 헤더) 0x00 제거 & 검증
    mov eax, [exist_p2_lba]
    test eax, eax
    jz .uni_done
    mov edx, 1
    call inst_zero_and_verify

.uni_done:
    mov cx, 50
    mov bl, ATTR_XP_YEL
    call xp_draw_bar_blocks

    mov si, msg_st_uni_done
    call xp_draw_status_bar
    mov cx, 0x0C0A
    mov dx, 0x1245
    mov al, ' '
    mov bl, ATTR_XP_TEXT
    call vga_fill_rect

    mov dh, 13
    mov bl, ATTR_XP_HDR
    mov si, msg_uni_done1
    call vga_print_center

    mov dx, 0x0F0C
    mov bl, ATTR_XP_TEXT
    mov si, msg_uni_done2
    call vga_print_at

    mov dx, 0x110C
    mov bl, ATTR_XP_YEL
    mov si, msg_uni_done3
    call vga_print_at

.uni_wait:
    xor ah, ah
    int 0x16
    cmp al, 0x0D                ; ENTER -> 재부팅
    je inst_do_reboot
    cmp al, 0x1B                ; ESC -> 안전 정지
    je inst_halt
    jmp .uni_wait

; 기존 BF64 OS & 슈퍼블록 감지 (HDD 0x80)
; 출력: existing_bf64 = 0(없음), 1(감지됨/OS파티션<32섹터), 2(감지됨/업그레이드 가능)
inst_detect_existing_bf64:
    push eax
    push ebx
    push cx
    push dx
    push si
    push di

    mov byte [existing_bf64], 0
    mov dword [exist_p1_lba], 0
    mov dword [exist_p1_cnt], 0
    mov dword [exist_p2_lba], 0
    mov dword [exist_p2_cnt], 0

    ; LBA 0 읽기
    xor eax, eax
    mov bx, INST_SCRATCH
    xor dx, dx
    mov cx, 1
    mov byte [inst_disk_op], 0x42
    call inst_lba_rw
    jc .done

    ; 혹시 LBA 0 자체에 BF64FS 슈퍼블록이 있는 경우 감지
    cmp dword [INST_SCRATCH + 0], "BF64"
    jne .chk_mbr
    cmp byte [INST_SCRATCH + 4], 2
    jne .chk_mbr
    mov byte [existing_bf64], 1
    jmp .done

.chk_mbr:
    cmp word [INST_SCRATCH + 0x1FE], 0xAA55
    jne .done
    cmp byte [INST_SCRATCH + 0x1BE + 4], 0xDA
    jne .done
    cmp byte [INST_SCRATCH + 0x1CE + 4], 0xBF
    jne .done

    mov eax, [INST_SCRATCH + 0x1BE + 8]
    mov [exist_p1_lba], eax
    mov eax, [INST_SCRATCH + 0x1BE + 12]
    mov [exist_p1_cnt], eax
    mov eax, [INST_SCRATCH + 0x1CE + 8]
    mov [exist_p2_lba], eax
    mov eax, [INST_SCRATCH + 0x1CE + 12]
    mov [exist_p2_cnt], eax
    test eax, eax
    jz .done

    ; 기존 64바이트 파티션 테이블 백업 (업그레이드 시 보존용)
    mov si, INST_SCRATCH + 0x1BE
    mov di, saved_ptbl
    mov cx, 64
    cld
    rep movsb

    ; 파티션 2 시작 LBA에서 BF64 슈퍼블록 확인
    mov eax, [exist_p2_lba]
    mov bx, INST_SCRATCH
    xor dx, dx
    mov cx, 1
    mov byte [inst_disk_op], 0x42
    call inst_lba_rw
    jc .done
    cmp dword [INST_SCRATCH + 0], "BF64"
    jne .done
    cmp byte [INST_SCRATCH + 4], 2
    jne .done

    ; BF64 OS 감지됨 -> 파티션 1 공간(>= 32섹터 & 파티션 2 비침범) 검사
    mov byte [existing_bf64], 1
    mov eax, [exist_p1_lba]
    test eax, eax
    jz .done
    cmp dword [exist_p1_cnt], 32
    jb .done
    add eax, 32
    cmp eax, [exist_p2_lba]
    ja .done
    mov byte [existing_bf64], 2
.done:
    pop di
    pop si
    pop dx
    pop cx
    pop ebx
    pop eax
    ret

; 지정 LBA 구간 0x00 쓰기 & 읽기 검증 공용 헬퍼 (EAX=시작 LBA, EDX=섹터 수)
inst_zero_and_verify:
    push eax
    push ebx
    push ecx
    push edx
    push di
    push es

    mov [tmp_start_lba], eax
    mov [tmp_rem_cnt], edx

    mov ax, WIPE_SEG
    mov es, ax
    xor di, di
    xor ax, ax
    mov cx, 0x4000
    cld
    rep stosw

    ; 쓰기 루프 (최대 64섹터 단위)
    mov ebx, [tmp_start_lba]
    mov edx, [tmp_rem_cnt]
.w_loop:
    test edx, edx
    jz .v_start
    mov ecx, edx
    cmp ecx, 64
    jbe .w_go
    mov ecx, 64
.w_go:
    push ebx
    push edx
    push ecx
    mov eax, ebx
    xor bx, bx
    mov dx, WIPE_SEG
    mov byte [inst_disk_op], 0x43
    call inst_lba_rw
    pop ecx
    pop edx
    pop ebx
    jc .io_err
    add ebx, ecx
    sub edx, ecx
    jmp .w_loop

    ; 읽기 0x00 검증 루프
.v_start:
    mov ebx, [tmp_start_lba]
    mov edx, [tmp_rem_cnt]
.v_loop:
    test edx, edx
    jz .ok
    mov ecx, edx
    cmp ecx, 64
    jbe .v_go
    mov ecx, 64
.v_go:
    push ebx
    push edx
    push ecx
    mov eax, ebx
    xor bx, bx
    mov dx, WIPE_SEG
    mov byte [inst_disk_op], 0x42
    call inst_lba_rw
    pop ecx
    pop edx
    pop ebx
    jc .io_err
    push cx
    xor di, di
    shl cx, 8
    xor ax, ax
    cld
    repe scasw
    pop cx
    jne .vfy_err
    add ebx, ecx
    sub edx, ecx
    jmp .v_loop

.ok:
    pop es
    pop di
    pop edx
    pop ecx
    pop ebx
    pop eax
    ret
.io_err:
    pop es
    pop di
    pop edx
    pop ecx
    pop ebx
    pop eax
    jmp inst_disk_fail
.vfy_err:
    pop es
    pop di
    pop edx
    pop ecx
    pop ebx
    pop eax
    jmp inst_verify_fail

; ---------------------------------------------------------
; 2단계: 클린 설치 유무 확인 창 -> Y 시 같은 창에서 포맷 방식 선택
; ---------------------------------------------------------
inst_ask_confirm:
    mov si, msg_st_confirm
    call xp_draw_base
    call xp_draw_dialog_frame

    mov dx, 0x0A0D
    mov bl, ATTR_XP_YEL
    mov si, msg_box_warn
    call vga_print_at

    mov dx, 0x0C0D
    mov bl, ATTR_XP_TEXT
    mov si, msg_box_p1
    call vga_print_at

    mov dx, 0x0D0D
    mov bl, ATTR_XP_TEXT
    mov si, msg_box_p2
    call vga_print_at

    mov dx, 0x0E0D
    mov bl, ATTR_XP_TEXT
    mov si, msg_box_cap
    call vga_print_at

    mov dx, 0x100D
    mov bl, ATTR_XP_HDR
    mov si, msg_box_ask
    call vga_print_at

.ask_key:
    xor ah, ah
    int 0x16
    cmp al, 'Y'
    je inst_select_format
    cmp al, 'y'
    je inst_select_format
    cmp al, 'N'
    je inst_chainload_hdd
    cmp al, 'n'
    je inst_chainload_hdd
    cmp al, 0x1B
    je inst_chainload_hdd
    cmp al, 0x08
    jne .ask_key
    cmp byte [existing_bf64], 0
    jne inst_existing_menu
    mov byte [cur_page], NUM_PAGES - 1
    jmp inst_show_tour

inst_select_format:
    mov byte [format_mode], 0
    mov si, msg_st_format
    call xp_draw_status_bar

.redraw_fmt:
    mov cx, 0x090B
    mov dx, 0x1144
    mov al, ' '
    mov bl, ATTR_XP_TEXT
    call vga_fill_rect

    mov dx, 0x0A0D
    mov bl, ATTR_XP_HDR
    mov si, msg_fmt_title
    call vga_print_at

    mov bl, ATTR_XP_TEXT
    cmp byte [format_mode], 0
    jne .opt1_attr
    mov bl, ATTR_XP_BAR
.opt1_attr:
    mov cx, 0x0C0D
    mov dx, 0x0C42
    mov al, ' '
    call vga_fill_rect
    mov dx, 0x0C0D
    mov si, msg_fmt_opt1
    call vga_print_at

    mov bl, ATTR_XP_TEXT
    cmp byte [format_mode], 1
    jne .opt2_attr
    mov bl, ATTR_XP_BAR
.opt2_attr:
    mov cx, 0x0D0D
    mov dx, 0x0D42
    mov al, ' '
    call vga_fill_rect
    mov dx, 0x0D0D
    mov si, msg_fmt_opt2
    call vga_print_at

    mov dx, 0x0F0D
    mov bl, ATTR_XP_YEL
    mov si, msg_fmt_desc1
    cmp byte [format_mode], 0
    je .print_desc
    mov si, msg_fmt_desc2
.print_desc:
    call vga_print_at

    mov dx, 0x110D
    mov bl, ATTR_XP_TEXT
    mov si, msg_fmt_hint
    call vga_print_at

.fmt_key:
    xor ah, ah
    int 0x16
    cmp ah, 0x48
    je .sel_quick
    cmp ah, 0x50
    je .sel_normal
    cmp al, 0x0D
    je inst_start_install
    cmp al, '1'
    je .go_quick
    cmp al, '2'
    je .go_normal
    cmp al, 0x08
    je inst_ask_confirm
    cmp al, 0x1B
    je inst_chainload_hdd
    jmp .fmt_key

.sel_quick:
    mov byte [format_mode], 0
    jmp .redraw_fmt

.sel_normal:
    mov byte [format_mode], 1
    jmp .redraw_fmt

.go_quick:
    mov byte [format_mode], 0
    jmp inst_start_install

.go_normal:
    mov byte [format_mode], 1

; ---------------------------------------------------------
; 3단계: XP 스타일 포맷 -> 0x00 읽기 검증 -> 설치 진행
; ---------------------------------------------------------
inst_start_install:
    mov si, msg_st_installing
    call xp_draw_base

    mov dx, 0x0303
    mov bl, ATTR_XP_TEXT
    mov si, msg_inst_wait
    call vga_print_at

    mov cx, 0x0B09
    mov dx, 0x1346
    mov bl, ATTR_XP_TEXT
    mov bh, ATTR_XP_TEXT
    call vga_draw_box

    mov ah, 0x41
    mov bx, 0x55AA
    mov dl, [inst_target_drv]
    int 0x13
    jc inst_no_lba
    cmp bx, 0xAA55
    jne inst_no_lba

    mov di, edd_buf
    mov cx, 30
    xor al, al
    rep stosb
    mov word [edd_buf], 0x001E

    mov ah, 0x48
    mov dl, [inst_target_drv]
    mov si, edd_buf
    int 0x13
    jc inst_disk_fail

    mov eax, [edd_buf + 16]
    mov edx, [edd_buf + 20]
    test edx, edx
    jz .chk_min
    mov eax, MAX_TARGET_SECTORS
    mov byte [was_capped], 1
    jmp .cap_done

.chk_min:
    cmp eax, 67
    jb inst_too_small
    mov byte [was_capped], 0
    cmp eax, MAX_TARGET_SECTORS
    jbe .cap_done
    mov eax, MAX_TARGET_SECTORS
    mov byte [was_capped], 1

.cap_done:
    mov [total_sectors], eax

    mov eax, [total_sectors]
    dec eax
    mov bx, INST_SCRATCH
    xor dx, dx
    mov cx, 1
    mov byte [inst_disk_op], 0x42
    call inst_lba_rw
    jc inst_disk_fail

    mov eax, [total_sectors]
    sub eax, 33
    mov [p2_sectors], eax

    dec eax
    mov ebx, eax
    shr eax, 5
    cmp eax, 65535
    jbe .slot_cap_ok
    mov eax, 65535
.slot_cap_ok:
.adjust_slots:
    test eax, eax
    jz inst_too_small
    mov ecx, eax
    add ecx, 31
    shr ecx, 5
    mov edx, eax
    shl edx, 5
    add edx, ecx
    cmp edx, ebx
    jbe .slots_ready
    dec eax
    jmp .adjust_slots

.slots_ready:
    mov [calc_max_slots], eax
    mov [calc_dir_secs], cx
    movzx edx, cx
    add edx, 34
    mov [calc_data_lba], edx

    mov dx, 0x0505
    mov bl, ATTR_XP_TEXT
    mov si, msg_info_sec
    call vga_print_at
    mov eax, [total_sectors]
    call u32_to_str
    call vga_print_at
    cmp byte [was_capped], 1
    jne .no_cap_lbl
    mov si, msg_capped
    mov bl, ATTR_XP_YEL
    call vga_print_at
.no_cap_lbl:

    mov dx, 0x0605
    mov bl, ATTR_XP_TEXT
    mov si, msg_info_p1
    call vga_print_at

    mov dx, 0x0705
    mov bl, ATTR_XP_TEXT
    mov si, msg_info_p2
    call vga_print_at
    mov eax, [p2_sectors]
    call u32_to_str
    call vga_print_at
    mov si, msg_info_slots
    call vga_print_at
    mov eax, [calc_max_slots]
    call u32_to_str
    call vga_print_at
    mov si, msg_info_tail
    call vga_print_at

    call xp_draw_bar_frame

    ; 빠른 포맷: 헤더/디렉토리(0..calc_data_lba-1)만, 전체 포맷: 전체(0..total_sectors-1)
    cmp byte [format_mode], 0
    jne .set_full_wipe
    mov eax, [calc_data_lba]
    mov [wipe_target], eax
    mov si, msg_fmt_run_q
    jmp .begin_wipe

.set_full_wipe:
    mov eax, [total_sectors]
    mov [wipe_target], eax
    mov si, msg_fmt_run_n

.begin_wipe:
    mov dx, 0x0C0C
    mov bl, ATTR_XP_HDR
    call vga_print_at

    push es
    mov ax, WIPE_SEG
    mov es, ax
    xor di, di
    xor ax, ax
    mov cx, 0x4000
    rep stosw
    pop es

    mov dword [wipe_lba], 0
    mov word [last_pct], 0xFFFF
    call xp_update_wipe_bar

.wipe_loop:
    mov eax, [wipe_target]
    sub eax, [wipe_lba]
    jz .wipe_done
    cmp eax, 64
    jbe .wipe_chunk
    mov eax, 64
.wipe_chunk:
    mov cx, ax
    mov eax, [wipe_lba]
    xor bx, bx
    mov dx, WIPE_SEG
    mov byte [inst_disk_op], 0x43
    call inst_lba_rw
    jc inst_disk_fail

    movzx ecx, cx
    add [wipe_lba], ecx

    test dword [wipe_lba], 0x1FF
    jz .upd_bar
    call inst_calc_pct
    cmp ax, [last_pct]
    je .wipe_loop
.upd_bar:
    call xp_update_wipe_bar
    jmp .wipe_loop

.wipe_done:
    call xp_update_wipe_bar

    ; 4. 0x00 읽기 검증 (빠른 포맷: 헤더/디렉토리만, 전체 포맷: 디스크 전체)
    mov cx, 0x0C0C
    mov dx, 0x0C44
    mov al, ' '
    mov bl, ATTR_XP_TEXT
    call vga_fill_rect

    mov dx, 0x0C0C
    mov bl, ATTR_XP_HDR
    mov si, msg_fmt_vfy_q
    cmp byte [format_mode], 0
    je .vfy_hdr_ok
    mov si, msg_fmt_vfy_n
.vfy_hdr_ok:
    call vga_print_at

    mov dword [wipe_lba], 0
    mov word [last_pct], 0xFFFF
    call xp_update_wipe_bar

.vfy_loop:
    mov eax, [wipe_target]
    sub eax, [wipe_lba]
    jz .vfy_done
    cmp eax, 64
    jbe .vfy_chunk
    mov eax, 64
.vfy_chunk:
    mov cx, ax
    push cx
    mov eax, [wipe_lba]
    xor bx, bx
    mov dx, WIPE_SEG
    mov byte [inst_disk_op], 0x42
    call inst_lba_rw
    pop cx
    jc inst_disk_fail

    push cx
    push es
    mov ax, WIPE_SEG
    mov es, ax
    xor di, di
    shl cx, 8                   ; 섹터 수 * 256워드 (= 섹터 수 * 512바이트)
    xor ax, ax
    cld
    repe scasw
    pop es
    pop cx
    jne inst_verify_fail

    movzx ecx, cx
    add [wipe_lba], ecx

    test dword [wipe_lba], 0x1FF
    jz .upd_vfy_bar
    call inst_calc_pct
    cmp ax, [last_pct]
    je .vfy_loop
.upd_vfy_bar:
    call xp_update_wipe_bar
    jmp .vfy_loop

.vfy_done:
    call xp_update_wipe_bar

    ; 5. MBR + 파티션 1 OS(32섹터) + 파티션 2 슈퍼블록 기록
    mov cx, 0x0C0C
    mov dx, 0x0C44
    mov al, ' '
    mov bl, ATTR_XP_TEXT
    call vga_fill_rect

    mov dx, 0x0C0C
    mov bl, ATTR_XP_HDR
    mov si, msg_copying
    call vga_print_at

    mov si, HDD_MBR_SRC
    mov di, INST_SCRATCH
    mov cx, 512
    rep movsb

    ; 파티션 1 (LBA 1..32, 16KB, 활성)
    mov di, INST_SCRATCH + 0x1BE
    mov byte  [di + 0], 0x80
    mov byte  [di + 1], 0x00
    mov byte  [di + 2], 0x02
    mov byte  [di + 3], 0x00
    mov byte  [di + 4], 0xDA
    mov byte  [di + 5], 0x00
    mov byte  [di + 6], 0x21
    mov byte  [di + 7], 0x00
    mov dword [di + 8], 1
    mov dword [di + 12], 32

    ; 파티션 2 (LBA 33..끝, BF64FS 슬롯 영역)
    mov di, INST_SCRATCH + 0x1CE
    mov byte  [di + 0], 0x00
    mov byte  [di + 1], 0xFE
    mov byte  [di + 2], 0xFF
    mov byte  [di + 3], 0xFF
    mov byte  [di + 4], 0xBF
    mov byte  [di + 5], 0xFE
    mov byte  [di + 6], 0xFF
    mov byte  [di + 7], 0xFF
    mov dword [di + 8], 33
    mov eax, [p2_sectors]
    mov dword [di + 12], eax

    mov word [INST_SCRATCH + 0x1FE], 0xAA55

    ; LBA 0: MBR 기록
    xor eax, eax
    mov bx, INST_SCRATCH
    xor dx, dx
    mov cx, 1
    mov byte [inst_disk_op], 0x43
    call inst_lba_rw
    jc inst_disk_fail

    ; LBA 1..32: BF64 v1.3 커널 기록 (32섹터)
    mov eax, 1
    mov bx, HDD_OS_SRC
    xor dx, dx
    mov cx, 32
    mov byte [inst_disk_op], 0x43
    call inst_lba_rw
    jc inst_disk_fail

    ; LBA 33: 파티션 2 슈퍼블록 기록
    mov di, INST_SCRATCH
    mov cx, 512
    xor al, al
    rep stosb

    mov dword [INST_SCRATCH + 0], "BF64"
    mov byte  [INST_SCRATCH + 4], 2
    mov dword [INST_SCRATCH + 8], 33
    mov eax, [calc_data_lba]
    mov dword [INST_SCRATCH + 12], eax
    mov eax, [calc_max_slots]
    mov dword [INST_SCRATCH + 16], eax
    mov ax, [calc_dir_secs]
    mov word  [INST_SCRATCH + 20], ax
    mov word  [INST_SCRATCH + 22], 32

    mov eax, 33
    mov bx, INST_SCRATCH
    xor dx, dx
    mov cx, 1
    mov byte [inst_disk_op], 0x43
    call inst_lba_rw
    jc inst_disk_fail

    mov si, msg_done_hdr

    ; 6. XP 스타일 완료 & 빨간색 재부팅 카운트다운 바 (SI = 완료 헤더 문자열)
inst_show_complete:
    push si
    mov si, msg_st_reboot
    call xp_draw_status_bar

    mov cx, 0x0C0A
    mov dx, 0x1245
    mov al, ' '
    mov bl, ATTR_XP_TEXT
    call vga_fill_rect

    mov dx, 0x0C0C
    mov bl, ATTR_XP_HDR
    pop si
    call vga_print_at

    mov dx, 0x0E0C
    mov bl, ATTR_XP_TEXT
    mov si, msg_done_sub
    call vga_print_at

    call xp_draw_bar_frame

    mov dx, 0x120C
    mov bl, ATTR_XP_YEL
    mov si, msg_done_tip
    call vga_print_at

    mov ax, [0x046C]
    mov [last_tick], ax
    mov word [reboot_step], 0

.reboot_loop:
    mov cx, [reboot_step]
    mov bl, ATTR_XP_RED
    call xp_draw_bar_blocks

    cmp word [reboot_step], 50
    jae inst_do_reboot

    mov ah, 0x01
    int 0x16
    jz .wait_tick
    xor ah, ah
    int 0x16
    cmp al, 0x0D
    je inst_do_reboot

.wait_tick:
    hlt
    mov ax, [0x046C]
    cmp ax, [last_tick]
    je .reboot_loop
    mov [last_tick], ax
    inc word [reboot_step]
    jmp .reboot_loop

inst_do_reboot:
    mov word [0x0472], 0x1234
    cli
.kbc_wait:
    in al, 0x64
    test al, 0x02
    jnz .kbc_wait
    mov al, 0xFE
    out 0x64, al
    jmp 0xFFFF:0x0000

; ---------------------------------------------------------
; 오류 표시 및 정지
; ---------------------------------------------------------
inst_no_lba:
    mov si, msg_err_lba
    jmp inst_show_err
inst_too_small:
    mov si, msg_err_small
    jmp inst_show_err
inst_verify_fail:
    mov si, msg_err_vfy
    jmp inst_show_err
inst_disk_fail:
    mov si, msg_err_io
inst_show_err:
    push si
    mov cx, 0x0C0A
    mov dx, 0x1245
    mov al, ' '
    mov bl, ATTR_XP_TEXT
    call vga_fill_rect
    mov dx, 0x0E0C
    mov bl, ATTR_XP_YEL
    pop si
    call vga_print_at
    mov si, msg_st_error
    call xp_draw_status_bar
inst_halt:
    cli
    hlt
    jmp inst_halt

; ---------------------------------------------------------
; XP Setup UI 및 Direct VGA(0xB800) 헬퍼
; ---------------------------------------------------------
xp_draw_base:
    push si
    mov cx, 0x0000
    mov dx, 0x174F
    mov al, ' '
    mov bl, ATTR_XP_TEXT
    call vga_fill_rect

    mov dx, 0x0001
    mov bl, ATTR_XP_HDR
    mov si, msg_setup_hdr
    call vga_print_at

    mov cx, 0x0100
    mov dx, 0x0110
    mov al, 0xCD
    mov bl, ATTR_XP_TEXT
    call vga_fill_rect

    pop si
    call xp_draw_status_bar
    ret

xp_draw_status_bar:
    push si
    mov cx, 0x1800
    mov dx, 0x184F
    mov al, ' '
    mov bl, ATTR_XP_BAR
    call vga_fill_rect
    mov dx, 0x1800
    mov bl, ATTR_XP_BAR
    pop si
    call vga_print_at
    ret

xp_draw_dialog_frame:
    mov cx, 0x060A
    mov dx, 0x1245
    mov bl, ATTR_XP_HDR
    mov bh, ATTR_XP_TEXT
    call vga_draw_box

    mov dh, 7
    mov bl, ATTR_XP_HDR
    mov si, msg_box_title
    call vga_print_center

    mov cx, 0x080B
    mov dx, 0x0844
    mov al, 0xC4
    mov bl, ATTR_XP_TEXT
    call vga_fill_rect
    ret

; 80열 중앙 정렬 문자열 출력 (DH=행, BL=속성, SI=NUL 종료 문자열)
vga_print_center:
    push ax
    push cx
    push dx
    push si
    xor cx, cx
.len:
    cmp byte [si], 0
    je .calc
    inc si
    inc cx
    jmp .len
.calc:
    pop si
    mov ax, 80
    sub ax, cx
    jns .ok
    xor ax, ax
.ok:
    shr ax, 1
    mov dl, al
    call vga_print_at
    pop dx
    pop cx
    pop ax
    ret

xp_draw_bar_frame:
    push ax
    push cx
    push dx
    push di
    push es
    mov ax, 0xB800
    mov es, ax
    mov ah, ATTR_XP_TEXT

    mov dx, 0x0F0E
    call vga_calc_di
    mov al, 0xDA
    stosw
    mov cx, 50
    mov al, 0xC4
    rep stosw
    mov al, 0xBF
    stosw

    mov dx, 0x100E
    call vga_calc_di
    mov al, 0xB3
    mov [es:di], ax
    mov dx, 0x1041
    call vga_calc_di
    mov al, 0xB3
    mov [es:di], ax

    mov dx, 0x110E
    call vga_calc_di
    mov al, 0xC0
    stosw
    mov cx, 50
    mov al, 0xC4
    rep stosw
    mov al, 0xD9
    stosw

    pop es
    pop di
    pop dx
    pop cx
    pop ax
    ret

xp_draw_bar_blocks:
    push ax
    push bx
    push cx
    push dx
    push di
    push es

    mov ax, 0xB800
    mov es, ax
    mov dx, 0x100F
    call vga_calc_di

    mov dx, 50
    sub dx, cx

    test cx, cx
    jz .empty_only
    mov ah, bl
    mov al, 0xDB
    rep stosw

.empty_only:
    mov cx, dx
    test cx, cx
    jz .done
    mov ah, ATTR_XP_TEXT
    mov al, 0xB0
    rep stosw
.done:
    pop es
    pop di
    pop dx
    pop cx
    pop bx
    pop ax
    ret

xp_update_wipe_bar:
    push eax
    push bx
    push cx
    push dx
    push si

    call inst_calc_pct
    mov [last_pct], ax
    push ax

    mov cx, 0x0E24
    mov dx, 0x0E2B
    mov al, ' '
    mov bl, ATTR_XP_HDR
    call vga_fill_rect

    pop ax
    push ax
    call u16_to_str
    mov dx, 0x0E26
    mov bl, ATTR_XP_HDR
    call vga_print_at
    mov si, msg_pct_sym
    call vga_print_at

    pop ax
    shr ax, 1
    mov cx, ax
    mov bl, ATTR_XP_YEL
    call xp_draw_bar_blocks

    mov dx, 0x120E
    mov bl, ATTR_XP_TEXT
    mov si, msg_sec_prog
    call vga_print_at
    mov eax, [wipe_lba]
    call u32_to_str
    call vga_print_at
    mov si, msg_slash
    call vga_print_at
    mov eax, [wipe_target]
    call u32_to_str
    call vga_print_at
    mov si, msg_pad_sp
    call vga_print_at

    pop si
    pop dx
    pop cx
    pop bx
    pop eax
    ret

inst_calc_pct:
    push ebx
    push edx
    mov eax, [wipe_lba]
    cmp eax, [wipe_target]
    jb .calc
    mov ax, 100
    jmp .ret
.calc:
    mov ebx, 100
    mul ebx
    div dword [wipe_target]
.ret:
    pop edx
    pop ebx
    ret

vga_clear_black:
    mov cx, 0x0000
    mov dx, 0x184F
    mov al, ' '
    mov bl, ATTR_BLACK
    jmp vga_fill_rect

vga_calc_di:
    push ax
    push dx
    mov al, dh
    mov ah, 80
    mul ah
    xor dh, dh
    add ax, dx
    shl ax, 1
    mov di, ax
    pop dx
    pop ax
    ret

vga_fill_rect:
    push ax
    push bx
    push cx
    push dx
    push di
    push es

    mov ah, bl
    push ax
    mov ax, 0xB800
    mov es, ax
    pop ax

    sub dl, cl
    inc dl
    mov bl, dh
    sub bl, ch
    inc bl
    mov dh, ch
.row_loop:
    push dx
    mov dl, cl
    call vga_calc_di
    pop dx
    push cx
    mov cl, dl
    xor ch, ch
    rep stosw
    pop cx
    inc dh
    dec bl
    jnz .row_loop

    pop es
    pop di
    pop dx
    pop cx
    pop bx
    pop ax
    ret

vga_draw_box:
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    push es

    push bx
    mov bl, bh
    mov al, ' '
    call vga_fill_rect
    pop bx

    mov ax, 0xB800
    mov es, ax

    mov al, dl
    sub al, cl
    dec al
    xor ah, ah
    mov si, ax
    mov ah, bl

    push dx
    mov dh, ch
    mov dl, cl
    call vga_calc_di
    pop dx
    mov al, 0xC9
    stosw
    push cx
    mov cx, si
    mov al, 0xCD
    rep stosw
    pop cx
    mov al, 0xBB
    stosw

    push dx
    mov dl, cl
    call vga_calc_di
    pop dx
    mov al, 0xC8
    stosw
    push cx
    mov cx, si
    mov al, 0xCD
    rep stosw
    pop cx
    mov al, 0xBC
    stosw

    mov bh, ch
    inc bh
.v_loop:
    cmp bh, dh
    jae .v_done
    push dx
    mov dh, bh
    mov dl, cl
    call vga_calc_di
    mov al, 0xBA
    mov [es:di], ax
    pop dx
    push dx
    mov dh, bh
    call vga_calc_di
    mov al, 0xBA
    mov [es:di], ax
    pop dx
    inc bh
    jmp .v_loop
.v_done:
    pop es
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

vga_print_at:
    push ax
    push cx
    push di
    push es
    mov ax, 0xB800
    mov es, ax
    mov cl, dl
    call vga_calc_di
    mov ah, bl
.loop:
    lodsb
    test al, al
    jz .done
    cmp al, 0x0A
    je .nl
    stosw
    inc dl
    jmp .loop
.nl:
    inc dh
    mov dl, cl
    call vga_calc_di
    jmp .loop
.done:
    pop es
    pop di
    pop cx
    pop ax
    ret

u16_to_str:
    push ax
    push bx
    push cx
    push dx
    push di
    mov bx, 10
    xor cx, cx
.div_loop:
    xor dx, dx
    div bx
    push dx
    inc cx
    test ax, ax
    jnz .div_loop
    mov di, num_buf
.pop_loop:
    pop ax
    add al, '0'
    stosb
    loop .pop_loop
    mov byte [di], 0
    mov si, num_buf
    pop di
    pop dx
    pop cx
    pop bx
    pop ax
    ret

u32_to_str:
    push eax
    push ebx
    push ecx
    push edx
    push di
    mov ebx, 10
    xor cx, cx
.div_loop:
    xor edx, edx
    div ebx
    push dx
    inc cx
    test eax, eax
    jnz .div_loop
    mov di, num_buf
.pop_loop:
    pop ax
    add al, '0'
    stosb
    loop .pop_loop
    mov byte [di], 0
    mov si, num_buf
    pop di
    pop edx
    pop ecx
    pop ebx
    pop eax
    ret

inst_lba_rw:
    push eax
    push ebx
    push ecx
    push edx
    push si
    mov word  [inst_dap], 0x0010
    mov word  [inst_dap_cnt], cx
    mov word  [inst_dap_off], bx
    mov word  [inst_dap_seg], dx
    mov dword [inst_dap_lba], eax
    mov dword [inst_dap_lba + 4], 0

    mov ah, [inst_disk_op]
    xor al, al
    mov dl, [inst_target_drv]
    mov si, inst_dap
    int 0x13
    pop si
    pop edx
    pop ecx
    pop ebx
    pop eax
    ret

; --- 설치기 데이터 및 버퍼 ---
align 4, db 0
inst_dap:
    db 0x10, 0x00
inst_dap_cnt:   dw 0
inst_dap_off:   dw 0
inst_dap_seg:   dw 0
inst_dap_lba:   dd 0, 0

edd_buf         times 30 db 0
num_buf         times 12 db 0
diag_str_pat    db "BF64TEST"
inst_boot_drv   db 0
inst_target_drv db 0x80
inst_disk_op    db 0
diag_flags      db 0
detected_ram_kb dw 0
cur_page        db 0
format_mode     db 0
was_capped      db 0
last_tick       dw 0
elapsed_ticks   dw 0
last_sec_shown  dw 0
last_pct        dw 0
reboot_step     dw 0
total_sectors   dd 0
wipe_target     dd 0
wipe_lba        dd 0
p2_sectors      dd 0
calc_max_slots  dd 0
calc_dir_secs   dw 0
calc_data_lba   dd 0
existing_bf64   db 0
exist_sel       db 0
exist_p1_lba    dd 0
exist_p1_cnt    dd 0
exist_p2_lba    dd 0
exist_p2_cnt    dd 0
tmp_start_lba   dd 0
tmp_rem_cnt     dd 0
saved_ptbl      times 64 db 0

page_table:
    dw msg_page_1
    dw msg_page_2
    dw msg_page_3
    dw msg_page_4
    dw msg_page_5
    dw msg_page_6

msg_wait_1        db "Press any key to boot from BF64 Setup... (", 0
msg_wait_2        db "s)   ", 0
msg_boot_hdd      db "Starting from hard disk...", 0
msg_no_hdd        db "Disk Error: Unable to read the hard disk.", 0
msg_no_boot_sig   db "No bootable operating system found on hard disk.", 0

msg_diag_hdr      db "BF64 v1.3 Setup - Hardware Compatibility Check", 0
msg_diag_sep      db "--------------------------------------------------", 0
msg_chk_cpu       db "[1/4] Processor (80386 or higher) ........... ", 0
msg_chk_ram       db "[2/4] System Memory (min. 128 KB) ........... ", 0
msg_chk_mem       db "[3/4] Memory Integrity Verification ......... ", 0
msg_chk_hdd       db "[4/4] Fixed Disk LBA & Capacity ............. ", 0
msg_kb_sp         db " KB ", 0
msg_tag_ok        db "[OK]", 0
msg_tag_fail      db "[FAIL]", 0
msg_tag_skip      db "[SKIP]", 0
msg_diag_pass     db "Hardware check complete. Loading BF64 Setup...", 0
msg_diag_fail     db "System requirements not met. Loading report...", 0

msg_st_req_fail   db "  ESC/ENTER=Exit Setup (Boot Hard Disk)", 0
msg_req_hdr       db "This computer does not meet the minimum requirements.", 0
msg_req_sub       db "BF64 v1.3 Setup cannot continue on this system.", 0
msg_fail_cpu      db "- Processor does not support required 80386 instructions.", 0
msg_fail_ram      db "- Insufficient conventional memory (128 KB minimum).", 0
msg_fail_mem      db "- System memory verification test failed.", 0
msg_fail_lba      db "- BIOS Enhanced Disk Drive (LBA) service unavailable.", 0
msg_fail_hdd      db "- Fixed disk not detected or capacity is too small.", 0
msg_req_quit      db "Press ESC or ENTER to exit Setup and boot from hard disk.", 0

msg_setup_hdr     db "BF64 v1.3 Setup", 0
msg_page_lbl      db "Page ", 0
msg_page_of       db "/6", 0

msg_st_tour       db "  SPACE=Next   BACKSPACE=Previous   S=Skip Tour   ESC=Exit Setup", 0
msg_st_tour_last  db "  SPACE=Continue to Install   BACKSPACE=Previous   ESC=Exit Setup", 0
msg_st_confirm    db "  Y=Install   N/ESC=Exit Setup   BACKSPACE=Back", 0
msg_st_format     db "  UP/DOWN=Select   ENTER=Continue   1/2=Pick   ESC=Cancel", 0
msg_st_installing db "  Please wait while Setup installs BF64 v1.3...", 0
msg_st_reboot     db "  ENTER=Restart Computer Now", 0
msg_st_error      db "  Setup cannot continue. Restart your computer to exit.", 0

msg_page_1:
    db "  Welcome to BF64 Setup.", 0x0A, 0x0A
    db "  This Setup program prepares your hard disk and installs BF64 v1.3", 0x0A
    db "  on your computer. BF64 is a standalone 16-bit operating system", 0x0A
    db "  featuring a classic interactive shell and built-in Brainfuck VM.", 0x0A, 0x0A
    db "  During installation, Setup will:", 0x0A
    db "    * Detect your hard disk via BIOS LBA Disk Services", 0x0A
    db "    * Format the target volume with BF64FS (Quick or Full)", 0x0A
    db "    * Create Partition 1 (16 KB, Active) for the BF64 v1.3 kernel", 0x0A
    db "    * Create Partition 2 for 16 KB program storage slots", 0x0A
    db "    * Write a Master Boot Record (MBR) for direct hard disk boot", 0x0A, 0x0A
    db "  To view the system overview and command guide, press SPACE.", 0x0A
    db "  To skip directly to installation, press S.", 0x0A
    db "  To exit Setup without changing your hard disk, press ESC.", 0

msg_page_2:
    db "  System Overview - BF64 v1.3 Architecture", 0x0A, 0x0A
    db "  BF64 is engineered as a compact, self-contained bare-metal OS", 0x0A
    db "  built for predictable performance and direct hardware control.", 0x0A, 0x0A
    db "    * Compact 16 KB Kernel", 0x0A
    db "      Startup diagnostics, shell, line editor, BF64FS file system,", 0x0A
    db "      disk utilities, and dual Brainfuck engines fit in 32 sectors.", 0x0A, 0x0A
    db "    * Dual Execution Engines", 0x0A
    db "      Choose between the Classic 1:1 Interpreter (default) and the", 0x0A
    db "      32 KB Optimizing IR Engine in System Settings.", 0x0A, 0x0A
    db "    * Configurable Console Environment", 0x0A
    db "      Switch between Classic BF64 (40x25 Blue) and Extended Console", 0x0A
    db "      (80x25 White-on-Black) with persistent settings on C:.", 0x0A, 0x0A
    db "    * Automatic Startup Health Check", 0x0A
    db "      Verifies memory integrity and optimizes C: on every boot.", 0

msg_page_3:
    db "  Memory Map & Storage Architecture", 0x0A, 0x0A
    db "  [16-Bit Real Mode Memory Layout]", 0x0A
    db "    0000:0500 - 05FF   Command Input Buffer     (256 B, max 240 chars)", 0x0A
    db "    0000:0600 - 07FF   Volume & Directory Cache (512 B, 1 sector)", 0x0A
    db "    0000:0800 - 77FF   Execution & Copy Buffer  (28 KB)", 0x0A
    db "    0000:7800 - 7BFF   System Stack             (1 KB)", 0x0A
    db "    0000:7C00 - BDFF   MBR & BF64 v1.3 Kernel   (32 sectors)", 0x0A
    db "    0000:BE00 - FDFF   Program Workspace RAM    (16 KB)", 0x0A
    db "    1000:0000 - 7FFF   Brainfuck Data Tape      (32 KB circular)", 0x0A
    db "    1800:0000 - 7FFF   Optimizing VM IR Buffer  (32 KB workspace)", 0x0A, 0x0A
    db "  [Storage Volumes]", 0x0A
    db "    C: (System Disk) : MBR + Partition 1 (Kernel) + Partition 2 (Data)", 0x0A
    db "    A:, B:, D:..Z:   : Floppy Drives (BF64FS 16 KB Program Slots)", 0x0A
    db "    Max Capacity     : Up to 65,535 slots (~1.0 GB) on C:, 89 on 1.44M", 0

msg_page_4:
    db "  Command Reference (1/2) : Editor, Execution & System", 0x0A, 0x0A
    db "    <Line#> <Code>   Add or replace a program line (0..65535).", 0x0A
    db "                     Enter '<Line#>' alone to delete that line.", 0x0A, 0x0A
    db "    RUN              Execute the program currently in memory.", 0x0A
    db "    RUN X:           Boot from a bf64exec disk in drive X:.", 0x0A, 0x0A
    db "    LIST [N[-M]]     Display all lines, line N, or range N..M.", 0x0A
    db "    NEW / CLS        Clear program memory / Clear console screen.", 0x0A, 0x0A
    db "    SETTINGS         Open System Settings (Interpreter & Shell).", 0x0A
    db "    HELP             Open the built-in Command Reference.", 0x0A
    db "    REBOOT/SHUTDOWN  Restart or power off the computer.", 0x0A, 0x0A
    db "    Direct Mode      Enter Brainfuck operators to run immediately.", 0

msg_page_5:
    db "  Command Reference (2/2) : Storage & Disk Utilities", 0x0A, 0x0A
    db "    DIR              Display all detected drives and free capacity.", 0x0A
    db "    DIR C: / DIR A:  List stored programs and free slots on a drive.", 0x0A
    db '    SAVE "C:NAME"    Save program in memory to a 16 KB disk slot.', 0x0A
    db '    LOAD "C:NAME"    Load a program ("A:*"=first, "A:$"=directory).', 0x0A
    db '    DEL "C:NAME"     Delete a program slot (alias: SCRATCH).', 0x0A
    db "    FORMAT [X:]      Open Disk Format utility (protects C:/bf64exec).", 0x0A
    db "    DEFRAG [X:]      Open Disk Defragmenter utility.", 0x0A, 0x0A
    db "    Optimizer Engine : Enable in SETTINGS for 32 KB IR acceleration.", 0x0A
    db "    Media Protection : System volume C: and bf64exec media are guarded.", 0x0A
    db "    Startup Check    : Runs memory verification and C: check at boot.", 0

msg_page_6:
    db "  Brainfuck Reference & Installation Notice", 0x0A, 0x0A
    db "  [Brainfuck Instruction Set]", 0x0A
    db "    >  /  <   Move data pointer right / left (32 KB circular tape)", 0x0A
    db "    +  /  -   Increment / decrement current cell (8-bit, 0..255)", 0x0A
    db "    .  /  ,   Output ASCII character / Read key (Enter=LF, ESC=BREAK)", 0x0A
    db "    [  /  ]   Loop while current cell is non-zero", 0x0A, 0x0A
    db "  [Before You Install]", 0x0A
    db "    ! ALL EXISTING DATA AND PARTITIONS on the target hard disk will", 0x0A
    db "      be permanently erased when installation begins.", 0x0A
    db "    ! Drives exceeding 2,100,000 sectors (~1 GB) are automatically", 0x0A
    db "      capped at 2,100,000 sectors (65,535 program slots max).", 0x0A
    db "    ! Requires Legacy BIOS / CSM with LBA Disk Extensions.", 0x0A, 0x0A
    db "  Press SPACE to continue to Installation Confirmation.", 0

msg_box_title    db "BF64 v1.3 Setup", 0
msg_box_warn     db "WARNING: All existing data on the hard disk will be lost!", 0
msg_box_p1       db "- Partition 1 : 16 KB (Active, BF64 v1.3 Kernel)", 0
msg_box_p2       db "- Partition 2 : Remaining Space (BF64FS Storage)", 0
msg_box_cap      db "- Volume Limit: approx. 1.0 GB", 0
msg_box_ask      db "Install BF64 v1.3 onto this hard disk? [Y/N]", 0

msg_fmt_title    db "Select a format method for the target volume:", 0
msg_fmt_opt1     db "  [1] Format the partition using BF64FS (Quick)  ", 0
msg_fmt_opt2     db "  [2] Format the partition using BF64FS (Full)   ", 0
msg_fmt_desc1    db "Quick: Initializes file system metadata and verifies headers.", 0
msg_fmt_desc2    db "Full : Erases and verifies every sector on the hard disk.", 0
msg_fmt_hint     db "Use UP/DOWN and press ENTER (or press 1/2) to begin.", 0

msg_inst_wait    db "Please wait while Setup prepares your disk and installs BF64.", 0
msg_info_sec     db "Target Disk Sectors : ", 0
msg_capped       db "", 0
msg_info_p1      db "Partition 1 (System): LBA 1..32 (16 KB, Active)", 0
msg_info_p2      db "Partition 2 (Data)  : ", 0
msg_info_slots   db " sectors (", 0
msg_info_tail    db " slots x 16 KB)", 0

msg_fmt_run_q    db "Setup is formatting the volume (Quick)...", 0
msg_fmt_run_n    db "Setup is formatting the volume (Full)...", 0
msg_fmt_vfy_q    db "Verifying file system metadata...", 0
msg_fmt_vfy_n    db "Verifying disk surface...", 0
msg_copying      db "Setup is copying BF64 v1.3 system files...", 0
msg_pct_sym      db "%", 0
msg_sec_prog     db "Sectors processed: ", 0
msg_slash        db " / ", 0
msg_pad_sp       db "      ", 0

msg_done_hdr     db "BF64 v1.3 installation is complete.", 0
msg_done_sub     db "Your computer will restart automatically in 3 seconds...", 0
msg_done_tip     db "Remove installation media or press ENTER to restart now.", 0

msg_err_lba      db "ERROR: BIOS LBA Disk Extensions are not supported.", 0
msg_err_small    db "ERROR: Hard disk is too small (minimum 67 sectors).", 0
msg_err_vfy      db "ERROR: Disk surface verification failed.", 0
msg_err_io       db "ERROR: Unable to write to the target hard disk.", 0

msg_st_exist     db "  UP/DOWN=Select   ENTER/1-3=Choose   BACKSPACE=Tour   ESC=Exit", 0
msg_st_upg_conf  db "  Y=Upgrade   N/ESC/BACKSPACE=Back", 0
msg_st_upgrading db "  Please wait while Setup upgrades BF64 v1.3...", 0
msg_st_uni_conf  db "  Y=Confirm   N/ESC/BACKSPACE=Cancel", 0
msg_st_uninst    db "  Please wait while Setup removes BF64 OS...", 0
msg_st_uni_done  db "  ENTER=Restart Computer   ESC=Halt System", 0

msg_ex_hdr       db "Existing BF64 OS detected on Hard Disk 0.", 0
msg_ex_opt1      db "  [1] Upgrade / Repair BF64 v1.3 (Keep Data)      ", 0
msg_ex_opt1_no   db "  [1] Upgrade Unavailable (OS Partition < 16 KB)  ", 0
msg_ex_opt2      db "  [2] Clean Install (Erase Entire Hard Disk)      ", 0
msg_ex_opt3      db "  [3] Uninstall BF64 OS (Remove from Hard Disk)   ", 0
msg_ex_desc1     db "Formats Partition 1 only; keeps C: programs/settings.", 0
msg_ex_desc1_no  db "Existing OS partition is too small. Use Clean Install.", 0
msg_ex_desc2     db "Repartitions and formats the entire hard disk.", 0
msg_ex_desc3     db "Removes BF64 bootloader, kernel, and file system.", 0
msg_ex_hint      db "Use UP/DOWN + ENTER (or press 1-3) to select.", 0

msg_upg_hdr      db "Upgrade / Repair BF64 v1.3 (Partition 1 Only)", 0
msg_upg_p1       db "- Partition 1 : Format & install v1.3 kernel (16 KB)", 0
msg_upg_p2       db "- Partition 2 : Preserved (programs & settings kept)", 0
msg_upg_ask      db "Proceed with BF64 v1.3 upgrade? [Y/N]", 0
msg_upg_wait     db "Please wait while Setup upgrades BF64 v1.3...", 0
msg_upg_fmt      db "Formatting & verifying Partition 1 (OS)...", 0
msg_upg_done     db "BF64 v1.3 upgrade complete. User data preserved.", 0

msg_uni_hdr1     db "WARNING: Uninstall BF64 OS (Check 1 of 2)", 0
msg_uni_info1    db "- Removes BF64 MBR bootloader and OS kernel.", 0
msg_uni_info2    db "- Removes BF64FS superblock (C: data inaccessible).", 0
msg_uni_info3    db "- Hard Disk 0 will no longer boot into BF64.", 0
msg_uni_ask1     db "Remove BF64 OS from Hard Disk 0? [Y/N]", 0
msg_uni_hdr2     db "FINAL CHECK (2 of 2): Permanent OS Removal", 0
msg_uni_warn1    db "All BF64 system files and data will be lost!", 0
msg_uni_warn2    db "This action cannot be undone once started.", 0
msg_uni_ask2     db "Confirm permanent uninstall of BF64? [Y/N]", 0
msg_uni_wait     db "Please wait while Setup removes BF64 OS...", 0
msg_uni_run      db "Erasing MBR, OS kernel & BF64FS superblock...", 0
msg_uni_done1    db "BF64 OS has been uninstalled from Hard Disk 0.", 0
msg_uni_done2    db "MBR, OS kernel, and BF64FS header were removed.", 0
msg_uni_done3    db "Remove setup media: ENTER=Restart, ESC=Halt.", 0

times 15360 - ($ - $$) db 0


; =========================================================================
; SECTION 3 : HDD용 MBR 부트로더 템플릿 (512 Bytes, 0x7C00)
; =========================================================================
section .hdd_mbr vstart=0x7C00 follows=.inst_s2 align=4

mbr_start:
    cli
    cld
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0x7C00
    sti

    mov [mbr_drive], dl
    mov eax, [0x7C00 + 0x1BE + 8]
    mov [mbr_dap_lba], eax
    mov dword [mbr_dap_lba + 4], 0

    mov si, 3
.retry:
    mov word [mbr_dap], 0x0010
    mov word [mbr_dap_cnt], 32
    mov word [mbr_dap_off], 0x7E00
    mov word [mbr_dap_seg], 0
    mov ah, 0x42
    mov dl, [mbr_drive]
    push si
    mov si, mbr_dap
    int 0x13
    pop si
    jnc mbr_boot_os

    xor ah, ah
    mov dl, [mbr_drive]
    int 0x13
    dec si
    jnz .retry

    mov si, mbr_msg_err
.err:
    lodsb
    test al, al
    jz .halt
    mov ah, 0x0E
    int 0x10
    jmp .err
.halt:
    cli
    hlt
    jmp .halt

mbr_boot_os:
    mov dl, [mbr_drive]
    jmp 0x0000:0x7E00

align 4, db 0
mbr_dap:
    db 0x10, 0x00
mbr_dap_cnt: dw 32
mbr_dap_off: dw 0x7E00
mbr_dap_seg: dw 0
mbr_dap_lba: dd 1, 0

mbr_drive    db 0x80
mbr_msg_err  db "Error loading operating system", 0

times 446 - ($ - $$) db 0
times 64 db 0
dw 0xAA55


; =========================================================================
; SECTION 4 : HDD용 BF64 v1.3 본체 (16,384 Bytes = 32 Sectors, 0x7E00)
; =========================================================================
section .hdd_os vstart=0x7E00 follows=.hdd_mbr align=4

INPUT_BUF    equ 0x0500
INPUT_MAX    equ 240
DIR_BUF      equ 0x0600
EXEC_BUF     equ 0x0800
EXEC_MAX     equ 0x77FE
PROG_START   equ 0xBE00
PROG_LIMIT   equ 0xFD00
TAPE_SEG     equ 0x1000
OPT_SEG      equ 0x1800         ; +32KB 최적화 VM 바이트코드 & 컴파일러 작업 영역
OPT_IR_BASE  equ 0x0000         ; In-Place 28KB IR 버퍼 (최대 7,167 ops + OP_END)
OPT_IR_MAX   equ 0x6FFC
OPT_STK_BASE equ 0x7000         ; 괄호 점프 해결 스택 (2KB = 1,024 중첩)
OPT_STK_MAX  equ 0x77FE
OPT_MAP_BASE equ 0x7800         ; 단순 루프 델타 맵 (2KB = 512 엔트리 x 4B)
OPT_MAP_MAX  equ 512

OP_END       equ 0              ; 점프 테이블(opt_jt) 짝수 바이트 오프셋 직접 사용
OP_ADD       equ 2
OP_MOVE      equ 4
OP_CLEAR     equ 6
OP_MUL       equ 8
OP_SCAN      equ 10
OP_OUT       equ 12
OP_IN        equ 14
OP_JZ        equ 16
OP_JNZ       equ 18

SM_DRV_TABLE equ 0x5000         ; EXEC_BUF 상위 미사용 영역 (8엔트리 x 64B = 512B)
SM_DRV_MAX   equ 8
SM_LINE_BUF  equ 0x5200         ; BF64TUI 동적 중앙 정렬 출력용 128B 버퍼

; 부팅 전 콘솔 POST 컬러 속성 (80x25 검은 배경)
CON_TEXT   equ 0x07
CON_HDR    equ 0x0F
CON_OK     equ 0x0A
CON_FAIL   equ 0x0C
CON_SKIP   equ 0x0E

; 공용 유틸리티 TUI 컬러 속성 (설치 화면과 동일한 XP 스타일)
SM_TEXT    equ 0x17
SM_HDR     equ 0x1F
SM_YEL     equ 0x1E
SM_GRN     equ 0x1A
SM_RED     equ 0x1C
SM_BAR     equ 0x70

stage2:
    cli
    cld
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0x7C00
    sti

    mov [hdd_drive], dl
    mov eax, [0x7C00 + 0x1CE + 8]
    mov [part2_lba], eax

    ; 1. 부팅 전 시스템 확인은 80x25 검은 콘솔 화면으로 출력
    mov ax, 0x0003
    int 0x10
    mov ah, 0x01
    mov cx, 0x2607
    int 0x10
    mov cx, 0x0000
    mov dx, 0x184F
    mov al, ' '
    mov bl, CON_TEXT
    call sm_fill_rect

    mov dx, 0x0000
    mov bl, CON_HDR
    mov si, msg_con_hdr
    call sm_print_at

    mov dx, 0x0100
    mov bl, CON_TEXT
    mov si, msg_con_sep
    call sm_print_at

    ; 2. 전체 640KB 컨벤셔널 RAM 포함 부팅 전 POST (콘솔 출력)
    call boot_post
    jc .post_halt

    ; 3. 부팅 POST 직후 메인 디스크(C:) 자동 조각 모음 (콘솔 출력)
    mov dx, 0x0600
    mov bl, CON_TEXT
    mov si, msg_con_def
    call sm_print_at

    mov al, [hdd_drive]
    mov [cur_drive], al
    mov eax, [part2_lba]
    mov [cur_base_lba], eax
    mov byte [sm_ui_active], 0
    call defrag_core
    jc .boot_def_err

    mov bl, CON_OK
    mov si, msg_p_ok
    call sm_print_at
    mov bl, CON_TEXT
    mov si, msg_def_lpar
    call sm_print_at
    movzx eax, word [def_moved]
    call sm_u32_to_str
    call sm_print_at
    mov si, msg_def_mv
    call sm_print_at
    jmp .boot_done

.boot_def_err:
    mov bl, CON_SKIP
    mov si, msg_p_skip
    call sm_print_at

.boot_done:
    call load_os_cfg_from_c
    mov dx, 0x0800
    mov bl, CON_HDR
    mov si, msg_con_start
    call sm_print_at
    call os_brief_pause

    ; 4. 확인 완료 후 BF64 초기 화면(클래식 40x25 블루 / 확장 80x25 콘솔) 진입
    mov byte [PROG_START], 0
    mov byte [PROG_LIMIT], 0
    call init_screen
    call print_shell_banner
    jmp prompt

.post_halt:
    mov dx, 0x0700
    mov bl, CON_FAIL
    mov si, msg_post_halt
    call sm_print_at
.halt_loop:
    cli
    hlt
    jmp .halt_loop

prompt:
    mov si, msg_ready
    call print_str

cmd_loop:
    mov di, INPUT_BUF
    xor cx, cx

.read_key:
    xor ah, ah
    int 0x16

    cmp al, 0x0D
    je .line_done
    cmp al, 0x08
    je .do_bs
    cmp al, 0x20
    jb .read_key
    cmp al, 0x7E
    ja .read_key
    cmp cx, INPUT_MAX
    jae .read_key

    stosb
    inc cx
    call put_char
    jmp .read_key

.do_bs:
    test cx, cx
    jz .read_key
    dec di
    dec cx
    call screen_bs
    jmp .read_key

.line_done:
    mov byte [di], 0
    mov al, 0x0A
    call put_char

    mov si, INPUT_BUF
.skip_lead:
    cmp byte [si], ' '
    jne .check_input
    inc si
    jmp .skip_lead

.check_input:
    mov al, [si]
    test al, al
    jz cmd_loop
    cmp al, '0'
    jb .check_cmds
    cmp al, '9'
    jbe handle_line_num

.check_cmds:
    mov di, str_new
    call match_cmd_exact
    jc cmd_new
    mov di, str_cls
    call match_cmd_exact
    jc cmd_cls
    mov di, str_help
    call match_cmd_exact
    jc cmd_launch_help
    mov di, str_settings
    call match_cmd_exact
    jc cmd_launch_settings
    mov di, str_config
    call match_cmd_exact
    jc cmd_launch_settings
    mov di, str_reboot
    call match_cmd_exact
    jc cmd_reboot
    mov di, str_shutdown
    call match_cmd_exact
    jc cmd_shutdown

    mov di, str_run
    call match_cmd_arg
    jc cmd_run
    mov di, str_list
    call match_cmd_arg
    jc cmd_list
    mov di, str_dir
    call match_cmd_arg
    jc cmd_dir
    mov di, str_save
    call match_cmd_arg
    jc cmd_save
    mov di, str_load
    call match_cmd_arg
    jc cmd_load
    mov di, str_del
    call match_cmd_arg
    jc cmd_del
    mov di, str_scratch
    call match_cmd_arg
    jc cmd_del
    ; FORMAT / DEFRAG -> BF64TUI 공용 기반을 공유하되 독립 창으로 진입
    mov di, str_format
    call match_cmd_arg
    jc cmd_launch_format
    mov di, str_defrag
    call match_cmd_arg
    jc cmd_launch_defrag

    call exec_bf
    jmp prompt

; =========================================================
; 시스템 부팅 전 콘솔 POST (CPU/명령어 + 컨벤셔널 RAM 최대 640KB 전수 검사)
; 출력: CF=0 통과, CF=1 실패
; =========================================================
boot_post:
    push eax
    push bx
    push cx
    push dx
    push si
    mov byte [post_fail], 0

    ; [1/4] CPU(80386+) & OS 사용 명령어 검증
    mov dx, 0x0300
    mov bl, CON_TEXT
    mov si, msg_con_cpu
    call sm_print_at
    call os_test_cpu_ops
    jc .cpu_bad
    mov bl, CON_OK
    mov si, msg_p_ok
    call sm_print_at
    jmp .chk_ram
.cpu_bad:
    mov byte [post_fail], 1
    mov bl, CON_FAIL
    mov si, msg_p_fail
    call sm_print_at

    ; [2/4] 컨벤셔널 RAM 용량 검사 (>= 128 KB)
.chk_ram:
    mov dx, 0x0400
    mov bl, CON_TEXT
    mov si, msg_con_ram
    call sm_print_at
    int 0x12
    mov [os_ram_kb], ax
    movzx eax, ax
    call sm_u32_to_str
    call sm_print_at
    mov si, msg_con_kb
    call sm_print_at
    cmp word [os_ram_kb], 128
    jb .ram_bad
    mov bl, CON_OK
    mov si, msg_p_ok
    call sm_print_at
    jmp .chk_mem
.ram_bad:
    mov byte [post_fail], 1
    mov bl, CON_FAIL
    mov si, msg_p_fail
    call sm_print_at

    ; [3/4] 컨벤셔널 RAM 최대 640KB 무결성 검사
.chk_mem:
    mov dx, 0x0500
    mov bl, CON_TEXT
    mov si, msg_con_mem
    call sm_print_at
    cmp byte [post_fail], 0
    jne .mem_skip

    push dx
    ; 영역 A: 0000:0500 ~ 0000:77FF (29,440B)
    xor ax, ax
    mov si, 0x0500
    mov cx, 0x7300
    call os_ram_test_region
    jc .mem_bad_pop

    ; 영역 B: 0000:BE00 ~ 0000:FFFF (16,896B, 64KB 경계 끝까지)
    xor ax, ax
    mov si, PROG_START
    mov cx, 0x4200
    call os_ram_test_region
    jc .mem_bad_pop

    ; 영역 C: 1000:0000 ~ INT 12h 상한(최대 640KB)까지 1KB 단위 전수 검사
    mov ax, [os_ram_kb]
    cmp ax, 640
    jbe .cap_ok
    mov ax, 640
.cap_ok:
    mov cl, 6
    shl ax, cl                  ; 끝 세그먼트 = KB * 64 (예: 640KB -> 0xA000)
    mov bx, ax

    mov ax, TAPE_SEG            ; 0x1000 (64KB 지점)
    xor si, si
    mov cx, 0x0400              ; 1KB(1,024B) 단위 검사
.ram_c_loop:
    cmp ax, bx
    jae .ram_c_done
    call os_ram_test_region
    jc .mem_bad_pop
    add ax, 0x0040              ; +1KB (+64 패러그래프)
    jmp .ram_c_loop
.ram_c_done:
    pop dx
    mov bl, CON_OK
    mov si, msg_p_ok
    call sm_print_at
    jmp .done

.mem_bad_pop:
    pop dx
    mov byte [post_fail], 1
    mov bl, CON_FAIL
    mov si, msg_p_fail
    call sm_print_at
    jmp .done

.mem_skip:
    mov bl, CON_SKIP
    mov si, msg_p_skip
    call sm_print_at

.done:
    cmp byte [post_fail], 0
    je .ok
    stc
    jmp .ret
.ok:
    clc
.ret:
    pop si
    pop dx
    pop cx
    pop bx
    pop eax
    ret

os_brief_pause:
    push ax
    push bx
    push cx
    mov bx, [0x046C]
    mov cx, 12
.p_loop:
    hlt
    mov ax, [0x046C]
    cmp ax, bx
    je .p_loop
    mov bx, ax
    loop .p_loop
    pop cx
    pop bx
    pop ax
    ret

os_test_cpu_ops:
    push eax
    push ebx
    push cx
    push edx
    push si
    push di

    pushf
    pop bx
    mov ax, bx
    and ax, 0x0FFF
    push ax
    popf
    pushf
    pop ax
    push bx
    popf
    and ax, 0xF000
    cmp ax, 0xF000
    je .fail

    mov ax, bx
    or ax, 0x7000
    push ax
    popf
    pushf
    pop ax
    push bx
    popf
    and ax, 0x7000
    jz .fail

    mov dl, 0xFE
    movzx eax, dl
    cmp eax, 0x000000FE
    jne .fail

    mov eax, 0x00012345
    shl eax, 5
    cmp eax, 0x002468A0
    jne .fail
    add eax, 17
    xor edx, edx
    mov ebx, 32
    div ebx
    cmp eax, 0x00012345
    jne .fail
    cmp edx, 17
    jne .fail

    cld
    mov si, os_diag_pat
    mov di, DIR_BUF
    mov cx, 8
    rep movsb

    std
    mov si, DIR_BUF + 7
    mov di, DIR_BUF + 11
    mov cx, 8
    rep movsb
    cld

    mov si, os_diag_pat
    mov di, DIR_BUF + 4
    mov cx, 8
    repe cmpsb
    jne .fail

    mov byte [DIR_BUF], 0xFF
    inc byte [DIR_BUF]
    cmp byte [DIR_BUF], 0x00
    jne .fail
    dec byte [DIR_BUF]
    cmp byte [DIR_BUF], 0xFF
    jne .fail

    mov di, 0x7FFF
    inc di
    and di, 0x7FFF
    test di, di
    jnz .fail
    dec di
    and di, 0x7FFF
    cmp di, 0x7FFF
    jne .fail

    clc
    jmp .done
.fail:
    stc
.done:
    pop di
    pop si
    pop edx
    pop cx
    pop ebx
    pop eax
    ret

os_ram_test_region:
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    push es

    mov es, ax
    mov bx, cx
    cld

    mov di, si
    mov cx, bx
    mov al, 0x55
    rep stosb

    mov di, si
    mov cx, bx
.p1_not:
    not byte [es:di]
    inc di
    loop .p1_not

    mov di, si
    mov cx, bx
    mov al, 0xAA
    repe scasb
    jne .fail

    mov dx, es
    xor dl, dh
    mov di, si
    mov cx, bx
.p2_write:
    mov ax, di
    xor al, ah
    xor al, dl
    mov [es:di], al
    xor byte [es:di], 0x5A
    add byte [es:di], 0x33
    inc di
    loop .p2_write

    mov di, si
    mov cx, bx
.p2_verify:
    mov ax, di
    xor al, ah
    xor al, dl
    xor al, 0x5A
    add al, 0x33
    cmp [es:di], al
    jne .fail
    inc di
    loop .p2_verify

    mov di, si
    mov cx, bx
    xor al, al
    rep stosb

    mov di, si
    mov cx, bx
    xor al, al
    repe scasb
    jne .fail

    clc
    jmp .done
.fail:
    stc
.done:
    pop es
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

handle_line_num:
    xor dx, dx
.parse_num:
    mov al, [si]
    cmp al, '0'
    jb .num_done
    cmp al, '9'
    ja .num_done
    sub al, '0'
    xor ah, ah
    push ax
    mov ax, dx
    mov bx, 10
    mul bx
    test dx, dx
    jnz .num_ovf
    mov dx, ax
    pop ax
    add dx, ax
    jc .syntax_err
    inc si
    jmp .parse_num

.num_ovf:
    pop ax
.syntax_err:
    mov si, msg_syntax
    call print_str
    jmp prompt

.num_done:
.skip_sp:
    cmp byte [si], ' '
    jne .got_text
    inc si
    jmp .skip_sp

.got_text:
    push si
    xor bx, bx
.len_loop:
    cmp byte [si], 0
    je .len_done
    inc si
    inc bx
    jmp .len_loop
.len_done:
    pop si

    cmp bx, 250
    ja .prog_oom

    call find_prog_end
    mov bp, PROG_START
.find_pos:
    cmp bp, PROG_LIMIT
    jae .pos_found
    xor ah, ah
    mov al, [bp]
    test al, al
    jz .pos_found
    cmp [bp + 1], dx
    jae .pos_found
    add bp, ax
    jmp .find_pos

.pos_found:
    xor cx, cx
    cmp byte [bp], 0
    je .check_space
    cmp [bp + 1], dx
    jne .check_space
    mov cl, [bp]

.check_space:
    test bx, bx
    jz .do_delete

    mov ax, bx
    add ax, 4
    add ax, di
    sub ax, cx
    cmp ax, PROG_LIMIT
    jae .prog_oom

.do_delete:
    test cx, cx
    jz .after_del

    push si
    mov ax, cx
    mov si, bp
    add si, ax
    mov cx, di
    sub cx, si
    inc cx
    push di
    mov di, bp
    rep movsb
    pop di
    sub di, ax
    pop si

.after_del:
    test bx, bx
    jz cmd_loop

    mov ax, bx
    add ax, 4

    push si
    mov cx, di
    sub cx, bp
    inc cx
    mov si, di
    add di, ax
    std
    rep movsb
    cld
    pop si

    mov [bp], al
    mov [bp + 1], dx
    mov di, bp
    add di, 3
    mov cx, bx
    inc cx
    rep movsb
    jmp cmd_loop

.prog_oom:
    mov si, msg_oom
    call print_str
    jmp prompt

; --- LIST / LIST N / LIST N-M / LIST N- / LIST -M ---
cmd_list:
    mov word [list_start], 0
    mov word [list_end], 0xFFFF

.skip_sp1:
    cmp byte [si], ' '
    jne .chk_arg
    inc si
    jmp .skip_sp1

.chk_arg:
    mov al, [si]
    test al, al
    jz .do_list
    cmp al, '-'
    je .parse_end_only

    call parse_u16
    jc err_syntax
    mov [list_start], dx
    mov [list_end], dx

.skip_sp2:
    cmp byte [si], ' '
    jne .chk_dash
    inc si
    jmp .skip_sp2

.chk_dash:
    mov al, [si]
    test al, al
    jz .do_list
    cmp al, '-'
    jne err_syntax

.parse_end_only:
    inc si
.skip_sp3:
    cmp byte [si], ' '
    jne .chk_end_num
    inc si
    jmp .skip_sp3

.chk_end_num:
    mov al, [si]
    test al, al
    jne .has_end_num
    mov word [list_end], 0xFFFF
    jmp .do_list

.has_end_num:
    call parse_u16
    jc err_syntax
    mov [list_end], dx

.skip_sp4:
    cmp byte [si], ' '
    jne .chk_eol
    inc si
    jmp .skip_sp4

.chk_eol:
    cmp byte [si], 0
    jne err_syntax

.do_list:
    mov si, PROG_START
.next_line:
    cmp si, PROG_LIMIT
    jae prompt
    xor ah, ah
    mov al, [si]
    test al, al
    jz prompt
    cmp al, 4
    jb prompt
    mov bx, si
    add bx, ax
    cmp bx, PROG_LIMIT
    ja prompt

    mov dx, [si + 1]
    cmp dx, [list_end]
    ja prompt
    cmp dx, [list_start]
    jb .skip_rec

    push ax
    push si
    call check_esc
    jnc .print_rec
    pop si
    pop ax
    mov si, msg_brk
    call print_str
    jmp prompt

.print_rec:
    mov ax, [si + 1]
    call print_dec
    mov al, ' '
    call put_char
    add si, 3
    call print_str
    mov al, 0x0A
    call put_char
    pop si
    pop ax
.skip_rec:
    add si, ax
    jmp .next_line

cmd_new:
    mov byte [PROG_START], 0
    jmp prompt

cmd_cls:
    call init_screen
    jmp prompt

cmd_run:
.skip_sp:
    cmp byte [si], ' '
    jne .chk_arg
    inc si
    jmp .skip_sp
.chk_arg:
    cmp byte [si], 0
    je .run_ram

    ; RUN X: / RUN "X:" -> bf64exec 디스크만 부트 실행, 일반 디스크는 오류
    xor ah, ah
    cmp byte [si], '"'
    jne .parse_drv
    mov ah, 1
    inc si
.parse_drv:
    call parse_drive_prefix
    jc err_syntax
    test ah, ah
    jz .trail_sp
    cmp byte [si], '"'
    jne err_syntax
    inc si
.trail_sp:
    cmp byte [si], ' '
    jne .chk_eol
    inc si
    jmp .trail_sp
.chk_eol:
    cmp byte [si], 0
    jne err_syntax

    ; 대상 드라이브 물리 LBA 0 읽기 후 bf64exec 시그니처 + 0xAA55 확인
    xor eax, eax
    mov di, DIR_BUF
    mov cx, 1
    mov bl, 0x42
    call disk_rw_lba
    jc err_device

    call is_bf64exec_buf
    jc .not_exec
    cmp word [DIR_BUF + 0x1FE], 0xAA55
    jne .not_exec

    ; bf64exec 실행 전 REBOOT/SHUTDOWN과 동일한 BF64TUI 확인 창 표시
    mov word [sm_win_title], exe_win_title
    mov word [sm_box_title], exe_box_title
    mov si, exe_warn_1
    mov di, exe_warn_2
    cmp byte [PROG_START], 0
    je .exe_msg_ok
    mov si, rbt_warn_1
    mov di, rbt_warn_2
.exe_msg_ok:
    mov bx, exe_ask
    mov ax, exe_st_conf
    call sm_confirm_window
    jc sm_exit_tui

    ; 80x25 텍스트 모드 복원 후 0000:7C00으로 부트섹터 복사 및 실행 인계
    mov byte [sm_ui_active], 0
    mov ax, 0x0003
    int 0x10
    mov ah, 0x01
    mov cx, 0x0607
    int 0x10

    cli
    cld
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0x7C00
    mov si, DIR_BUF
    mov di, 0x7C00
    mov cx, 256
    rep movsw
    mov dl, [cur_drive]
    sti
    jmp 0x0000:0x7C00

.not_exec:
    mov si, msg_not_exec
    call print_str
    jmp prompt

.run_ram:
    mov si, PROG_START
    mov di, EXEC_BUF
.rec_loop:
    cmp si, PROG_LIMIT
    jae .flatten_done
    xor ah, ah
    mov al, [si]
    test al, al
    jz .flatten_done
    cmp al, 4
    jb .flatten_done
    mov bx, si
    add bx, ax
    cmp bx, PROG_LIMIT
    ja .flatten_done

    push ax
    push si
    add si, 3
.char_loop:
    lodsb
    test al, al
    jz .rec_next
    cmp al, '>'
    je .keep
    cmp al, '<'
    je .keep
    cmp al, '+'
    je .keep
    cmp al, '-'
    je .keep
    cmp al, '.'
    je .keep
    cmp al, ','
    je .keep
    cmp al, '['
    je .keep
    cmp al, ']'
    jne .char_loop
.keep:
    cmp di, EXEC_MAX
    jae .run_oom
    stosb
    jmp .char_loop
.rec_next:
    pop si
    pop ax
    add si, ax
    jmp .rec_loop

.run_oom:
    pop si
    pop ax
    mov si, msg_oom
    call print_str
    jmp prompt

.flatten_done:
    mov byte [di], 0
    mov si, EXEC_BUF
    call exec_bf
    jmp prompt

; DIR_BUF(LBA 0)에 "bf64exec" 식별자가 있는지 확인
; 출력: CF=0 bf64exec 맞음, CF=1 아님
is_bf64exec_buf:
    cmp dword [DIR_BUF + 3], "bf64"
    jne .chk_off0
    cmp dword [DIR_BUF + 7], "exec"
    je .yes
.chk_off0:
    cmp dword [DIR_BUF + 0], "bf64"
    jne .no
    cmp dword [DIR_BUF + 4], "exec"
    je .yes
.no:
    stc
    ret
.yes:
    clc
    ret

; 현재 cur_drive의 물리 LBA 0을 읽어 bf64exec 디스크인지 실시간 확인
; 출력: CF=0 bf64exec 맞음(포맷 차단), CF=1 아님/읽기실패
check_cur_drive_bf64exec:
    push eax
    push bx
    push cx
    push di
    xor eax, eax
    mov di, DIR_BUF
    mov cx, 1
    mov bl, 0x42
    call disk_rw_lba
    jc .not_exec
    call is_bf64exec_buf
    jmp .ret
.not_exec:
    stc
.ret:
    pop di
    pop cx
    pop bx
    pop eax
    ret

; =========================================================
; 디스크 명령어 (DIR, SAVE, LOAD, DEL)
; =========================================================
cmd_dir:
.skip_sp:
    cmp byte [si], ' '
    jne .chk_empty
    inc si
    jmp .skip_sp
.chk_empty:
    cmp byte [si], 0
    je cmd_dir_all
.chk_q:
    xor ah, ah
    cmp byte [si], '"'
    jne .parse_drv
    mov ah, 1
    inc si
.parse_drv:
    call parse_drive_prefix
    jc err_syntax
    test ah, ah
    jz .trail_sp
    cmp byte [si], '"'
    jne err_syntax
    inc si
.trail_sp:
    cmp byte [si], ' '
    jne .chk_end
    inc si
    jmp .trail_sp
.chk_end:
    cmp byte [si], 0
    jne err_syntax

dir_show_cur_drive:
    call load_superblock
    jc err_device

    mov si, msg_dir_hdr
    call print_str

    mov word [cached_sec], 0xFFFF
    mov word [used_slots], 0
    mov ax, 1

.dir_loop:
    call check_esc
    jnc .dir_read
    mov si, msg_brk
    call print_str
    jmp prompt

.dir_read:
    call ensure_dir_sec
    jc err_device
    call get_slot_ptr
    cmp byte [bx], 1
    jne .dir_next

    inc word [used_slots]
    push ax
    mov ax, [bx + 14]
    call print_dec_pad
    mov al, '"'
    call put_char
    lea si, [bx + 1]
    call print_str
    mov si, msg_dir_bf
    call print_str
    pop ax

.dir_next:
    cmp ax, [fs_max_slots]
    je .dir_done
    inc ax
    jmp .dir_loop

.dir_done:
    mov ax, [fs_max_slots]
    sub ax, [used_slots]
    call print_dec
    mov si, msg_free
    call print_str
    jmp prompt

cmd_dir_all:
    mov si, msg_drv_hdr
    call print_str

    int 0x11
    test al, 0x01
    jz .scan_hdd
    shr al, 6
    and al, 0x03
    inc al
    mov [scan_cnt], al
    mov byte [scan_idx], 0

.flp_loop:
    mov al, [scan_idx]
    cmp al, [scan_cnt]
    jae .scan_hdd

    mov [cur_drive], al
    mov dword [cur_base_lba], 0
    call get_floppy_geom
    jc .next_flp
    mov [raw_sectors], eax

    mov al, [scan_idx]
    add al, 'A'
    cmp al, 'C'
    jb .ltr_ok
    inc al
.ltr_ok:
    call dir_probe_drive
    jc prompt

.next_flp:
    inc byte [scan_idx]
    jmp .flp_loop

.scan_hdd:
    mov al, [hdd_drive]
    mov [cur_drive], al
    mov eax, [part2_lba]
    mov [cur_base_lba], eax
    mov al, 'C'
    call dir_probe_drive
    jmp prompt

dir_probe_drive:
    push eax
    push bx
    push cx
    push dx
    push si
    push di

    call put_char
    mov si, msg_drv_sep
    call print_str

    cmp byte [cur_drive], 0x80
    jb .try_read
    cmp dword [cur_base_lba], 0
    je .no_disk

.try_read:
    mov eax, [cur_base_lba]
    mov di, DIR_BUF
    mov cx, 1
    mov bl, 0x42
    call disk_rw_lba
    jc .no_disk

    cmp dword [DIR_BUF], "BF64"
    jne .unfmt
    cmp byte [DIR_BUF + 4], 2
    jne .unfmt
    mov ax, [DIR_BUF + 16]
    test ax, ax
    jz .unfmt

    mov [fs_max_slots], ax
    mov eax, [DIR_BUF + 12]
    mov [fs_data_lba], eax
    mov word [cached_sec], 0xFFFF
    mov word [used_slots], 0
    mov ax, 1

.cnt_loop:
    call check_esc
    jc .brk
    call ensure_dir_sec
    jc .io_err
    call get_slot_ptr
    cmp byte [bx], 1
    jne .cnt_next
    inc word [used_slots]
.cnt_next:
    cmp ax, [fs_max_slots]
    je .print_cap
    inc ax
    jmp .cnt_loop

.print_cap:
    movzx eax, word [used_slots]
    shl eax, 4
    call print_dec32
    mov al, '/'
    call put_char
    movzx eax, word [fs_max_slots]
    shl eax, 4
    call print_dec32
    mov si, msg_kb_lpar
    call print_str
    mov ax, [used_slots]
    call print_dec
    mov al, '/'
    call put_char
    mov ax, [fs_max_slots]
    call print_dec
    mov si, msg_rpar_nl
    call print_str
    clc
    jmp .done

.unfmt:
    mov si, msg_bf64exec
    call is_bf64exec_buf
    jnc .unfmt_lbl
    mov si, msg_unfmt
.unfmt_lbl:
    call print_str
    cmp byte [cur_drive], 0x80
    jae .unfmt_nl
    mov si, msg_sp_lpar
    call print_str
    mov eax, [raw_sectors]
    shr eax, 1
    call print_dec32
    mov si, msg_kb_rpar
    call print_str
.unfmt_nl:
    mov al, 0x0A
    call put_char
    clc
    jmp .done

.no_disk:
    mov si, msg_no_disk
    call print_str
    clc
    jmp .done

.io_err:
    mov si, msg_io_err
    call print_str
    clc
    jmp .done

.brk:
    mov si, msg_brk
    call print_str
    stc
.done:
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop eax
    ret

cmd_save:
    call parse_filename
    jc err_syntax
    cmp byte [name_buf], '$'
    je err_syntax
    cmp byte [name_buf], '*'
    je err_syntax

    call load_superblock
    jc err_device

    call find_slot_and_free
    jnc .got_slot
    test dx, dx
    jnz err_device

    mov ax, [first_free_slot]
    test ax, ax
    jnz .got_slot

    mov si, msg_disk_full
    call print_str
    jmp prompt

.got_slot:
    mov [target_slot], ax
    mov si, msg_saving
    call print_str
    mov si, name_buf
    call print_str
    mov al, 0x0A
    call put_char

    movzx eax, word [target_slot]
    dec eax
    shl eax, 5
    add eax, [fs_data_lba]
    mov di, PROG_START
    mov cx, 32
    mov bl, 0x43
    call disk_rw_lba
    jc err_device

    mov ax, [target_slot]
    call ensure_dir_sec
    jc err_device
    call get_slot_ptr

    call find_prog_end
    sub di, PROG_START
    inc di
    mov dx, di

    mov byte [bx], 1
    lea di, [bx + 1]
    mov si, name_buf
    mov cx, 13
    rep movsb
    mov [bx + 14], dx

    call write_cur_dir_sec
    jc err_device
    jmp prompt

cmd_load:
    call parse_filename
    jc err_syntax
    cmp byte [name_buf], '$'
    jne .not_dir
    cmp byte [name_buf + 1], 0
    je dir_show_cur_drive

.not_dir:
    mov si, msg_searching
    call print_str
    mov si, name_buf
    call print_str
    mov al, 0x0A
    call put_char

    call load_superblock
    jc err_device

    cmp byte [name_buf], '*'
    jne .search_name
    cmp byte [name_buf + 1], 0
    jne .search_name

    mov word [cached_sec], 0xFFFF
    mov ax, 1
.find_first:
    call ensure_dir_sec
    jc err_device
    call get_slot_ptr
    cmp byte [bx], 1
    je .found_file
    cmp ax, [fs_max_slots]
    je err_not_found
    inc ax
    jmp .find_first

.search_name:
    call find_slot_and_free
    jnc .found_file
    test dx, dx
    jnz err_device
    jmp err_not_found

.found_file:
    mov [target_slot], ax
    mov si, msg_loading
    call print_str

    movzx eax, word [target_slot]
    dec eax
    shl eax, 5
    add eax, [fs_data_lba]
    mov di, PROG_START
    mov cx, 32
    mov bl, 0x42
    call disk_rw_lba
    jc .load_fail

    mov byte [PROG_LIMIT], 0
    jmp prompt

.load_fail:
    mov byte [PROG_START], 0
    jmp err_device

cmd_del:
    call parse_filename
    jc err_syntax
    call load_superblock
    jc err_device

    call find_slot_and_free
    jnc .do_del
    test dx, dx
    jnz err_device
    jmp err_not_found

.do_del:
    mov [target_slot], ax

    mov di, bx
    mov cx, 16
    xor al, al
    cld
    rep stosb

    call write_cur_dir_sec
    jc err_device

    mov ax, [target_slot]
    call zero_data_slot
    jc err_device

    mov si, msg_deleted
    call print_str
    mov si, name_buf
    call print_str
    mov al, 0x0A
    call put_char
    jmp prompt

err_syntax:
    mov si, msg_syntax
    call print_str
    jmp prompt
err_device:
    mov si, msg_dev_err
    call print_str
    jmp prompt
err_not_found:
    mov si, msg_not_found
    call print_str
    jmp prompt

; =========================================================
; BF64TUI 공용 시스템 기반 (80x25 XP 스타일 TUI + DIR 스캐너)
; - Format / Defrag / Help / Reboot / Shutdown / bf64exec 확인 공용 기반
; =========================================================

; --- [독립 창 1] BF64TUI Disk Format ---
; 초기 화면: DIR 결과 위/아래 선택 -> ENTER -> 포맷 종류 위/아래 선택 -> Y/N 확인 -> 포맷
cmd_launch_format:
    call sm_parse_opt_drv
    jc err_syntax
    mov byte [sm_drv_sel], 0
    mov word [sm_win_title], fmt_win_title
    mov word [sm_box_title], fmt_box_title
    mov word [sm_drv_hint],  fmt_drv_hint
    call sm_enter_tui

.rescan:
    call sm_show_scanning
    call sm_scan_drives

.drive_select:
    call sm_drive_select_screen
    jc sm_exit_tui

    ; 메인 OS 디스크(C:) 포맷 보호
    cmp byte [cur_drive], 0x80
    jb .chk_exec_prot
    mov si, sm_err_prot
    call sm_show_err_wait
    jmp .drive_select

.chk_exec_prot:
    ; bf64exec 식별자가 있는 실행/부팅 디스크 포맷 보호
    call check_cur_drive_bf64exec
    jc .mode_init
.fmt_exec_blocked:
    mov si, sm_err_exec
    call sm_show_err_wait
    jmp .rescan

.mode_init:
    mov byte [sm_fmt_mode], 0

.mode_redraw:
    mov si, fmt_st_mode
    call sm_draw_status
    call sm_clear_dialog

    mov dh, 8
    mov bl, SM_YEL
    call sm_print_drv_center

    mov dh, 9
    mov bl, SM_HDR
    mov si, fmt_lbl_mode
    call sm_print_center

    mov al, [sm_fmt_mode]
    mov si, sm_opt_qfmt
    mov di, sm_opt_nfmt
    call sm_draw_2opt

    ; 선택된 포맷 방식 설명
    mov dh, 16
    mov bl, SM_YEL
    mov si, sm_desc_qfmt
    cmp byte [sm_fmt_mode], 0
    je .m_desc
    mov si, sm_desc_nfmt
.m_desc:
    call sm_print_center

.mode_key:
    xor ah, ah
    int 0x16
    cmp ah, 0x48                ; UP -> Quick Format
    je .sel_quick
    cmp ah, 0x50                ; DOWN -> Normal Format
    je .sel_normal
    cmp al, 0x0D                ; ENTER -> 최종 포맷 확인
    je .confirm
    cmp al, '1'
    je .pick_quick
    cmp al, '2'
    je .pick_normal
    cmp al, 0x1B                ; ESC -> DIR 드라이브 목록으로 복귀
    je .drive_select
    cmp al, 0x08                ; BACKSPACE -> DIR 드라이브 목록으로 복귀
    je .drive_select
    jmp .mode_key

.sel_quick:
    mov byte [sm_fmt_mode], 0
    jmp .mode_redraw
.sel_normal:
    mov byte [sm_fmt_mode], 1
    jmp .mode_redraw
.pick_quick:
    mov byte [sm_fmt_mode], 0
    jmp .confirm
.pick_normal:
    mov byte [sm_fmt_mode], 1

.confirm:
    call sm_clear_dialog
    mov si, sm_st_conf_fmt
    call sm_draw_status

    mov dh, 9
    mov bl, SM_YEL
    mov si, sm_warn_erase
    call sm_print_center

    mov dh, 11
    mov bl, SM_TEXT
    call sm_print_drv_center

    mov dh, 13
    mov bl, SM_HDR
    mov si, sm_conf_q
    cmp byte [sm_fmt_mode], 0
    je .conf_mode_ok
    mov si, sm_conf_n
.conf_mode_ok:
    call sm_print_center

    mov dh, 16
    mov bl, SM_HDR
    mov si, sm_conf_ask_fmt
    call sm_print_center

.conf_key:
    xor ah, ah
    int 0x16
    cmp al, 'Y'
    je .do_fmt
    cmp al, 'y'
    je .do_fmt
    cmp al, 'N'
    je .mode_redraw
    cmp al, 'n'
    je .mode_redraw
    cmp al, 0x1B
    je .mode_redraw
    cmp al, 0x08
    je .mode_redraw
    jmp .conf_key

.do_fmt:
    ; 디스크 교체 대비: 실제 포맷 직전 bf64exec 재확인
    call check_cur_drive_bf64exec
    jnc .fmt_exec_blocked

    call sm_clear_dialog
    mov si, sm_st_busy
    call sm_draw_status

    ; 1. 플로피 실제 지오메트리 및 용량 계산
    call get_floppy_geom
    jc .fmt_io_err
    cmp eax, 34
    jb .fmt_io_err
    mov [raw_sectors], eax

    dec eax
    mov ebx, eax
    shr eax, 5
.fmt_adj:
    test eax, eax
    jz .fmt_io_err
    mov ecx, eax
    add ecx, 31
    shr ecx, 5
    mov edx, eax
    shl edx, 5
    add edx, ecx
    cmp edx, ebx
    jbe .fmt_calc_ok
    dec eax
    jmp .fmt_adj

.fmt_calc_ok:
    mov [fs_max_slots], ax
    mov [sm_dir_secs], cx
    movzx edx, cx
    inc edx
    mov [fs_data_lba], edx

    ; 포맷 대상 구간 결정: Quick = 헤더/디렉토리(fs_data_lba), Normal = 전체(raw_sectors)
    cmp byte [sm_fmt_mode], 0
    jne .set_full
    mov eax, [fs_data_lba]
    mov [sm_prog_tot], eax
    mov si, sm_msg_w_q
    jmp .start_wipe
.set_full:
    mov eax, [raw_sectors]
    mov [sm_prog_tot], eax
    mov si, sm_msg_w_n

.start_wipe:
    mov dh, 10
    mov bl, SM_HDR
    call sm_print_center
    call sm_draw_bar_frame

    ; 드라이브 리셋
    xor ah, ah
    mov dl, [cur_drive]
    int 0x13

    ; 512B 0x00 버퍼 준비
    push es
    push ds
    pop es
    mov di, DIR_BUF
    mov cx, 256
    xor ax, ax
    cld
    rep stosw
    pop es

    mov dword [sm_prog_cur], 0
    mov word [sm_last_pct], 0xFFFF
    call sm_update_bar

.w_loop:
    mov eax, [sm_prog_cur]
    cmp eax, [sm_prog_tot]
    jae .w_done
    mov di, DIR_BUF
    mov cx, 1
    mov bl, 0x43
    call disk_rw_lba
    jc .fmt_io_err
    inc dword [sm_prog_cur]
    call sm_update_bar
    jmp .w_loop

.w_done:
    call sm_update_bar

    ; 2. 0x00 읽기 검증 (빠른 포맷: 헤더/디렉토리만, 전체 포맷: 전체 섹터)
    mov cx, 0x0A0A
    mov dx, 0x0A45
    mov al, ' '
    mov bl, SM_TEXT
    call sm_fill_rect

    mov dh, 10
    mov bl, SM_HDR
    mov si, sm_msg_v_q
    cmp byte [sm_fmt_mode], 0
    je .v_hdr_ok
    mov si, sm_msg_v_n
.v_hdr_ok:
    call sm_print_center

    mov dword [sm_prog_cur], 0
    mov word [sm_last_pct], 0xFFFF
    call sm_update_bar

.v_loop:
    mov eax, [sm_prog_cur]
    cmp eax, [sm_prog_tot]
    jae .v_done
    mov di, DIR_BUF
    mov cx, 1
    mov bl, 0x42
    call disk_rw_lba
    jc .fmt_io_err

    push es
    push ds
    pop es
    mov di, DIR_BUF
    mov cx, 256
    xor ax, ax
    cld
    repe scasw
    pop es
    jne .fmt_vfy_err

    inc dword [sm_prog_cur]
    call sm_update_bar
    jmp .v_loop

.v_done:
    call sm_update_bar

    ; 3. LBA 0 슈퍼블록 기록 및 재읽기 확인
    push es
    push ds
    pop es
    mov di, DIR_BUF
    mov cx, 256
    xor ax, ax
    cld
    rep stosw
    pop es

    mov dword [DIR_BUF + 0], "BF64"
    mov byte  [DIR_BUF + 4], 2
    mov dword [DIR_BUF + 8], 0
    mov eax, [fs_data_lba]
    mov dword [DIR_BUF + 12], eax
    movzx eax, word [fs_max_slots]
    mov dword [DIR_BUF + 16], eax
    mov ax, [sm_dir_secs]
    mov word  [DIR_BUF + 20], ax
    mov word  [DIR_BUF + 22], 32

    xor eax, eax
    mov di, DIR_BUF
    mov cx, 1
    mov bl, 0x43
    call disk_rw_lba
    jc .fmt_io_err

    call load_superblock
    jc .fmt_vfy_err

    call sm_clear_dialog
    mov dh, 11
    mov bl, SM_GRN
    mov si, sm_done_fmt
    call sm_print_center

    mov di, SM_LINE_BUF
    mov si, sm_res_cap
    call sm_str_cat
    movzx eax, word [fs_max_slots]
    shl eax, 4
    call sm_u32_cat
    mov si, msg_kb_lpar
    call sm_str_cat
    movzx eax, word [fs_max_slots]
    call sm_u32_cat
    mov si, sm_res_slots
    call sm_str_cat
    mov dh, 13
    mov bl, SM_TEXT
    mov si, SM_LINE_BUF
    call sm_print_center
    call sm_wait_any_key
    jmp .rescan

.fmt_io_err:
    mov si, sm_err_io
    call sm_show_err_wait
    jmp .rescan

.fmt_vfy_err:
    mov si, sm_err_vfy
    call sm_show_err_wait
    jmp .rescan

; --- [독립 창 2] BF64TUI Disk Defragmenter ---
; 초기 화면: DIR 결과 위/아래 선택 -> ENTER -> 조각모음 여부 Y/N 확인 -> 조각모음
cmd_launch_defrag:
    call sm_parse_opt_drv
    jc err_syntax
    mov byte [sm_drv_sel], 0
    mov word [sm_win_title], def_win_title
    mov word [sm_box_title], def_box_title
    mov word [sm_drv_hint],  def_drv_hint
    call sm_enter_tui

.rescan:
    call sm_show_scanning
    call sm_scan_drives

.drive_select:
    call sm_drive_select_screen
    jc sm_exit_tui

    ; bf64exec 실행/부팅 디스크 조각모음 차단
    cmp byte [cur_drive], 0x80
    jae .confirm
    call check_cur_drive_bf64exec
    jc .confirm
.def_exec_blocked:
    mov si, sm_err_def_exec
    call sm_show_err_wait
    jmp .rescan

.confirm:
    call sm_clear_dialog
    mov si, sm_st_conf_def
    call sm_draw_status

    mov dh, 9
    mov bl, SM_YEL
    call sm_print_drv_center

    mov dh, 12
    mov bl, SM_TEXT
    mov si, sm_desc_def
    call sm_print_center

    mov dh, 15
    mov bl, SM_HDR
    mov si, sm_conf_ask_def
    call sm_print_center

.conf_key:
    xor ah, ah
    int 0x16
    cmp al, 'Y'
    je .do_def
    cmp al, 'y'
    je .do_def
    cmp al, 'N'
    je .drive_select
    cmp al, 'n'
    je .drive_select
    cmp al, 0x1B
    je .drive_select
    cmp al, 0x08
    je .drive_select
    jmp .conf_key

.do_def:
    ; 디스크 교체 대비: 실행 직전 bf64exec 재확인
    cmp byte [cur_drive], 0x80
    jae .do_def_go
    call check_cur_drive_bf64exec
    jnc .def_exec_blocked
.do_def_go:
    call sm_clear_dialog
    mov si, sm_st_busy
    call sm_draw_status

    mov dh, 10
    mov bl, SM_HDR
    mov si, sm_msg_def
    call sm_print_center
    call sm_draw_bar_frame

    call defrag_core
    jc .def_err

    call sm_clear_dialog
    mov dh, 11
    mov bl, SM_GRN
    mov si, sm_done_def
    call sm_print_center

    mov di, SM_LINE_BUF
    mov si, sm_res_mv
    call sm_str_cat
    movzx eax, word [def_moved]
    call sm_u32_cat
    mov dh, 13
    mov bl, SM_TEXT
    mov si, SM_LINE_BUF
    call sm_print_center

    mov di, SM_LINE_BUF
    mov si, sm_res_cln
    call sm_str_cat
    movzx eax, word [def_cleaned]
    call sm_u32_cat
    mov dh, 14
    mov bl, SM_TEXT
    mov si, SM_LINE_BUF
    call sm_print_center
    call sm_wait_any_key
    jmp .rescan

.def_err:
    mov si, sm_err_def
    call sm_show_err_wait
    jmp .rescan

; --- [독립 창 3] BF64TUI Command Help ---
cmd_launch_help:
    mov word [sm_win_title], hlp_win_title
    mov word [sm_box_title], hlp_box_title
    mov byte [sm_help_page], 0
    call sm_enter_tui

.redraw:
    mov si, hlp_st_bar
    call sm_draw_base
    call sm_draw_dialog

    mov dh, 7
    mov bl, SM_YEL
    mov si, hlp_hdr_1
    cmp byte [sm_help_page], 0
    je .hdr_ok
    mov si, hlp_hdr_2
.hdr_ok:
    call sm_print_center

    mov dx, 0x090C
    mov bl, SM_TEXT
    mov si, hlp_page_1
    cmp byte [sm_help_page], 0
    je .pg_txt_ok
    mov si, hlp_page_2
.pg_txt_ok:
    call sm_print_at

    mov dh, 18
    mov bl, SM_YEL
    mov si, hlp_pg1_lbl
    cmp byte [sm_help_page], 0
    je .pg_lbl_ok
    mov si, hlp_pg2_lbl
.pg_lbl_ok:
    call sm_print_center

.key_loop:
    xor ah, ah
    int 0x16
    cmp al, 0x1B                ; ESC -> 셸 복귀
    je sm_exit_tui
    cmp ah, 0x4B                ; LEFT -> Page 1
    je .pg0
    cmp ah, 0x48                ; UP -> Page 1
    je .pg0
    cmp ah, 0x4D                ; RIGHT -> Page 2
    je .pg1
    cmp ah, 0x50                ; DOWN -> Page 2
    je .pg1
    cmp al, ' '                 ; SPACE -> 페이지 전환
    je .toggle
    cmp al, 0x0D                ; ENTER -> 페이지 전환
    je .toggle
    jmp .key_loop

.pg0:
    mov byte [sm_help_page], 0
    jmp .redraw
.pg1:
    mov byte [sm_help_page], 1
    jmp .redraw
.toggle:
    xor byte [sm_help_page], 1
    jmp .redraw

; --- [독립 창 4] REBOOT / SHUTDOWN (RAM 비어있으면 즉시 실행, 있으면 BF64TUI 확인) ---
cmd_reboot:
    cmp byte [PROG_START], 0
    je os_do_reboot

    mov word [sm_win_title], rbt_win_title
    mov word [sm_box_title], rbt_box_title
    mov si, rbt_warn_1
    mov di, rbt_warn_2
    mov bx, rbt_ask
    mov ax, rbt_st_conf
    call sm_confirm_window
    jc sm_exit_tui

os_do_reboot:
    mov word [0x0472], 0x1234
    cli
.kbc_wait:
    in al, 0x64
    test al, 0x02
    jnz .kbc_wait
    mov al, 0xFE
    out 0x64, al
    jmp 0xFFFF:0x0000

cmd_shutdown:
    cmp byte [PROG_START], 0
    je os_do_shutdown

    mov word [sm_win_title], sdn_win_title
    mov word [sm_box_title], sdn_box_title
    mov si, rbt_warn_1
    mov di, rbt_warn_2
    mov bx, sdn_ask
    mov ax, sdn_st_conf
    call sm_confirm_window
    jc sm_exit_tui

os_do_shutdown:
    ; 1. APM BIOS 1.1+ 전원 끄기 (SeaBIOS/QEMU/Bochs/VirtualBox/VMware/실기)
    mov ax, 0x5300
    xor bx, bx
    int 0x15
    jc .try_io
    mov ax, 0x5301
    xor bx, bx
    int 0x15
    mov ax, 0x530E
    xor bx, bx
    mov cx, 0x0102
    int 0x15
    mov ax, 0x5307
    mov bx, 0x0001
    mov cx, 0x0003
    int 0x15

.try_io:
    ; 2. QEMU / Bochs / VirtualBox ACPI 포트 전원 끄기
    mov dx, 0x0604
    mov ax, 0x2000
    out dx, ax
    mov dx, 0xB004
    mov ax, 0x2000
    out dx, ax
    mov dx, 0x4004
    mov ax, 0x3400
    out dx, ax

    ; 3. 소프트웨어 전원 끄기 미지원 시 안전 종료 콘솔 안내 후 정지
    mov ax, 0x0003
    int 0x10
    mov ah, 0x01
    mov cx, 0x2607
    int 0x10
    mov cx, 0x0000
    mov dx, 0x184F
    mov al, ' '
    mov bl, CON_TEXT
    call sm_fill_rect
    mov dh, 12
    mov bl, CON_HDR
    mov si, msg_safe_off
    call sm_print_center
.off_halt:
    cli
    hlt
    jmp .off_halt

; --- [독립 창 5] BF64TUI System Settings (Interpreter / Shell Config 2단계 설정 & C: 저장) ---
cmd_launch_settings:
    mov byte [sm_set_cat], 0
    call sm_enter_tui

.cat_redraw:
    mov word [sm_win_title], set_win_title
    mov word [sm_box_title], set_box_title
    mov si, set_st_cat
    call sm_draw_base
    call sm_draw_dialog

    mov dh, 8
    mov bl, SM_HDR
    mov si, set_lbl_cat
    call sm_print_center

    mov al, [sm_set_cat]
    mov si, set_cat_int
    mov di, set_cat_sh
    call sm_draw_2opt

    mov dh, 15
    mov bl, SM_YEL
    call set_get_active_str
    call sm_print_center

.cat_key:
    xor ah, ah
    int 0x16
    cmp ah, 0x48                ; UP -> Interpreter
    je .cat_0
    cmp ah, 0x50                ; DOWN -> Shell Config
    je .cat_1
    cmp al, '1'
    je .pick_cat_0
    cmp al, '2'
    je .pick_cat_1
    cmp al, 0x0D                ; ENTER -> 하위 메뉴 진입
    je .open_sub
    cmp al, 0x1B                ; ESC -> 셸 복귀
    je sm_exit_tui
    jmp .cat_key

.cat_0:
    mov byte [sm_set_cat], 0
    jmp .cat_redraw
.cat_1:
    mov byte [sm_set_cat], 1
    jmp .cat_redraw
.pick_cat_0:
    mov byte [sm_set_cat], 0
    jmp .open_sub
.pick_cat_1:
    mov byte [sm_set_cat], 1

.open_sub:
    cmp byte [sm_set_cat], 0
    jne .open_sh
    mov word [sm_win_title], set_int_win
    mov word [sm_box_title], set_int_box
    mov al, [vm_opt_mode]
    mov [sm_set_sel], al
    jmp .sub_redraw
.open_sh:
    mov word [sm_win_title], set_sh_win
    mov word [sm_box_title], set_sh_box
    mov al, [shell_mode]
    mov [sm_set_sel], al

.sub_redraw:
    mov si, set_st_sub
    call sm_draw_base
    call sm_draw_dialog

    mov dh, 8
    mov bl, SM_HDR
    mov si, set_lbl_int
    cmp byte [sm_set_cat], 0
    je .sub_lbl_ok
    mov si, set_lbl_sh
.sub_lbl_ok:
    call sm_print_center

    mov dh, 9
    mov bl, SM_YEL
    call set_get_active_str
    call sm_print_center

    mov si, set_opt_cls
    mov di, set_opt_opt
    cmp byte [sm_set_cat], 0
    je .sub_opt_ok
    mov si, set_opt_sh0
    mov di, set_opt_sh1
.sub_opt_ok:
    mov al, [sm_set_sel]
    call sm_draw_2opt

    mov dh, 15
    mov bl, SM_YEL
    cmp byte [sm_set_cat], 0
    jne .desc_sh
    mov si, set_desc_cls
    cmp byte [sm_set_sel], 0
    je .desc_ok
    mov si, set_desc_opt
    jmp .desc_ok
.desc_sh:
    mov si, set_desc_sh0
    cmp byte [sm_set_sel], 0
    je .desc_ok
    mov si, set_desc_sh1
.desc_ok:
    call sm_print_center

.sub_key:
    xor ah, ah
    int 0x16
    cmp ah, 0x48                ; UP -> 항목 0
    je .sel_0
    cmp ah, 0x50                ; DOWN -> 항목 1
    je .sel_1
    cmp al, '1'
    je .pick_0
    cmp al, '2'
    je .pick_1
    cmp al, 0x0D                ; ENTER -> 적용 및 C: 저장
    je .sub_apply
    cmp al, 0x1B                ; ESC -> 상위 설정 메뉴로 복귀
    je .cat_redraw
    cmp al, 0x08                ; BS -> 상위 설정 메뉴로 복귀
    je .cat_redraw
    jmp .sub_key

.sel_0:
    mov byte [sm_set_sel], 0
    jmp .sub_redraw
.sel_1:
    mov byte [sm_set_sel], 1
    jmp .sub_redraw
.pick_0:
    mov byte [sm_set_sel], 0
    jmp .sub_apply
.pick_1:
    mov byte [sm_set_sel], 1

.sub_apply:
    mov al, [sm_set_sel]
    cmp byte [sm_set_cat], 0
    jne .apply_sh
    mov [vm_opt_mode], al
    jmp .do_save
.apply_sh:
    mov [shell_mode], al
.do_save:
    call save_os_cfg_to_c

    call sm_clear_dialog
    mov si, set_st_done
    call sm_draw_status

    mov dh, 11
    mov bl, SM_GRN
    mov si, set_msg_saved
    call sm_print_center

    mov dh, 13
    mov bl, SM_HDR
    call set_get_active_str
    call sm_print_center

    mov dh, 16
    mov bl, SM_YEL
    mov si, set_st_done
    call sm_print_center

    xor ah, ah
    int 0x16
    jmp .cat_redraw

; 2항목 좌측 정렬 선택 메뉴 공용 렌더링 헬퍼 (AL=선택 0/1, SI=항목0, DI=항목1)
sm_draw_2opt:
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    mov ah, al

    mov bl, SM_TEXT
    cmp ah, 0
    jne .o0_a
    mov bl, SM_BAR
.o0_a:
    mov cx, 0x0B0A
    mov dx, 0x0B45
    mov al, ' '
    call sm_fill_rect
    cmp ah, 0
    jne .o0_txt
    push si
    mov dx, 0x0B0A
    mov si, sm_sel_l
    call sm_print_at
    pop si
.o0_txt:
    mov dx, 0x0B0C
    call sm_print_at

    mov bl, SM_TEXT
    cmp ah, 1
    jne .o1_a
    mov bl, SM_BAR
.o1_a:
    mov cx, 0x0C0A
    mov dx, 0x0C45
    mov al, ' '
    call sm_fill_rect
    cmp ah, 1
    jne .o1_txt
    mov dx, 0x0C0A
    mov si, sm_sel_l
    call sm_print_at
.o1_txt:
    mov dx, 0x0C0C
    mov si, di
    call sm_print_at

    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; 현재 [sm_set_cat] 카테고리의 활성 설정 문자열 반환 (-> SI)
set_get_active_str:
    cmp byte [sm_set_cat], 0
    jne .sh
    mov si, set_cur_cls
    cmp byte [vm_opt_mode], 0
    je .done
    mov si, set_cur_opt
    ret
.sh:
    mov si, set_cur_sh0
    cmp byte [shell_mode], 0
    je .done
    mov si, set_cur_sh1
.done:
    ret

; C: 파티션 2 슈퍼블록을 DIR_BUF로 읽기 & BF64 v2 검증 (CF=0 성공, CF=1 실패)
read_c_superblock:
    mov eax, [part2_lba]
    test eax, eax
    jz .fail
    mov bl, [hdd_drive]
    mov [cur_drive], bl
    mov [cur_base_lba], eax
    mov di, DIR_BUF
    mov cx, 1
    mov bl, 0x42
    call disk_rw_lba
    jc .fail
    cmp dword [DIR_BUF], "BF64"
    jne .fail
    cmp byte [DIR_BUF + 4], 2
    jne .fail
    clc
    ret
.fail:
    stc
    ret

; C: 파티션 2 슈퍼블록 예약 바이트(+5=Interpreter, +6=Shell) 로드 (기본값 모두 0=Classic)
load_os_cfg_from_c:
    push eax
    push bx
    push cx
    push di
    mov byte [vm_opt_mode], 0
    mov byte [shell_mode], 0
    call read_c_superblock
    jc .done
    cmp byte [DIR_BUF + 5], 1
    jne .chk_sh
    mov byte [vm_opt_mode], 1
.chk_sh:
    cmp byte [DIR_BUF + 6], 1
    jne .done
    mov byte [shell_mode], 1
.done:
    pop di
    pop cx
    pop bx
    pop eax
    ret

; C: 파티션 2 슈퍼블록 예약 바이트(+5=Interpreter, +6=Shell) 영구 저장
save_os_cfg_to_c:
    push eax
    push bx
    push cx
    push di
    call read_c_superblock
    jc .done
    mov al, [vm_opt_mode]
    mov [DIR_BUF + 5], al
    mov al, [shell_mode]
    mov [DIR_BUF + 6], al
    mov eax, [part2_lba]
    mov di, DIR_BUF
    mov cx, 1
    mov bl, 0x43
    call disk_rw_lba
.done:
    pop di
    pop cx
    pop bx
    pop eax
    ret

; =========================================================
; BF64TUI 공용 진입/종료, 공용 확인 창, 옵션 파싱, DIR 스캔 & 드라이브 선택
; =========================================================
; 공용 확인 창 (REBOOT / SHUTDOWN / bf64exec 실행 공용)
; 입력: [sm_win_title], [sm_box_title], si=경고1, di=경고2, bx=질문, ax=상태바
; 출력: CF=0 (Y 확인), CF=1 (N/ESC 취소)
sm_confirm_window:
    push bx
    push si
    push di
    push ax
    call sm_enter_tui
    pop si
    call sm_draw_base
    call sm_draw_dialog

    pop di
    pop si
    mov dh, 9
    mov bl, SM_YEL
    call sm_print_center

    mov dh, 11
    mov bl, SM_TEXT
    mov si, di
    call sm_print_center

    pop si
    mov dh, 15
    mov bl, SM_HDR
    call sm_print_center

.key_loop:
    xor ah, ah
    int 0x16
    cmp al, 'Y'
    je .yes
    cmp al, 'y'
    je .yes
    cmp al, 'N'
    je .no
    cmp al, 'n'
    je .no
    cmp al, 0x1B
    je .no
    jmp .key_loop
.yes:
    clc
    ret
.no:
    stc
    ret

sm_parse_opt_drv:
    mov byte [sm_init_drv], 0
.skip_sp:
    cmp byte [si], ' '
    jne .chk_empty
    inc si
    jmp .skip_sp
.chk_empty:
    cmp byte [si], 0
    je .ok
    xor ah, ah
    cmp byte [si], '"'
    jne .chk_drv
    mov ah, 1
    inc si
.chk_drv:
    mov al, [si]
    cmp al, 'a'
    jb .chk_up
    cmp al, 'z'
    ja .chk_up
    sub al, 32
.chk_up:
    cmp al, 'A'
    jb .bad
    cmp al, 'Z'
    ja .bad
    cmp byte [si + 1], ':'
    jne .bad
    mov [sm_init_drv], al
    add si, 2
    test ah, ah
    jz .trail_sp
    cmp byte [si], '"'
    jne .bad
    inc si
.trail_sp:
    cmp byte [si], ' '
    jne .chk_end
    inc si
    jmp .trail_sp
.chk_end:
    cmp byte [si], 0
    jne .bad
.ok:
    clc
    ret
.bad:
    stc
    ret

sm_enter_tui:
    mov ax, 0x0003
    int 0x10
    mov ah, 0x01
    mov cx, 0x2607
    int 0x10
    mov byte [sm_ui_active], 1
    ret

sm_exit_tui:
    mov byte [sm_ui_active], 0
    call init_screen
    call print_shell_banner
    jmp prompt

sm_show_scanning:
    mov si, sm_st_scan
    call sm_draw_base
    call sm_draw_dialog
    mov dh, 11
    mov bl, SM_HDR
    mov si, sm_msg_scan
    call sm_print_center
    ret

sm_show_err_wait:
    push si
    call sm_clear_dialog
    pop si
    mov dh, 12
    mov bl, SM_RED
    call sm_print_center
sm_wait_any_key:
    mov si, sm_st_done
    call sm_draw_status
    mov dh, 17
    mov bl, SM_HDR
    mov si, sm_press_key
    call sm_print_center
    xor ah, ah
    int 0x16
    ret

; dh=행, bl=속성 -> "Target Drive : X: (Floppy Drive / Main HDD)" 중앙 정렬 출력
sm_print_drv_center:
    push ax
    push si
    push di
    mov di, SM_LINE_BUF
    mov si, sm_lbl_drv
    call sm_str_cat
    mov al, [sm_drv_ltr]
    mov [sm_drv_ltr_str], al
    mov si, sm_drv_ltr_str
    call sm_str_cat
    mov si, sm_tag_hdd
    cmp byte [cur_drive], 0x80
    jae .tag_ok
    mov si, sm_tag_flp
.tag_ok:
    call sm_str_cat
    mov si, SM_LINE_BUF
    call sm_print_center
    pop di
    pop si
    pop ax
    ret

; DIR 명령어와 동일한 방식으로 전체 드라이브(FDD + C:)를 점검해 SM_DRV_TABLE에 기록
sm_scan_drives:
    push eax
    push bx
    push cx
    push di
    mov byte [sm_drv_cnt], 0

    int 0x11
    test al, 0x01
    jz .scan_hdd
    shr al, 6
    and al, 0x03
    inc al
    mov [scan_cnt], al
    mov byte [scan_idx], 0

.flp_loop:
    mov al, [scan_idx]
    cmp al, [scan_cnt]
    jae .scan_hdd

    mov [cur_drive], al
    mov dword [cur_base_lba], 0
    call get_floppy_geom
    jc .next_flp
    mov [raw_sectors], eax

    mov al, [scan_idx]
    add al, 'A'
    cmp al, 'C'
    jb .ltr_ok
    inc al
.ltr_ok:
    call sm_probe_add_drive

.next_flp:
    inc byte [scan_idx]
    jmp .flp_loop

.scan_hdd:
    mov al, [hdd_drive]
    mov [cur_drive], al
    mov eax, [part2_lba]
    mov [cur_base_lba], eax
    mov dword [raw_sectors], 0
    mov al, 'C'
    call sm_probe_add_drive

    ; 명령 인자로 드라이브(예: FORMAT B:, DEFRAG C:)가 주어진 경우 초기 포커스 적용
    mov al, [sm_init_drv]
    test al, al
    jz .chk_bounds
    mov byte [sm_init_drv], 0
    xor cx, cx
    mov cl, [sm_drv_cnt]
    xor bx, bx
.find_init:
    test cx, cx
    jz .chk_bounds
    mov di, bx
    shl di, 6
    cmp [SM_DRV_TABLE + di], al
    je .found_init
    inc bx
    dec cx
    jmp .find_init
.found_init:
    mov [sm_drv_sel], bl

.chk_bounds:
    mov al, [sm_drv_sel]
    cmp al, [sm_drv_cnt]
    jb .done
    mov byte [sm_drv_sel], 0
.done:
    pop di
    pop cx
    pop bx
    pop eax
    ret

; 입력: AL=드라이브 문자('A'..'Z'), cur_drive, cur_base_lba, raw_sectors
sm_probe_add_drive:
    push eax
    push bx
    push cx
    push dx
    push si
    push di
    push es

    push ds
    pop es

    cmp byte [sm_drv_cnt], SM_DRV_MAX
    jae .done

    mov [sm_tmp_ltr], al
    movzx bx, byte [sm_drv_cnt]
    shl bx, 6
    add bx, SM_DRV_TABLE
    mov [sm_cur_ent], bx

    ; 64B 엔트리 초기화
    mov di, bx
    mov cx, 32
    xor ax, ax
    cld
    rep stosw

    mov bx, [sm_cur_ent]
    mov al, [sm_tmp_ltr]
    mov [bx + 0], al
    mov al, [cur_drive]
    mov [bx + 1], al
    mov eax, [cur_base_lba]
    mov [bx + 4], eax
    mov eax, [raw_sectors]
    mov [bx + 12], eax

    ; DIR 표시 문자열 시작: "X: "
    lea di, [bx + 16]
    mov al, [sm_tmp_ltr]
    stosb
    mov al, ':'
    stosb
    mov al, ' '
    stosb

    cmp byte [cur_drive], 0x80
    jb .try_read
    cmp dword [cur_base_lba], 0
    je .no_disk

.try_read:
    mov eax, [cur_base_lba]
    push di
    mov di, DIR_BUF
    mov cx, 1
    mov bl, 0x42
    call disk_rw_lba
    pop di
    jc .no_disk

    cmp dword [DIR_BUF], "BF64"
    jne .unfmt
    cmp byte [DIR_BUF + 4], 2
    jne .unfmt
    mov ax, [DIR_BUF + 16]
    test ax, ax
    jz .unfmt

    mov [fs_max_slots], ax
    mov eax, [DIR_BUF + 12]
    mov [fs_data_lba], eax
    mov word [cached_sec], 0xFFFF
    mov word [used_slots], 0
    mov ax, 1

.cnt_loop:
    call ensure_dir_sec
    jc .io_err
    call get_slot_ptr
    cmp byte [bx], 1
    jne .cnt_next
    inc word [used_slots]
.cnt_next:
    cmp ax, [fs_max_slots]
    je .fmt_ok
    inc ax
    jmp .cnt_loop

.fmt_ok:
    mov bx, [sm_cur_ent]
    mov byte [bx + 2], 0
    mov ax, [used_slots]
    mov [bx + 8], ax
    mov ax, [fs_max_slots]
    mov [bx + 10], ax

    movzx eax, word [used_slots]
    shl eax, 4
    call sm_u32_cat
    mov al, '/'
    stosb
    movzx eax, word [fs_max_slots]
    shl eax, 4
    call sm_u32_cat
    mov si, msg_kb_lpar
    call sm_str_cat
    movzx eax, word [used_slots]
    call sm_u32_cat
    mov al, '/'
    stosb
    movzx eax, word [fs_max_slots]
    call sm_u32_cat
    mov al, ')'
    stosb
    jmp .append_tag

.unfmt:
    mov bx, [sm_cur_ent]
    call is_bf64exec_buf
    jc .is_unfmt
    mov byte [bx + 2], 4
    mov si, msg_bf64exec
    jmp .unfmt_cat
.is_unfmt:
    mov byte [bx + 2], 1
    mov si, msg_unfmt
.unfmt_cat:
    call sm_str_cat
    cmp byte [cur_drive], 0x80
    jae .append_tag
    mov si, msg_sp_lpar
    call sm_str_cat
    mov eax, [raw_sectors]
    shr eax, 1
    call sm_u32_cat
    mov si, msg_kb_rpar
    call sm_str_cat
    jmp .append_tag

.no_disk:
    mov bx, [sm_cur_ent]
    mov byte [bx + 2], 2
    mov si, sm_txt_nodisk
    call sm_str_cat
    jmp .append_tag

.io_err:
    mov bx, [sm_cur_ent]
    mov byte [bx + 2], 3
    mov si, sm_txt_ioerr
    call sm_str_cat

.append_tag:
    mov si, sm_tag_hdd_s
    cmp byte [cur_drive], 0x80
    jae .tag_cat
    mov si, sm_tag_flp_s
.tag_cat:
    call sm_str_cat
    inc byte [sm_drv_cnt]

.done:
    pop es
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop eax
    ret

; 공용 DIR 드라이브 선택 화면 (UP/DOWN 선택 + ENTER 확정 / ESC 종료 / R 새로고침)
; 출력: CF=0 선택 완료, CF=1 ESC 취소
sm_drive_select_screen:
.redraw:
    mov si, sm_st_drv
    call sm_draw_base
    call sm_draw_dialog

    mov dh, 8
    mov bl, SM_HDR
    mov si, sm_lbl_dir_hdr
    call sm_print_center

    cmp byte [sm_drv_cnt], 0
    je .draw_hint

    xor cx, cx
    mov cl, [sm_drv_cnt]
    xor ax, ax
.row_loop:
    push ax
    push cx

    mov dh, al
    add dh, 10
    mov bl, SM_TEXT
    cmp al, [sm_drv_sel]
    jne .attr_ok
    mov bl, SM_BAR
.attr_ok:
    push ax
    push dx
    mov ch, dh
    mov cl, 0x0A
    mov dl, 0x45
    mov al, ' '
    call sm_fill_rect
    pop dx
    pop ax

    cmp al, [sm_drv_sel]
    jne .print_drv
    mov dl, 0x0A
    mov si, sm_sel_l
    call sm_print_at

.print_drv:
    mov di, ax
    shl di, 6
    lea si, [di + SM_DRV_TABLE + 16]
    mov dl, 0x0C
    call sm_print_at

    pop cx
    pop ax
    inc ax
    loop .row_loop

.draw_hint:
    mov dh, 18
    mov bl, SM_YEL
    mov si, [sm_drv_hint]
    call sm_print_center

.key_loop:
    xor ah, ah
    int 0x16

    cmp al, 0x1B                ; ESC -> 셸 복귀
    je .cancel
    cmp ah, 0x48                ; UP
    je .move_up
    cmp ah, 0x50                ; DOWN
    je .move_dn
    cmp al, 'R'                 ; R -> DIR 재검사
    je .refresh
    cmp al, 'r'
    je .refresh
    cmp al, 0x0D                ; ENTER -> 선택 확정
    je .confirm_sel
    jmp .key_loop

.move_up:
    cmp byte [sm_drv_sel], 0
    je .key_loop
    dec byte [sm_drv_sel]
    jmp .redraw

.move_dn:
    mov al, [sm_drv_sel]
    inc al
    cmp al, [sm_drv_cnt]
    jae .key_loop
    mov [sm_drv_sel], al
    jmp .redraw

.refresh:
    call sm_show_scanning
    call sm_scan_drives
    jmp .redraw

.confirm_sel:
    cmp byte [sm_drv_cnt], 0
    je .key_loop
    movzx bx, byte [sm_drv_sel]
    shl bx, 6
    add bx, SM_DRV_TABLE
    mov al, [bx + 0]
    mov [sm_drv_ltr], al
    mov al, [bx + 1]
    mov [cur_drive], al
    mov eax, [bx + 4]
    mov [cur_base_lba], eax
    mov eax, [bx + 12]
    mov [raw_sectors], eax
    clc
    ret

.cancel:
    stc
    ret

sm_str_cat:
    push ax
    push es
    push ds
    pop es
    cld
.loop:
    lodsb
    test al, al
    jz .done
    stosb
    jmp .loop
.done:
    mov byte [es:di], 0
    pop es
    pop ax
    ret

sm_u32_cat:
    push si
    call sm_u32_to_str
    call sm_str_cat
    pop si
    ret

; AL('A'..'Z') -> cur_drive, cur_base_lba 반영 (셸 parse_drive_prefix 겸용)
sm_apply_drive:
    cmp al, 'C'
    je .hdd
    sub al, 'A'
    cmp al, 2
    jb .flp
    dec al
.flp:
    mov [cur_drive], al
    mov dword [cur_base_lba], 0
    ret
.hdd:
    mov al, [hdd_drive]
    mov [cur_drive], al
    mov eax, [part2_lba]
    mov [cur_base_lba], eax
    ret

; =========================================================
; 공용 조각 모음 코어 (부팅 시 콘솔 / System Manager TUI 겸용)
; 입력: cur_drive, cur_base_lba, sm_ui_active (0=콘솔, 1=TUI 바 갱신)
; 출력: CF=0 성공(def_moved/def_cleaned 갱신), CF=1 실패/미포맷
; =========================================================
defrag_core:
    push eax
    push bx
    push cx
    push dx
    push si
    push di
    push es
    push ds
    pop es

    call load_superblock
    jc .fail

    mov word [def_write], 1
    mov word [def_read], 1
    mov word [def_moved], 0
    mov word [def_cleaned], 0
    mov word [cached_sec], 0xFFFF

    movzx eax, word [fs_max_slots]
    mov [sm_prog_tot], eax
    mov dword [sm_prog_cur], 0
    mov word [sm_last_pct], 0xFFFF
    cmp byte [sm_ui_active], 1
    jne .scan_loop
    call sm_update_bar

.scan_loop:
    mov ax, [def_read]
    call ensure_dir_sec
    jc .fail
    call get_slot_ptr

    cmp byte [bx], 1
    je .used_slot

    ; 빈 슬롯 디렉토리 잔여 비0 바이트 정리
    mov di, bx
    mov cx, 16
    xor al, al
    cld
    repe scasb
    je .next_read

    mov di, bx
    mov cx, 16
    xor al, al
    rep stosb
    call write_cur_dir_sec
    jc .fail
    inc word [def_cleaned]
    jmp .next_read

.used_slot:
    mov ax, [def_read]
    cmp ax, [def_write]
    je .no_move

    ; 1. 원본 디렉토리 엔트리 보관
    mov si, bx
    mov di, def_entry
    mov cx, 16
    cld
    rep movsb

    ; 2. 원본 슬롯(def_read) 16KB -> EXEC_BUF 읽기
    movzx eax, word [def_read]
    dec eax
    shl eax, 5
    add eax, [fs_data_lba]
    mov di, EXEC_BUF
    mov cx, 32
    mov bl, 0x42
    call disk_rw_lba
    jc .fail

    ; 3. 앞쪽 빈 슬롯(def_write)으로 16KB 쓰기
    movzx eax, word [def_write]
    dec eax
    shl eax, 5
    add eax, [fs_data_lba]
    mov di, EXEC_BUF
    mov cx, 32
    mov bl, 0x43
    call disk_rw_lba
    jc .fail

    ; 4. 대상 디렉토리 엔트리 기록
    mov ax, [def_write]
    call ensure_dir_sec
    jc .fail
    call get_slot_ptr
    mov si, def_entry
    mov di, bx
    mov cx, 16
    cld
    rep movsb
    call write_cur_dir_sec
    jc .fail

    ; 5. 원본 디렉토리 엔트리 0x00 초기화
    mov ax, [def_read]
    call ensure_dir_sec
    jc .fail
    call get_slot_ptr
    mov di, bx
    mov cx, 16
    xor al, al
    cld
    rep stosb
    call write_cur_dir_sec
    jc .fail

    ; 6. 비워진 원본 16KB 슬롯 0x00 정리
    mov ax, [def_read]
    call zero_data_slot
    jc .fail

    inc word [def_moved]

.no_move:
    inc word [def_write]

.next_read:
    inc dword [sm_prog_cur]
    cmp byte [sm_ui_active], 1
    jne .chk_end
    call sm_update_bar
.chk_end:
    mov ax, [def_read]
    cmp ax, [fs_max_slots]
    je .ok
    inc word [def_read]
    jmp .scan_loop

.ok:
    clc
    jmp .ret
.fail:
    stc
.ret:
    pop es
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop eax
    ret

zero_data_slot:
    push eax
    push bx
    push cx
    push dx
    push di
    push es

    mov dx, ax
    push ds
    pop es
    mov di, EXEC_BUF
    mov cx, 0x2000
    xor ax, ax
    cld
    rep stosw

    movzx eax, dx
    dec eax
    shl eax, 5
    add eax, [fs_data_lba]
    mov di, EXEC_BUF
    mov cx, 32
    mov bl, 0x43
    call disk_rw_lba

    pop es
    pop di
    pop dx
    pop cx
    pop bx
    pop eax
    ret

; =========================================================
; BF64TUI Direct VGA(0xB800) 공용 TUI 헬퍼
; =========================================================
sm_draw_base:
    push si
    mov cx, 0x0000
    mov dx, 0x174F
    mov al, ' '
    mov bl, SM_TEXT
    call sm_fill_rect

    mov dx, 0x0001
    mov bl, SM_HDR
    mov si, [sm_win_title]
    call sm_print_at

    mov cx, 0x0100
    mov dh, 0x01
    mov al, 0xCD
    mov bl, SM_TEXT
    call sm_fill_rect

    pop si
    call sm_draw_status
    ret

sm_draw_status:
    push si
    mov cx, 0x1800
    mov dx, 0x184F
    mov al, ' '
    mov bl, SM_BAR
    call sm_fill_rect
    mov dx, 0x1802
    mov bl, SM_BAR
    pop si
    call sm_print_at
    ret

sm_draw_dialog:
    mov cx, 0x0407
    mov dx, 0x1448
    mov bl, SM_HDR
    mov bh, SM_TEXT
    call sm_draw_box

    mov dh, 5
    mov bl, SM_HDR
    mov si, [sm_box_title]
    call sm_print_center

    mov cx, 0x0608
    mov dx, 0x0647
    mov al, 0xC4
    mov bl, SM_TEXT
    call sm_fill_rect
    ret

sm_clear_dialog:
    mov cx, 0x0708
    mov dx, 0x1347
    mov al, ' '
    mov bl, SM_TEXT
    jmp sm_fill_rect

; dh=행, bl=속성, si=NULL 종료 문자열 -> 각 줄을 80컬럼 중앙에 정렬 출력
sm_print_center:
    push ax
    push cx
    push dx
    push si
    push di
.line_loop:
    mov di, si
    xor cx, cx
.len_loop:
    mov al, [di]
    test al, al
    jz .got_len
    cmp al, 0x0A
    je .got_len
    inc di
    inc cx
    jmp .len_loop
.got_len:
    mov ax, 80
    sub ax, cx
    jns .col_ok
    xor ax, ax
.col_ok:
    shr ax, 1
    mov dl, al
    push di
    call sm_calc_di
    push es
    mov ax, 0xB800
    mov es, ax
    mov ah, bl
    cld
.out_loop:
    test cx, cx
    jz .out_done
    lodsb
    stosw
    dec cx
    jmp .out_loop
.out_done:
    pop es
    pop di
    mov si, di
    cmp byte [si], 0x0A
    jne .done
    inc si
    inc dh
    jmp .line_loop
.done:
    pop di
    pop si
    pop dx
    pop cx
    pop ax
    ret

sm_draw_bar_frame:
    push ax
    push cx
    push dx
    push di
    push es
    mov ax, 0xB800
    mov es, ax
    mov ah, SM_TEXT

    mov dx, 0x0D0E
    call sm_calc_di
    mov al, 0xDA
    stosw
    mov cx, 50
    mov al, 0xC4
    rep stosw
    mov al, 0xBF
    stosw

    mov dx, 0x0E0E
    call sm_calc_di
    mov al, 0xB3
    mov [es:di], ax
    mov dx, 0x0E41
    call sm_calc_di
    mov al, 0xB3
    mov [es:di], ax

    mov dx, 0x0F0E
    call sm_calc_di
    mov al, 0xC0
    stosw
    mov cx, 50
    mov al, 0xC4
    rep stosw
    mov al, 0xD9
    stosw

    pop es
    pop di
    pop dx
    pop cx
    pop ax
    ret

sm_update_bar:
    push eax
    push ebx
    push cx
    push edx
    push si
    push di
    push es

    mov eax, [sm_prog_cur]
    cmp eax, [sm_prog_tot]
    jb .calc
    mov ax, 100
    jmp .chk_chg
.calc:
    mov ebx, 100
    mul ebx
    div dword [sm_prog_tot]
.chk_chg:
    cmp ax, [sm_last_pct]
    je .done
    mov [sm_last_pct], ax
    push ax

    mov cx, 0x0C0A
    mov dx, 0x0C45
    mov al, ' '
    mov bl, SM_HDR
    call sm_fill_rect

    pop ax
    push ax
    mov di, SM_LINE_BUF
    movzx eax, ax
    call sm_u32_cat
    mov si, sm_pct_sym
    call sm_str_cat
    mov dh, 12
    mov bl, SM_HDR
    mov si, SM_LINE_BUF
    call sm_print_center

    pop ax
    shr ax, 1                   ; 0..50 칸
    mov cx, ax
    mov ax, 0xB800
    mov es, ax
    mov dx, 0x0E0F
    call sm_calc_di
    mov dx, 50
    sub dx, cx
    test cx, cx
    jz .empty_bar
    mov ah, SM_YEL
    mov al, 0xDB
    rep stosw
.empty_bar:
    mov cx, dx
    test cx, cx
    jz .bar_txt
    mov ah, SM_TEXT
    mov al, 0xB0
    rep stosw

.bar_txt:
    mov cx, 0x100A
    mov dx, 0x1045
    mov al, ' '
    mov bl, SM_TEXT
    call sm_fill_rect

    mov di, SM_LINE_BUF
    mov si, sm_lbl_prog
    call sm_str_cat
    mov eax, [sm_prog_cur]
    call sm_u32_cat
    mov si, sm_slash
    call sm_str_cat
    mov eax, [sm_prog_tot]
    call sm_u32_cat
    mov dh, 16
    mov bl, SM_TEXT
    mov si, SM_LINE_BUF
    call sm_print_center

.done:
    pop es
    pop di
    pop si
    pop edx
    pop cx
    pop ebx
    pop eax
    ret

sm_calc_di:
    push ax
    push dx
    mov al, dh
    mov ah, 80
    mul ah
    xor dh, dh
    add ax, dx
    shl ax, 1
    mov di, ax
    pop dx
    pop ax
    ret

sm_fill_rect:
    push ax
    push bx
    push cx
    push dx
    push di
    push es

    mov ah, bl
    push ax
    mov ax, 0xB800
    mov es, ax
    pop ax

    sub dl, cl
    inc dl
    mov bl, dh
    sub bl, ch
    inc bl
    mov dh, ch
.row_loop:
    push dx
    mov dl, cl
    call sm_calc_di
    pop dx
    push cx
    mov cl, dl
    xor ch, ch
    rep stosw
    pop cx
    inc dh
    dec bl
    jnz .row_loop

    pop es
    pop di
    pop dx
    pop cx
    pop bx
    pop ax
    ret

sm_draw_box:
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    push es

    push bx
    mov bl, bh
    mov al, ' '
    call sm_fill_rect
    pop bx

    mov ax, 0xB800
    mov es, ax

    mov al, dl
    sub al, cl
    dec al
    xor ah, ah
    mov si, ax
    mov ah, bl

    push dx
    mov dh, ch
    mov dl, cl
    call sm_calc_di
    pop dx
    mov al, 0xC9
    stosw
    push cx
    mov cx, si
    mov al, 0xCD
    rep stosw
    pop cx
    mov al, 0xBB
    stosw

    push dx
    mov dl, cl
    call sm_calc_di
    pop dx
    mov al, 0xC8
    stosw
    push cx
    mov cx, si
    mov al, 0xCD
    rep stosw
    pop cx
    mov al, 0xBC
    stosw

    mov bh, ch
    inc bh
.v_loop:
    cmp bh, dh
    jae .v_done
    push dx
    mov dh, bh
    mov dl, cl
    call sm_calc_di
    mov al, 0xBA
    mov [es:di], ax
    pop dx
    push dx
    mov dh, bh
    call sm_calc_di
    mov al, 0xBA
    mov [es:di], ax
    pop dx
    inc bh
    jmp .v_loop
.v_done:
    pop es
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

sm_print_at:
    push ax
    push cx
    push di
    push es
    mov ax, 0xB800
    mov es, ax
    mov cl, dl
    call sm_calc_di
    mov ah, bl
.loop:
    lodsb
    test al, al
    jz .done
    cmp al, 0x0A
    je .nl
    stosw
    inc dl
    jmp .loop
.nl:
    inc dh
    mov dl, cl
    call sm_calc_di
    jmp .loop
.done:
    pop es
    pop di
    pop cx
    pop ax
    ret

sm_u32_to_str:
    push eax
    push ebx
    push cx
    push edx
    push di
    push es
    push ds
    pop es
    mov ebx, 10
    xor cx, cx
.div_loop:
    xor edx, edx
    div ebx
    push dx
    inc cx
    test eax, eax
    jnz .div_loop
    mov di, sm_num_buf
.pop_loop:
    pop ax
    add al, '0'
    stosb
    loop .pop_loop
    mov byte [di], 0
    mov si, sm_num_buf
    pop es
    pop di
    pop edx
    pop cx
    pop ebx
    pop eax
    ret

; --- 플로피 지오메트리 및 총 섹터 수 조회 ---
get_floppy_geom:
    push ebx
    push cx
    push edx
    push di
    push es

    mov ah, 0x08
    mov dl, [cur_drive]
    xor di, di
    mov es, di
    int 0x13
    pop es
    jc .fail

    cmp [cur_drive], dl
    jae .fail
    mov ax, cx
    and ax, 0x003F
    jz .fail
    mov [flp_spt], ax

    movzx bx, dh
    inc bx
    mov [flp_heads], bx

    mov al, cl
    shr al, 6
    mov ah, al
    mov al, ch
    inc ax
    movzx eax, ax
    movzx ebx, word [flp_heads]
    mul ebx
    movzx ebx, word [flp_spt]
    mul ebx
    clc
    jmp .done
.fail:
    stc
.done:
    pop di
    pop edx
    pop cx
    pop ebx
    ret

; --- 드라이브 접두사 의무 파싱 ---
parse_drive_prefix:
    push ax
    mov al, [si]
    cmp al, 'a'
    jb .chk_alpha
    cmp al, 'z'
    ja .chk_alpha
    sub al, 32
.chk_alpha:
    cmp al, 'A'
    jb .fail
    cmp al, 'Z'
    ja .fail
    cmp byte [si + 1], ':'
    jne .fail

    add si, 2
    call sm_apply_drive
    clc
    pop ax
    ret

.fail:
    stc
    pop ax
    ret

; --- 슈퍼블록 & 디렉토리 헬퍼 ---
load_superblock:
    push eax
    push bx
    push cx
    push di
    cmp byte [cur_drive], 0x80
    jb .read_sb
    cmp dword [cur_base_lba], 0
    je .fail
.read_sb:
    mov eax, [cur_base_lba]
    mov di, DIR_BUF
    mov cx, 1
    mov bl, 0x42
    call disk_rw_lba
    jc .fail
    cmp dword [DIR_BUF], "BF64"
    jne .fail
    cmp byte [DIR_BUF + 4], 2
    jne .fail
    mov eax, [DIR_BUF + 12]
    mov [fs_data_lba], eax
    mov ax, [DIR_BUF + 16]
    test ax, ax
    jz .fail
    mov [fs_max_slots], ax
    mov word [cached_sec], 0xFFFF
    clc
    jmp .done
.fail:
    stc
.done:
    pop di
    pop cx
    pop bx
    pop eax
    ret

ensure_dir_sec:
    push eax
    push bx
    push cx
    push di
    dec ax
    shr ax, 5
    cmp ax, [cached_sec]
    je .ok
    mov [cached_sec], ax
    movzx eax, ax
    add eax, [cur_base_lba]
    inc eax
    mov di, DIR_BUF
    mov cx, 1
    mov bl, 0x42
    call disk_rw_lba
    jc .err
.ok:
    clc
    jmp .done
.err:
    mov word [cached_sec], 0xFFFF
    stc
.done:
    pop di
    pop cx
    pop bx
    pop eax
    ret

write_cur_dir_sec:
    push eax
    push bx
    push cx
    push di
    movzx eax, word [cached_sec]
    add eax, [cur_base_lba]
    inc eax
    mov di, DIR_BUF
    mov cx, 1
    mov bl, 0x43
    call disk_rw_lba
    pop di
    pop cx
    pop bx
    pop eax
    ret

get_slot_ptr:
    push ax
    dec ax
    and ax, 31
    shl ax, 4
    add ax, DIR_BUF
    mov bx, ax
    pop ax
    ret

find_slot_and_free:
    mov word [first_free_slot], 0
    mov word [cached_sec], 0xFFFF
    mov ax, 1
.scan:
    call ensure_dir_sec
    jc .io_err
    call get_slot_ptr
    cmp byte [bx], 1
    je .chk_name
    cmp word [first_free_slot], 0
    jne .next
    mov [first_free_slot], ax
    jmp .next
.chk_name:
    push si
    push di
    push cx
    lea si, [bx + 1]
    mov di, name_buf
    mov cx, 12
    repe cmpsb
    pop cx
    pop di
    pop si
    je .found
.next:
    cmp ax, [fs_max_slots]
    je .not_found
    inc ax
    jmp .scan
.found:
    clc
    ret
.not_found:
    xor dx, dx
    stc
    ret
.io_err:
    mov dx, 1
    stc
    ret

; 통합 디스크 읽기/쓰기 (HDD=LBA 확장, Floppy=CHS 자동 변환 + 디스크 교체 재시도)
disk_rw_lba:
    push eax
    push ebx
    push cx
    push edx
    push si
    push di
    push bp
    push es

    mov [disk_op], bl
    mov [dap_lba], eax
    mov [dap_off], di
    mov [disk_cnt], cx

    xor ax, ax
    mov es, ax

    cmp byte [cur_drive], 0x80
    jb .floppy_mode

    mov word [dap], 0x0010
    mov dword [dap_lba + 4], 0
    mov word [dap_seg], 0

    mov ah, 0x41
    mov bx, 0x55AA
    mov dl, [cur_drive]
    int 0x13
    jc .fail
    cmp bx, 0xAA55
    jne .fail

.hdd_loop:
    mov word [dap_cnt], 1
    mov ah, [disk_op]
    xor al, al
    mov dl, [cur_drive]
    mov si, dap
    int 0x13
    jc .fail
    inc dword [dap_lba]
    add word [dap_off], 512
    dec word [disk_cnt]
    jnz .hdd_loop
    clc
    jmp .done

.floppy_mode:
    call get_floppy_geom
    jc .fail

.flp_sec_loop:
    mov bp, 3
.flp_retry:
    mov eax, [dap_lba]
    xor edx, edx
    movzx ebx, word [flp_spt]
    div ebx
    mov cl, dl
    inc cl
    xor edx, edx
    movzx ebx, word [flp_heads]
    div ebx
    mov ch, al
    shl ah, 6
    or cl, ah
    mov dh, dl

    mov ah, 0x02
    cmp byte [disk_op], 0x42
    je .flp_op_ok
    mov ah, 0x03
.flp_op_ok:
    mov al, 1
    mov dl, [cur_drive]
    mov bx, [dap_off]
    int 0x13
    jnc .flp_sec_ok

    xor ah, ah
    mov dl, [cur_drive]
    int 0x13
    dec bp
    jnz .flp_retry
    jmp .fail

.flp_sec_ok:
    inc dword [dap_lba]
    add word [dap_off], 512
    dec word [disk_cnt]
    jnz .flp_sec_loop
    clc
    jmp .done

.fail:
    stc
.done:
    pop es
    pop bp
    pop di
    pop si
    pop edx
    pop cx
    pop ebx
    pop eax
    ret

parse_filename:
    push di
    push cx
    push ax
    mov di, name_buf
    mov cx, 13
    xor al, al
    rep stosb
.skip_sp:
    cmp byte [si], ' '
    jne .check_quote
    inc si
    jmp .skip_sp
.check_quote:
    xor ah, ah
    cmp byte [si], '"'
    jne .parse_drv
    mov ah, 1
    inc si
.parse_drv:
    call parse_drive_prefix
    jc .syntax_fail

    mov di, name_buf
    xor cx, cx
.char_loop:
    mov al, [si]
    test al, al
    jz .end_of_str
    test ah, ah
    jnz .quoted_mode
    cmp al, ' '
    je .unquoted_end
    cmp al, ','
    je .unquoted_end
    cmp al, '"'
    je .syntax_fail
    jmp .store_ch
.quoted_mode:
    cmp al, '"'
    je .quoted_close
.store_ch:
    cmp cx, 12
    jae .skip_extra
    cmp al, 'a'
    jb .no_upper
    cmp al, 'z'
    ja .no_upper
    sub al, 32
.no_upper:
    stosb
    inc cx
.skip_extra:
    inc si
    jmp .char_loop
.end_of_str:
    test ah, ah
    jnz .syntax_fail
    jmp .done_parse
.quoted_close:
    inc si
.unquoted_end:
.trail_sp:
    cmp byte [si], ' '
    jne .chk_trail_end
    inc si
    jmp .trail_sp
.chk_trail_end:
    cmp byte [si], 0
    jne .syntax_fail
.done_parse:
    test cx, cx
    jz .syntax_fail
    clc
    jmp .ret
.syntax_fail:
    stc
.ret:
    pop ax
    pop cx
    pop di
    ret

parse_u16:
    push ax
    push bx
    push cx
    xor dx, dx
    xor cx, cx
.loop:
    mov al, [si]
    cmp al, '0'
    jb .done
    cmp al, '9'
    ja .done
    sub al, '0'
    xor ah, ah
    push ax
    mov ax, dx
    mov bx, 10
    mul bx
    test dx, dx
    jnz .ovf
    mov dx, ax
    pop ax
    add dx, ax
    jc .fail
    inc si
    inc cx
    jmp .loop
.ovf:
    pop ax
.fail:
    stc
    jmp .ret
.done:
    test cx, cx
    jz .fail
    clc
.ret:
    pop cx
    pop bx
    pop ax
    ret

; --- Brainfuck 인터프리터 (Classic 1:1 VM 기본 / Optimize 32KB IR VM 듀얼 모드) ---
exec_bf:
    cmp byte [vm_opt_mode], 0
    je exec_bf_manual
    push si
    call bf_compile_opt
    jc .opt_err
    add sp, 2
    jmp exec_bf_opt
.opt_err:
    pop si
    cmp al, 1
    jne exec_bf_manual          ; 32KB IR 작업 영역 초과 시 기존 1:1 VM으로 자동 폴백
    mov si, msg_syntax
    call print_str
    ret

; ---------------------------------------------------------
; bfint.cpp 최적화 알고리즘 기반 3-Pass Brainfuck -> IR 컴파일러 (OPT_SEG = 0x1800, 32KB)
;   Pass 1: 연속 +/- 및 >/< RLE 압축 (주석 건너뜀) + 괄호 매칭 검사
;   Pass 2: In-Place(di <= si) 단순 루프 패턴 단순화 (CLEAR, MUL+CLEAR, SCAN)
;   Pass 3: 최종 IR 기준 JZ / JNZ 점프 오프셋 O(1) 해결
; 입력: DS:SI = NUL 종료 Brainfuck 소스
; 출력: CF=0 성공 (OPT_SEG:OPT_IR_BASE, OP_END 종료, 최대 7,167 ops)
;       CF=1 실패 (AL=1 괄호 문법 오류, AL=2 28KB IR 작업 영역 초과)
; ---------------------------------------------------------
bf_compile_opt:
    push bx
    push cx
    push dx
    push si
    push di
    push bp
    push es

    mov ax, OPT_SEG
    mov es, ax

    ; === Pass 1: RLE 압축 & 1차 괄호 매칭 ===
    mov di, OPT_IR_BASE
    mov bp, OPT_STK_BASE

.p1_loop:
    mov al, [si]
    test al, al
    jz .p1_done
    cmp al, '+'
    je .p1_add
    cmp al, '-'
    je .p1_add
    cmp al, '>'
    je .p1_move
    cmp al, '<'
    je .p1_move
    cmp al, '.'
    je .p1_out
    cmp al, ','
    je .p1_in
    cmp al, '['
    je .p1_open
    cmp al, ']'
    je .p1_close
    inc si
    jmp .p1_loop

.p1_add:
    xor bl, bl
.p1_add_loop:
    mov al, [si]
    cmp al, '+'
    je .p1_add_inc
    cmp al, '-'
    je .p1_add_dec
    call is_bf_op_al
    jc .p1_add_emit
    inc si
    jmp .p1_add_loop
.p1_add_inc:
    inc bl
    inc si
    jmp .p1_add_loop
.p1_add_dec:
    dec bl
    inc si
    jmp .p1_add_loop
.p1_add_emit:
    test bl, bl
    jz .p1_loop
    cmp di, OPT_IR_MAX
    jae .ovf_err
    mov byte [es:di], OP_ADD
    mov [es:di + 1], bl
    mov word [es:di + 2], 0
    add di, 4
    jmp .p1_loop

.p1_move:
    xor bx, bx
.p1_mv_loop:
    mov al, [si]
    cmp al, '>'
    je .p1_mv_inc
    cmp al, '<'
    je .p1_mv_dec
    call is_bf_op_al
    jc .p1_mv_emit
    inc si
    jmp .p1_mv_loop
.p1_mv_inc:
    inc bx
    inc si
    jmp .p1_mv_loop
.p1_mv_dec:
    dec bx
    inc si
    jmp .p1_mv_loop
.p1_mv_emit:
    and bx, 0x7FFF
    jz .p1_loop
    cmp di, OPT_IR_MAX
    jae .ovf_err
    mov word [es:di], OP_MOVE
    mov [es:di + 2], bx
    add di, 4
    jmp .p1_loop

.p1_out:
    inc si
    cmp di, OPT_IR_MAX
    jae .ovf_err
    mov word [es:di], OP_OUT
    mov word [es:di + 2], 0
    add di, 4
    jmp .p1_loop

.p1_in:
    inc si
    cmp di, OPT_IR_MAX
    jae .ovf_err
    mov word [es:di], OP_IN
    mov word [es:di + 2], 0
    add di, 4
    jmp .p1_loop

.p1_open:
    inc si
    cmp bp, OPT_STK_MAX
    jae .ovf_err
    cmp di, OPT_IR_MAX
    jae .ovf_err
    mov [es:bp], di
    add bp, 2
    mov word [es:di], OP_JZ
    mov word [es:di + 2], 0
    add di, 4
    jmp .p1_loop

.p1_close:
    inc si
    cmp bp, OPT_STK_BASE
    je .syntax_err
    cmp di, OPT_IR_MAX
    jae .ovf_err
    sub bp, 2
    mov bx, [es:bp]
    mov [es:bx + 2], di
    mov word [es:di], OP_JNZ
    mov [es:di + 2], bx
    add di, 4
    jmp .p1_loop

.p1_done:
    cmp bp, OPT_STK_BASE
    jne .syntax_err
    mov [opt_p1_end], di

    ; === Pass 2: In-Place 루프 패턴 단순화 (SCAN / CLEAR / MUL+CLEAR, di <= si 보장) ===
    mov si, OPT_IR_BASE
    mov di, OPT_IR_BASE

.p2_loop:
    cmp si, [opt_p1_end]
    jae .p2_done
    cmp byte [es:si], OP_JZ
    jne .p2_copy_one

    mov dx, [es:si + 2]         ; dx = 매칭되는 OP_JNZ 오프셋

    ; 패턴 A: [>], [<<] 등 본문이 단일 OP_MOVE 인 루프 -> OP_SCAN
    mov ax, si
    add ax, 8
    cmp ax, dx
    jne .p2_chk_simple
    cmp byte [es:si + 4], OP_MOVE
    jne .p2_chk_simple
    mov bx, [es:si + 6]
    mov word [es:di], OP_SCAN
    mov [es:di + 2], bx
    add di, 4
    mov si, dx
    add si, 4
    jmp .p2_loop

.p2_chk_simple:
    ; 본문이 오직 OP_ADD / OP_MOVE 로만 구성된 단순 루프인지 확인
    lea bx, [si + 4]
.p2_scan_body:
    cmp bx, dx
    jae .p2_build_map
    mov al, [es:bx]
    cmp al, OP_ADD
    je .p2_scan_next
    cmp al, OP_MOVE
    jne .p2_copy_one
.p2_scan_next:
    add bx, 4
    jmp .p2_scan_body

.p2_build_map:
    mov word [opt_map_cnt], 0
    xor cx, cx                  ; cx = 현재 상대 오프셋 (mod 32768)
    lea bx, [si + 4]
.p2_map_loop:
    cmp bx, dx
    jae .p2_map_done
    cmp byte [es:bx], OP_MOVE
    jne .p2_map_add
    add cx, [es:bx + 2]
    and cx, 0x7FFF
    jmp .p2_map_next
.p2_map_add:
    mov al, [es:bx + 1]
    call opt_map_add
    jc .p2_copy_one             ; 델타 맵 초과 시 일반 루프 유지
.p2_map_next:
    add bx, 4
    jmp .p2_map_loop

.p2_map_done:
    test cx, cx
    jnz .p2_copy_one            ; 루프 종료 후 포인터 순이동이 0이어야 함

    mov bx, [opt_map_cnt]
    test bx, bx
    jz .p2_copy_one
    mov bp, OPT_MAP_BASE
    xor ax, ax                  ; ah=has_self, al=self_delta
    xor cx, cx                  ; cx=nonzero_others
.p2_ana_loop:
    cmp word [es:bp], 0
    jne .p2_ana_other
    mov ah, 1
    mov al, [es:bp + 2]
    jmp .p2_ana_next
.p2_ana_other:
    cmp byte [es:bp + 2], 0
    je .p2_ana_next
    inc cx
.p2_ana_next:
    add bp, 4
    dec bx
    jnz .p2_ana_loop

    test ah, ah
    jz .p2_copy_one
    test cx, cx
    jnz .p2_chk_mul

    ; 패턴 B: [-] 또는 [+] (self_delta == -1 또는 +1) -> OP_CLEAR
    cmp al, 0xFF
    je .p2_emit_clear
    cmp al, 0x01
    jne .p2_copy_one

.p2_emit_clear:
    mov word [es:di], OP_CLEAR
    mov word [es:di + 2], 0
    add di, 4
    mov si, dx
    add si, 4
    jmp .p2_loop

.p2_chk_mul:
    ; 패턴 C: [->+++>+<<] 복사/곱셈 루프 (self_delta == -1) -> OP_MUL... + OP_CLEAR
    cmp al, 0xFF
    jne .p2_copy_one

    mov bx, [opt_map_cnt]
    mov bp, OPT_MAP_BASE
.p2_mul_loop:
    mov ax, [es:bp]
    test ax, ax
    jz .p2_mul_next
    mov cl, [es:bp + 2]
    test cl, cl
    jz .p2_mul_next
    mov byte [es:di], OP_MUL
    mov [es:di + 1], cl
    mov [es:di + 2], ax
    add di, 4
.p2_mul_next:
    add bp, 4
    dec bx
    jnz .p2_mul_loop
    jmp .p2_emit_clear

.p2_copy_one:
    mov eax, [es:si]
    mov [es:di], eax
    add si, 4
    add di, 4
    jmp .p2_loop

.p2_done:
    mov dword [es:di], 0        ; OP_END 종료 마커
    mov [opt_p2_end], di

    ; === Pass 3: 최종 IR 기준 JZ / JNZ 점프 오프셋 해결 ===
    mov si, OPT_IR_BASE
    mov bp, OPT_STK_BASE
.p3_loop:
    cmp si, [opt_p2_end]
    jae .ok
    mov al, [es:si]
    cmp al, OP_JZ
    je .p3_open
    cmp al, OP_JNZ
    jne .p3_next
    sub bp, 2
    mov bx, [es:bp]
    lea ax, [si + 4]
    mov [es:bx + 2], ax         ; JZ 점프 대상 = JNZ 다음 명령어
    lea ax, [bx + 4]
    mov [es:si + 2], ax         ; JNZ 점프 대상 = JZ 다음 명령어
    jmp .p3_next
.p3_open:
    mov [es:bp], si
    add bp, 2
.p3_next:
    add si, 4
    jmp .p3_loop

.ok:
    xor al, al
    clc
    jmp .ret
.syntax_err:
    mov al, 1
    stc
    jmp .ret
.ovf_err:
    mov al, 2
    stc
.ret:
    pop es
    pop bp
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    ret

; 단순 루프 델타 맵 누적 헬퍼 (ES=OPT_SEG, CX=off, AL=delta)
opt_map_add:
    push bx
    push dx
    push bp
    mov dx, [opt_map_cnt]
    mov bp, OPT_MAP_BASE
    test dx, dx
    jz .not_found
.search:
    cmp [es:bp], cx
    je .found
    add bp, 4
    dec dx
    jnz .search
.not_found:
    cmp word [opt_map_cnt], OPT_MAP_MAX
    jae .full
    mov [es:bp], cx
    mov [es:bp + 2], al
    mov byte [es:bp + 3], 0
    inc word [opt_map_cnt]
    clc
    jmp .ret
.found:
    add [es:bp + 2], al
    clc
    jmp .ret
.full:
    stc
.ret:
    pop bp
    pop dx
    pop bx
    ret

; AL이 NUL 또는 BF 연산자(+-><.,[])이면 CF=1, 주석 문자이면 CF=0
is_bf_op_al:
    push cx
    push di
    push es
    push ds
    pop es
    mov di, bf_ops_str
    mov cx, 9
    cld
    repne scasb
    pop es
    pop di
    pop cx
    je .yes
    clc
    ret
.yes:
    stc
    ret

; ---------------------------------------------------------
; 고속 32KB 최적화 IR 실행 엔진
;   DS=OPT_SEG (세그먼트 프리픽스 없는 lodsw 페치)
;   ES=TAPE_SEG (32KB 원형 테이프)
;   GS=0x0040 (BIOS 키보드 버퍼 head==tail 2명령어 무부하 ESC 감시)
;   CS:opt_jt (O(1) 점프 테이블 디스패치)
; ---------------------------------------------------------
exec_bf_opt:
    push ds
    push es
    push gs

    mov ax, TAPE_SEG
    mov es, ax
    xor di, di
    mov cx, 0x4000
    xor ax, ax
    cld
    rep stosw
    xor di, di

    mov ax, 0x0040
    mov gs, ax
    mov ax, OPT_SEG
    mov ds, ax
    mov si, OPT_IR_BASE

opt_loop:
    lodsw                       ; al = op*2, ah = arg2 (delta / factor)
    mov bx, [si]                ; bx = arg1 (offset / stride / target)
    add si, 2
    movzx bp, al
    jmp word [cs:opt_jt + bp]

opt_h_add:
    add [es:di], ah
    jmp opt_loop

opt_h_move:
    add di, bx
    and di, 0x7FFF
    jmp opt_loop

opt_h_clear:
    mov byte [es:di], 0
    jmp opt_loop

opt_h_mul:
    mov al, [es:di]
    test al, al
    jz opt_loop
    mul ah
    mov bp, di
    add bp, bx
    and bp, 0x7FFF
    add [es:bp], al
    jmp opt_loop

opt_h_scan:
    xor cl, cl
.scan_fast:
    cmp byte [es:di], 0
    je opt_loop
    add di, bx
    and di, 0x7FFF
    dec cl
    jnz .scan_fast
    mov dx, [gs:0x001A]
    cmp dx, [gs:0x001C]
    je .scan_fast
    call opt_chk_esc
    jc opt_h_brk
    jmp .scan_fast

opt_h_jz:
    cmp byte [es:di], 0
    jne opt_loop
    mov si, bx
    jmp opt_loop

opt_h_jnz:
    cmp byte [es:di], 0
    je opt_loop
    mov si, bx
    mov dx, [gs:0x001A]
    cmp dx, [gs:0x001C]
    je opt_loop
    call opt_chk_esc
    jc opt_h_brk
    jmp opt_loop

opt_h_out:
    mov dx, [gs:0x001A]
    cmp dx, [gs:0x001C]
    je .out_go
    call opt_chk_esc
    jc opt_h_brk
.out_go:
    xor ax, ax
    mov ds, ax
    mov al, [es:di]
    call put_char
    jmp opt_reseg

opt_h_in:
    xor ax, ax
    mov ds, ax
.in_wait:
    xor ah, ah
    int 0x16
    cmp al, 0x1B
    je opt_h_brk
    test al, al
    jz .in_wait
    cmp al, 0x0D
    jne .in_ok
    mov al, 0x0A
.in_ok:
    mov [es:di], al
    call put_char
opt_reseg:
    mov ax, 0x0040
    mov gs, ax
    mov ax, OPT_SEG
    mov ds, ax
    jmp opt_loop

opt_chk_esc:
    push ds
    xor ax, ax
    mov ds, ax
    call check_esc
    pop ds
    ret

opt_h_brk:
    pop gs
    pop es
    pop ds
    mov si, msg_brk
    call print_str
    ret

opt_h_end:
    pop gs
    pop es
    pop ds
    mov al, 0x0A
    call put_char
    ret

align 2, db 0
opt_jt:
    dw opt_h_end                ; 0  OP_END
    dw opt_h_add                ; 2  OP_ADD
    dw opt_h_move               ; 4  OP_MOVE
    dw opt_h_clear              ; 6  OP_CLEAR
    dw opt_h_mul                ; 8  OP_MUL
    dw opt_h_scan               ; 10 OP_SCAN
    dw opt_h_out                ; 12 OP_OUT
    dw opt_h_in                 ; 14 OP_IN
    dw opt_h_jz                 ; 16 OP_JZ
    dw opt_h_jnz                ; 18 OP_JNZ

; --- 기존 1:1 Brainfuck 인터프리터 (Classic Mode / 폴백용) ---
exec_bf_manual:
    push es
    mov bp, si
    mov ax, TAPE_SEG
    mov es, ax
    xor di, di
    mov cx, 0x8000
    xor al, al
    rep stosb
    xor di, di

.exec_loop:
    call check_esc
    jc .brk_exit
    lodsb
    test al, al
    jz .done
    cmp al, '>'
    je .op_right
    cmp al, '<'
    je .op_left
    cmp al, '+'
    je .op_inc
    cmp al, '-'
    je .op_dec
    cmp al, '.'
    je .op_out
    cmp al, ','
    je .op_in
    cmp al, '['
    je .op_jz
    cmp al, ']'
    je .op_jnz
    jmp .exec_loop

.op_right:
    inc di
    and di, 0x7FFF
    jmp .exec_loop
.op_left:
    dec di
    and di, 0x7FFF
    jmp .exec_loop
.op_inc:
    inc byte [es:di]
    jmp .exec_loop
.op_dec:
    dec byte [es:di]
    jmp .exec_loop
.op_out:
    mov al, [es:di]
    call put_char
    jmp .exec_loop
.op_in:
    xor ah, ah
    int 0x16
    cmp al, 0x1B
    je .brk_exit
    test al, al
    jz .op_in
    cmp al, 0x0D
    jne .in_ok
    mov al, 0x0A
.in_ok:
    mov [es:di], al
    call put_char
    jmp .exec_loop
.op_jz:
    cmp byte [es:di], 0
    jne .exec_loop
    mov cx, 1
.find_close:
    lodsb
    test al, al
    jz .bracket_err
    cmp al, '['
    jne .not_open
    inc cx
.not_open:
    cmp al, ']'
    jne .find_close
    loop .find_close
    jmp .exec_loop
.op_jnz:
    cmp byte [es:di], 0
    je .exec_loop
    dec si
    mov cx, 1
.find_open:
    dec si
    cmp si, bp
    jb .bracket_err
    mov al, [si]
    cmp al, ']'
    jne .not_close
    inc cx
.not_close:
    cmp al, '['
    jne .find_open
    loop .find_open
    inc si
    jmp .exec_loop
.brk_exit:
    pop es
    mov si, msg_brk
    call print_str
    ret
.bracket_err:
    pop es
    mov si, msg_syntax
    call print_str
    ret
.done:
    pop es
    mov al, 0x0A
    call put_char
    ret

; --- OS 유틸리티 ---
check_esc:
    push ax
    push bx
    push dx
    push ds
    mov ax, 0x0040
    mov ds, ax
    cli
    mov bx, [0x001A]
    mov dx, [0x0082]
    test dx, dx
    jnz .scan
    mov dx, 0x003E
.scan:
    cmp bx, [0x001C]
    je .no_esc
    cmp byte [bx], 0x1B
    je .found
    add bx, 2
    cmp bx, dx
    jb .scan
    mov bx, [0x0080]
    test bx, bx
    jnz .scan
    mov bx, 0x001E
    jmp .scan
.found:
    mov ax, [0x001C]
    mov [0x001A], ax
    sti
    pop ds
    pop dx
    pop bx
    pop ax
    stc
    ret
.no_esc:
    sti
    pop ds
    pop dx
    pop bx
    pop ax
    clc
    ret

init_screen:
    cmp byte [shell_mode], 0
    jne .ext_mode
    mov ax, 0x0001              ; Classic BF64: 40x25 블루 스크린
    int 0x10
    mov ax, 0x1001
    mov bh, 0x09
    int 0x10
    mov ax, 0x0600
    mov bh, 0x19
    xor cx, cx
    mov dx, 0x1827
    int 0x10
    jmp .home
.ext_mode:
    mov ax, 0x0003              ; Extended Console: 80x25 검정 배경 + 흰 글씨
    int 0x10
    mov ax, 0x1001
    xor bh, bh
    int 0x10
    mov ax, 0x0600
    mov bh, 0x0F
    xor cx, cx
    mov dx, 0x184F
    int 0x10
.home:
    mov ah, 0x01
    mov cx, 0x0007
    int 0x10
    mov ah, 0x02
    xor bh, bh
    xor dx, dx
    int 0x10
    ret

print_shell_banner:
    mov si, msg_banner
    cmp byte [shell_mode], 0
    je .go
    mov si, msg_banner_ext
.go:
    jmp print_str

find_prog_end:
    mov di, PROG_START
.loop:
    cmp di, PROG_LIMIT
    jae .clamp
    xor ah, ah
    mov al, [di]
    test al, al
    jz .done
    add di, ax
    jmp .loop
.clamp:
    mov di, PROG_LIMIT
    mov byte [di], 0
.done:
    ret

match_cmd_exact:
    push si
    push di
    push ax
    call match_prefix
    jc match_cmd_fail
.skip_tail:
    cmp byte [si], ' '
    jne .chk_nul
    inc si
    jmp .skip_tail
.chk_nul:
    cmp byte [si], 0
    jne match_cmd_fail
    jmp match_cmd_ok

match_cmd_arg:
    push si
    push di
    push ax
    call match_prefix
    jc match_cmd_fail
    mov al, [si]
    test al, al
    jz match_cmd_ok
    cmp al, ' '
    je match_cmd_ok
    cmp al, '"'
    je match_cmd_ok
match_cmd_fail:
    pop ax
    pop di
    pop si
    clc
    ret
match_cmd_ok:
    pop ax
    pop di
    add sp, 2
    stc
    ret

match_prefix:
    mov al, [di]
    test al, al
    jz .mp_ok
    mov ah, [si]
    cmp ah, 'a'
    jb .mp_cmp
    cmp ah, 'z'
    ja .mp_cmp
    sub ah, 32
.mp_cmp:
    cmp ah, al
    jne .mp_fail
    inc si
    inc di
    jmp match_prefix
.mp_ok:
    clc
    ret
.mp_fail:
    stc
    ret

screen_bs:
    push ax
    push bx
    push cx
    push dx
    mov ah, 0x03
    xor bh, bh
    int 0x10
    dec dl
    jns .erase
    mov dl, 0
    test dh, dh
    jz .erase
    mov dl, 39
    cmp byte [shell_mode], 0
    je .bs_col_ok
    mov dl, 79
.bs_col_ok:
    dec dh
.erase:
    mov ah, 0x02
    int 0x10
    mov ax, 0x0A20
    mov cx, 1
    int 0x10
    pop dx
    pop cx
    pop bx
    pop ax
    ret

print_dec:
    push eax
    movzx eax, ax
    call print_dec32
    pop eax
    ret

print_dec32:
    push eax
    push ebx
    push cx
    push edx
    mov ebx, 10
    xor cx, cx
.div_loop:
    xor edx, edx
    div ebx
    push dx
    inc cx
    test eax, eax
    jnz .div_loop
.print_loop:
    pop ax
    add al, '0'
    call put_char
    loop .print_loop
    pop edx
    pop cx
    pop ebx
    pop eax
    ret

print_dec_pad:
    push ax
    push bx
    push cx
    push dx
    mov bx, 10
    xor cx, cx
.div_loop:
    xor dx, dx
    div bx
    push dx
    inc cx
    test ax, ax
    jnz .div_loop
    mov bx, cx
.print_loop:
    pop ax
    add al, '0'
    call put_char
    loop .print_loop
    mov cx, 6
    sub cx, bx
.pad_loop:
    mov al, ' '
    call put_char
    loop .pad_loop
    pop dx
    pop cx
    pop bx
    pop ax
    ret

put_char:
    push ax
    push bx
    push bp
    cmp al, 0x0A
    jne .raw
    mov al, 0x0D
    call .out
    mov al, 0x0A
.raw:
    call .out
    pop bp
    pop bx
    pop ax
    ret
.out:
    mov ah, 0x0E
    mov bx, 0x0009
    cmp byte [shell_mode], 0
    je .go
    mov bl, 0x0F
.go:
    int 0x10
    ret

print_str:
    lodsb
    test al, al
    jz .done
    call put_char
    jmp print_str
.done:
    ret

; --- OS 데이터 ---
align 4, db 0
dap:
    db 0x10, 0x00
dap_cnt:        dw 1
dap_off:        dw 0
dap_seg:        dw 0
dap_lba:        dd 0, 0

hdd_drive       db 0x80
cur_drive       db 0x80
part2_lba       dd 0
cur_base_lba    dd 0
fs_data_lba     dd 0
raw_sectors     dd 0
fs_max_slots    dw 0
cached_sec      dw 0xFFFF
first_free_slot dw 0
target_slot     dw 0
used_slots      dw 0
list_start      dw 0
list_end        dw 0xFFFF
flp_spt         dw 18
flp_heads       dw 2
disk_op         db 0
disk_cnt        dw 0
scan_cnt        db 0
scan_idx        db 0
post_fail       db 0
os_ram_kb       dw 0
def_write       dw 0
def_read        dw 0
def_moved       dw 0
def_cleaned     dw 0
def_entry       times 16 db 0
os_diag_pat     db "BF64POST"
name_buf        times 13 db 0

; BF64TUI 공용 상태 변수
sm_ui_active    db 0
sm_fmt_mode     db 0
sm_help_page    db 0
sm_set_cat      db 0
sm_set_sel      db 0
sm_drv_cnt      db 0
sm_drv_sel      db 0
sm_init_drv     db 0
sm_drv_ltr      db 'A'
sm_tmp_ltr      db 0
sm_cur_ent      dw 0
sm_win_title    dw 0
sm_box_title    dw 0
sm_drv_hint     dw 0
sm_dir_secs     dw 0
sm_last_pct     dw 0
sm_prog_cur     dd 0
sm_prog_tot     dd 0
sm_num_buf      times 12 db 0
sm_drv_ltr_str  db "A:", 0

; 시스템 설정 및 32KB 최적화 VM 상태 변수
vm_opt_mode     db 0            ; 0=Classic Mode (기본), 1=Optimize Mode (32KB IR)
shell_mode      db 0            ; 0=Classic BF64 (40x25 블루, 기본), 1=Extended (80x25 흑백 콘솔)
opt_p1_end      dw 0
opt_p2_end      dw 0
opt_map_cnt     dw 0

str_run         db "RUN", 0
str_list        db "LIST", 0
str_new         db "NEW", 0
str_cls         db "CLS", 0
str_help        db "HELP", 0
str_settings    db "SETTINGS", 0
str_config      db "CONFIG", 0
str_reboot      db "REBOOT", 0
str_shutdown    db "SHUTDOWN", 0
str_dir         db "DIR", 0
str_save        db "SAVE", 0
str_load        db "LOAD", 0
str_del         db "DEL", 0
str_scratch     db "SCRATCH", 0
str_format      db "FORMAT", 0
str_defrag      db "DEFRAG", 0

msg_banner      db "          **** BF64 v1.3 ****", 0x0A, 0x0A
                db "  64K SYSTEM RAM   32K TAPE + 32K VM", 0x0A, 0x0A, 0
msg_banner_ext  db "BF64 Operating System [Version 1.3]", 0x0A
                db "64K System RAM (32K Tape / 32K Optimizer)", 0x0A, 0
msg_con_hdr     db "BF64 v1.3 System Startup", 0
msg_con_sep     db "--------------------------------------------------", 0
msg_con_cpu     db "[1/4] Processor (80386+) .................... ", 0
msg_con_ram     db "[2/4] Base Memory ........................... ", 0
msg_con_mem     db "[3/4] Memory Test (up to 640 KB) ............ ", 0
msg_con_def     db "[4/4] System Volume (C:) Check .............. ", 0
msg_con_kb      db " KB ", 0
msg_p_ok        db "[OK]", 0
msg_p_fail      db "[FAIL]", 0
msg_p_skip      db "[SKIP]", 0
msg_def_lpar    db " (", 0
msg_def_mv      db " moved)", 0
msg_con_start   db "Starting BF64 v1.3...", 0
msg_post_halt   db "SYSTEM CHECK FAILED. SYSTEM HALTED.", 0
msg_safe_off    db "It is now safe to turn off your computer.", 0

msg_ready       db 0x0A, "READY.", 0x0A, 0
msg_oom         db 0x0A, "?OUT OF MEMORY ERROR", 0
msg_syntax      db 0x0A, "?SYNTAX ERROR", 0
msg_brk         db 0x0A, "BREAK", 0
msg_dev_err     db 0x0A, "?DEVICE NOT PRESENT ERROR", 0
msg_not_found   db 0x0A, "?FILE NOT FOUND ERROR", 0
msg_disk_full   db 0x0A, "?DISK FULL ERROR", 0
msg_not_exec    db 0x0A, "?NOT A BF64EXEC DISK", 0
msg_saving      db "SAVING ", 0
msg_searching   db "SEARCHING FOR ", 0
msg_loading     db "LOADING", 0x0A, 0
msg_deleted     db "DELETED ", 0
msg_drv_hdr     db "DRIVES (USED/TOTAL KB, SLOTS):", 0x0A, 0
msg_drv_sep     db ": ", 0
msg_kb_lpar     db "KB (", 0
msg_rpar_nl     db ")", 0x0A, 0
msg_unfmt       db "UNFORMATTED", 0
msg_bf64exec    db "BF64EXEC", 0
msg_sp_lpar     db " (", 0
msg_kb_rpar     db "KB)", 0
msg_no_disk     db "NO DISK", 0x0A, 0
msg_io_err      db "I/O ERROR", 0x0A, 0
msg_dir_hdr     db '0 "BF64 v1.3 VOLUME" 01 2A', 0x0A, 0
msg_dir_bf      db '" BF', 0x0A, 0
msg_free        db " SLOTS FREE.", 0x0A, 0

; BF64TUI 내부 창 및 공용 문자열 (화면 표시에는 BF64만 노출)
fmt_win_title   db "BF64 v1.3 - Disk Format", 0
fmt_box_title   db "Disk Format", 0
fmt_drv_hint    db "Select a drive and press ENTER to format.", 0
fmt_st_mode     db "UP/DOWN=Select  ENTER=Continue  1/2=Pick  ESC/BS=Back", 0
fmt_lbl_mode    db "Select format type:", 0

def_win_title   db "BF64 v1.3 - Disk Defragmenter", 0
def_box_title   db "Disk Defragmenter", 0
def_drv_hint    db "Select a drive and press ENTER to optimize.", 0

hlp_win_title   db "BF64 v1.3 - Command Reference", 0
hlp_box_title   db "Command Reference", 0
hlp_st_bar      db "LEFT/RIGHT/SPACE=Next Page   ESC=Close", 0
hlp_hdr_1       db "[Program Editor, Execution & System]", 0
hlp_hdr_2       db "[Storage & Disk Utilities]", 0
hlp_pg1_lbl     db "Page 1 of 2", 0
hlp_pg2_lbl     db "Page 2 of 2", 0
hlp_page_1:
    db "<N> <CODE>   Add/edit line (0..65535); <N> deletes", 0x0A
    db "LIST [N[-M]] Display program lines (ESC=BREAK)", 0x0A
    db "RUN          Execute program in memory", 0x0A
    db "RUN X:       Boot from bf64exec disk in drive X:", 0x0A
    db "NEW / CLS    Clear program memory / Clear screen", 0x0A
    db "SETTINGS     System Settings (alias: CONFIG)", 0x0A
    db "HELP         Open this Command Reference", 0x0A
    db "REBOOT/SHUTDOWN  Restart / Power off computer", 0x0A
    db "Direct Mode  Run Brainfuck operators immediately", 0
hlp_page_2:
    db "DIR          List detected drives and capacity", 0x0A
    db "DIR X:       List saved programs on drive X:", 0x0A
    db 'SAVE "X:NM"  Save program to a 16 KB disk slot', 0x0A
    db 'LOAD "X:NM"  Load program ("X:*"=1st, "X:$"=DIR)', 0x0A
    db 'DEL "X:NM"   Delete program slot (alias: SCRATCH)', 0x0A
    db "FORMAT [X:]  Format disk (protects C:/bf64exec)", 0x0A
    db "DEFRAG [X:]  Optimize disk layout (defragmenter)", 0x0A, 0x0A
    db "Operators: > < + - . , [ ] (32K Tape / 32K VM)", 0

bf_ops_str      db 0, "+-><.,[]"

set_win_title   db "BF64 v1.3 - System Settings", 0
set_box_title   db "System Settings", 0
set_int_win     db "BF64 v1.3 - Interpreter", 0
set_int_box     db "Interpreter", 0
set_sh_win      db "BF64 v1.3 - Shell Config", 0
set_sh_box      db "Shell Config", 0
set_st_cat      db "UP/DOWN=Select  ENTER/1/2=Open  ESC=Close", 0
set_st_sub      db "UP/DOWN=Select  ENTER/1/2=Save  ESC/BS=Back", 0
set_st_done     db "Press any key to continue.", 0
set_lbl_cat     db "Choose a configuration category:", 0
set_cat_int     db "[1] Interpreter", 0
set_cat_sh      db "[2] Shell Config", 0
set_lbl_int     db "Select Brainfuck interpreter engine:", 0
set_lbl_sh      db "Select shell display mode:", 0
set_cur_cls     db "Current: Classic (Standard 1:1 VM)", 0
set_cur_opt     db "Current: Optimize (32KB IR Engine)", 0
set_cur_sh0     db "Current: Classic BF64 (40x25 Blue)", 0
set_cur_sh1     db "Current: Extended (80x25 Console)", 0
set_opt_cls     db "[1] Classic  (Standard 1:1 Interpreter)", 0
set_opt_opt     db "[2] Optimize (32KB IR Optimizing Engine)", 0
set_opt_sh0     db "[1] Classic BF64 (40x25 Blue Screen)", 0
set_opt_sh1     db "[2] Extended     (80x25 Console)", 0
set_desc_cls    db "Standard step-by-step execution (Default).", 0
set_desc_opt    db "Pre-compiles loops via 32KB IR for speed.", 0
set_desc_sh0    db "Classic 40x25 blue BF64 display (Default).", 0
set_desc_sh1    db "80x25 black console, white left-aligned text.", 0
set_msg_saved   db "Configuration saved.", 0

rbt_win_title   db "BF64 v1.3 - Restart", 0
rbt_box_title   db "Restart Computer", 0
rbt_st_conf     db "Y=Restart   N/ESC=Cancel", 0
rbt_warn_1      db "WARNING: Unsaved changes in memory.", 0
rbt_warn_2      db "Any unsaved program in RAM will be lost.", 0
rbt_ask         db "Restart the computer now? [Y/N]", 0

sdn_win_title   db "BF64 v1.3 - Shut Down", 0
sdn_box_title   db "Shut Down Computer", 0
sdn_st_conf     db "Y=Shut Down   N/ESC=Cancel", 0
sdn_ask         db "Shut down the computer now? [Y/N]", 0

exe_win_title   db "BF64 v1.3 - Boot Disk", 0
exe_box_title   db "Boot bf64exec Media", 0
exe_st_conf     db "Y=Boot Disk   N/ESC=Cancel", 0
exe_warn_1      db "Bootable media (bf64exec) detected.", 0
exe_warn_2      db "System control will transfer to this disk.", 0
exe_ask         db "Boot from this bf64exec disk? [Y/N]", 0

sm_st_scan:
sm_msg_scan     db "Detecting storage devices... Please wait.", 0
sm_st_drv       db "UP/DOWN=Select  ENTER=Continue  R=Refresh  ESC=Close", 0
sm_st_conf_fmt  db "Y=Format   N/ESC=Cancel", 0
sm_st_conf_def  db "Y=Optimize   N/ESC=Cancel", 0
sm_st_busy      db "Working... Please wait.", 0
sm_st_done:
sm_press_key    db "Press any key to return to drive list.", 0
sm_lbl_dir_hdr  db "DETECTED DRIVES (USED/TOTAL KB, SLOTS):", 0
sm_sel_l        db "> ", 0
sm_txt_nodisk   db "NO MEDIA", 0
sm_txt_ioerr    db "I/O ERROR", 0
sm_tag_hdd_s    db " [HDD]", 0
sm_tag_flp_s    db " [FDD]", 0
sm_lbl_drv      db "Selected Drive : ", 0
sm_tag_hdd      db " (System Disk)", 0
sm_tag_flp      db " (Floppy Disk)", 0
sm_opt_qfmt     db "[1] Quick Format (Initialize File System)", 0
sm_opt_nfmt     db "[2] Full Format  (Erase & Verify All Sectors)", 0
sm_desc_qfmt    db "Quick: Initializes file system metadata only.", 0
sm_desc_nfmt    db "Full : Erases and verifies every disk sector.", 0
sm_desc_def     db "Compacts stored slots and clears unused space.", 0
sm_warn_erase   db "WARNING: Formatting erases all data on this drive!", 0
sm_conf_q       db "Format Type : Quick Format", 0
sm_conf_n       db "Format Type : Full Format", 0
sm_conf_ask_fmt db "Proceed with format? [Y/N]", 0
sm_conf_ask_def db "Optimize this drive now? [Y/N]", 0
sm_msg_w_q      db "Initializing file system (Quick Format)...", 0
sm_msg_w_n      db "Erasing all sectors (Full Format)...", 0
sm_msg_v_q      db "Verifying file system metadata...", 0
sm_msg_v_n      db "Verifying disk surface...", 0
sm_msg_def      db "Optimizing disk layout...", 0
sm_lbl_prog     db "Progress: ", 0
sm_slash        db " / ", 0
sm_pct_sym      db "%", 0
sm_done_fmt     db "Format completed successfully.", 0
sm_res_cap      db "Volume Capacity : ", 0
sm_res_slots    db " slots)", 0
sm_done_def     db "Disk optimization completed.", 0
sm_res_mv       db "Programs relocated : ", 0
sm_res_cln      db "Entries repaired   : ", 0
sm_err_prot     db "Access Denied: System drive (C:) cannot be formatted.", 0
sm_err_exec     db "Protected Media: Cannot format bf64exec disk.", 0
sm_err_def_exec db "Protected Media: Cannot defragment bf64exec disk.", 0
sm_err_io       db "Disk Error: Drive not ready or I/O failure.", 0
sm_err_vfy      db "Format Failed: Disk verification error.", 0
sm_err_def      db "Defrag Failed: Drive is unformatted or unreadable.", 0

times 16384 - ($ - $$) db 0


; =========================================================================
; SECTION 5 : 1.44MB 플로피 이미지 규격 패딩
; =========================================================================
section .pad follows=.hdd_os align=4
times 1474560 - (512 + 15360 + 512 + 16384) db 0
