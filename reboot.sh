#!/usr/bin/env bash
# Reset a board over USB serial without touching flash — uses esptool's own
# reset sequence (the same DTR/RTS dance it performs before/after writing),
# so it works with whatever auto-reset circuit the board actually has.
# Useful after a flash to force a clean boot, or to check "is anything
# there at all" together with monitor.sh.
#
# Usage:
#   ./reboot.sh <project> <module> [--port <port>] [--esp-type esp32|esp32s3]
#
# Examples:
#   ./reboot.sh wendy rbtensy
#   ./reboot.sh wendy rbtensy --port /dev/cu.usbmodem2101

set -euo pipefail

TOOLS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$TOOLS_ROOT/lib/common.sh"

usage() {
    sed -n '2,13p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

PROJECT_ARG=""
MODULE_ARG=""
PORT_OVERRIDE=""
ESP_TYPE_OVERRIDE=""

while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        --port) PORT_OVERRIDE="${2:?--port requires a value}"; shift 2 ;;
        --esp-type) ESP_TYPE_OVERRIDE="${2:?--esp-type requires a value}"; shift 2 ;;
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

[ -n "$PROJECT_ARG" ] && [ -n "$MODULE_ARG" ] || { usage; die "Usage: reboot.sh <project> <module> [options]"; }

load_module_settings "$PROJECT_ARG" "$MODULE_ARG"
[ -n "$ESP_TYPE_OVERRIDE" ] && IDF_TARGET="$ESP_TYPE_OVERRIDE"

resolve_port
find_esptool || die "Could not find esptool. Install the esp32 core in Arduino IDE (Boards Manager), or install esptool yourself (pip install esptool)."

info "Resetting $PROJECT_ARG $MODULE_ARG on $SERIAL_PORT..."
"${ESPTOOL_CMD[@]}" --chip "$IDF_TARGET" --port "$SERIAL_PORT" run

echo "${C_GREEN}${C_BOLD}RESET SENT${C_RESET} — the board should now be booting. Run ./monitor.sh $PROJECT_ARG $MODULE_ARG to watch it."
