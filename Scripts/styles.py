#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
# Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import argparse
from pathlib import Path
import shutil


STYLES = Path(__file__).resolve().parents[1] / "styles"


def main():
    parser = argparse.ArgumentParser(description="Install a style from this checkout without replacing local files.")
    commands = parser.add_subparsers(dest="command", required=True)
    install = commands.add_parser("install")
    install.add_argument("name", choices=sorted(path.name for path in STYLES.iterdir() if path.is_dir()))
    install.add_argument("--to", type=Path, required=True, metavar="SHELL_FOLDER")
    args = parser.parse_args()
    target = args.to.expanduser() / args.name
    try:
        shutil.copytree(STYLES / args.name, target)
    except OSError as error:
        parser.exit(1, f"Could not install {args.name}: {error}\n")
    print(f"Installed {args.name} in {target}. Choose Use Style in Settings > Styles & Widgets.")


if __name__ == "__main__":
    main()
