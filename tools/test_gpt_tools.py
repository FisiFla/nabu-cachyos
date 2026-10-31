#!/usr/bin/env python3
"""Regression tests for the GPT surgery tools (gpt-relabel.py, gpt-carve.py).

Run with:  python3 -m unittest tools.test_gpt_tools -v
(or directly: python3 tools/test_gpt_tools.py)

Every test works on a synthetic *primary GPT dump* — the same 6-sector
partial dump release/relabel-partition.sh and carve-linux-partition.sh pull
from the device — so no tablet and no root are needed.
"""
import contextlib
import hashlib
import importlib.util
import io
import struct
import sys
import tempfile
import unittest
import zlib
from pathlib import Path

TOOLS_DIR = Path(__file__).resolve().parent

SECTOR = 4096
ENTRY_SIZE = 128
NUM_ENTRIES = 128
ENTRIES_LBA = 2
ARRAY_BYTES = ENTRY_SIZE * NUM_ENTRIES
GPT_HEADER_FMT = "<8sIII4xQQQQ16sQIII"
HEADER_SIZE = struct.calcsize(GPT_HEADER_FMT)


def _load(name, filename):
    spec = importlib.util.spec_from_file_location(name, str(TOOLS_DIR / filename))
    mod = importlib.util.module_from_spec(spec)
    sys.modules[name] = mod
    spec.loader.exec_module(mod)
    return mod


gpt_relabel = _load("gpt_relabel", "gpt-relabel.py")
gpt_carve = _load("gpt_carve", "gpt-carve.py")
# Loading gpt-carve.py re-executes gpt-relabel.py into sys.modules under the
# same name, which would leave this file holding a *second* GptError class
# object and assertRaises() would miss carve-raised errors. Unify on the
# instance gpt-carve imported from.
gpt_relabel = sys.modules["gpt_relabel"]

PARTIAL_ARGS = ["--sector-size", str(SECTOR), "--dump-base-lba", "0",
                "--header-lba", "1", "--primary-only"]


def _entry(name, first_lba, last_lba):
    ent = bytearray(ENTRY_SIZE)
    ent[0:16] = b"\xaa" * 16
    ent[16:32] = b"\xbb" * 16
    struct.pack_into("<QQQ", ent, 32, first_lba, last_lba, 0)
    ent[56:] = gpt_relabel.encode_name(name, ENTRY_SIZE)
    return ent


def make_primary_dump(path, partitions):
    """Write LBA0..5 (protective MBR slot, header, entry array) to `path`.

    `partitions` is a list of (name, first_lba, last_lba). The claimed LBA
    ranges are pure GPT metadata — nothing writes to them — so the dump
    stays 6 sectors no matter how large the fake partitions are.
    """
    array = bytearray(ARRAY_BYTES)
    for i, (name, first_lba, last_lba) in enumerate(partitions):
        array[i * ENTRY_SIZE:(i + 1) * ENTRY_SIZE] = _entry(name, first_lba, last_lba)
    array_crc = zlib.crc32(bytes(array)) & 0xFFFFFFFF

    hdr = bytearray(SECTOR)
    struct.pack_into(GPT_HEADER_FMT, hdr, 0,
                     b"EFI PART", 0x00010000, HEADER_SIZE, 0,
                     1, 63, 6, 100000, b"\x01" * 16,
                     ENTRIES_LBA, NUM_ENTRIES, ENTRY_SIZE, array_crc)
    hdr_crc = zlib.crc32(bytes(hdr[:HEADER_SIZE])) & 0xFFFFFFFF
    struct.pack_into("<I", hdr, 0x10, hdr_crc)

    with open(path, "wb") as fh:
        fh.write(b"\x00" * SECTOR)
        fh.write(hdr)
        fh.write(array)
    return path


def _digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def _names(path):
    with gpt_relabel.GptDevice(path, SECTOR, 0) as dev:
        header = dev.read_header(1)
        array, _ = gpt_relabel.read_entry_array(dev, header)
        return [(name, first, last)
                for _i, name, first, last in gpt_relabel.list_partitions(dev, header, array)]


def _quiet(fn, *args):
    with contextlib.redirect_stdout(io.StringIO()):
        return fn(*args)


class RelabelTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.dump = str(Path(self._tmp.name) / "primary.bin")

    def tearDown(self):
        self._tmp.cleanup()

    def _relabel(self, old, new):
        return _quiet(gpt_relabel.main, PARTIAL_ARGS + [self.dump, old, new])

    def test_refuses_when_new_label_already_exists(self):
        # The Kumar-Jy migration case: `linux` is already there, so renaming
        # `userdata` would create a duplicate PARTLABEL=linux.
        make_primary_dump(self.dump, [("userdata", 100, 9000),
                                      ("linux", 10000, 20000)])
        before = _digest(self.dump)
        with self.assertRaises(gpt_relabel.GptError) as ctx:
            self._relabel("userdata", "linux")
        self.assertIn("already exists", str(ctx.exception))
        self.assertEqual(_digest(self.dump), before, "refused relabel must not write")

    def test_refuses_same_old_and_new_label(self):
        make_primary_dump(self.dump, [("userdata", 100, 9000)])
        before = _digest(self.dump)
        with self.assertRaises(gpt_relabel.GptError):
            self._relabel("userdata", "userdata")
        self.assertEqual(_digest(self.dump), before)

    def test_renames_userdata_to_linux(self):
        make_primary_dump(self.dump, [("userdata", 100, 9000),
                                      ("boot_a", 50, 99)])
        self.assertEqual(self._relabel("userdata", "linux"), 0)
        names = [name for name, _f, _l in _names(self.dump)]
        self.assertEqual(names, ["linux", "boot_a"])
        self.assertEqual(
            _quiet(gpt_relabel.main, PARTIAL_ARGS + [self.dump, "--verify"]), 0)


class CarveTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.dump = str(Path(self._tmp.name) / "primary.bin")

    def tearDown(self):
        self._tmp.cleanup()

    def _carve(self, new_first_lba="8000"):
        return _quiet(gpt_carve.main, PARTIAL_ARGS + [
            self.dump, "--carve", "linux", "--carve-source", "userdata",
            "--new-first-lba", new_first_lba])

    def test_refuses_when_new_label_already_exists(self):
        # Existing `linux` sits outside the carve range, so the overlap
        # check alone does not save us: carving would mint a second `linux`.
        make_primary_dump(self.dump, [("userdata", 100, 12000),
                                      ("linux", 20000, 22000)])
        before = _digest(self.dump)
        with self.assertRaises(gpt_relabel.GptError) as ctx:
            self._carve()
        self.assertIn("already exists", str(ctx.exception))
        self.assertEqual(_digest(self.dump), before, "refused carve must not write")

    def test_carves_linux_out_of_userdata_tail(self):
        make_primary_dump(self.dump, [("userdata", 100, 12000)])
        self.assertEqual(self._carve(), 0)
        parts = {name: (first, last) for name, first, last in _names(self.dump)}
        self.assertEqual(parts["userdata"], (100, 7999))
        self.assertEqual(parts["linux"], (8000, 12000))
        self.assertEqual(
            _quiet(gpt_carve.main, PARTIAL_ARGS + [self.dump, "--verify"]), 0)


if __name__ == "__main__":
    unittest.main()
