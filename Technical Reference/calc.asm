[BITS 16]

; =========================================================================
; BF64 Calculator v1.0 (bf64exec Bootable Application - 1.44MB Floppy)
; 컴파일: nasm -f bin bf64calc.asm -o bf64calc.img
;
; 실행 방법:
;   1) BF64 OS에서 플로피 A:에 마운트 후 `RUN A:` 입력
;   2) 또는 BIOS/에뮬레이터에서 단독 플로피 부팅
;
; [.img 섹터 구성 - 1.44MB 플로피 규격]
;   LBA 0     (1섹터,   512B) : Stage 1 CHS 로더 ("bf64exec" 헤더, RAM 0x7C00)
;   LBA 1 ~ 8 (8섹터, 4096B)  : BF64 Calculator 본체 (RAM 0x7E00)
;   LBA 9 ~ 끝                : 1.44MB 플로피 규격 패딩
; =========================================================================

CALC_SECTORS equ 8

; =========================================================================
; SECTION 1 : Stage 1 - bf64exec 8086-Safe Multi-Track CHS 로더 (512B)
; =========================================================================
section .s1 vstart=0x7C00 align=4

    jmp short stage1
    nop
    db "bf64exec"

stage1:
    cli
    cld
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0x7C00
    sti

    mov [s1_drive], dl

    ; 드라이브 지오메트리 조회 (실패 시 1.44MB 기본값 18 SPT / 2 Heads 사용)
    mov ah, 0x08
    mov dl, [s1_drive]
    xor di, di
    mov es, di
    int 0x13
    jc .geom_def
    and cx, 0x003F
    jz .geom_def
    mov [s1_spt], cx
    xor ah, ah
    mov al, dh
    inc ax
    mov [s1_heads], ax

.geom_def:
    xor ax, ax
    mov es, ax
    mov word [s1_lba], 1
    mov word [s1_buf], 0x7E00
    mov word [s1_left], CALC_SECTORS

.load_next:
    mov bp, 3
.retry:
    mov ax, [s1_lba]
    xor dx, dx
    div word [s1_spt]
    mov cl, dl
    inc cl                      ; Sector (1-based)
    xor dx, dx
    div word [s1_heads]
    mov dh, dl                  ; Head
    mov ch, al                  ; Cylinder low 8 bits
    shl ah, 6
    or cl, ah                   ; Cylinder high 2 bits

    mov ax, 0x0201
    mov dl, [s1_drive]
    mov bx, [s1_buf]
    int 0x13
    jnc .sec_ok

    xor ah, ah
    mov dl, [s1_drive]
    int 0x13
    dec bp
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
s1_left  dw CALC_SECTORS
s1_err   db "Calculator read error.", 0

times 510 - ($ - $$) db 0
dw 0xAA55


; =========================================================================
; SECTION 2 : BF64 Calculator 본체 (4,096 Bytes = 8 Sectors, 0x7E00)
; =========================================================================
section .s2 vstart=0x7E00 follows=.s1 align=4

; 컬러 속성 (BF64 TUI 스타일)
ATTR_BG      equ 0x17           ; 파란 배경 + 밝은 회색
ATTR_HDR     equ 0x1F           ; 파란 배경 + 밝은 흰색
ATTR_YEL     equ 0x1E           ; 파란 배경 + 노란색
ATTR_RED     equ 0x1C           ; 파란 배경 + 밝은 빨간색
ATTR_BAR     equ 0x70           ; 회색 배경 + 검정 글씨 (상태바)
ATTR_LCD     equ 0x0F           ; 검정 LCD 배경 + 밝은 흰색 숫자
ATTR_LCD_EXP equ 0x0A           ; 검정 LCD 배경 + 밝은 녹색 수식
ATTR_LCD_ERR equ 0x0C           ; 검정 LCD 배경 + 밝은 빨간색 오류
ATTR_BTN     equ 0x30           ; 청록 배경 + 검정 글씨 (일반 버튼)
ATTR_BTN_OP  equ 0x1E           ; 파란 배경 + 노란 글씨 (연산자/기능 버튼)
ATTR_BTN_SEL equ 0x70           ; 밝은 회색 배경 + 검정 글씨 (선택된 버튼)

; 키패드 그리드 크기 (4열 x 5행)
GRID_COLS    equ 4
GRID_ROWS    equ 5

