#!/usr/bin/env python3
"""Command line front end for Material Maker (headless).

    python tools/mm.py <command> [arguments]       # see: python tools/mm.py help

Wraps `Godot --cli ...`, hides the engine log noise and prints the result as JSON.
Exit status is 0 on success, 1 on error. Add --log to always show the engine log.
Set MM_GODOT (Godot 4.7 binary) or MM_EXE (exported Material Maker) first; see mm_launcher.py.
"""
import json
import os
import sys

from mm_launcher import LauncherError, Server, interesting_log, run_cli, start_gui


def gui(argv):
    """gui [--port N] [file.ptex ...]: open the editor with the live server on (default port 8765)."""
    port = 8765
    if "--port" in argv:
        i = argv.index("--port")
        port = int(argv[i + 1])
        argv = argv[:i] + argv[i + 2:]
    try:
        proc = start_gui(port, argv)
    except LauncherError as e:
        print(json.dumps({"error": str(e)}), file=sys.stderr)
        return 2
    print(json.dumps({"ok": True, "pid": proc.pid, "port": port,
                      "next": "python tools/mm.py live --port %d ping   (once the window is up)" % port}))
    return 0


def live(argv):
    """live [--port N] <op> [json args]: send one operation to a running editor (see `gui`)."""
    port = int(os.environ.get("MM_LIVE_PORT", "8765"))
    if "--port" in argv:
        i = argv.index("--port")
        port = int(argv[i + 1])
        argv = argv[:i] + argv[i + 2:]
    if not argv:
        print(live.__doc__)
        return 1
    try:
        args = json.loads(argv[1]) if len(argv) > 1 else {}
    except ValueError as e:
        print(json.dumps({"error": "args must be JSON: %s" % e}), file=sys.stderr)
        return 2
    server = Server(cwd=os.getcwd(), live_port=port)
    try:
        resp = server.call(argv[0], args)
    except LauncherError as e:
        print(json.dumps({"error": str(e)}), file=sys.stderr)
        return 2
    finally:
        server.stop()
    print(json.dumps(resp.get("result") if resp.get("ok") else {"error": resp.get("error"), "details": resp.get("details")}, indent=2))
    return 0 if resp.get("ok") else 1


def main(argv):
    if argv and argv[0] == "gui":
        return gui(argv[1:])
    if argv and argv[0] == "live":
        return live(argv[1:])
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
