#!/usr/bin/env bash
# Build the OGX-Mini firmware for a chosen Raspberry Pi board and flash it
# through the board's BOOTSEL USB drive.
#
# Usage: ./build-and-flash.sh [BOARD] [--build-only]
#   BOARD         PI_PICO, PI_PICO2, PI_PICOW, PI_PICO2W, RP2040_ZERO,
#                 ADAFRUIT_FEATHER (asked interactively when omitted)
#   --build-only  build the UF2, skip flashing
#   MAX_GAMEPADS  environment variable, 1-4 (default 1)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SDK_DIR="$REPO_ROOT/Firmware/external/pico-sdk"
SDK_TAG="2.1.0"
SDK_URL="https://github.com/raspberrypi/pico-sdk.git"
# Shared picotool checkout/build for all board build dirs (already gitignored).
PICOTOOL_DIR="$REPO_ROOT/Firmware/external/picotool"
BOOTSEL_TIMEOUT=120
REBOOT_TIMEOUT=30

BOARDS=(PI_PICO PI_PICO2 PI_PICOW PI_PICO2W RP2040_ZERO ADAFRUIT_FEATHER)
BOARD_NAMES=(
    "Raspberry Pi Pico          (Controller per USB)"
    "Raspberry Pi Pico 2        (Controller per USB)"
    "Raspberry Pi Pico W        (Controller per Bluetooth)"
    "Raspberry Pi Pico 2 W      (Controller per Bluetooth)"
    "Waveshare RP2040-Zero      (Controller per USB)"
    "Adafruit Feather USB Host  (Controller per USB)"
)

die()  { echo "Fehler: $*" >&2; exit 1; }
info() { echo "==> $*"; }

# Chip family of a board: rp2040 or rp2350. Returns 1 for unknown boards.
board_family() {
    case "$1" in
        PI_PICO|PI_PICOW|RP2040_ZERO|ADAFRUIT_FEATHER) echo rp2040 ;;
        PI_PICO2|PI_PICO2W)                            echo rp2350 ;;
        *) return 1 ;;
    esac
}

# Volume label the boot ROM gives the BOOTSEL drive.
bootsel_label() {
    case "$1" in
        rp2040) echo RPI-RP2 ;;
        rp2350) echo RP2350 ;;
        *) return 1 ;;
    esac
}

# Prints the block device of a BOOTSEL drive for FAMILY.
# Returns 0 if found, 2 if only a drive of the other family is present, 1 if none.
find_bootsel() {
    local family="$1" dir="${OGXM_BYLABEL_DIR:-/dev/disk/by-label}" other
    if [[ -e "$dir/$(bootsel_label "$family")" ]]; then
        readlink -f "$dir/$(bootsel_label "$family")"
        return 0
    fi
    for other in rp2040 rp2350; do
        [[ "$other" == "$family" ]] && continue
        [[ -e "$dir/$(bootsel_label "$other")" ]] && return 2
    done
    return 1
}