; 버튼 액션 코드
ACT_CLR      equ 0x80           ; C  (전체 초기화)
ACT_CE       equ 0x81           ; CE (현재 입력 초기화)
ACT_BS       equ 0x82           ; BS (백스페이스)
ACT_NEG      equ 0x83           ; +/- (부호 반전)
ACT_EQ       equ 0x84           ; =  (계산)
ACT_EXIT     equ 0x85           ; EXIT (종료)

calc_main:
    cli
    cld
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0x7C00
    sti

    mov [boot_drive], dl

    ; 80x25 텍스트 모드 설정 및 커서 숨김
    mov ax, 0x0003
    int 0x10
    mov ah, 0x01
    mov cx, 0x2607
    int 0x10

    ; 계산기 초기 상태 (커서는 [=] 버튼 위치에서 시작해 키보드 ENTER=계산 바로 지원)
    call calc_clear_all
    mov byte [cur_row], 4
    mov byte [cur_col], 2

    call draw_static_frame

.main_loop:
    call draw_lcd
    call draw_keypad

    xor ah, ah
    int 0x16

    ; 방향키 처리 (4x5 그리드 순환 이동)
    cmp ah, 0x48                ; UP
    je .move_up
    cmp ah, 0x50                ; DOWN
    je .move_dn
    cmp ah, 0x4B                ; LEFT
    je .move_lt
    cmp ah, 0x4D                ; RIGHT
    je .move_rt
    cmp ah, 0x53                ; DELETE -> 전체 초기화 (C)
    je .key_clear

    ; 일반 키보드 입력
    cmp al, 0x1B                ; ESC -> 종료
    je calc_exit
    cmp al, 'q'
    je calc_exit
    cmp al, 'Q'
    je calc_exit

    cmp al, 0x0D                ; ENTER -> 현재 선택된 버튼 실행
    je .press_selected
    cmp al, ' '                 ; SPACE -> 현재 선택된 버튼 실행
    je .press_selected

    cmp al, '0'
    jb .chk_ops
    cmp al, '9'
    jbe .key_digit

.chk_ops:
    cmp al, '+'
    je .key_op
    cmp al, '-'
    je .key_op
    cmp al, '*'
    je .key_op
    cmp al, 'x'
    je .key_mul
    cmp al, 'X'
    je .key_mul
    cmp al, '/'
    je .key_op
    cmp al, '='
    je .key_eq
    cmp al, 0x08                ; BACKSPACE
    je .key_bs
    cmp al, 'c'
    je .key_clear
    cmp al, 'C'
    je .key_clear
    cmp al, 'r'
    je .key_clear
    cmp al, 'R'
    je .key_clear
    cmp al, 'e'
    je .key_ce
    cmp al, 'E'
    je .key_ce
    cmp al, 'n'
    je .key_neg
    cmp al, 'N'
    je .key_neg
    jmp .main_loop

.move_up:
    dec byte [cur_row]
    jns .main_loop
    mov byte [cur_row], GRID_ROWS - 1
    jmp .main_loop

.move_dn:
    inc byte [cur_row]
    cmp byte [cur_row], GRID_ROWS
    jb .main_loop
    mov byte [cur_row], 0
    jmp .main_loop

.move_lt:
    dec byte [cur_col]
    jns .main_loop
    mov byte [cur_col], GRID_COLS - 1
    jmp .main_loop

.move_rt:
    inc byte [cur_col]
    cmp byte [cur_col], GRID_COLS
    jb .main_loop
    mov byte [cur_col], 0
    jmp .main_loop

.press_selected:
    movzx bx, byte [cur_row]
    shl bx, 2
    movzx ax, byte [cur_col]
    add bx, ax
    mov al, [btn_actions + bx]
    call dispatch_action
    jmp .main_loop

.key_digit:
    call dispatch_action
    jmp .main_loop

.key_mul:
    mov al, '*'
.key_op:
    call dispatch_action
    jmp .main_loop

.key_eq:
    mov al, ACT_EQ
    call dispatch_action
    jmp .main_loop

.key_bs:
    mov al, ACT_BS
    call dispatch_action
    jmp .main_loop

.key_clear:
    mov al, ACT_CLR
    call dispatch_action
    jmp .main_loop

.key_ce:
    mov al, ACT_CE
    call dispatch_action
    jmp .main_loop

.key_neg:
    mov al, ACT_NEG
    call dispatch_action
    jmp .main_loop

; =========================================================
; 계산기 액션 디스패처 (AL = '0'..'9', '+-*/', 또는 ACT_*)
; =========================================================
dispatch_action:
    cmp al, '0'
    jb .chk_act
    cmp al, '9'
    ja .chk_act
    sub al, '0'
    jmp calc_digit

