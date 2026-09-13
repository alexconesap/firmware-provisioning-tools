#!/usr/bin/env bash
# Wipe a board's saved settings (or its entire flash) over USB via esptool.
# Replicates arduino-build-scripts/erase_settings.sh, but reads the NVS
# offset/size from the module's own partitions.csv instead of assuming the
# classic Arduino default — a differently-partitioned module can differ.
#
# Usage:
#   ./reset.sh <project> <module> [--port <port>] [--full] [--yes]
#
#   <project> <module>   e.g. wendy rbtensy — resolves to ./wendy/rbtensy/
#   --port <port>        Override the serial port (skips auto-detect/prompt).
#   --full                 Erase the ENTIRE flash, including the firmware
#                         itself — not just NVS. The device will need a full
#                         `flash` afterward, not just a reset. Without this
#                         flag, only the NVS/settings partition is erased.
#   --yes / -y             Skip the confirmation prompt.
#
# Examples:
#   ./reset.sh wendy rbtensy
#   ./reset.sh wendy rbtensy --full

set -euo pipefail

TOOLS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$TOOLS_ROOT/lib/common.sh"

usage() {
    sed -n '2,21p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

PROJECT_ARG=""
MODULE_ARG=""
PORT_OVERRIDE=""
FULL=0
ASSUME_YES=0

while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        --port) PORT_OVERRIDE="${2:?--port requires a value}"; shift 2 ;;
        --full) FULL=1; shift ;;
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

[ -n "$PROJECT_ARG" ] && [ -n "$MODULE_ARG" ] || { usage; die "Usage: reset.sh <project> <module> [options]"; }

load_module_settings "$PROJECT_ARG" "$MODULE_ARG"
resolve_port
find_esptool || die "Could not find esptool. Install the esp32 core in Arduino IDE (Boards Manager), or install esptool yourself (pip install esptool)."
parse_partitions_csv "$PARTITIONS_CSV"

set +e
if [ "$FULL" -eq 1 ]; then
    echo "${C_RED}${C_BOLD}This will erase the ENTIRE flash on this board, including its firmware.${C_RESET}"
    echo "It will not run again until you flash it (./flash.sh $PROJECT_ARG $MODULE_ARG --full)."
    confirm "Erase everything on ${SERIAL_PORT}?" || die "Aborted."
    "${ESPTOOL_CMD[@]}" --chip "$IDF_TARGET" --port "$SERIAL_PORT" erase_flash
    RC=$?
else
    echo "Erasing NVS/settings only — offset $NVS_OFFSET, size $NVS_SIZE (from $PARTITIONS_CSV)."
    confirm "Erase settings on ${SERIAL_PORT}?" || die "Aborted."
    "${ESPTOOL_CMD[@]}" --chip "$IDF_TARGET" --port "$SERIAL_PORT" erase_region "$NVS_OFFSET" "$NVS_SIZE"
    RC=$?
fi
set -e

echo
if [ "$RC" -eq 0 ]; then
    echo "${C_GREEN}${C_BOLD}RESET DONE${C_RESET} — ${PROJECT_ARG} ${MODULE_ARG}  port: ${C_YELLOW}${SERIAL_PORT}${C_RESET}"
else
    echo "${C_RED}${C_BOLD}RESET FAILED${C_RESET} — ${PROJECT_ARG} ${MODULE_ARG}  port: ${C_YELLOW}${SERIAL_PORT}${C_RESET}"
fi
exit "$RC"
