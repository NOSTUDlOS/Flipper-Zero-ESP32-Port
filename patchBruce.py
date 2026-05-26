#!/usr/bin/env python3
"""Keep the bundled GhostESP checkout up to date and apply the multi-boot patch.

What it does (idempotent, safe to run before every build):
  1. clones GhostESP-Revival/GhostESP into multi-boot/ghostesp if it's missing
  2. resets the working tree to a pristine state
  3. `git pull --ff-only` so a build always picks up upstream changes
  4. re-applies tools/ghostesp_multiboot.patch (adds the "Flipper Zero" main-menu
     entry that reboots into the ota_0 slot — see 00_Skills/multi-boot.md)
  5. copies partitions_multiboot.csv over GhostESP's custom_16Mb.csv so both
     firmwares are built against the exact same partition table

Exits non-zero (loudly) if the patch no longer applies — that means upstream
GhostESP moved the menu code and tools/ghostesp_multiboot.patch must be regenerated.
"""

import shutil
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent
GHOST_DIR = REPO_ROOT / "multi-boot" / "ghostesp"
GHOST_REPO_URL = "https://github.com/GhostESP-Revival/GhostESP.git"
PATCH_FILE = REPO_ROOT / "tools" / "ghostesp_multiboot.patch"
PARTITIONS_SRC = REPO_ROOT / "partitions_multiboot.csv"
PARTITIONS_DST_NAME = "custom_16Mb.csv"

# Files that tools/ghostesp_multiboot.patch *creates* (as opposed to modifies).
# `git reset --hard` won't remove these, so we delete them explicitly before
# re-applying the patch to keep the operation idempotent.
PATCH_CREATED_FILES = [
    "src/core/menu_items/FlipperOsMenu.h",
    "src/core/menu_items/FlipperOsMenu.cpp",
]


def run(cmd):
    print("+ " + " ".join(str(c) for c in cmd))
    subprocess.run(cmd, check=True)


def git(*args, check=True):
    cmd = ["git", "-C", str(GHOST_DIR), *args]
    print("+ " + " ".join(cmd))
    return subprocess.run(cmd, check=check)


def reset_worktree():
    git("reset", "--hard", "HEAD")
    for rel in PATCH_CREATED_FILES:
        path = GHOST_DIR / rel
        if path.exists():
            print(f"  rm {rel}")
            path.unlink()


def main():
    if not PATCH_FILE.is_file():
        sys.exit(f"error: missing patch file: {PATCH_FILE}")
    if not PARTITIONS_SRC.is_file():
        sys.exit(f"error: missing partition table: {PARTITIONS_SRC}")

    if not (GHOST_DIR / ".git").is_dir():
        if GHOST_DIR.exists():
            if any(GHOST_DIR.iterdir()):
                sys.exit(
                    f"error: {GHOST_DIR} exists but is not a git checkout. "
                    "Remove it and rerun, or run patchGhost.py manually."
                )
            GHOST_DIR.rmdir()  # leftover empty dir — git clone wants it gone
        print(f"GhostESP checkout not found, cloning into {GHOST_DIR} ...")
        GHOST_DIR.parent.mkdir(parents=True, exist_ok=True)
        run(["git", "clone", "--depth", "1", GHOST_REPO_URL, str(GHOST_DIR)])

    # 1) pristine tree
    reset_worktree()

    # 2) keep GhostESP current
    if git("pull", "--ff-only", check=False).returncode != 0:
        print(
            "warning: 'git pull' failed (offline / non-ff?), continuing with the "
            "local GhostESP checkout",
            file=sys.stderr,
        )
        reset_worktree()

    # 3) apply the multi-boot menu patch
    if git("apply", "--whitespace=nowarn", str(PATCH_FILE), check=False).returncode != 0:
        sys.exit(
            "\nerror: tools/ghostesp_multiboot.patch did not apply.\n"
            "Upstream GhostESP most likely changed src/core/main_menu.{h,cpp}.\n"
            "Regenerate the patch — see 00_Skills/multi-boot.md ('Updating the "
            "GhostESP patch').\n"
        )

    # 4) single-source the partition table
    shutil.copyfile(PARTITIONS_SRC, GHOST_DIR / PARTITIONS_DST_NAME)
    print(f"copied {PARTITIONS_SRC.name} -> multi-boot/ghostesp/{PARTITIONS_DST_NAME}")

    print("GhostESP checkout is patched and ready for multi-boot.")


if __name__ == "__main__":
    main()
