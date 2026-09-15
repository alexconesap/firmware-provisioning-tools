#!/usr/bin/env bash
# Shared helpers for flash.sh / reset.sh.
# Not meant to be run directly — sourced after the caller sets TOOLS_ROOT to
# the repo root (the directory containing this lib/ folder).
#
# Layout this file assumes — everything lives under
# projects/ so the repo root stays clean:
#   <TOOLS_ROOT>/projects/<project>/<module>/.settings        tracked
#   <TOOLS_ROOT>/projects/<project>/<module>/.local.settings   gitignored
#   <TOOLS_ROOT>/projects/<project>/<module>/partitions.csv    tracked (copy of the firmware repo's)
#   <TOOLS_ROOT>/projects/<project>/<module>/build/            gitignored cache/staging,
#                                                                mirrors the firmware repo's
#                                                                code/build/<module>/ shape

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    C_RED=$'\033[0;31m'; C_GREEN=$'\033[0;32m'; C_YELLOW=$'\033[0;33m'
    C_CYAN=$'\033[0;36m'; C_BOLD=$'\033[1m'; C_RESET=$'\033[0m'
else
    C_RED=""; C_GREEN=""; C_YELLOW=""; C_CYAN=""; C_BOLD=""; C_RESET=""
fi

info()  { echo "${C_CYAN}[info]${C_RESET} $*"; }
warn()  { echo "${C_YELLOW}[warn]${C_RESET} $*" >&2; }
die()   { echo "${C_RED}${C_BOLD}[error]${C_RESET} $*" >&2; exit 1; }

confirm() {
    local prompt="$1"
    if [ "${ASSUME_YES:-0}" = "1" ]; then
        return 0
    fi
    local ans
    read -r -p "$prompt [y/N]: " ans
    case "$ans" in
        [Yy]|[Yy][Ee][Ss]) return 0 ;;
        *) return 1 ;;
    esac
}

# True when someone is there to answer prompts: no --yes, and stdin is a
# terminal (not piped/scripted).
is_interactive() {
    [ "${ASSUME_YES:-0}" != "1" ] && [ -t 0 ]
}

# Numbered menu for non-technical users:
#   choose_option "<prompt>" "<option 1>" "<option 2>" ...
# Sets CHOICE to the 1-based pick; Enter picks option 1, so keep the
# safe/default option first. Re-asks on bad input.
choose_option() {
    local prompt="$1"; shift
    local n=$# i=1 opt ans
    echo "$prompt"
    for opt in "$@"; do
        echo "  $i) $opt"
        i=$((i + 1))
    done
    while true; do
        read -r -p "Choose [1-$n] (Enter = 1): " ans || die "No answer given."
        if [ -z "$ans" ]; then CHOICE=1; return 0; fi
        if [[ "$ans" =~ ^[0-9]+$ ]] && [ "$ans" -ge 1 ] && [ "$ans" -le "$n" ]; then
            CHOICE="$ans"; return 0
        fi
        warn "Please type a number between 1 and $n."
    done
}

_trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

# Resolve <TOOLS_ROOT>/<project>/<module>, load .settings + .local.settings,
# and locate partitions.csv. Dies with a plain-English message on anything
# missing — this is the field-tool audience, no stack traces.
load_module_settings() {
    local project="$1" module="$2"
    MODULE_DIR="$TOOLS_ROOT/projects/$project/$module"
    # As the user typed it; MAIN_PROJECT_ID can differ (fs-uv's is fs_uv).
    MODULE_LABEL="$project $module"

    [ -d "$MODULE_DIR" ] || die "Unknown product/board: '$project $module' (no folder at $MODULE_DIR)."

    local settings_file="$MODULE_DIR/.settings"
    local local_file="$MODULE_DIR/.local.settings"
    [ -f "$settings_file" ] || die "Missing settings file: $settings_file"

    unset SERIAL_PORT MAIN_PROJECT_ID PROJECT_ID IDF_TARGET OTA_UPDATE_URL OTA_BIN_FILENAME IDF_BAUD

    # .settings is the firmware repo's own build config, sourced as-is, and can
    # reference variables only its build scripts define (e.g. benny's
    # $PROJECT_DIR) — fatal under the callers' `set -u`, so relax it here.
    set +u
    # shellcheck disable=SC1090
    . "$settings_file"
    if [ -f "$local_file" ]; then
        # shellcheck disable=SC1090
        . "$local_file"
    fi
    set -u

    : "${MAIN_PROJECT_ID:?Missing MAIN_PROJECT_ID in $settings_file}"
    : "${PROJECT_ID:?Missing PROJECT_ID in $settings_file}"
    : "${IDF_TARGET:?Missing IDF_TARGET in $settings_file}"
    : "${OTA_UPDATE_URL:?Missing OTA_UPDATE_URL in $settings_file}"
    : "${OTA_BIN_FILENAME:?Missing OTA_BIN_FILENAME in $settings_file}"

    PARTITIONS_CSV="$MODULE_DIR/partitions.csv"
    [ -f "$PARTITIONS_CSV" ] || die "Missing $PARTITIONS_CSV — copy it from the firmware repo's <project>/code/<module>/partitions.csv."
}

