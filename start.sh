#!/usr/bin/env bash
# start.sh — сборка и запуск Deadman Switch на Windows
# Запуск:  ./start.sh            (собрать и запустить)
#          ./start.sh build      (только собрать)
#          ./start.sh run        (только запустить)
#          ./start.sh clean      (удалить артефакты)
#          ./start.sh setup      (принудительно установить компилятор)
#          ./start.sh doctor     (диагностика окружения)

set -euo pipefail

# ---------- настройки ----------
SRC="deadman.cpp"
OUT="deadman.exe"
OBJ="deadman.obj"
INI="config.ini"
GIST_ID_DEFAULT="3bc0ddc4fecc120a9925dbd1009d2b11"

# Портативный MinGW (WinLibs) — standalone, без MSYS2
MINGW_VER="14.2.0-ucrt-r2"
MINGW_URL="https://github.com/brechtsanders/winlibs_mingw/releases/download/14.2.0posix-19.1.1-12.0.0-ucrt-r2/winlibs-x86_64-posix-seh-gcc-${MINGW_VER%-*}-mingw-w64ucrt-12.0.0-r2.zip"
MINGW_FALLBACK_URL="https://github.com/brechtsanders/winlibs_mingw/releases/latest"
MINGW_DIR_WIN="${LOCALAPPDATA:-$HOME/AppData/Local}/deadman-mingw"

# ---------- цвета ----------
if [ -t 1 ]; then
    C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YLW=$'\033[33m'
    C_BLU=$'\033[34m'; C_RST=$'\033[0m'; C_BLD=$'\033[1m'
else
    C_RED=""; C_GRN=""; C_YLW=""; C_BLU=""; C_RST=""; C_BLD=""
fi

log()  { printf '%s[*]%s %s\n' "$C_BLU" "$C_RST" "$*"; }
ok()   { printf '%s[+]%s %s\n' "$C_GRN" "$C_RST" "$*"; }
warn() { printf '%s[!]%s %s\n' "$C_YLW" "$C_RST" "$*" >&2; }
die()  { printf '%s[x]%s %s\n' "$C_RED" "$C_RST" "$*" >&2; exit 1; }

# ---------- определение окружения ----------
is_msys2()  { [ -n "${MSYSTEM:-}" ] && [ -d /mingw64 ] || [ -d /ucrt64 ]; }
is_wsl()    { [ -n "${WSL_DISTRO_NAME:-}" ] || grep -qi microsoft /proc/version 2>/dev/null; }
is_debian() { command -v apt-get >/dev/null 2>&1; }
is_win_bash(){ case "${OSTYPE:-}" in msys*|cygwin*|win32*) return 0;; esac; return 1; }

has_cmd() { command -v "$1" >/dev/null 2>&1; }

# ---------- поиск MSVC ----------
find_vcvars() {
    for p in \
        "/c/Program Files/Microsoft Visual Studio/2022/BuildTools/VC/Auxiliary/Build/vcvars64.bat" \
        "/c/Program Files/Microsoft Visual Studio/2022/Community/VC/Auxiliary/Build/vcvars64.bat" \
        "/c/Program Files/Microsoft Visual Studio/2022/Professional/VC/Auxiliary/Build/vcvars64.bat" \
        "/c/Program Files/Microsoft Visual Studio/2022/Enterprise/VC/Auxiliary/Build/vcvars64.bat" \
        "/c/Program Files (x86)/Microsoft Visual Studio/2019/BuildTools/VC/Auxiliary/Build/vcvars64.bat" \
        "/c/Program Files (x86)/Microsoft Visual Studio/2019/Community/VC/Auxiliary/Build/vcvars64.bat" \
        "/c/Program Files (x86)/Microsoft Visual Studio/2019/Professional/VC/Auxiliary/Build/vcvars64.bat" \
        "/c/Program Files (x86)/Microsoft Visual Studio/2019/Enterprise/VC/Auxiliary/Build/vcvars64.bat"; do
        [ -f "$p" ] && { echo "$p"; return 0; }
    done
    return 1
}

