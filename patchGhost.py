#!/usr/bin/env python3
"""Patches GhostESP's LVGL main menu to add a native 'Reboot to Flipper' GUI item."""

import shutil
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent
GHOST_DIR = REPO_ROOT / "multi-boot" / "ghostesp"
GHOST_REPO_URL = "https://github.com/GhostESP-Revival/GhostESP.git"
PARTITIONS_SRC = REPO_ROOT / "partitions_multiboot.csv"
PARTITIONS_DST_NAME = "custom_16Mb.csv"

# Pfad zur Menüdatei
MENU_SCREEN_C = GHOST_DIR / "main" / "managers" / "views" / "main_menu_screen.c"

def main():
    import subprocess
    
    if not PARTITIONS_SRC.is_file():
        sys.exit(f"error: missing partition table: {PARTITIONS_SRC}")

    # 1) Repository klonen falls nicht vorhanden
    if not (GHOST_DIR / ".git").is_dir():
        print(f"GhostESP checkout not found, cloning into {GHOST_DIR} ...")
        GHOST_DIR.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(["git", "clone", "--depth", "1", GHOST_REPO_URL, str(GHOST_DIR)], check=True)

    # 2) Repository sauber zurücksetzen
    subprocess.run(["git", "-C", str(GHOST_DIR), "reset", "--hard", "HEAD"], check=True)

    if not MENU_SCREEN_C.is_file():
        sys.exit(f"error: GhostESP menu file not found at {MENU_SCREEN_C}")

    # 3) main_menu_screen.c einlesen
    with open(MENU_SCREEN_C, "r", encoding="utf-8") as f:
        code = f.read()

    # --- INJEKTION 1: OTA & Reboot Logik ganz oben einflechten ---
    ota_reboot_logic = """
// --- Multi-boot Add-on GUI Action ---
#include "esp_ota_ops.h"
#include "esp_partition.h"

static void gui_reboot_to_flipper(void) {
    const esp_partition_t *target = esp_partition_find_first(
        ESP_PARTITION_TYPE_APP, ESP_PARTITION_SUBTYPE_APP_OTA_0, NULL);
    if (target != NULL) {
        esp_ota_set_boot_partition(target);
        vTaskDelay(pdMS_TO_TICKS(100));
        esp_restart();
    }
}
// ------------------------------------
"""
    if "gui_reboot_to_flipper" not in code:
        # Nach den Standard-Includes einfügen
        code = code.replace('#include "managers/views/main_menu_screen.h"', '#include "managers/views/main_menu_screen.h"\n' + ota_reboot_logic)

    # --- INJEKTION 2: Menüpunkt im Array registrieren ---
    # Wir hängen es direkt vor "Settings" an, damit es auf jedem Board sichtbar ist
    target_item = '{"Settings", &settings_icon, 5, {{0}}}, // applies to all boards'
    flipper_item = '{"Flipper", &settings_icon, 2, {{0}}},\n    {"Settings", &settings_icon, 5, {{0}}}, // applies to all boards'
    
    if target_item in code and '{"Flipper"' not in code:
        code = code.replace(target_item, flipper_item)

    # --- INJEKTION 3: Die Klick-Aktion in handle_menu_item_selection einbauen ---
    target_action = '{"Settings", OT_Settings, &options_menu_view},'
    flipper_action = '{"Flipper", 0, NULL},\n        {"Settings", OT_Settings, &options_menu_view},'
    
    if target_action in code and '"Flipper"' not in code:
        code = code.replace(target_action, flipper_action)

    # Die eigentliche Ausführung abfangen (bevor die Ansicht gewechselt wird)
    target_execution = 'if (!target_view) {'
    execution_intercept = """if (strcmp(name, "Flipper") == 0) {
        status_display_show_status("Booting Flipper...");
        gui_reboot_to_flipper();
        return;
    }

    if (!target_view) {"""
    
    if target_execution in code and 'strcmp(name, "Flipper")' not in code:
        code = code.replace(target_execution, execution_intercept)

    # 4) Datei zurückschreiben
    with open(MENU_SCREEN_C, "w", encoding="utf-8") as f:
        f.write(code)

    # 5) Partitionstabelle rüberkopieren
    shutil.copyfile(PARTITIONS_SRC, GHOST_DIR / PARTITIONS_DST_NAME)
    print("Successfully patched GhostESP's LVGL main menu for Multi-Boot!")

if __name__ == "__main__":
    main()