# Reads partitions.csv (same format/offsets used by the real firmware
# build — see __REFERENCE__) and sets:
#   NVS_OFFSET, NVS_SIZE, OTADATA_OFFSET, OTADATA_SIZE, APP_OFFSET, APP_SIZE,
#   APP1_OFFSET, APP1_SIZE
# APP_OFFSET prefers the ota_0 slot; falls back to a factory partition if
# the module has no OTA slots. APP1_OFFSET is the ota_1 slot, if the module
# has a second one (empty otherwise) — see flash.sh: a device that has ever
# received a real OTA update may currently be booting from ota_1, not
# ota_0, so an app-only serial reflash has to write BOTH slots to be sure
# the new binary actually takes effect regardless of which one is active.
parse_partitions_csv() {
    local csv="$1"
    NVS_OFFSET=""; NVS_SIZE=""; OTADATA_OFFSET=""; OTADATA_SIZE=""
    APP_OFFSET=""; APP_SIZE=""; APP1_OFFSET=""; APP1_SIZE=""
    local factory_offset="" factory_size=""
    local line name type subtype offset size

    while IFS= read -r line || [ -n "$line" ]; do
        local trimmed
        trimmed="$(_trim "$line")"
        [ -z "$trimmed" ] && continue
        [ "${trimmed:0:1}" = "#" ] && continue

        IFS=',' read -r name type subtype offset size _ <<< "$line"
        name="$(_trim "$name")"; type="$(_trim "$type")"; subtype="$(_trim "$subtype")"
        offset="$(_trim "$offset")"; size="$(_trim "$size")"
        [ -z "$name" ] && continue

        case "$type,$subtype" in
            data,nvs) NVS_OFFSET="$offset"; NVS_SIZE="$size" ;;
            data,ota) OTADATA_OFFSET="$offset"; OTADATA_SIZE="$size" ;;
            app,ota_0) APP_OFFSET="$offset"; APP_SIZE="$size" ;;
            app,ota_1) APP1_OFFSET="$offset"; APP1_SIZE="$size" ;;
            app,factory) factory_offset="$offset"; factory_size="$size" ;;
        esac
    done < "$csv"

    if [ -z "$APP_OFFSET" ] && [ -n "$factory_offset" ]; then
        APP_OFFSET="$factory_offset"; APP_SIZE="$factory_size"
    fi

    [ -n "$NVS_OFFSET" ] || die "Could not find an 'nvs' partition in $csv"
    [ -n "$APP_OFFSET" ] || die "Could not find an 'ota_0' or 'factory' app partition in $csv"
}

# ESP-IDF convention: the classic ESP32 bootloader lives at 0x1000; every
# later chip (S2/S3/C3/C6/H2/P4...) puts it at 0x0.
bootloader_offset_for_target() {
    case "$1" in
        esp32) echo "0x1000" ;;
        *) echo "0x0" ;;
    esac
}

# Default-mode (app-only) safety check. Reads the first 0x9000 bytes off the
# connected chip (uses IDF_TARGET/SERIAL_PORT/BAUD/ESPTOOL_CMD, already set by
# the caller) and dies with a plain-English message if an app-only flash
# can't work there — both cases need --full instead:
#  - no ESP image header (magic byte 0xe9) at $1, the bootloader offset: a
#    blank / never-flashed chip, which could never boot the app;
#  - the partition table at 0x8000 doesn't have the app slots/otadata this
#    module's partitions.csv expects: the board runs other firmware (e.g. a
#    vendor demo) or an older layout, so its bootloader never looks where
#    the app gets written and it sits in a reset loop.
# If the chip can't be read at all, warns and continues.
check_existing_firmware() {
    local offset="$1"
    local tmp magic device expected
    tmp="$(mktemp)"
    if ! "${ESPTOOL_CMD[@]}" --chip "$IDF_TARGET" --port "$SERIAL_PORT" --baud "$BAUD" \
            read_flash 0x0 0x9000 "$tmp" >/dev/null 2>&1; then
        rm -f "$tmp"
        warn "Could not check the firmware already on the board before flashing — continuing anyway."
        return 0
    fi
    magic="$(od -An -tx1 -v -j $((offset)) -N1 "$tmp" 2>/dev/null | tr -d ' \n')"
    device="$(_device_layout "$tmp")"
    rm -f "$tmp"
    if [ "$magic" != "e9" ]; then
        die "No valid bootloader found at $offset (expected ESP image magic byte 0xe9, found 0x${magic:-??}). This looks like a blank / never-flashed chip — an app-only flash would write the app but the chip could never boot it. Run flash again and choose 'Full flash' (or pass --full) — it needs bootloader.bin/partition-table.bin/ota_data_initial.bin pre-staged locally, see AGENTS.md/CLAUDE.md."
    fi
    expected="$(_csv_layout "$PARTITIONS_CSV")"
    if [ "$device" != "$expected" ]; then
        die "The board's flash layout doesn't match $MODULE_LABEL — it most likely has different firmware on it (for example a manufacturer demo) or an older layout. A normal update would leave it stuck restarting. Run flash again and choose 'Full flash' (or pass --full).
  on the board: $(_layout_pretty "$device")
  expected:     $(_layout_pretty "$expected")"
    fi
}

