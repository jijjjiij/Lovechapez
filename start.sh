#!/usr/bin/env bash
# start.sh — сборка и запуск Deadman Switch на Windows
# Запуск:  ./start.sh          (собрать и запустить)
#          ./start.sh build    (только собрать)
#          ./start.sh run      (только запустить)
#          ./start.sh clean    (удалить артефакты сборки)

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
    C_BLU=$'\033[34m'; C_RST=$'\033[0m'; C_BLD=$'\033[1m'
else
    C_RED=""; C_GRN=""; C_YLW=""; C_BLU=""; C_RST=""; C_BLD=""
fi

log()  { printf '%s[*]%s %s\n' "$C_BLU" "$C_RST" "$*"; }
ok()   { printf '%s[+]%s %s\n' "$C_GRN" "$C_RST" "$*"; }
warn() { printf '%s[!]%s %s\n' "$C_YLW" "$C_RST" "$*" >&2; }
die()  { printf '%s[x]%s %s\n' "$C_RED" "$C_RST" "$*" >&2; exit 1; }

# ---------- проверка окружения ----------
[ -f "$SRC" ] || die "Не найден $SRC — запустите скрипт из папки проекта"

# ---------- определение компилятора ----------
detect_toolchain() {
    if command -v cl.exe >/dev/null 2>&1; then
        echo "msvc"
    elif command -v g++ >/dev/null 2>&1; then
        echo "mingw"
    elif command -v x86_64-w64-mingw32-g++ >/dev/null 2>&1; then
        echo "mingw-cross"
    else
        echo "none"
    fi
}

# ---------- сборка ----------
build() {
    local tc
    tc="$(detect_toolchain)"

    case "$tc" in
      msvc)
        log "Компилятор: MSVC (cl.exe)"
        # Ищем окружение VS, если cl ещё не в PATH — но обычно в Developer Prompt
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
      *)
        die "Не найден компилятор. Установите MSVC (Developer Command Prompt) или MinGW-w64 (g++)."
        ;;
    esac

    [ -f "$OUT" ] || die "Компилятор не создал $OUT"
    ok "Собрано: $OUT ($(stat -c%s "$OUT" 2>/dev/null || echo '?') байт)"
}

# ---------- проверка/создание config.ini ----------
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

    # Проверка обязательных ключей
    if ! grep -qE '^\s*gist_id\s*=' "$INI"; then
        warn "В $INI нет gist_id — добавляю значение по умолчанию"
        # аккуратно вставим после [deadman]
        sed -i "/^\[deadman\]/a gist_id=$GIST_ID_DEFAULT" "$INI" 2>/dev/null \
            || warn "Не удалось автоматически вставить gist_id, добавьте вручную"
    fi

    local tok
    tok="$(grep -E '^\s*token\s*=' "$INI" | head -n1 | cut -d= -f2- | tr -d ' \r')"
    case "$tok" in
      ""|PASTE_YOUR_TOKEN_HERE|github_pat_11BRPWDMA0A7AONceT4FNP_*)
        warn "Похоже, в $INI указан placeholder или старый скомпрометированный токен."
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
    # В Git Bash / MSYS прямой запуск .exe работает; в WSL — через cmd.exe
    if command -v cmd.exe >/dev/null 2>&1 && [ -n "${WSL_DISTRO_NAME:-}" ]; then
        cmd.exe /c start "" "$(wslpath -w "$PWD/$OUT")"
    else
        ./"$OUT" &
    fi
    ok "Запущено"
}

# ---------- очистка ----------
clean() {
    rm -f "$OUT" "$OBJ" *.o *.pdb *.ilk
    ok "Очищено"
}

# ---------- main ----------
case "${1:-all}" in
  build) build ;;
  run)   run_app ;;
  clean) clean ;;
  all|"") build; run_app ;;
  *) die "Использование: $0 [build|run|clean|all]" ;;
esac
