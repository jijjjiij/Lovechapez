#!/usr/bin/env bash
# start.sh — cross-сборка Windows-EXE Deadman Switch из Linux/Windows
# Команды:
#   ./start.sh build   — собрать deadman.exe
#   ./start.sh clean   — удалить артефакты
#   ./start.sh doctor  — диагностика окружения
#   ./start.sh run     — запустить .exe (только на Windows-хосте)
#   ./start.sh         — build (+run, если возможно)

set -euo pipefail

# ---------- настройки ----------
SRC="deadman.cpp"
OUT="deadman.exe"
OBJ="deadman.obj"
INI="config.ini"
GIST_ID_DEFAULT="3bc0ddc4fecc120a9925dbd1009d2b11"

# ---------- цвета ----------
if [ -t 1 ]; then
    C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YLW=$'\033[33m'
    C_BLU=$'\033[34m'; C_RST=$'\033[0m'
else
    C_RED=""; C_GRN=""; C_YLW=""; C_BLU=""; C_RST=""
fi
log()  { printf '%s[*]%s %s\n' "$C_BLU" "$C_RST" "$*"; }
ok()   { printf '%s[+]%s %s\n' "$C_GRN" "$C_RST" "$*"; }
warn() { printf '%s[!]%s %s\n' "$C_YLW" "$C_RST" "$*" >&2; }
die()  { printf '%s[x]%s %s\n' "$C_RED" "$C_RST" "$*" >&2; exit 1; }

has_cmd() { command -v "$1" >/dev/null 2>&1; }
is_debian() { has_cmd apt-get; }
is_wsl()    { [ -n "${WSL_DISTRO_NAME:-}" ] || grep -qi microsoft /proc/version 2>/dev/null; }
is_win_bash(){ case "${OSTYPE:-}" in msys*|cygwin*|win32*) return 0;; esac; return 1; }

# ---------- определение компилятора ----------
# Приоритет: cross-MinGW → MSVC → Windows-g++ (MSYS2/MinGW) → clang (Windows) → ошибка.
# Linux-нативный g++ (dumpmachine == x86_64-linux-gnu) НЕ подходит для .exe.
detect_toolchain() {
    if has_cmd x86_64-w64-mingw32-g++; then
        echo "mingw-cross"; return
    fi
    if has_cmd cl.exe; then
        echo "msvc"; return
    fi
    if has_cmd g++; then
        local m
        m="$(g++ -dumpmachine 2>/dev/null || echo unknown)"
        case "$m" in
            *mingw*|*windows*) echo "mingw"; return ;;
            *)                 echo "linux-gcc"; return ;;
        esac
    fi
    if has_cmd clang++; then
        local m
        m="$(clang++ -dumpmachine 2>/dev/null || echo unknown)"
        case "$m" in
            *mingw*|*windows*) echo "clang-win"; return ;;
            *)                 echo "clang-linux"; return ;;
        esac
    fi
    echo "none"
}

# ---------- установка cross-компилятора ----------
install_debian_cross() {
    log "apt: устанавливаю g++-mingw-w64-x86-64 (Windows cross-compiler)"
    local sudo=""; [ "$(id -u)" -ne 0 ] && sudo="sudo"
    $sudo apt-get update -y
    $sudo apt-get install -y --no-install-recommends g++-mingw-w64-x86-64 \
        || die "apt не смог установить mingw-w64"
    ok "Cross-компилятор установлен"
}

install_msys2_cross() {
    log "MSYS2: устанавливаю mingw-w64 gcc через pacman"
    if [ -d /ucrt64 ]; then
        pacman -S --noconfirm --needed mingw-w64-ucrt-x86_64-gcc || die "pacman ucrt64 gcc"
    elif [ -d /mingw64 ]; then
        pacman -S --noconfirm --needed mingw-w64-x86_64-gcc || die "pacman mingw64 gcc"
    else
        die "Откройте MSYS2 UCRT64/MINGW64"
    fi
    ok "gcc установлен"
}

ensure_toolchain() {
    local tc; tc="$(detect_toolchain)"
    case "$tc" in
        mingw-cross|mingw|msvc|clang-win) ok "Компилятор найден: $tc"; return 0 ;;
        linux-gcc|clang-linux)
            die "Найден Linux-компилятор ($(g++ -dumpmachine 2>/dev/null || clang++ -dumpmachine)),
а нужен MinGW-w64 cross. Установите:
  apt-get install -y g++-mingw-w64-x86-64
и повторите: ./start.sh build"
            ;;
    esac

    # Ничего нет — ставим
    if [ -d /ucrt64 ] || [ -d /mingw64 ]; then
        install_msys2_cross
    elif is_debian; then
        install_debian_cross
    else
        die "Не знаю, как поставить cross-компилятор в этом окружении.
Поставьте MinGW-w64 (x86_64-w64-mingw32-g++) вручную."
    fi

    hash -r 2>/dev/null || true
    tc="$(detect_toolchain)"
    case "$tc" in
        mingw-cross|mingw|msvc|clang-win) ok "Компилятор доступен: $tc" ;;
        *) die "После установки компилятор всё ещё не найден" ;;
    esac
}