usage() {
    cat <<EOF
Baut die OGX-Mini-Firmware für einen Raspberry Pi und flasht sie per BOOTSEL.

Aufruf: ${0##*/} [BOARD] [--build-only]
  BOARD         ${BOARDS[*]}
                (ohne Angabe wird gefragt)
  --build-only  nur bauen, nicht flashen
  MAX_GAMEPADS  Umgebungsvariable, 1 bis 4 (Standard 1)
EOF
}

choose_board() {
    local PS3=$'\nNummer eingeben: ' choice
    echo "Für welchen Raspberry Pi soll die Firmware gebaut werden?" >&2
    select choice in "${BOARD_NAMES[@]}"; do
        if [[ -n "$choice" ]]; then
            echo "${BOARDS[REPLY - 1]}"
            return 0
        fi
        echo "Ungültige Auswahl, bitte eine Nummer aus der Liste." >&2
    done
    die "Keine Auswahl getroffen."
}

check_tools() {
    local build_only="$1" tool
    local -a missing=()
    for tool in git cmake ninja python3 arm-none-eabi-gcc arm-none-eabi-g++; do
        command -v "$tool" >/dev/null || missing+=("$tool")
    done
    if command -v arm-none-eabi-gcc >/dev/null \
        && [[ "$(arm-none-eabi-gcc -print-file-name=libc.a)" == "libc.a" ]]; then
        missing+=("newlib (libc.a)")
    fi
    if (( ! build_only )); then
        for tool in udisksctl findmnt; do
            command -v "$tool" >/dev/null || missing+=("$tool")
        done
    fi
    if (( ${#missing[@]} )); then
        echo "Fehler: Es fehlen: ${missing[*]}" >&2
        echo "Installieren mit:" >&2
        echo "  sudo pacman -S --needed git cmake ninja python arm-none-eabi-gcc arm-none-eabi-newlib udisks2 util-linux" >&2
        exit 1
    fi
}

ensure_sdk() {
    if [[ ! -f "$SDK_DIR/pico_sdk_init.cmake" ]]; then
        info "Lade pico-sdk $SDK_TAG nach $SDK_DIR ..."
        git clone --depth 1 --branch "$SDK_TAG" --recurse-submodules \
            --shallow-submodules "$SDK_URL" "$SDK_DIR"
        return
    fi
    local version
    version="$(sed -n 's/^set(PICO_SDK_VERSION_\(MAJOR\|MINOR\|REVISION\) \([0-9]*\))$/\2/p' \
        "$SDK_DIR/pico_sdk_version.cmake" | paste -sd.)"
    if [[ "$version" != "$SDK_TAG" ]]; then
        echo "Warnung: pico-sdk in $SDK_DIR ist Version $version, getestet ist $SDK_TAG." >&2
    fi
}

# bluepad32 and tinyusb are initialized by CMake itself; these two are not.
ensure_submodules() {
    local sub
    for sub in Firmware/external/Pico-PIO-USB Firmware/external/libfixmath; do
        if [[ -z "$(ls -A "$REPO_ROOT/$sub" 2>/dev/null)" ]]; then
            info "Lade Submodul $sub ..."
            git -C "$REPO_ROOT" submodule update --init "$sub"
        fi
    done
}

build_firmware() {
    local board="$1" gamepads="$2" build_dir="$SCRIPT_DIR/build/$1" cached=""
    if [[ -f "$build_dir/CMakeCache.txt" ]]; then
        cached="$(sed -n 's/^MAX_GAMEPADS:[A-Z]*=//p' "$build_dir/CMakeCache.txt")"
    fi
    # CMakeLists.txt bakes the configure time into BUILD_DATETIME, so every
    # configure run forces a full rebuild. Only configure when needed.
    if [[ -f "$build_dir/build.ninja" && "$cached" == "$gamepads" ]]; then
        info "Build-Ordner $build_dir ist eingerichtet, baue nur Änderungen ..."
    else
        info "Konfiguriere $board (MAX_GAMEPADS=$gamepads) in $build_dir ..."
        cmake -S "$SCRIPT_DIR" -B "$build_dir" -G Ninja \
            -DPICO_SDK_PATH="$SDK_DIR" \
            -DPICOTOOL_FETCH_FROM_GIT_PATH="$PICOTOOL_DIR" \
            -DCMAKE_BUILD_TYPE=Release \
            -DOGXM_BOARD="$board" \
            -DMAX_GAMEPADS="$gamepads"
    fi
    info "Baue Firmware ..."
    # pioasm (pico-sdk 2.1.0 host tool) misses <cstdint> with GCC 16. The env
    # var only reaches host tools configured during the build, not the firmware.
    CXXFLAGS="-include cstdint" cmake --build "$build_dir"
}

# Prints the newest UF2 for BOARD in its build dir.
find_uf2() {
    local board="$1" f newest=""
    for f in "$SCRIPT_DIR/build/$board"/OGX-Mini-*-"$board".uf2; do
        [[ -f "$f" ]] || continue
        [[ -z "$newest" || "$f" -nt "$newest" ]] && newest="$f"
    done
    [[ -n "$newest" ]] || return 1
    echo "$newest"
}

flash_uf2() {
    local uf2="$1" board="$2" family label dev rc mnt waited=0 cp_ok=1
    family="$(board_family "$board")"
    label="$(bootsel_label "$family")"

    echo
    echo "Pico in den BOOTSEL-Modus bringen:"
    echo "  1. Pico vom USB-Kabel trennen."
    echo "  2. BOOTSEL-Taste gedrückt halten, Pico an diesen PC anstecken, Taste loslassen."
    info "Warte auf Laufwerk $label (höchstens ${BOOTSEL_TIMEOUT} s) ..."
    while :; do
        rc=0
        dev="$(find_bootsel "$family")" || rc=$?
        (( rc == 0 )) && break
        if (( rc == 2 )); then
            local found=rp2040
            [[ "$family" == rp2040 ]] && found=rp2350
            die "Angesteckt ist ein Pico mit ${found^^}-Chip, gewählt ist $board (${family^^})." \
                "Es wurde nichts geflasht. Script mit dem passenden Board neu starten."
        fi
        (( waited >= BOOTSEL_TIMEOUT )) \
            && die "Kein Laufwerk $label gefunden. Die Firmware liegt unter $uf2"
        sleep 1
        waited=$((waited + 1))
    done

    # The desktop may automount the drive at the same moment, so retry briefly.
    for _ in 1 2 3 4 5; do
        mnt="$(findmnt -nro TARGET -S "$dev" | head -n1)"
        [[ -n "$mnt" ]] && break
        udisksctl mount -b "$dev" --no-user-interaction >/dev/null 2>&1 || true
        sleep 1
    done
    [[ -n "$mnt" && -d "$mnt" ]] || die "Konnte $dev nicht einhängen."
    [[ -f "$mnt/INFO_UF2.TXT" ]] \
        || die "$mnt ist kein BOOTSEL-Laufwerk (INFO_UF2.TXT fehlt), es wurde nichts geflasht."

    info "Kopiere $(basename "$uf2") nach $mnt ..."
    # The Pico reboots as soon as it has all blocks, which can make cp/sync
    # report an error although flashing worked. The reboot is the real signal.
    cp "$uf2" "$mnt/" || cp_ok=0
    sync 2>/dev/null || true

    # The drive's label link vanishes once the Pico reboots into the firmware.
    waited=0
    while find_bootsel "$family" >/dev/null; do
        (( waited >= REBOOT_TIMEOUT )) \
            && die "Der Pico ist nach ${REBOOT_TIMEOUT} s nicht neu gestartet. Flashen fehlgeschlagen?"
        sleep 1
        waited=$((waited + 1))
    done
    (( cp_ok )) || echo "Hinweis: cp meldete einen Fehler, der Pico hat aber neu gestartet." >&2
    info "Fertig: $board läuft jetzt mit $(basename "$uf2")."
}

main() {
    set -euo pipefail
    local board="" build_only=0 arg family gamepads uf2
    for arg in "$@"; do
        case "$arg" in
            --build-only) build_only=1 ;;
            -h|--help) usage; exit 0 ;;
            -*) die "Unbekannte Option: $arg (siehe --help)" ;;
            *) [[ -z "$board" ]] || die "Bitte nur ein Board angeben."
               board="${arg^^}" ;;
        esac
    done

    [[ -n "$board" ]] || board="$(choose_board)"
    family="$(board_family "$board")" \
        || die "Unbekanntes Board '$board'. Möglich: ${BOARDS[*]}"
    gamepads="${MAX_GAMEPADS:-1}"
    [[ "$gamepads" =~ ^[1-4]$ ]] || die "MAX_GAMEPADS muss 1 bis 4 sein, nicht '$gamepads'."

    check_tools "$build_only"
    ensure_sdk
    ensure_submodules
    build_firmware "$board" "$gamepads"
    uf2="$(find_uf2 "$board")" || die "Build lief durch, aber keine UF2-Datei gefunden."
    info "Firmware ($family): $uf2"

    if (( build_only )); then
        return 0
    fi
    flash_uf2 "$uf2" "$board"

    echo
    echo "Konsolen-Modus: Ab Werk startet OGX-Mini als Original-Xbox-Controller."
    echo "Für die PS3 bei verbundenem Controller Start/Menü + Steuerkreuz links 3 s halten."
    echo "Ein schon eingestellter Modus bleibt bei einem Firmware-Update in der Regel erhalten."
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
