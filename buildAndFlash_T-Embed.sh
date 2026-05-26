#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ESP32_DIR="${SCRIPT_DIR}"
PORT="${ESPPORT:-}"
RUN_MONITOR=0
BUILD_ONLY=0
SKIP_GHOST=0
EXPORT_SCRIPT="${ESP_IDF_EXPORT_SCRIPT:-${HOME}/esp/esp-idf/export.sh}"

BOARD="lilygo_t_embed_cc1101"
BUILD_DIR="build_t_embed"
IDF_TARGET="esp32s3"

# --- Multi-boot (GhostESP in the ota_1 slot) ---------------------------------
# This board ships with two firmwares flashed side by side: this Flipper Zero
# port in ota_0 and the GhostESP firmware in ota_1 (see 00_Skills/multi-boot.md
# and partitions_multiboot.csv). buildAndFlash builds both and flashes both.
GHOST_DIR="${ESP32_DIR}/multi-boot/ghostesp"
GHOST_BUILD_DIR="${GHOST_DIR}/build"
PATCH_GHOST="${ESP32_DIR}/patchGhost.py"
PARTITIONS_CSV="${ESP32_DIR}/partitions_multiboot.csv"

detect_usbmodem_port() {
    local matches=()
    shopt -s nullglob
    matches=(/dev/cu.usbmodem* /dev/ttyACM*)
    shopt -u nullglob

    if [[ "${#matches[@]}" -eq 1 ]]; then
        printf '%s\n' "${matches[0]}"
        return 0
    fi

    if [[ "${#matches[@]}" -eq 0 ]]; then
        if [[ "${BUILD_ONLY}" -eq 0 ]]; then
            echo "No serial device found (searched /dev/cu.usbmodem* and /dev/ttyACM*). Use --port or set ESPPORT." >&2
            return 1
        else
            return 0
        fi
    else
        echo "Multiple serial devices found: ${matches[*]}" >&2
        echo "Use --port or set ESPPORT." >&2
        return 1
    fi
}

# Read a partition offset (e.g. "ota_1") from partitions_multiboot.csv.
partition_offset() {
    awk -F',' -v name="$1" '
        $1 ~ "^[[:space:]]*"name"[[:space:]]*$" {
            gsub(/[[:space:]]/, "", $4);
            print $4;
            exit
        }' "${PARTITIONS_CSV}"
}

usage() {
    cat <<EOF
Usage: $(basename "$0") [--port <device>] [--monitor] [--build-only] [--skip-ghost]

Builds and flashes the multi-boot image for the LilyGo T-Embed CC1101:
  ota_0 = this ESP32 Flipper Zero port      ota_1 = GhostESP firmware

It runs patchGhost.py (clone/pull + patch the bundled GhostESP checkout), builds
GhostESP with ESP-IDF, builds this firmware with ESP-IDF, then flashes both.

Options:
  --port <device>  Serial device to flash. Default: auto-detect /dev/cu.usbmodem* (macOS) or /dev/ttyACM* (Linux)
  --monitor        Open idf.py monitor after flashing
  --build-only     Build both firmwares, skip flashing
  --skip-ghost     Don't touch / build / flash GhostESP — only this firmware

Environment:
  ESPPORT                  Overrides the auto-detected serial device
  ESP_IDF_EXPORT_SCRIPT    Overrides the ESP-IDF export.sh path
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --port|-p)
            if [[ $# -lt 2 ]]; then
                echo "Missing value for $1" >&2
                usage
                exit 1
            fi
            PORT="$2"
            shift 2
            ;;
        --monitor|-m)
            RUN_MONITOR=1
            shift
            ;;
        --build-only)
            BUILD_ONLY=1
            shift
            ;;
        --skip-ghost)
            SKIP_GHOST=1
            shift
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            usage
            exit 1
            ;;
    esac
done

if [[ -z "${PORT}" && "${BUILD_ONLY}" -eq 0 ]]; then
    PORT="$(detect_usbmodem_port)"
fi

if [[ ! -f "${EXPORT_SCRIPT}" ]]; then
    echo "ESP-IDF export script not found: ${EXPORT_SCRIPT}" >&2
    exit 1
fi

echo "Board:          ${BOARD}"
echo "Target:         ${IDF_TARGET}"
echo "Build dir:      ${BUILD_DIR}"
echo "Using ESP-IDF:  ${EXPORT_SCRIPT}"
echo "Serial port:    ${PORT}"
if [[ "${SKIP_GHOST}" -eq 1 ]]; then
    echo "GhostESP:       skipped (--skip-ghost)"
else
    echo "GhostESP:       ${GHOST_DIR}"
fi

# Kill any process holding the serial port exclusively (e.g. a left-over
# `idf.py monitor`, `screen`, `pyserial`). Without this the flash fails with
# "Could not exclusively lock port [...] Resource temporarily unavailable".
release_serial_port() {
    local port="$1"
    [[ -z "${port}" || ! -e "${port}" ]] && return 0
    if ! command -v lsof >/dev/null 2>&1; then return 0; fi
    local pids
    pids="$(lsof -t "${port}" 2>/dev/null || true)"
    if [[ -n "${pids}" ]]; then
        echo "Releasing serial port ${port} from PID(s): ${pids}" >&2
        # shellcheck disable=SC2086
        kill -9 ${pids} 2>/dev/null || true
        sleep 0.3
    fi
}