# Partition layout helpers for check_existing_firmware: one
# "<type>/<subtype>/<offset>/<size>" line (decimal) per app slot and per
# otadata partition, sorted, so the chip's table and partitions.csv compare
# as plain strings.
_csv_layout() {
    local line name type subtype offset size t s
    while IFS= read -r line || [ -n "$line" ]; do
        line="$(_trim "$line")"
        case "$line" in ''|'#'*) continue ;; esac
        IFS=',' read -r name type subtype offset size _ <<< "$line"
        type="$(_trim "$type")"; subtype="$(_trim "$subtype")"
        case "$type,$subtype" in
            app,factory) t=0; s=0 ;;
            app,ota_*) t=0; s=$((16 + ${subtype#ota_})) ;;
            data,ota) t=1; s=0 ;;
            *) continue ;;
        esac
        echo "$t/$s/$(_flash_int "$(_trim "$offset")")/$(_flash_int "$(_trim "$size")")"
    done < "$1" | sort
}

_device_layout() {
    local bytes i t s
    # shellcheck disable=SC2207
    bytes=($(od -An -tx1 -v -j $((0x8000)) -N 3072 "$1"))
    i=0
    while [ $((i + 32)) -le ${#bytes[@]} ]; do
        case "${bytes[i]}${bytes[i+1]}" in
            aa50) ;;
            ebeb) i=$((i + 32)); continue ;;   # MD5 checksum row
            *) break ;;                        # 0xffff: end of table
        esac
        t=$((16#${bytes[i+2]})); s=$((16#${bytes[i+3]}))
        if [ "$t" -eq 0 ] || { [ "$t" -eq 1 ] && [ "$s" -eq 0 ]; }; then
            echo "$t/$s/$((16#${bytes[i+7]}${bytes[i+6]}${bytes[i+5]}${bytes[i+4]}))/$((16#${bytes[i+11]}${bytes[i+10]}${bytes[i+9]}${bytes[i+8]}))"
        fi
        i=$((i + 32))
    done | sort
}

# "0x20000" / "131072" / "64K" / "4M" -> decimal
_flash_int() {
    case "$1" in
        *[Kk]) echo $(( ${1%?} * 1024 )) ;;
        *[Mm]) echo $(( ${1%?} * 1048576 )) ;;
        *) echo $(( $1 )) ;;
    esac
}

_layout_pretty() {
    local t s o z out=""
    while IFS=/ read -r t s o z; do
        [ -n "$t" ] || continue
        case "$t/$s" in
            0/0) out="$out factory" ;;
            1/0) out="$out otadata" ;;
            *) out="$out ota_$((s - 16))" ;;
        esac
        out="$out@$(printf '0x%x[0x%x]' "$o" "$z")"
    done <<< "$1"
    out="${out# }"
    echo "${out:-(no partition table)}"
}

cache_build_dir() {
    echo "$TOOLS_ROOT/projects/$1/$2/build"
}