activate_msvc() {
    local vcvars
    vcvars="$(find_vcvars)" || return 1
    log "Найден MSVC: $vcvars — активирую окружение"
    local vcpath
    # cmd.exe вернёт PATH в формате Windows (с ;). Переводим в POSIX.
    vcpath="$(cmd.exe //c "call \"$(cygpath -w "$vcvars" 2>/dev/null || echo "$vcvars")\" >nul && echo %PATH%" 2>/dev/null | tr -d '\r')"
    if [ -n "$vcpath" ]; then
        # В MSYS/Cygwin путь уже с : после tr
        if command -v cygpath >/dev/null 2>&1; then
            # оставим как есть — gcc/cl понимают оба формата
            export PATH="$vcpath:$PATH"
        else
            export PATH="$(echo "$vcpath" | tr ';' ':'):$PATH"
        fi
        return 0
    fi
    return 1
}

# ---------- установка: MSYS2 ----------
install_msys2_pkg() {
    log "MSYS2 обнаружен — устанавливаю mingw-w64 gcc через pacman"
    if [ -d /ucrt64 ]; then
        pacman -S --noconfirm --needed mingw-w64-ucrt-x86_64-gcc || die "pacman не смог установить gcc (ucrt64)"
    elif [ -d /mingw64 ]; then
        pacman -S --noconfirm --needed mingw-w64-x86_64-gcc || die "pacman не смог установить gcc (mingw64)"
    else
        die "Не найден ни /ucrt64, ни /mingw64 — откройте MSYS2 UCRT64/MINGW64"
    fi
    ok "gcc установлен"
}

# ---------- установка: WSL / Debian / Ubuntu ----------
install_debian_pkg() {
    log "Обнаружен apt — устанавливаю mingw-w64 cross-компилятор"
    local sudo=""
    [ "$(id -u)" -ne 0 ] && sudo="sudo"
    $sudo apt-get update -y
    $sudo apt-get install -y g++-mingw-w64-x86-64 || die "apt не смог установить mingw-w64"
    ok "Cross-компилятор установлен"
}

# ---------- установка: портативный WinLibs MinGW для Windows Bash ----------
install_winlibs() {
    log "MSYS2/WSL не обнаружены — ставлю портативный WinLibs MinGW-w64"
    log "Каталог: $MINGW_DIR_WIN"

    mkdir -p "$MINGW_DIR_WIN"

    # Определяем утилиты распаковки
    local unzip_cmd="" dl_cmd=""
    if has_cmd curl; then dl_cmd="curl -fL --retry 3 -o"; elif has_cmd wget; then dl_cmd="wget -O"; fi
    [ -z "$dl_cmd" ] && die "Нужен curl или wget для скачивания"

    if has_cmd unzip; then unzip_cmd="unzip -q"
    elif has_cmd 7z;    then unzip_cmd="7z x -y"
    elif has_cmd tar;   then unzip_cmd="tar -xf"
    else die "Нужен unzip, 7z или tar для распаковки"
    fi

    local zip="$MINGW_DIR_WIN/mingw.zip"
    if [ ! -f "$MINGW_DIR_WIN/bin/g++.exe" ]; then
        log "Скачиваю $MINGW_URL"
        if ! $dl_cmd "$zip" "$MINGW_URL"; then
            warn "Не удалось скачать фиксированную версию, открываю страницу релизов"
            warn "Скачайте вручную: $MINGW_FALLBACK_URL"
            die  "Автоустановка не удалась"
        fi
        log "Распаковываю..."
        $unzip_cmd "$zip" -d "$MINGW_DIR_WIN" >/dev/null || die "Не удалось распаковать $zip"
        rm -f "$zip"
    fi

    # WinLibs кладёт файлы в mingw64/ — переносим наверх
    if [ -d "$MINGW_DIR_WIN/mingw64/bin" ] && [ ! -f "$MINGW_DIR_WIN/bin/g++.exe" ]; then
        log "Переношу mingw64/* наверх"
        shopt -s dotglob
        mv "$MINGW_DIR_WIN/mingw64/"* "$MINGW_DIR_WIN/" 2>/dev/null || true
        rmdir "$MINGW_DIR_WIN/mingw64" 2>/dev/null || true
    fi

    if [ ! -f "$MINGW_DIR_WIN/bin/g++.exe" ]; then
        die "После распаковки не найден $MINGW_DIR_WIN/bin/g++.exe"
    fi

    export PATH="$MINGW_DIR_WIN/bin:$PATH"
    ok "MinGW установлен: $MINGW_DIR_WIN/bin"
    warn "Добавьте в PATH навсегда:  $MINGW_DIR_WIN/bin"
}