# Lade die ESP-IDF Toolchain-Umgebung direkt am Anfang, da wir sie für beide brauchen
# shellcheck source=/dev/null
source "${EXPORT_SCRIPT}"

# Platzhalter Variable für die automatische Dateierkennung initialisieren
GHOST_BIN=""

# ---------------------------------------------------------------------------
# 1) GhostESP: update the bundled checkout, patch it, build it with ESP-IDF (idf.py).
# ---------------------------------------------------------------------------
if [[ "${SKIP_GHOST}" -eq 0 ]]; then
    echo
    echo "=== Updating + patching GhostESP ==="
    python3 "${PATCH_GHOST}"

    echo
    echo "=== Building GhostESP ==="
    cd "${GHOST_DIR}"
    
    # Target setzen, falls das Build-Verzeichnis noch jungfräulich ist
    if [[ ! -f "${GHOST_BUILD_DIR}/build.ninja" ]]; then
        echo "Setting GhostESP target to ${IDF_TARGET}..."
        idf.py -B "${GHOST_BUILD_DIR}" set-target "${IDF_TARGET}"
    fi
    
    # Reconfigure & Build via CMake/IDF
    idf.py -B "${GHOST_BUILD_DIR}" reconfigure build

    # Automatische Erkennung der .bin-Hauptanwendung (ignoriert Bootloader/Partition-Table)
    GHOST_BIN=$(find "${GHOST_BUILD_DIR}" -maxdepth 1 -name "*.bin" ! -name "bootloader.bin" ! -name "partition-table.bin" | head -n 1)

    if [[ -z "${GHOST_BIN}" || ! -f "${GHOST_BIN}" ]]; then
        echo "Error: GhostESP build did not produce any application .bin file in ${GHOST_BUILD_DIR}" >&2
        exit 1
    fi
    echo "GhostESP firmware automatically detected: ${GHOST_BIN}"
fi

# ---------------------------------------------------------------------------
# 2) This firmware: build (and flash) with ESP-IDF.
# ---------------------------------------------------------------------------
echo
echo "=== Building this firmware ==="

if [[ "${BUILD_ONLY}" -eq 0 ]]; then
    release_serial_port "${PORT}"
fi

cd "${ESP32_DIR}"

# Set target if build dir doesn't exist yet or target changed
if [[ ! -f "${BUILD_DIR}/build.ninja" ]]; then
    echo "Setting IDF target to ${IDF_TARGET}..."
    idf.py -B "${BUILD_DIR}" set-target "${IDF_TARGET}"
fi

# Flash GhostESP's app image into the ota_1 slot, and make sure otadata is erased
# so the bootloader boots ota_0 (this firmware) by default.
flash_ghost() {
    [[ "${SKIP_GHOST}" -eq 1 ]] && return 0
    local ota1_offset otadata_offset
    ota1_offset="$(partition_offset ota_1)"
    otadata_offset="$(partition_offset otadata)"
    if [[ -z "${ota1_offset}" ]]; then
        echo "Could not determine ota_1 offset from ${PARTITIONS_CSV}" >&2
        exit 1
    fi
    
    # Da der Build-Schritt oben die Variable füllt, stellen wir hier sicher, dass sie existiert
    if [[ -z "${GHOST_BIN}" ]]; then
        GHOST_BIN=$(find "${GHOST_BUILD_DIR}" -maxdepth 1 -name "*.bin" ! -name "bootloader.bin" ! -name "partition-table.bin" | head -n 1)
    fi

    echo
    echo "=== Flashing GhostESP to ota_1 (${ota1_offset}) ==="
    release_serial_port "${PORT}"
    # otadata is 0x2000 bytes; erasing it (-> 0xFF) makes the bootloader pick ota_0.
    if [[ -n "${otadata_offset}" ]]; then
        esptool.py --chip "${IDF_TARGET}" -p "${PORT}" --before default_reset --after no_reset \
            erase_region "${otadata_offset}" 0x2000
    fi
    esptool.py --chip "${IDF_TARGET}" -p "${PORT}" --before default_reset --after hard_reset \
        write_flash --flash_size detect "${ota1_offset}" "${GHOST_BIN}"
}

if [[ "${BUILD_ONLY}" -eq 1 ]]; then
    idf.py -B "${BUILD_DIR}" -DFLIPPER_BOARD="${BOARD}" reconfigure build
    echo
    echo "Build complete (--build-only). Nothing flashed."
    exit 0
fi

idf.py -B "${BUILD_DIR}" -DFLIPPER_BOARD="${BOARD}" -p "${PORT}" reconfigure build flash
flash_ghost

if [[ "${RUN_MONITOR}" -eq 1 ]]; then
    release_serial_port "${PORT}"
    idf.py -B "${BUILD_DIR}" -p "${PORT}" monitor
fi
