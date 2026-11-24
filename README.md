# BF64 v1.3

**BF64**는 외부 라이브러리나 C 런타임 없이 **순수 16-bit x86 어셈블리(NASM)**로 작성된 독립형 베어메탈 운영체제입니다.  
클래식 8비트 컴퓨터 스타일의 인터랙티브 쉘과 **Brainfuck 가상 머신**, 자체 파일시스템(**BF64FS**), 디스크 유틸리티, 외부 실행 디스크 규격(**`bf64exec`**)을 **16 KB 커널(32섹터)** 안에 담았습니다.

---

## 주요 특징

- **단일 1.44 MB 부팅 설치 이미지 (`bf64inst.asm`)**
  - 부팅 시 하드웨어 호환성 검사(80386+ CPU, 128 KB+ RAM, 메모리 무결성, BIOS LBA) 수행
  - XP 스타일 TUI 설치기: 6페이지 가이드 투어, Quick/Full 포맷, 기존 BF64 감지 시 **데이터 유지 업그레이드 / 클린 설치 / 2단계 확인 제거(Uninstall)** 지원
- **부팅 콘솔 POST & 듀얼 쉘 모드**
  - 부팅 시 80×25 콘솔에서 CPU·최대 640 KB RAM 무결성 검사 및 시스템 볼륨(`C:`) 자동 조각모음 수행
  - `SETTINGS`에서 **Classic BF64 (40×25 블루 스크린)**와 **Extended Console (80×25 검정/흰색 콘솔)** 전환 가능(`C:` 영구 저장)
- **듀얼 Brainfuck 실행 엔진**
  - **Classic Mode (기본)**: 원본 코드를 1:1로 직접 해석하는 표준 인터프리터 (`32 KB` 원형 테이프)
  - **Optimize Mode (+32 KB IR)**: 실행 직전 3-Pass 최적화(RLE 압축, `CLEAR`/`MUL`/`SCAN` 루프 단순화, $O(1)$ 점프 테이블)로 고속 실행
- **BF64FS v2 파일시스템 & 내장 TUI 유틸리티**
  - 16 KB 고정 슬롯 기반 저장소 (HDD `C:` 최대 ~1.0 GB / 65,535슬롯, 플로피 `A:`/`B:` 등 지원)
  - `FORMAT`, `DEFRAG`, `HELP`, `SETTINGS`, `REBOOT`, `SHUTDOWN` 내장 (시스템 드라이브 `C:` 및 `bf64exec` 미디어 자동 보호)
- **`bf64exec` 외부 실행 디스크 규격**
  - LBA 0에 `"bf64exec"` 헤더를 넣은 부팅 디스크를 `RUN A:`로 바로 실행 가능
  - 예제 앱 포함: **`calc.asm`** (4×5 키패드 · 화살표/키보드 입력 지원 32비트 사칙연산 계산기)

---

## 주요 명령어

| 명령어 | 설명 |
|---|---|
| `<N> <CODE>` / `<N>` | 줄 번호(`0..65535`) 코드 저장·수정 / 삭제 |
| `LIST [N[-M]]` | 저장된 코드 목록 출력 (`ESC`로 중단) |
| `RUN` / `RUN X:` | RAM 프로그램 실행 / `X:` 드라이브의 `bf64exec` 디스크 부팅 |
| `NEW` / `CLS` | 프로그램 메모리 초기화 / 화면 지우기 |
| `DIR` / `DIR X:` | 드라이브 목록 조회 / 특정 드라이브 저장 파일 조회 |
| `SAVE` / `LOAD` / `DEL` | `"X:NAME"` 형식으로 16 KB 슬롯 저장·불러오기·삭제 |
| `FORMAT [X:]` / `DEFRAG [X:]` | 디스크 포맷 / 조각모음 유틸리티 실행 |
| `SETTINGS` (`CONFIG`) | Interpreter(Classic/Optimize) 및 Shell Config(40×25/80×25) 설정 |
| `HELP` / `REBOOT` / `SHUTDOWN` | 명령어 도움말 / 재부팅 / 시스템 종료 |

> 명령어 대신 Brainfuck 연산자(`> < + - . , [ ]`)를 직접 입력하면 **Direct Mode**로 즉시 실행됩니다.

---

## 빌드 및 실행

### 요구 사항
- [NASM](https://www.nasm.us/)
- x86 에뮬레이터 (QEMU, Bochs, 86Box, VirtualBox 등) 또는 Legacy BIOS 지원 PC

### 빌드
```bash
# BF64 v1.3 설치/OS 플로피 이미지 빌드 (1.44 MB)
nasm -f bin bf64inst.asm -o bf64inst.img

# bf64exec 계산기 플로피 이미지 빌드 (선택)
nasm -f bin bf64calc.asm -o bf64calc.img
```

### QEMU 실행
```bash
# 1. 가상 하드 디스크 생성 (예: 16 MB)
qemu-img create -f raw bf64hdd.img 16M

# 2. 설치 플로피로 부팅하여 HDD에 설치
qemu-system-i386 -fda bf64inst.img -hda bf64hdd.img -boot a

# 3. 설치 완료 후 HDD로 부팅 (A:에 계산기 플로피 마운트 후 `RUN A:` 실행 가능)
qemu-system-i386 -fda bf64calc.img -hda bf64hdd.img -boot c
```

---

## 프로젝트 구성

- `bf64inst.asm` — BF64 v1.3 부트로더, 설치/업그레이드/제거기, MBR 및 16 KB OS 커널 전체 소스
- `bf64calc.asm` — `bf64exec` 규격으로 동작하는 독립형 계산기 애플리케이션 소스
