#!/usr/bin/env python3
"""End-to-end smoke test of the CLI and the MCP bridge. Needs MM_GODOT or MM_EXE (and a GPU)."""
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mm_launcher import Server, run_cli


def cli(*args, cwd=None):
    result, log = run_cli(list(args), cwd=cwd)
    assert result is not None, log[-2000:]
    return result


class CliTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.dir = tempfile.mkdtemp(prefix="mm_cli_test_")
        cls.file = os.path.join(cls.dir, "t.ptex")

    def test_1_build_and_render(self):
        self.assertTrue(cli("new", self.file, "--size", "9").get("ok"))
        r = cli("add", self.file, "bricks", "--name", "B", "rows=4", "columns=2")
        self.assertEqual(r["name"], "B")
        self.assertEqual(cli("connect", self.file, "B:0", "Material:roughness")["connection"], "B:0 -> Material:2")
        info = cli("info", self.file)
        self.assertIn("B:0 -> Material:2", info["connections"])
        out = os.path.join(self.dir, "r.png")
        r = cli("render", self.file, "--output", "roughness", "--size", "64", "-o", out)
        self.assertEqual((r["width"], r["height"]), (64, 64))
        self.assertTrue(os.path.getsize(out) > 0)
        self.assertLess(r["min_rgba"][0], 0.1)
        self.assertGreater(r["max_rgba"][0], 0.9)

    def test_2_errors(self):
        self.assertIn("no parameter", cli("set", self.file, "B", "nope=1")["error"])
        self.assertIn("Unknown node type", cli("add", self.file, "does_not_exist")["error"])
        self.assertIn("File not found", cli("info", os.path.join(self.dir, "missing.ptex"))["error"])

    def test_3_server(self):
        server = Server()
        try:
            self.assertTrue(server.call("ping")["ok"])
            self.assertTrue(server.call("open", {"path": self.file})["ok"])
            self.assertTrue(server.call("set_parameters", {"node": "B", "parameters": {"pattern": "Herringbone"}})["ok"])
            r = server.call("render", {"node": "B", "size": 32})
            self.assertTrue(r["ok"], r)
            self.assertEqual(r["result"]["width"], 32)
        finally:
            server.stop()


if __name__ == "__main__":
    unittest.main(verbosity=2)
