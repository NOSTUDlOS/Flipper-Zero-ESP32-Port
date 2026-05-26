#!/usr/bin/env bash
set -e

# ==============================================================================
# KONFIGURATION
# ==============================================================================
TARGET="esp32s3"
GHOST_DIR="/home/runner/work/Flipper-Zero-ESP32-Port/Flipper-Zero-ESP32-Port/multi-boot/ghostesp"
PATCH_SCRIPT="./patchGhost.py"
# KORREKTUR: "C1101" statt "CC1101" (Entwickler-Tippfehler im Repo)
SDK_PATH="configs/sdkconfig.TEmbedC1101"

echo "=== 1. ESP-IDF Umgebung laden ==="
if [ -f "$HOME/esp/esp-idf/export.sh" ]; then
    source "$HOME/esp/esp-idf/export.sh"
else
    echo "Fehler: export.sh nicht gefunden unter $HOME/esp/esp-idf/"
    exit 1
fi

echo "=== 2. GhostESP Repository vorbereiten ==="
if [ ! -d "$GHOST_DIR/.git" ]; then
    echo "Klone GhostESP nach $GHOST_DIR..."
    git clone --recursive https://github.com/GhostESP-Revival/GhostESP.git "$GHOST_DIR"
else
    echo "GhostESP existiert bereits. Setze Änderungen zurück und aktualisiere..."
    cd "$GHOST_DIR"
    git reset --hard HEAD
    git clean -fd
    git pull
    cd - > /dev/null
fi

echo "=== 3. Multi-Boot-Patch anwenden ==="
if [ -f "$PATCH_SCRIPT" ]; then
    echo "Führe Patch-Skript aus..."
    python3 "$PATCH_SCRIPT"
else
    echo "WARNUNG: $PATCH_SCRIPT nicht im aktuellen Verzeichnis gefunden!"
    echo "Stelle sicher, dass patchGhost.py existiert, bevor du den Build startest."
fi

echo "=== 4. Board-Konfiguration vorbereiten ==="
cd "$GHOST_DIR"

# Überprüfen, ob die angegebene SDK-Datei wirklich existiert
if [ ! -f "$SDK_PATH" ]; then
    echo "FEHLER: Die Datei $SDK_PATH wurde nicht gefunden!"
    exit 1
fi

echo "Nutze Board-Konfiguration: $SDK_PATH"

# TRICK: Kopiere die funktionierende Board-Konfiguration als 'sdkconfig.defaults'
# und zusätzlich als 'sdkconfig' direkt in das Hauptverzeichnis.
# Damit ist CMake beim anschließenden 'set-target' sofort wunschlos glücklich.
cp "$SDK_PATH" sdkconfig.defaults
cp "$SDK_PATH" sdkconfig

echo "=== 5. Starte ESP-IDF Build (--build-only) ==="
# Setze das Ziel-Target auf den ESP32-S3 Chip
idf.py set-target "$TARGET"

# Führe den eigentlichen Kompiliervorgang aus
echo "Kompiliere Firmware..."
export CMAKE_BUILD_PARALLEL_LEVEL=$(nproc)
idf.py build

echo "=== Build erfolgreich abgeschlossen! ==="