.chk_act:
    cmp al, '+'
    je calc_op
    cmp al, '-'
    je calc_op
    cmp al, '*'
    je calc_op
    cmp al, '/'
    je calc_op
    cmp al, ACT_CLR
    je calc_clear_all
    cmp al, ACT_CE
    je calc_clear_entry
    cmp al, ACT_BS
    je calc_bs
    cmp al, ACT_NEG
    je calc_neg
    cmp al, ACT_EQ
    je calc_equals
    cmp al, ACT_EXIT
    je calc_exit
    ret

; --- 전체 초기화 (C) ---
calc_clear_all:
    mov dword [val_acc], 0
    mov dword [val_cur], 0
    mov dword [val_lhs], 0
    mov dword [val_rhs], 0
    mov byte [pend_op], 0
    mov byte [last_op], 0
    mov byte [new_entry], 1
    mov byte [just_eq], 0
    mov byte [err_flag], 0
    ret

; --- 현재 입력 초기화 (CE) ---
calc_clear_entry:
    cmp byte [err_flag], 0
    jne calc_clear_all
    cmp byte [just_eq], 0
    jne calc_clear_all
    mov dword [val_cur], 0
    mov byte [new_entry], 1
    ret

; --- 숫자 입력 (AL = 0..9) ---
calc_digit:
    push eax
    push ebx
    movzx ebx, al

    cmp byte [err_flag], 0
    je .no_err
    call calc_clear_all
.no_err:
    cmp byte [just_eq], 0
    je .no_eq
    mov byte [pend_op], 0
    mov byte [last_op], 0
    mov byte [just_eq], 0
    mov byte [new_entry], 1
.no_eq:
    cmp byte [new_entry], 0
    je .append
    mov dword [val_cur], 0
    mov byte [new_entry], 0
.append:
    mov eax, [val_cur]
    cmp eax, 0
    jl .neg_append
    imul eax, eax, 10
    jo .done
    add eax, ebx
    jo .done
    mov [val_cur], eax
    jmp .done
.neg_append:
    imul eax, eax, 10
    jo .done
    sub eax, ebx
    jo .done
    mov [val_cur], eax
.done:
    pop ebx
    pop eax
    ret

; --- 백스페이스 (BS) ---
calc_bs:
    cmp byte [err_flag], 0
    jne calc_clear_all
    cmp byte [new_entry], 0
    jne .ret
    push eax
    push ebx
    push edx
    mov eax, [val_cur]
    cdq
    mov ebx, 10
    idiv ebx
    mov [val_cur], eax
    pop edx
    pop ebx
    pop eax
.ret:
    ret

; --- 부호 반전 (+/-) ---
calc_neg:
    cmp byte [err_flag], 0
    jne .ret
    cmp dword [val_cur], 0x80000000
    je .ovf
    neg dword [val_cur]
    ret
.ovf:
    mov byte [err_flag], 2
.ret:
    ret

; --- 사칙연산자 입력 (AL = '+', '-', '*', '/') ---
calc_op:
    cmp byte [err_flag], 0
    jne .ret

    push ax
    cmp byte [pend_op], 0
    je .store_acc
    cmp byte [new_entry], 0
    jne .set_op                 ; 연산자만 연속 변경 시 값 유지

    ; 중간 연산 수행 (체이닝 계산: 예 12 + 34 + ...)
    call calc_eval_core
    cmp byte [err_flag], 0
    jne .err_pop
    mov eax, [val_acc]
    mov [val_cur], eax
    jmp .set_op

.store_acc:
    mov eax, [val_cur]
    mov [val_acc], eax

.set_op:
    pop ax
    mov [pend_op], al
    mov byte [new_entry], 1
    mov byte [just_eq], 0
    mov byte [last_op], 0
.ret:
    ret
.err_pop:
    pop ax
    mov byte [pend_op], 0
    mov byte [new_entry], 1
    ret

; --- 계산 실행 (=) ---
calc_equals:
    cmp byte [err_flag], 0
    jne .ret

    cmp byte [pend_op], 0
    jne .do_eval

    ; 직전 계산 반복 (= 연속 입력 지원)
    cmp byte [just_eq], 0
    je .ret
    cmp byte [last_op], 0
    je .ret
    mov eax, [val_cur]
    mov [val_acc], eax
    mov eax, [val_rhs]
    mov [val_cur], eax
    mov al, [last_op]
    mov [pend_op], al

