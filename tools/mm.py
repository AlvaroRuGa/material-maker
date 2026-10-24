#!/usr/bin/env python3
"""Command line front end for Material Maker (headless).

    python tools/mm.py <command> [arguments]       # see: python tools/mm.py help

Wraps `Godot --cli ...`, hides the engine log noise and prints the result as JSON.
Exit status is 0 on success, 1 on error. Add --log to always show the engine log.
Set MM_GODOT (Godot 4.7 binary) or MM_EXE (exported Material Maker) first; see mm_launcher.py.
"""
import json
import sys

from mm_launcher import LauncherError, interesting_log, run_cli


def main(argv):
    show_log = "--log" in argv
    argv = [a for a in argv if a != "--log"]
    try:
        result, log = run_cli(argv)
    except LauncherError as e:
        print(json.dumps({"error": str(e)}), file=sys.stderr)
        return 2
    if result is None:
        # `help` and usage errors print plain text
        text = interesting_log(log, 80)
        print(text)
        return 0 if (not argv or argv[0] == "help") else 1
    print(json.dumps(result, indent=2))
    if show_log or "error" in result:
        extra = interesting_log(log)
        if extra:
            print(extra, file=sys.stderr)
    return 1 if "error" in result else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