# ---------- сборка ----------
build() {
    ensure_toolchain
    local tc; tc="$(detect_toolchain)"
    log "Компилятор: $tc"

    case "$tc" in
      mingw-cross)
        x86_64-w64-mingw32-g++ "$SRC" -o "$OUT" \
            -lgdiplus -lwinhttp -lgdi32 -luser32 -lcomctl32 -ldwmapi \
            -mwindows -std=c++17 -O2 -DUNICODE -D_UNICODE \
            || die "Сборка x86_64-w64-mingw32-g++ не удалась"
        ;;
      mingw)
        g++ "$SRC" -o "$OUT" \
            -lgdiplus -lwinhttp -lgdi32 -luser32 -lcomctl32 -ldwmapi \
            -mwindows -std=c++17 -O2 -DUNICODE -D_UNICODE \
            || die "Сборка MinGW g++ не удалась"
        ;;
      msvc)
        cl "$SRC" /nologo /EHsc /std:c++17 /O2 /DUNICODE /D_UNICODE \
           /link gdiplus.lib winhttp.lib gdi32.lib user32.lib comctl32.lib dwmapi.lib \
           /SUBSYSTEM:WINDOWS /OUT:"$OUT" \
           || die "Сборка MSVC не удалась"
        ;;
      clang-win)
        clang++ --target=x86_64-w64-windows-gnu "$SRC" -o "$OUT" \
            -lgdiplus -lwinhttp -lgdi32 -luser32 -lcomctl32 -ldwmapi \
            -mwindows -std=c++17 -O2 -DUNICODE -D_UNICODE \
            || die "Сборка clang++ (Windows target) не удалась"
        ;;
      *) die "detect_toolchain() вернул неподходящее: $tc" ;;
    esac

    [ -f "$OUT" ] || die "Компилятор не создал $OUT"
    ok "Собрано: $OUT ($(stat -c%s "$OUT" 2>/dev/null || echo '?') байт)"
    if has_cmd file; then
        file "$OUT" || true
    fi
    # Быстрая проверка, что это PE-файл
    if has_cmd file && ! file "$OUT" | grep -qi 'PE32'; then
        warn "Результат не похож на Windows PE-файл — проверьте компилятор"
    fi
}

# ---------- запуск ----------
run_app() {
    [ -f "$OUT" ] || die "$OUT не найден — сначала ./start.sh build"

    if is_win_bash && has_cmd cmd.exe; then
        log "Запуск $OUT через cmd.exe ..."
        cmd.exe /c start "" "$(cygpath -w "$PWD/$OUT" 2>/dev/null || echo "$PWD/$OUT")"
        ok "Запущено"
        return
    fi

    if is_wsl && has_cmd cmd.exe; then
        log "Запуск $OUT через WSL → cmd.exe ..."
        cmd.exe /c start "" "$(wslpath -w "$PWD/$OUT")"
        ok "Запущено"
        return
    fi

    warn "Это не Windows-хост — $OUT нельзя запустить здесь."
    warn "Заберите артефакт наружу и запустите на Windows:"
    warn "  docker cp <container>:/src/$OUT ./$OUT"
    warn "или запустите контейнер с volume:"
    warn "  docker run --rm -v \"\$PWD:/out\" deadman-builder cp /src/$OUT /out/"
}

# ---------- диагностика ----------
doctor() {
    echo "=== Окружение ==="
    echo "OSTYPE    : ${OSTYPE:-?}"
    echo "MSYSTEM   : ${MSYSTEM:-?}"
    echo "uname     : $(uname -a 2>/dev/null || echo '?')"
    echo
    echo "=== Компиляторы ==="
    for c in x86_64-w64-mingw32-g++ g++ cl.exe clang++; do
        printf '%-28s' "$c:"
        if command -v "$c" >/dev/null 2>&1; then
            printf '%s\n' "$("$c" --version 2>/dev/null | head -n1)"
            case "$c" in
                g++|clang++) printf '%-28s%s\n' '  dumpmachine:' "$($c -dumpmachine 2>/dev/null)";;
            esac
        else
            echo "(нет)"
        fi
    done
    echo
    echo "=== Определённый toolchain ==="
    echo "detect_toolchain() -> $(detect_toolchain)"
    echo
    echo "=== Утилиты ==="
    for c in file zip pacman apt-get; do
        printf '%-12s' "$c:"
        command -v "$c" >/dev/null 2>&1 && echo OK || echo "(нет)"
    done
}

clean() { rm -f "$OUT" "$OBJ" *.o *.pdb *.ilk; ok "Очищено"; }

case "${1:-all}" in
  build)  build ;;
  run)    run_app ;;
  clean)  clean ;;
  doctor) doctor ;;
  all|"") build; run_app ;;
  *) die "Использование: $0 [build|run|clean|doctor|all]" ;;
esac
