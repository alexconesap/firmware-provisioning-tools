#!/usr/bin/env bash
# Developer-only (macOS): copy a firmware project's per-module settings and
# built binaries into this kit's local projects/ tree, so flash/reset can use
# them — including a --full blank-chip flash, which needs the bootloader,
# partition table and OTA-init data the OTA server does not publish yet.
#
# Usage:
#   ./sync.sh <project | path/to/firmware/code> [module ...] [--name <name>]
#                                                [--dry-run]
#
#   <project>            e.g. benny — resolves to ../../benny/code (the
#                        sibling firmware checkout in this workspace).
#   path/to/.../code     Or an explicit path to a firmware repo root.
#   [module ...]         Only these modules (default: every firmware target
#                        listed in the repo's projects.yaml).
#   --name <name>        Folder name under projects/ (default: the project
#                        name, e.g. fs-uv — what flash.sh expects as-typed).
#   --dry-run            Show what would be copied, change nothing.
#
# Copied per module, and nothing else (an explicit whitelist — no .DS_Store,
# no .local.settings, no build clutter):
#   .settings  partitions.csv
#   build/<module>.bin  build/bootloader/bootloader.bin
#   build/partition_table/partition-table.bin  build/ota_data_initial.bin
#
# A build file missing from the source is also removed from the destination,
# so a stale bootloader/app from an older build is never mixed with new files.
#
# Examples:
#   ./sync.sh benny
#   ./sync.sh wendy rbtensy
#   ./sync.sh ~/checkouts/fs-uv/code --name fs-uv

set -euo pipefail

TOOLS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$TOOLS_ROOT/lib/common.sh"

usage() {
    sed -n '2,33p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

SOURCE_ARG=""
NAME_OVERRIDE=""
DRY_RUN=0
MODULES=()

while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        --name) NAME_OVERRIDE="${2:?--name requires a value}"; shift 2 ;;
        --dry-run|-n) DRY_RUN=1; shift ;;
        --*) die "Unknown option: $1 (see --help)" ;;
        *)
            if [ -z "$SOURCE_ARG" ]; then SOURCE_ARG="$1"
            else MODULES+=("$1")
            fi
            shift
            ;;
    esac
done

[ -n "$SOURCE_ARG" ] || { usage; exit 1; }

# A bare project name means the sibling checkout <workspace>/<project>/code;
# anything else is taken as a path to the firmware repo root.
if [ -d "$SOURCE_ARG" ]; then
    SRC_ROOT="$(cd "$SOURCE_ARG" && pwd)"
else
    SRC_ROOT="$(cd "$TOOLS_ROOT/../.." && pwd)/$SOURCE_ARG/code"
    [ -d "$SRC_ROOT" ] || die "No firmware repo at $SRC_ROOT (pass a project name or a path)."
fi

if [ -n "$NAME_OVERRIDE" ]; then
    PROJECT_NAME="$NAME_OVERRIDE"
elif [ "$(basename "$SRC_ROOT")" = "code" ]; then
    PROJECT_NAME="$(basename "$(dirname "$SRC_ROOT")")"
else
    PROJECT_NAME="$(basename "$SRC_ROOT")"
fi

# Module list: the `folder:` of every entry under the top-level `projects:`
# key of projects.yaml (wendy also has a `shared:` section, which is skipped).
if [ ${#MODULES[@]} -eq 0 ]; then
    [ -f "$SRC_ROOT/projects.yaml" ] || die "No projects.yaml in $SRC_ROOT — name the modules explicitly."
    while IFS= read -r m; do
        [ -n "$m" ] && MODULES+=("$m")
    done < <(awk '
        /^[^[:space:]#][^:]*:/ { in_projects = ($0 ~ /^projects:/) }
        in_projects && /^[[:space:]]+folder:/ {
            sub(/^[[:space:]]+folder:[[:space:]]*/, ""); gsub(/["\047[:space:]]/, ""); print
        }' "$SRC_ROOT/projects.yaml")
    [ ${#MODULES[@]} -gt 0 ] || die "No modules found in $SRC_ROOT/projects.yaml."
fi

DEST_PROJECT="$TOOLS_ROOT/projects/$PROJECT_NAME"
info "Source: $SRC_ROOT"
info "Target: $DEST_PROJECT"
info "Modules: ${MODULES[*]}"
[ "$DRY_RUN" = "1" ] && warn "Dry run — nothing will be changed."

run() {
    if [ "$DRY_RUN" = "1" ]; then echo "    (dry-run) $*"; else "$@"; fi
}

# copy_file <src> <dst> — plain copy without extended attributes/resource
# forks (-X), so no Finder metadata comes along either.
copy_file() {
    run mkdir -p "$(dirname "$2")"
    run cp -X "$1" "$2"
    echo "    ${C_GREEN}copied${C_RESET}  ${2#"$DEST_PROJECT/"}"
}

FAILED=0
for module in "${MODULES[@]}"; do
    src="$SRC_ROOT/$module"
    dst="$DEST_PROJECT/$module"
    echo "${C_BOLD}$PROJECT_NAME $module${C_RESET}"

    if [ ! -f "$src/.settings" ] || [ ! -f "$src/partitions.csv" ]; then
        warn "  $src has no .settings/partitions.csv — skipped."
        FAILED=1
        continue
    fi

    copy_file "$src/.settings" "$dst/.settings"
    copy_file "$src/partitions.csv" "$dst/partitions.csv"

    build_src="$SRC_ROOT/build/$module"
    for rel in "$module.bin" bootloader/bootloader.bin \
               partition_table/partition-table.bin ota_data_initial.bin; do
        if [ -f "$build_src/$rel" ]; then
            copy_file "$build_src/$rel" "$dst/build/$rel"
        else
            warn "  missing build/$module/$rel in source (not built?)"
            if [ -f "$dst/build/$rel" ]; then
                run rm -f "$dst/build/$rel"
                echo "    ${C_YELLOW}removed${C_RESET} stale $module/build/$rel"
            fi
            FAILED=1
        fi
    done
done

# Clear out any Finder cruft already sitting in this project's folder.
if [ -d "$DEST_PROJECT" ]; then
    while IFS= read -r junk; do
        run rm -f "$junk"
        echo "    ${C_YELLOW}removed${C_RESET} ${junk#"$DEST_PROJECT/"}"
    done < <(find "$DEST_PROJECT" -type f \( -name .DS_Store -o -name '._*' \))
fi

if [ "$FAILED" = "1" ]; then
    warn "Finished with warnings (see above)."
    exit 1
fi
info "${C_GREEN}Done.${C_RESET}"
