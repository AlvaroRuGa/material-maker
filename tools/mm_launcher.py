"""Shared helpers to start Material Maker headlessly (used by mm.py and mm_mcp.py).

Finding the program, in order:
  MM_EXE    path of an exported Material Maker executable (runs `<exe> --cli ...`)
  MM_GODOT  path of a Godot 4.7 binary, run against this source tree (godot --path <repo> ...)
  GODOT     same as MM_GODOT
  godot / godot4 found on PATH
"""
import json
import os
import shutil
import socket
import subprocess
import sys
import threading
import time
from collections import deque

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RESULT_MARKER = "@@MM_RESULT@@ "
READY_MARKER = "@@MM_READY@@ "


class LauncherError(RuntimeError):
    pass


def _console_variant(path):
    """On Windows the GUI-subsystem Godot exe does not reliably write to pipes."""
    base, ext = os.path.splitext(path)
    if sys.platform == "win32" and ext.lower() == ".exe" and not base.lower().endswith("_console"):
        candidate = base + "_console" + ext
        if os.path.exists(candidate):
            return candidate
    return path


def command_prefix():
    """argv that precedes the `--cli ...` arguments."""
    exe = os.environ.get("MM_EXE")
    if exe:
        return [exe]
    godot = os.environ.get("MM_GODOT") or os.environ.get("GODOT")
    if not godot:
        for name in ("godot", "godot4", "Godot"):
            godot = shutil.which(name)
            if godot:
                break
    if not godot:
        raise LauncherError(
            "Cannot find Godot. Set MM_GODOT to a Godot 4.7 binary (or MM_EXE to an exported "
            "Material Maker), or put godot on PATH.")
    godot = _console_variant(godot)
    # --no-window: rendering still works (GPU needed) but no window is shown
    return [godot, "--path", REPO, "--no-window", "--"]


def _env(cwd):
    env = dict(os.environ)
    env["MM_CWD"] = (cwd or os.getcwd()).replace("\\", "/")
    return env


def start_gui(port=8765, files=()):
    """Launch the editor with the live server enabled. Returns the Popen (the editor keeps running)."""
    argv = command_prefix()
    exe = os.environ.get("MM_EXE")
    if exe:
        argv = [exe]
    else:
        # the full GUI: no --no-window; use the windowed exe, not the console one
        argv = [a for a in argv if a != "--no-window"]
        if sys.platform == "win32":
            argv[0] = argv[0].replace("_console.exe", ".exe")
        argv = [a for a in argv if a != "--"]
    argv = argv + ["--"] + ["--live-server", str(port)] + [os.path.abspath(f) for f in files]
    return subprocess.Popen(argv, env=_env(None), cwd=REPO if not exe else None)


def run_cli(args, cwd=None, timeout=600):
    """Run one `--cli` command. Returns (result_dict, log_text)."""
    argv = command_prefix() + ["--cli"] + list(args)
    try:
        proc = subprocess.run(argv, capture_output=True, text=True, encoding="utf-8", errors="replace",
                              env=_env(cwd), timeout=timeout)
    except subprocess.TimeoutExpired:
        raise LauncherError("Material Maker timed out after %ds" % timeout)
    log = (proc.stdout or "") + (proc.stderr or "")
    result = None
    for line in (proc.stdout or "").splitlines():
        if line.startswith(RESULT_MARKER):
            result = json.loads(line[len(RESULT_MARKER):])
    return result, log


def interesting_log(log, limit=40):
    """Engine log lines worth showing when something failed (drops known teardown noise)."""
    noise = ("process_frame", "data.tree", "Unreferenced static string", "Steam", "ObjectDB",
             "resources still in use", "Thread object", "Semaphore", "at: ", "GDScript backtrace",
             "[0] ", "[1] ", "Godot Engine v", "Vulkan", "Please call", RESULT_MARKER.strip(),
             "Cannot open user://", "Failed to open", "Successfully read library", "Loading...")
    lines = [l for l in log.splitlines() if l.strip() and not any(n in l for n in noise)]
    return "\n".join(lines[-limit:])


class Server:
    """A long-running `--cli serve` process spoken to with JSON lines over localhost TCP."""

    def __init__(self, cwd=None, startup_timeout=120, live_port=None):
        self.cwd = cwd
        self.live_port = live_port  # attach to a running editor (--live-server) instead of starting one
        self.startup_timeout = startup_timeout
        self.proc = None
        self.sock = None
        self.buffer = b""
        self.log = deque(maxlen=400)
        self.next_id = 1
        self.lock = threading.Lock()

    def _free_port(self):
        with socket.socket() as s:
            s.bind(("127.0.0.1", 0))
            return s.getsockname()[1]

    def _drain(self, stream, ready):
        for line in stream:
            line = line.rstrip("\r\n")
            self.log.append(line)
            if line.startswith(READY_MARKER):
                ready.set()

    def start(self):
        if self.live_port:
            try:
                self.sock = socket.create_connection(("127.0.0.1", self.live_port), timeout=5)
            except OSError:
                raise LauncherError("No live Material Maker on port %d. Start the editor with: python tools/mm.py gui --port %d"
                                    % (self.live_port, self.live_port))
            self.sock.settimeout(None)
            self.buffer = b""
            return
        port = self._free_port()
        argv = command_prefix() + ["--cli", "serve", "--port", str(port)]
        self.proc = subprocess.Popen(argv, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                                     encoding="utf-8", errors="replace", env=_env(self.cwd))
        ready = threading.Event()
        threading.Thread(target=self._drain, args=(self.proc.stdout, ready), daemon=True).start()
        deadline = time.time() + self.startup_timeout
        while not ready.is_set():
            if self.proc.poll() is not None:
                raise LauncherError("Material Maker exited during startup:\n" + interesting_log("\n".join(self.log)))
            if time.time() > deadline:
                self.stop()
                raise LauncherError("Material Maker did not start within %ds" % self.startup_timeout)
            time.sleep(0.05)
        self.sock = socket.create_connection(("127.0.0.1", port), timeout=10)
        self.sock.settimeout(None)

    def alive(self):
        if self.live_port:
            return self.sock is not None
        return self.proc is not None and self.proc.poll() is None and self.sock is not None

    def call(self, op, args=None, timeout=600):
        """Returns the response dict: {ok, result} or {ok: False, error, details}."""
        with self.lock:
            if not self.alive():
                self.start()
            request = {"id": self.next_id, "op": op, "args": args or {}, "cwd": (self.cwd or os.getcwd()).replace("\\", "/")}
            self.next_id += 1
            self.sock.sendall((json.dumps(request) + "\n").encode("utf-8"))
            self.sock.settimeout(timeout)
            try:
                while b"\n" not in self.buffer:
                    chunk = self.sock.recv(65536)
                    if not chunk:
                        raise LauncherError("Material Maker closed the connection:\n" + interesting_log("\n".join(self.log)))
                    self.buffer += chunk
            except socket.timeout:
                raise LauncherError("Operation '%s' timed out after %ds" % (op, timeout))
            line, self.buffer = self.buffer.split(b"\n", 1)
            return json.loads(line.decode("utf-8"))

    def stop(self):
        if self.live_port:  # never shut down somebody's editor
            if self.sock is not None:
                self.sock.close()
            self.sock = None
            return
        try:
            if self.sock is not None:
                self.sock.sendall(b'{"id":0,"op":"shutdown"}\n')
        except OSError:
            pass
        if self.proc is not None:
            try:
                self.proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.proc.kill()
            if self.proc.stdout is not None:
                self.proc.stdout.close()
        if self.sock is not None:
            self.sock.close()
        self.proc = None
        self.sock = None