.do_eval:
    mov eax, [val_acc]
    mov [val_lhs], eax
    mov eax, [val_cur]
    mov [val_rhs], eax
    mov al, [pend_op]
    mov [last_op], al

    call calc_eval_core
    mov byte [pend_op], 0
    mov byte [new_entry], 1
    cmp byte [err_flag], 0
    jne .err_out

    mov eax, [val_acc]
    mov [val_cur], eax
    mov byte [just_eq], 1
    ret

.err_out:
    mov byte [just_eq], 0
.ret:
    ret

; --- 부호 있는 32비트 사칙연산 코어: val_acc = val_acc <pend_op> val_cur ---
calc_eval_core:
    push eax
    push ebx
    push edx
    mov eax, [val_acc]
    mov ebx, [val_cur]
    mov dl, [pend_op]

    cmp dl, '+'
    je .do_add
    cmp dl, '-'
    je .do_sub
    cmp dl, '*'
    je .do_mul
    cmp dl, '/'
    je .do_div
    jmp .done

.do_add:
    add eax, ebx
    jo .ovf
    jmp .store

.do_sub:
    sub eax, ebx
    jo .ovf
    jmp .store

.do_mul:
    imul eax, ebx
    jo .ovf
    jmp .store

.do_div:
    test ebx, ebx
    jz .div0
    cmp eax, 0x80000000
    jne .div_ok
    cmp ebx, -1
    je .ovf                     ; INT32_MIN / -1 오버플로 방지
.div_ok:
    cdq
    idiv ebx
    jmp .store

.div0:
    mov byte [err_flag], 1
    jmp .done
.ovf:
    mov byte [err_flag], 2
    jmp .done
.store:
    mov [val_acc], eax
.done:
    pop edx
    pop ebx
    pop eax
    ret

; --- 종료: HDD 0x80(BF64 OS)으로 안전 복귀, 미부팅 시 웜 리부트 ---
calc_exit:
    mov ax, 0x0003
    int 0x10
    mov ah, 0x01
    mov cx, 0x0607
    int 0x10

    ; HDD 0x80 LBA 0 (MBR) 로드 시도 -> 유효하면 BF64 OS로 복귀
    xor ax, ax
    mov es, ax
    mov ax, 0x0201
    mov cx, 0x0001
    mov dx, 0x0080
    mov bx, 0x7C00
    int 0x13
    jc .reboot
    cmp word [0x7C00 + 0x1FE], 0xAA55
    jne .reboot

    cli
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0x7C00
    mov dl, 0x80
    sti
    jmp 0x0000:0x7C00

.reboot:
    mov word [0x0472], 0x1234
    cli
.kbc_wait:
    in al, 0x64
    test al, 0x02
    jnz .kbc_wait
    mov al, 0xFE
    out 0x64, al
    jmp 0xFFFF:0x0000

; =========================================================
; 화면 렌더링 (BF64 TUI 스타일 80x25 Direct VGA 0xB800)
; =========================================================
draw_static_frame:
    ; 전체 파란 배경
    mov cx, 0x0000
    mov dx, 0x174F
    mov al, ' '
    mov bl, ATTR_BG
    call vga_fill_rect

    ; 좌측 상단 타이틀 (BF64 스타일)
    mov dx, 0x0001
    mov bl, ATTR_HDR
    mov si, str_win_title
    call vga_print_at

    ; 타이틀 밑줄 (제목 길이에 맞춰 0xCD)
    mov cx, 0x0100
    mov dx, 0x0118
    mov al, 0xCD
    mov bl, ATTR_BG
    call vga_fill_rect

    ; 하단 상태바 (좌측 정렬)
    mov cx, 0x1800
    mov dx, 0x184F
    mov al, ' '
    mov bl, ATTR_BAR
    call vga_fill_rect
    mov dx, 0x1802
    mov bl, ATTR_BAR
    mov si, str_status
    call vga_print_at

    ; 계산기 본체 외곽 프레임 (rows 3..21, cols 18..60, 폭 43)
    mov cx, 0x0312
    mov dx, 0x153C
    mov bl, ATTR_HDR
    mov bh, ATTR_BG
    call vga_draw_box

    ; 계산기 제목 (가운데 정렬)
    mov dh, 4
    mov bl, ATTR_HDR
    mov si, str_box_title
    call vga_print_center

    ; 제목 구분선
    mov cx, 0x0513
    mov dx, 0x053B
    mov al, 0xC4
    mov bl, ATTR_BG
    call vga_fill_rect

    ; LCD 프레임 (rows 6..9, cols 20..58, 폭 39 -> 버튼과 좌우 정렬 일치)
    mov cx, 0x0614
    mov dx, 0x093A
    mov bl, ATTR_YEL
    mov bh, ATTR_LCD
    call vga_draw_box
    ret