# ---------- обеспечение компилятора ----------
ensure_toolchain() {
    # Уже есть?
    if has_cmd g++; then ok "g++ уже в PATH"; return 0; fi
    if has_cmd clang++; then ok "clang++ уже в PATH"; return 0; fi
    if has_cmd cl.exe; then ok "cl.exe уже в PATH"; return 0; fi

    # Попробуем MSVC без установки
    if activate_msvc && has_cmd cl.exe; then ok "MSVC активирован"; return 0; fi

    # Ставим
    if is_msys2; then
        install_msys2_pkg
    elif is_wsl && is_debian; then
        install_debian_pkg
    elif is_win_bash; then
        install_winlibs
    elif is_debian; then
        # Linux, не WSL — установим нативный g++ (соберёт ELF, не EXE!)
        warn "Похоже, это Linux без WSL. Ставлю нативный g++ (соберёт Linux-бинарь, не .exe)"
        local sudo=""; [ "$(id -u)" -ne 0 ] && sudo="sudo"
        $sudo apt-get update -y && $sudo apt-get install -y g++ || die "apt не смог установить g++"
    else
        die "Не знаю, как установить компилятор в этом окружении. Поставьте MinGW-w64 или MSVC вручную."
    fi

    # Проверка после установки
    hash -r 2>/dev/null || true
    if has_cmd g++ || has_cmd clang++ || has_cmd cl.exe; then
        ok "Компилятор доступен"
        return 0
    fi
    die "Компилятор всё ещё не найден в PATH. Перезапустите терминал и повторите."
}

# ---------- определение компилятора ----------
detect_toolchain() {
    if has_cmd cl.exe; then echo "msvc"
    elif has_cmd g++; then echo "mingw"
    elif has_cmd x86_64-w64-mingw32-g++; then echo "mingw-cross"
    elif has_cmd clang++; then echo "clang"
    else echo "none"
    fi
}

# ---------- сборка ----------
build() {
    ensure_toolchain
    local tc; tc="$(detect_toolchain)"

    case "$tc" in
      msvc)
        log "Компилятор: MSVC (cl.exe)"
        cl "$SRC" /nologo /EHsc /std:c++17 /O2 /DUNICODE /D_UNICODE \
           /link gdiplus.lib winhttp.lib gdi32.lib user32.lib comctl32.lib dwmapi.lib \
           /SUBSYSTEM:WINDOWS /OUT:"$OUT" \
           || die "Сборка MSVC не удалась"
        ;;
      mingw)
        log "Компилятор: MinGW g++"
        g++ "$SRC" -o "$OUT" \
            -lgdiplus -lwinhttp -lgdi32 -luser32 -lcomctl32 -ldwmapi \
            -mwindows -std=c++17 -O2 -DUNICODE -D_UNICODE \
            || die "Сборка MinGW не удалась"
        ;;
      mingw-cross)
        log "Компилятор: mingw-w64 cross"
        x86_64-w64-mingw32-g++ "$SRC" -o "$OUT" \
            -lgdiplus -lwinhttp -lgdi32 -luser32 -lcomctl32 -ldwmapi \
            -mwindows -std=c++17 -O2 -DUNICODE -D_UNICODE \
            || die "Сборка cross-MinGW не удалась"
        ;;
      clang)
        log "Компилятор: clang++"
        clang++ "$SRC" -o "$OUT" \
            -lgdiplus -lwinhttp -lgdi32 -luser32 -lcomctl32 -ldwmapi \
            -mwindows -std=c++17 -O2 -DUNICODE -D_UNICODE \
            || die "Сборка clang++ не удалась"
        ;;
      *) die "Не найден компилятор после ensure_toolchain()" ;;
    esac

    [ -f "$OUT" ] || die "Компилятор не создал $OUT"
    ok "Собрано: $OUT ($(stat -c%s "$OUT" 2>/dev/null || echo '?') байт)"
}

