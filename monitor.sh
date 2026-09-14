#!/usr/bin/env bash
# Serial monitor: prints whatever the board's own UART logging writes, so
# you can see boot/panic output without Arduino IDE. Read-only — never
# touches flash. Ctrl+C to stop (Ctrl+A K first if it falls back to
# `screen`).
#
# Usage:
#   ./monitor.sh <project> <module> [--port <port>] [--baud <n>]
#
# --baud <n>   Serial baud rate for the board's own log output (default
#              115200 — this is the app's runtime UART speed, NOT the
#              460800 flashing baud used by flash.sh).
#
# Examples:
#   ./monitor.sh wendy rbtensy
#   ./monitor.sh wendy rbtensy --port /dev/cu.usbmodem2101 --baud 115200

set -euo pipefail

TOOLS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$TOOLS_ROOT/lib/common.sh"

usage() {
    sed -n '2,16p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

PROJECT_ARG=""
MODULE_ARG=""
PORT_OVERRIDE=""
BAUD="115200"

while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        --port) PORT_OVERRIDE="${2:?--port requires a value}"; shift 2 ;;
        --baud) BAUD="${2:?--baud requires a value}"; shift 2 ;;
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

[ -n "$PROJECT_ARG" ] && [ -n "$MODULE_ARG" ] || { usage; die "Usage: monitor.sh <project> <module> [options]"; }

load_module_settings "$PROJECT_ARG" "$MODULE_ARG"
resolve_port

info "Opening $SERIAL_PORT at $BAUD baud. Ctrl+C to stop."

if find_pyserial_python3; then
    exec "$PYSERIAL_PYTHON3" -m serial.tools.miniterm --raw "$SERIAL_PORT" "$BAUD"
fi

if command -v screen >/dev/null 2>&1; then
    warn "No pyserial found; falling back to 'screen' (Ctrl+A then K to quit)."
    exec screen "$SERIAL_PORT" "$BAUD"
fi

warn "No serial monitor tool found (pyserial's miniterm or 'screen'); falling back to a raw read-only dump."
if ! stty -f "$SERIAL_PORT" "$BAUD" cs8 -cstopb -parenb raw 2>/dev/null; then
    stty -F "$SERIAL_PORT" "$BAUD" cs8 -cstopb -parenb raw
fi
exec cat "$SERIAL_PORT"
