#!/usr/bin/env bash
set -e

# ==============================================================================
# KONFIGURATION
# ==============================================================================
TARGET="esp32s3"
GHOST_DIR="/home/runner/work/Flipper-Zero-ESP32-Port/Flipper-Zero-ESP32-Port/multi-boot/ghostesp"
PATCH_SCRIPT="./patchGhost.py"
# Exakter Pfad zu deiner Board-Konfiguration innerhalb des Repositories
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

echo "=== 4. Starte ESP-IDF Build (--build-only) ==="
cd "$GHOST_DIR"

# Überprüfen, ob die angegebene SDK-Datei wirklich existiert
if [ ! -f "$SDK_PATH" ]; then
    echo "FEHLER: Die Datei $SDK_PATH wurde nicht gefunden!"
    echo "Aktueller Ordnerinhalt von configs/:"
    ls -la configs/ || true
    exit 1
fi

echo "Nutze Board-Konfiguration: $SDK_PATH"

# Setze das Ziel-Target auf den ESP32-S3 Chip des LilyGO
idf.py set-target "$TARGET"

# Führe den reinen Build mit der korrekten sdkconfig aus.
# (Der reine "build"-Befehl in GitHub Actions kompiliert nur, ohne zu flashen)
idf.py -D SDKCONFIG_DEFAULTS="$SDK_PATH" build

echo "=== Build erfolgreich abgeschlossen! ==="