# Locates esptool, bundled inside the Arduino IDE's esp32 core so field
# machines need nothing else installed. Sets ESPTOOL_CMD (an array — may be
# `python3 /path/esptool.py` or a single prebuilt binary). Falls back to
# whatever's on PATH. Returns 1 if nothing is found.
find_esptool() {
    local base=""
    case "$(uname -s)" in
        Darwin) base="$HOME/Library/Arduino15/packages/esp32/tools/esptool_py" ;;
        *)      base="$HOME/.arduino15/packages/esp32/tools/esptool_py" ;;
    esac

    if [ -d "$base" ]; then
        # Newest version first, skipping any that can't actually run here
        # (e.g. an Intel-only esptool on an Apple Silicon Mac without Rosetta).
        local ver
        while IFS= read -r ver; do
            if [ -f "$base/$ver/esptool" ] && "$base/$ver/esptool" version >/dev/null 2>&1; then
                ESPTOOL_CMD=("$base/$ver/esptool")
                return 0
            fi
            if [ -f "$base/$ver/esptool.py" ] && command -v python3 >/dev/null 2>&1 \
                    && python3 "$base/$ver/esptool.py" version >/dev/null 2>&1; then
                ESPTOOL_CMD=(python3 "$base/$ver/esptool.py")
                return 0
            fi
        done < <(ls -1 "$base" 2>/dev/null | sort -Vr)
        warn "Arduino IDE's bundled esptool (in $base) can't run on this machine — looking for one on PATH instead."
    fi

    if command -v esptool.py >/dev/null 2>&1; then
        ESPTOOL_CMD=(esptool.py)
        return 0
    fi
    if command -v esptool >/dev/null 2>&1; then
        ESPTOOL_CMD=(esptool)
        return 0
    fi
    return 1
}

# Locates a python3 with pyserial installed (needed for `python3 -m
# serial.tools.miniterm`, the nicest available serial monitor). Tries the
# Arduino IDE's bundled python3 first (pyserial is one of esptool.py's own
# dependencies, so it's normally already there), then whatever's on PATH.
# Sets PYSERIAL_PYTHON3. Returns 1 if none has pyserial.
find_pyserial_python3() {
    local base=""
    case "$(uname -s)" in
        Darwin) base="$HOME/Library/Arduino15/packages/esp32/tools/python3" ;;
        *)      base="$HOME/.arduino15/packages/esp32/tools/python3" ;;
    esac

    local candidate=""
    if [ -d "$base" ]; then
        local latest
        latest="$(ls -1 "$base" 2>/dev/null | sort -V | tail -n1)"
        [ -n "$latest" ] && [ -f "$base/$latest/python3" ] && candidate="$base/$latest/python3"
    fi

    for py in "$candidate" python3; do
        [ -n "$py" ] || continue
        command -v "$py" >/dev/null 2>&1 || [ -x "$py" ] || continue
        if "$py" -c 'import serial.tools.miniterm' >/dev/null 2>&1; then
            PYSERIAL_PYTHON3="$py"
            return 0
        fi
    done
    return 1
}

list_serial_ports() {
    case "$(uname -s)" in
        Darwin) ls /dev/cu.* 2>/dev/null ;;
        *) ls /dev/ttyUSB* /dev/ttyACM* 2>/dev/null ;;
    esac
}

# Sets SERIAL_PORT from (in order): --port override, .local.settings, or an
# interactive prompt over the ports currently plugged in.
resolve_port() {
    if [ -n "${PORT_OVERRIDE:-}" ]; then
        SERIAL_PORT="$PORT_OVERRIDE"
        return 0
    fi
    if [ -n "${SERIAL_PORT:-}" ]; then
        return 0
    fi

    local ports=()
    while IFS= read -r p; do
        [ -n "$p" ] && ports+=("$p")
    done < <(list_serial_ports)

    if [ ${#ports[@]} -eq 0 ]; then
        die "No serial ports found. Plug in the board via USB and try again, or pass --port <port>."
    elif [ ${#ports[@]} -eq 1 ]; then
        SERIAL_PORT="${ports[0]}"
        info "Using serial port: $SERIAL_PORT"
    else
        echo "Multiple serial ports found:"
        local i=1
        for p in "${ports[@]}"; do
            echo "  $i) $p"
            i=$((i + 1))
        done
        local choice
        read -r -p "Which port is the board on? [1-${#ports[@]}]: " choice
        if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "${#ports[@]}" ]; then
            die "Invalid selection."
        fi
        SERIAL_PORT="${ports[$((choice - 1))]}"
    fi
}

# Downloads $OTA_BIN_FILENAME from $OTA_UPDATE_URL into $1 (a directory).
# Prints the path to the downloaded file on success.
download_app_bin() {
    local dest_dir="$1"
    mkdir -p "$dest_dir"
    local url="${OTA_UPDATE_URL%/}/$OTA_BIN_FILENAME"
    local dest="$dest_dir/$OTA_BIN_FILENAME"
    # stderr: callers capture stdout for the path.
    info "Downloading $url" >&2
    # Temp name first: an interrupted download must never be left where the
    # next run would reuse it as the cached binary.
    if ! curl -fsSL --connect-timeout 30 --max-time 600 -o "$dest.part" "$url"; then
        rm -f "$dest.part"
        die "Download failed: $url
Check your internet connection, or pre-stage $OTA_BIN_FILENAME in:
  $dest_dir"
    fi
    mv -f "$dest.part" "$dest"
    printf '%s' "$dest"
}
