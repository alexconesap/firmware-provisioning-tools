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

    [ -d "$MODULE_DIR" ] || die "Unknown product/board: '$project $module' (no folder at $MODULE_DIR)."

    local settings_file="$MODULE_DIR/.settings"
    local local_file="$MODULE_DIR/.local.settings"
    [ -f "$settings_file" ] || die "Missing settings file: $settings_file"

    unset SERIAL_PORT MAIN_PROJECT_ID PROJECT_ID IDF_TARGET OTA_UPDATE_URL OTA_BIN_FILENAME IDF_BAUD

    # shellcheck disable=SC1090
    . "$settings_file"
    if [ -f "$local_file" ]; then
        # shellcheck disable=SC1090
        . "$local_file"
    fi

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

# Reads the single byte at $1 (a bootloader offset) off the currently
# connected chip (uses IDF_TARGET/SERIAL_PORT/BAUD/ESPTOOL_CMD, already set
# by the caller) and dies with a plain-English message if it isn't a valid
# ESP image header (magic byte 0xe9) — i.e. this chip has no bootloader at
# all, so an app-only flash would "succeed" while leaving it unable to boot
# anything (a genuinely blank chip needs --full instead). Only meaningful
# before an app-only flash; --full always (re)writes the bootloader itself.
check_bootloader_present() {
    local offset="$1"
    local tmp
    tmp="$(mktemp)"
    if ! "${ESPTOOL_CMD[@]}" --chip "$IDF_TARGET" --port "$SERIAL_PORT" --baud "$BAUD" \
            read_flash "$offset" 1 "$tmp" >/dev/null 2>&1; then
        rm -f "$tmp"
        warn "Could not verify the existing bootloader before flashing — continuing anyway."
        return 0
    fi
    local magic
    magic="$(od -An -tx1 -N1 "$tmp" 2>/dev/null | tr -d ' \n')"
    rm -f "$tmp"
    if [ "$magic" != "e9" ]; then
        die "No valid bootloader found at $offset (expected ESP image magic byte 0xe9, found 0x${magic:-??}). This looks like a blank / never-flashed chip — an app-only flash would write the app but the chip could never boot it. Re-run with --full instead (needs bootloader.bin/partition-table.bin/ota_data_initial.bin pre-staged locally — see AGENTS.md/CLAUDE.md)."
    fi
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
        local latest
        latest="$(ls -1 "$base" 2>/dev/null | sort -V | tail -n1)"
        if [ -n "$latest" ]; then
            if [ -f "$base/$latest/esptool" ]; then
                ESPTOOL_CMD=("$base/$latest/esptool")
                return 0
            fi
            if [ -f "$base/$latest/esptool.py" ]; then
                if command -v python3 >/dev/null 2>&1; then
                    ESPTOOL_CMD=(python3 "$base/$latest/esptool.py")
                    return 0
                fi
                warn "Found esptool.py at $base/$latest but no python3 on PATH."
            fi
        fi
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
    info "Downloading $url"
    if ! curl -fsSL --max-time 60 -o "$dest" "$url"; then
        die "Download failed: $url
Check your internet connection, or pre-stage $OTA_BIN_FILENAME in:
  $dest_dir"
    fi
    printf '%s' "$dest"
}