# ---------- config.ini ----------
ensure_config() {
    if [ ! -f "$INI" ]; then
        warn "$INI не найден — создаю шаблон"
        cat > "$INI" <<EOF
[deadman]
; GitHub PAT со scope "gist"
token=PASTE_YOUR_TOKEN_HERE
; ID из URL гиста: https://gist.github.com/USER/<gist_id>
gist_id=$GIST_ID_DEFAULT
filename=status.json
interval_hours=12
EOF
        die "Заполните $INI (token, gist_id) и запустите снова"
    fi

    if ! grep -qE '^\s*gist_id\s*=' "$INI"; then
        warn "В $INI нет gist_id — добавляю значение по умолчанию"
        if sed --version >/dev/null 2>&1; then
            sed -i "/^\[deadman\]/a gist_id=$GIST_ID_DEFAULT" "$INI" || \
                warn "Не удалось вставить gist_id, добавьте вручную"
        else
            warn "sed -i недоступен, добавьте строку вручную: gist_id=$GIST_ID_DEFAULT"
        fi
    fi

    local tok
    tok="$(grep -E '^\s*token\s*=' "$INI" | head -n1 | cut -d= -f2- | tr -d ' \r')"
    case "$tok" in
      ""|PASTE_YOUR_TOKEN_HERE|github_pat_11BRPWDMA0A7AONceT4FNP_*)
        warn "В $INI указан placeholder или старый скомпрометированный токен."
        warn "Сгенерируйте новый PAT со scope 'gist' и впишите его в $INI."
        ;;
    esac
    ok "config.ini проверен"
}

# ---------- запуск ----------
run_app() {
    [ -f "$OUT" ] || die "$OUT не найден — сначала соберите: ./start.sh build"
    ensure_config
    log "Запуск $OUT ..."
    if is_wsl && has_cmd cmd.exe; then
        cmd.exe /c start "" "$(wslpath -w "$PWD/$OUT")"
    else
        ./"$OUT" &
    fi
    ok "Запущено"
}

# ---------- диагностика ----------
doctor() {
    echo "=== Окружение ==="
    echo "OSTYPE      : ${OSTYPE:-?}"
    echo "MSYSTEM     : ${MSYSTEM:-?}"
    echo "WSL_DISTRO  : ${WSL_DISTRO_NAME:-?}"
    echo "uname       : $(uname -a 2>/dev/null || echo '?')"
    echo "PATH        : $PATH" | fold -s -w 120
    echo
    echo "=== Компиляторы ==="
    for c in g++ cl.exe x86_64-w64-mingw32-g++ clang++; do
        printf '%-28s' "$c:"
        command -v "$c" 2>/dev/null && ("$c" --version 2>/dev/null | head -n1) || echo "(нет)"
    done
    echo
    echo "=== Распаковщики/загрузчики ==="
    for c in curl wget unzip 7z tar pacman apt-get; do
        printf '%-12s' "$c:"
        command -v "$c" >/dev/null 2>&1 && echo "OK" || echo "(нет)"
    done
    echo
    echo "=== MSVC vcvars ==="
    find_vcvars || echo "(не найден)"
    echo
    echo "=== Портативный MinGW ==="
    echo "Каталог: $MINGW_DIR_WIN"
    [ -f "$MINGW_DIR_WIN/bin/g++.exe" ] && echo "g++.exe: OK" || echo "g++.exe: отсутствует"
}

# ---------- очистка ----------
clean() {
    rm -f "$OUT" "$OBJ" *.o *.pdb *.ilk
    ok "Очищено"
}

# ---------- main ----------
case "${1:-all}" in
  build)  build ;;
  run)    run_app ;;
  clean)  clean ;;
  setup)  ensure_toolchain ;;
  doctor) doctor ;;
  all|"") build; run_app ;;
  *) die "Использование: $0 [build|run|clean|setup|doctor|all]" ;;
esac