; --- LCD 수식 & 숫자 표시 갱신 ---
draw_lcd:
    ; LCD 내부 지우기 (rows 7..8, cols 21..57)
    mov cx, 0x0715
    mov dx, 0x0839
    mov al, ' '
    mov bl, ATTR_LCD
    call vga_fill_rect

    ; 1. 상단 수식 줄 구성 (row 7)
    mov di, exp_buf
    mov byte [di], 0

    cmp byte [pend_op], 0
    je .chk_just_eq
    ; 진행 중 수식: "<val_acc> <pend_op>"
    mov eax, [val_acc]
    call i32_cat
    mov al, ' '
    stosb
    mov al, [pend_op]
    stosb
    mov byte [di], 0
    jmp .print_exp

.chk_just_eq:
    cmp byte [just_eq], 0
    je .print_exp
    ; 완료 수식: "<val_lhs> <last_op> <val_rhs> ="
    mov eax, [val_lhs]
    call i32_cat
    mov al, ' '
    stosb
    mov al, [last_op]
    stosb
    mov al, ' '
    stosb
    mov eax, [val_rhs]
    call i32_cat
    mov al, ' '
    stosb
    mov al, '='
    stosb
    mov byte [di], 0

.print_exp:
    mov si, exp_buf
    mov dh, 7
    mov bl, ATTR_LCD_EXP
    call print_lcd_right

    ; 2. 하단 메인 숫자 / 오류 줄 표시 (row 8)
    cmp byte [err_flag], 1
    je .show_div0
    cmp byte [err_flag], 2
    je .show_ovf

    mov di, num_buf
    mov eax, [val_cur]
    call i32_cat
    mov byte [di], 0
    mov si, num_buf
    mov bl, ATTR_LCD
    jmp .print_main

.show_div0:
    mov si, str_err_div0
    mov bl, ATTR_LCD_ERR
    jmp .print_main

.show_ovf:
    mov si, str_err_ovf
    mov bl, ATTR_LCD_ERR

.print_main:
    mov dh, 8
    call print_lcd_right
    ret

; LCD 우측 정렬 출력 (DH=행, BL=속성, SI=문자열, col 57 끝맞춤)
print_lcd_right:
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
    cmp cx, 35
    jbe .fit
    mov cx, 35
.fit:
    mov al, 57
    sub al, cl
    mov dl, al
    call vga_print_at
    pop dx
    pop cx
    pop ax
    ret

; --- 4x5 키패드 버튼 렌더링 (rows 11,13,15,17,19 / cols 20,30,40,50, 각 폭 9) ---
draw_keypad:
    push ax
    push bx
    push cx
    push dx
    push si
    push bp

    xor bp, bp                  ; bp = 버튼 인덱스 (0..19)
    xor ch, ch                  ; ch = row (0..4)
.row_loop:
    xor cl, cl                  ; cl = col (0..3)
.col_loop:
    ; 화면 행 = 11 + row*2
    mov dh, ch
    shl dh, 1
    add dh, 11

    ; 화면 열 = 20 + col*10
    mov al, cl
    mov ah, 10
    mul ah
    add al, 20
    mov dl, al

    ; 버튼 색상 결정: 선택 -> ATTR_BTN_SEL, 기능/연산자 -> ATTR_BTN_OP, 숫자 -> ATTR_BTN
    mov bl, ATTR_BTN
    cmp ch, 0
    je .is_op_col
    cmp cl, 3
    je .is_op_col
    cmp ch, 4
    jne .chk_sel
    cmp cl, 1
    je .chk_sel
.is_op_col:
    mov bl, ATTR_BTN_OP
.chk_sel:
    cmp ch, [cur_row]
    jne .draw_one
    cmp cl, [cur_col]
    jne .draw_one
    mov bl, ATTR_BTN_SEL

.draw_one:
    ; 버튼 라벨 (각 9바이트 고정: bp * 9 = bp*8 + bp)
    mov si, bp
    shl si, 3
    add si, bp
    add si, btn_labels
    push cx
    mov cx, 9
    call vga_print_n
    pop cx

    inc bp
    inc cl
    cmp cl, GRID_COLS
    jb .col_loop

    inc ch
    cmp ch, GRID_ROWS
    jb .row_loop

    pop bp
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; =========================================================
; 부호 있는 32비트 정수 -> 문자열 이어쓰기 (EAX -> [DI], DI 전진)
; =========================================================
i32_cat:
    push eax
    push ebx
    push cx
    push edx

    test eax, eax
    jns .pos
    mov byte [di], '-'
    inc di
    neg eax                     ; INT32_MIN(0x80000000)은 unsigned 2147483648로 정상 변환
