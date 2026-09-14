#!/usr/bin/env bash
# Flash firmware onto an ESP32 / ESP32-S3 board over USB, using nothing but
# esptool (bundled inside the Arduino IDE's esp32 core) — no ESP-IDF, no git,
# no source repo required.
#
# Usage:
#   ./flash.sh <project> <module> [--port <port>] [--esp-type esp32|esp32s3]
#                                  [--baud <n>] [--full] [--refresh] [--yes]
#
#   <project> <module>   e.g. wendy rbtensy — resolves to ./wendy/rbtensy/
#   --port <port>        Override the serial port (skips auto-detect/prompt).
#   --esp-type <type>    Override IDF_TARGET from .settings.
#   --baud <n>            Flash baud rate (default 460800).
#   --full                Blank-chip flash: writes bootloader + partition
#                         table + OTA-init data + the app, instead of just
#                         re-flashing the app over an existing bootloader.
#                         Requires those files pre-staged locally (the OTA
#                         server does not publish them yet);
#                         this is the "prepared on a laptop before going
#                         on-site" case.
#   --refresh             Re-download the app binary even if a cached copy
#                         already sits in the local cache.
#   --yes / -y             Skip the confirmation prompt before flashing.
#
# Examples:
#   ./flash.sh wendy rbtensy
#   ./flash.sh wendy rbtensy --port /dev/cu.usbmodem2101
#   ./flash.sh wendy rbtensy --full          (needs pre-staged build files)
#
# The exact same command re-flashes a device instead of a fresh chip — there
# is no separate "update over serial" path.

set -euo pipefail

TOOLS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$TOOLS_ROOT/lib/common.sh"

usage() {
    sed -n '2,31p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

PROJECT_ARG=""
MODULE_ARG=""
PORT_OVERRIDE=""
ESP_TYPE_OVERRIDE=""
BAUD="460800"
FULL=0
REFRESH=0
ASSUME_YES=0

while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        --port) PORT_OVERRIDE="${2:?--port requires a value}"; shift 2 ;;
        --esp-type) ESP_TYPE_OVERRIDE="${2:?--esp-type requires a value}"; shift 2 ;;
        --baud) BAUD="${2:?--baud requires a value}"; shift 2 ;;
        --full) FULL=1; shift ;;
        --refresh) REFRESH=1; shift ;;
        --yes|-y) ASSUME_YES=1; shift ;;
        --*) die "Unknown option: $1 (see --help)" ;;
        *)
            if [ -z "$PROJECT_ARG" ]; then PROJECT_ARG="$1"
            elif [ -z "$MODULE_ARG" ]; then MODULE_ARG="$1"
            else die "Unexpected argument: $1"
            fi
            shift
            ;;
    esac
done

[ -n "$PROJECT_ARG" ] && [ -n "$MODULE_ARG" ] || { usage; die "Usage: flash.sh <project> <module> [options]"; }

load_module_settings "$PROJECT_ARG" "$MODULE_ARG"
[ -n "$ESP_TYPE_OVERRIDE" ] && IDF_TARGET="$ESP_TYPE_OVERRIDE"

resolve_port
find_esptool || die "Could not find esptool. Install the esp32 core in Arduino IDE (Boards Manager), or install esptool yourself (pip install esptool)."
parse_partitions_csv "$PARTITIONS_CSV"

BUILD_DIR="$(cache_build_dir "$PROJECT_ARG" "$MODULE_ARG")"
mkdir -p "$BUILD_DIR"

BOOTLOADER_OFFSET="$(bootloader_offset_for_target "$IDF_TARGET")"
FLASH_ARGS=()

if [ "$FULL" -eq 1 ]; then
    BOOTLOADER_FILE="$BUILD_DIR/bootloader/bootloader.bin"
    PARTTABLE_FILE="$BUILD_DIR/partition_table/partition-table.bin"
    OTADATA_FILE="$BUILD_DIR/ota_data_initial.bin"
    APP_FILE="$BUILD_DIR/$OTA_BIN_FILENAME"

    MISSING=()
    for f in "$BOOTLOADER_FILE" "$PARTTABLE_FILE" "$OTADATA_FILE" "$APP_FILE"; do
        [ -f "$f" ] || MISSING+=("$f")
    done
    if [ ${#MISSING[@]} -gt 0 ]; then
        echo "Full blank-chip flash needs these files staged locally first (the update" >&2
        echo "server doesn't publish them yet):" >&2
        for f in "${MISSING[@]}"; do echo "  - $f" >&2; done
        echo "" >&2
        echo "Copy a full 'code/build/$MODULE_ARG/' folder from a developer machine into:" >&2
        echo "  $BUILD_DIR" >&2
        die "Missing pre-staged build files."
    fi

    FLASH_ARGS=(
        "$BOOTLOADER_OFFSET" "bootloader/bootloader.bin"
        "0x8000" "partition_table/partition-table.bin"
        "$OTADATA_OFFSET" "ota_data_initial.bin"
        "$APP_OFFSET" "$OTA_BIN_FILENAME"
    )
    MODE_LABEL="full (blank-chip) flash"
else
    check_bootloader_present "$BOOTLOADER_OFFSET"
    APP_FILE="$BUILD_DIR/$OTA_BIN_FILENAME"
    if [ "$REFRESH" -eq 1 ] || [ ! -f "$APP_FILE" ]; then
        download_app_bin "$BUILD_DIR" >/dev/null
    else
        info "Using cached binary: $APP_FILE (pass --refresh to re-download)"
    fi
    FLASH_ARGS=("$APP_OFFSET" "$OTA_BIN_FILENAME")
    MODE_LABEL="app-only flash (existing bootloader/partition table preserved)"
    if [ -n "$APP1_OFFSET" ]; then
        # Two-slot OTA layout: the device may currently be booting from
        # ota_1, not ota_0 (normal after any real OTA update), so write the
        # same image to both slots — otherwise "succeeded" can silently land
        # in the slot that isn't actually booted, and the old version keeps
        # running. See AGENTS.md/CLAUDE.md, "Implemented scripts".
        FLASH_ARGS+=("$APP1_OFFSET" "$OTA_BIN_FILENAME")
        MODE_LABEL="app-only flash, both OTA slots (existing bootloader/partition table preserved)"
    fi
fi

print_separator() { printf '%*s\n' "67" '' | tr ' ' '='; }

print_separator
echo "Product/board:  ${C_CYAN}${PROJECT_ARG} ${MODULE_ARG}${C_RESET}"
echo "Chip:           $IDF_TARGET"
echo "Port:           ${C_YELLOW}${SERIAL_PORT}${C_RESET}"
echo "Mode:           $MODE_LABEL"
echo "Files:"
i=0
while [ "$i" -lt ${#FLASH_ARGS[@]} ]; do
    echo "  ${FLASH_ARGS[$i]}  ${FLASH_ARGS[$((i + 1))]}"
    i=$((i + 2))
done
print_separator

confirm "Flash now?" || die "Aborted."

LOG_FILE="$BUILD_DIR/flash.last.log"
: > "$LOG_FILE"

set +e
(
    cd "$BUILD_DIR"
    "${ESPTOOL_CMD[@]}" --chip "$IDF_TARGET" --port "$SERIAL_PORT" --baud "$BAUD" \
        write_flash -z --flash_mode keep --flash_freq keep --flash_size keep \
        "${FLASH_ARGS[@]}"
) 2>&1 | tee "$LOG_FILE"
RC=${PIPESTATUS[0]}
set -e

echo
if [ "$RC" -eq 0 ]; then
    echo "${C_GREEN}${C_BOLD}FLASH SUCCEEDED${C_RESET} — ${PROJECT_ARG} ${MODULE_ARG}  port: ${C_YELLOW}${SERIAL_PORT}${C_RESET}"
else
    echo "${C_RED}${C_BOLD}FLASH FAILED${C_RESET} — ${PROJECT_ARG} ${MODULE_ARG}  port: ${C_YELLOW}${SERIAL_PORT}${C_RESET}"
    echo "Full log: $LOG_FILE"
fi
exit "$RC"