.pos:
    mov ebx, 10
    xor cx, cx
.div_loop:
    xor edx, edx
    div ebx
    push dx
    inc cx
    test eax, eax
    jnz .div_loop
.pop_loop:
    pop ax
    add al, '0'
    stosb
    loop .pop_loop

    pop edx
    pop cx
    pop ebx
    pop eax
    ret

; =========================================================
; Direct VGA (0xB800) 헬퍼
; =========================================================
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
    push si
    push di
    push es
    mov si, 0xB800
    mov es, si
    mov ah, bl                  ; AH = 속성, AL = 문자
    movzx si, dl
    movzx bx, cl
    sub si, bx
    inc si                      ; SI = 열 개수 (dl - cl + 1)
    mov bh, ch
.r_loop:
    cmp bh, dh
    ja .done
    push dx
    mov dh, bh
    mov dl, cl
    call vga_calc_di
    pop dx
    push cx
    mov cx, si
    cld
    rep stosw
    pop cx
    inc bh
    jmp .r_loop
.done:
    pop es
    pop di
    pop si
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

    ; 내부 채우기
    push bx
    push cx
    push dx
    inc ch
    inc cl
    dec dh
    dec dl
    mov bl, bh
    mov al, ' '
    call vga_fill_rect
    pop dx
    pop cx
    pop bx

    mov ax, 0xB800
    mov es, ax
    mov ah, bl

    movzx si, dl
    movzx di, cl
    sub si, di
    dec si                      ; 내부 폭

    ; 상단 테두리
    push dx
    mov dx, cx
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

    ; 하단 테두리
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

    ; 좌우 테두리
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
    push di
    push es
    mov ax, 0xB800
    mov es, ax
    call vga_calc_di
    mov ah, bl
.loop:
    lodsb
    test al, al
    jz .done
    stosw
    jmp .loop
.done:
    pop es
    pop di
    pop ax
    ret

vga_print_n:
    push ax
    push cx
    push di
    push es
    mov ax, 0xB800
    mov es, ax
    call vga_calc_di
    mov ah, bl
.loop:
    lodsb
    stosw
    loop .loop
    pop es
    pop di
    pop cx
    pop ax
    ret

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

; =========================================================
; 데이터 영역
; =========================================================
boot_drive      db 0
cur_row         db 4
cur_col         db 2
pend_op         db 0
last_op         db 0
new_entry       db 1
just_eq         db 0
err_flag        db 0

val_acc         dd 0
val_cur         dd 0
val_lhs         dd 0
val_rhs         dd 0

num_buf         times 16 db 0
exp_buf         times 48 db 0

str_win_title   db "BF64 v1.3 - Calculator", 0
str_box_title   db "BF64 Calculator", 0
str_status      db "ARROWS+ENTER=Select  0-9/+-*/==Input  C/DEL=Clear  BS=Del  ESC=Exit", 0
str_err_div0    db "ERROR: DIVIDE BY ZERO", 0
str_err_ovf     db "ERROR: OVERFLOW", 0

; 4x5 키패드 버튼 라벨 (각 9바이트 고정, 좌우 완벽 대칭)
btn_labels:
    db "[   C   ][  CE   ][  BS   ][   /   ]"
    db "[   7   ][   8   ][   9   ][   *   ]"
    db "[   4   ][   5   ][   6   ][   -   ]"
    db "[   1   ][   2   ][   3   ][   +   ]"
    db "[  +/-  ][   0   ][   =   ][ EXIT  ]"

; 4x5 키패드 액션 테이블
btn_actions:
    db ACT_CLR, ACT_CE,  ACT_BS, '/'
    db '7',     '8',     '9',    '*'
    db '4',     '5',     '6',    '-'
    db '1',     '2',     '3',    '+'
    db ACT_NEG, '0',     ACT_EQ, ACT_EXIT

times 4096 - ($ - $$) db 0


; =========================================================================
; SECTION 3 : 1.44MB 플로피 이미지 규격 패딩
; =========================================================================
section .pad follows=.s2 align=4
times 1474560 - (512 + 4096) db 0
