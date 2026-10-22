#!/usr/bin/env python3
"""Relabel a GPT partition, patching both the primary and the backup GPT.

The nabu kernel boots with `root=PARTLABEL=linux`, but the stock Xiaomi GPT
labels the root partition `userdata`.  Renaming it is a GPT surgery: the
partition *name* lives in the partition-entry array, and the array CRC32 plus
the GPT header CRC32 both have to be recomputed afterwards.  Both GPT copies
(primary at LBA 1, backup at the last usable LBA) have to be patched, or the
firmware will fall back to one of them and undo the change.

This tool supersedes the earlier scratch scripts `gpt-rename-primary.py` and
`gpt-rename-backup.py`, which read whole files into memory (an instant OOM on
a 128 GB UFS LUN dump) and had to be run twice with hardcoded offsets.

Memory use is bounded: only the GPT header (one sector) and the partition
entry array (num_entries * entry_size bytes) are ever held in RAM, and the
file is read and written with seek + read/write at explicit offsets.

Whole disk:

    gpt-relabel.py --list /dev/block/sda
    gpt-relabel.py --dry-run /dev/block/sda userdata linux
    gpt-relabel.py /dev/block/sda userdata linux

Partial dump (only the GPT regions were pulled off the device, so the file is
a few sectors long and the absolute LBAs are still the on-disk ones):

    gpt-relabel.py --dump-base-lba 0 --header-lba 1 \
        --primary-only primary.bin userdata linux
    gpt-relabel.py --dump-base-lba 30660603 --header-lba 30660607 \
        --primary-only backup.bin userdata linux

Reference: docs/crdroid-reference-2026-05-24.md section 5.
"""
import argparse
import os
import struct
import sys
import zlib

GPT_SIGNATURE = b"EFI PART"

# GPT header field layout (little endian):
#   0x00 signature[8]  0x08 revision  0x0c header_size  0x10 header_crc32
#   0x14 reserved[4]   0x18 current_lba  0x20 backup_lba
#   0x28 first_usable_lba  0x30 last_usable_lba
#   0x38 disk_guid[16] 0x48 partition_entry_lba
#   0x50 num_partition_entries  0x54 partition_entry_size
#   0x58 partition_entry_array_crc32
GPT_HEADER_FMT = "<8sIII4xQQQQ16sQIII"
GPT_HEADER_LEN = struct.calcsize(GPT_HEADER_FMT)
OFF_HEADER_CRC = 0x10
OFF_ENTRY_ARRAY_LBA = 0x48
OFF_NUM_ENTRIES = 0x50
OFF_ENTRY_SIZE = 0x54
OFF_ARRAY_CRC = 0x58

# Partition entry layout: type_guid[16] unique_guid[16] first_lba[8]
# last_lba[8] attributes[8] name[36] (UTF-16LE, NUL terminated)
ENTRY_NAME_OFFSET = 56

DEFAULT_SECTOR_SIZE = 4096
PRIMARY_HEADER_LBA = 1


class GptError(Exception):
    """Raised for malformed or unexpected GPT structures."""


def parse_header(buf):
    """Decode a GPT header from the start of `buf`."""
    if len(buf) < GPT_HEADER_LEN:
        raise GptError("short read: not enough bytes for a GPT header")
    if buf[:8] != GPT_SIGNATURE:
        raise GptError("no 'EFI PART' signature (got %r)" % (buf[:8],))
    (_sig, _rev, hdr_size, hdr_crc, current_lba, backup_lba,
     first_usable, last_usable, disk_guid, entries_lba, num_entries,
     entry_size, array_crc) = struct.unpack_from(GPT_HEADER_FMT, buf, 0)
    return {
        "header_size": hdr_size,
        "header_crc": hdr_crc,
        "current_lba": current_lba,
        "backup_lba": backup_lba,
        "first_usable_lba": first_usable,
        "last_usable_lba": last_usable,
        "disk_guid": disk_guid,
        "entries_lba": entries_lba,
        "num_entries": num_entries,
        "entry_size": entry_size,
        "array_crc": array_crc,
    }


def decode_name(raw):
    """Decode a partition name field (UTF-16LE, NUL padded)."""
    try:
        text = raw.decode("utf-16-le")
    except UnicodeDecodeError:
        return None
    return text.split("\x00", 1)[0]


def encode_name(name, entry_size):
    """Encode a partition name into a fixed size field."""
    encoded = name.encode("utf-16-le")
    if len(encoded) > entry_size - ENTRY_NAME_OFFSET:
        raise GptError("name %r does not fit in %d bytes" % (name, entry_size - ENTRY_NAME_OFFSET))
    field = bytearray(entry_size - ENTRY_NAME_OFFSET)
    field[:len(encoded)] = encoded
    return bytes(field)


class GptDevice:
    """Bounded random access reader/writer over a block device or image file.

    `base_lba` is the absolute LBA that maps to offset 0 of the file.  It is 0
    for a whole disk, and non-zero when working on a partial dump (only the
    primary or only the backup GPT region was pulled off the device).  All
    LBAs used by the rest of this module stay absolute; the base only shifts
    the file offset.
    """

    def __init__(self, path, sector_size, base_lba=0):
        self.path = path
        self.sector_size = sector_size
        self.base_lba = base_lba
        self.fh = open(path, "r+b")
        try:
            self.size = os.fstat(self.fh.fileno()).st_size
        except OSError:
            self.size = 0

    def close(self):
        self.fh.close()

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()
        return False

    def offset_for_lba(self, lba):
        """Byte offset inside the file for an absolute `lba`."""
        if lba < self.base_lba:
            raise GptError(
                "LBA %d is before the start of the dump (base LBA %d)" % (lba, self.base_lba))
        return (lba - self.base_lba) * self.sector_size

    def read_sectors(self, lba, count):
        """Read `count` sectors starting at absolute `lba`."""
        want = count * self.sector_size
        off = self.offset_for_lba(lba)
        self.fh.seek(off)
        data = self.fh.read(want)
        if len(data) != want:
            raise GptError(
                "short read at LBA %d (offset %d): wanted %d bytes, got %d (dump too small?)"
                % (lba, off, want, len(data)))
        return bytearray(data)

    def write_at(self, lba, data):
        """Write `data` at absolute `lba`."""
        off = self.offset_for_lba(lba)
        if self.size and off + len(data) > self.size:
            raise GptError(
                "write at LBA %d would run past the end of %s (%d bytes)"
                % (lba, self.path, self.size))
        self.fh.seek(off)
        self.fh.write(bytes(data))
        self.fh.flush()
        os.fsync(self.fh.fileno())

    def read_header(self, lba):
        """Read and decode the GPT header at absolute `lba`."""
        return parse_header(self.read_sectors(lba, 1))


def read_entry_array(dev, header):
    """Read the partition entry array referenced by `header`."""
    array_len = header["num_entries"] * header["entry_size"]
    if array_len == 0:
        raise GptError("GPT header declares an empty partition entry array")
    sectors = (array_len + dev.sector_size - 1) // dev.sector_size
    return dev.read_sectors(header["entries_lba"], sectors), array_len


def find_partition(array, header, wanted):
    """Return (index, byte offset) of the entry named `wanted`, or (None, None)."""
    for i in range(header["num_entries"]):
        off = i * header["entry_size"]
        raw = array[off + ENTRY_NAME_OFFSET:off + header["entry_size"]]
        if decode_name(raw) == wanted:
            return i, off
    return None, None


def list_partitions(dev, header, array):
    """Yield (index, name, first_lba, last_lba) for every named entry."""
    for i in range(header["num_entries"]):
        off = i * header["entry_size"]
        name = decode_name(array[off + ENTRY_NAME_OFFSET:off + header["entry_size"]])
        if not name:
            continue
        first_lba, last_lba = struct.unpack_from("<QQ", array, off + 32)
        yield i, name, first_lba, last_lba


def patch_one_gpt(dev, hdr_lba, old_name, new_name, dry_run):
    """Relabel `old_name` in the GPT whose header is at `hdr_lba`.

    Returns a dict describing what was done, or None when the partition is
    not present in this copy of the GPT.
    """
    header = dev.read_header(hdr_lba)
    array, array_len = read_entry_array(dev, header)
    idx, off = find_partition(array, header, old_name)
    if idx is None:
        return None

    array[off + ENTRY_NAME_OFFSET:off + header["entry_size"]] = encode_name(
        new_name, header["entry_size"])

    new_array_crc = zlib.crc32(bytes(array[:array_len])) & 0xFFFFFFFF

    # Patch the header: array CRC, then header CRC with its own field zeroed.
    hdr = dev.read_sectors(hdr_lba, 1)
    struct.pack_into("<I", hdr, OFF_ARRAY_CRC, new_array_crc)
    struct.pack_into("<I", hdr, OFF_HEADER_CRC, 0)
    new_hdr_crc = zlib.crc32(bytes(hdr[:header["header_size"]])) & 0xFFFFFFFF
    struct.pack_into("<I", hdr, OFF_HEADER_CRC, new_hdr_crc)

    info = {
        "index": idx,
        "header_lba": hdr_lba,
        "entries_lba": header["entries_lba"],
        "old_array_crc": header["array_crc"],
        "new_array_crc": new_array_crc,
        "old_header_crc": header["header_crc"],
        "new_header_crc": new_hdr_crc,
    }

    if not dry_run:
        dev.write_at(header["entries_lba"], array)
        dev.write_at(hdr_lba, hdr)

    return info


def resolve_targets(dev, args):
    """Return the absolute LBAs of the GPT headers to operate on.

    With an explicit --header-lba only that header is touched.  Otherwise the
    primary header is used, plus the backup copy unless --primary-only was
    given.  A partial dump always needs an explicit --header-lba, because the
    backup copy is not part of the dump.
    """
    if args.header_lba is not None:
        return [args.header_lba]
    if dev.base_lba != 0:
        raise GptError(
            "--header-lba is required for a partial dump (base LBA %d)" % dev.base_lba)
    try:
        header = dev.read_header(PRIMARY_HEADER_LBA)
    except GptError:
        raise GptError(
            "no primary GPT header at LBA 1 — is %s really a GPT disk?" % dev.path)
    if args.primary_only:
        return [PRIMARY_HEADER_LBA]
    return [PRIMARY_HEADER_LBA, header["backup_lba"]]


def format_guid(header):
    """Format the disk GUID (GPT stores the first three fields little endian)."""
    raw = header.get("disk_guid", b"")
    if len(raw) != 16:
        return "<unknown>"
    d1, d2, d3 = struct.unpack_from("<IHH", raw, 0)
    return "%08X-%04X-%04X-%s-%s" % (d1, d2, d3, raw[8:10][::-1].hex(), raw[10:16][::-1].hex())


def cmd_list(args):
    with GptDevice(args.device, args.sector_size, args.dump_base_lba) as dev:
        targets = resolve_targets(dev, args)
        header = dev.read_header(targets[0])
        array, _ = read_entry_array(dev, header)
        print("Device:   %s" % dev.path)
        print("Sector:   %d bytes" % dev.sector_size)
        if dev.base_lba:
            print("Dump base LBA: %d" % dev.base_lba)
        print("Disk GUID: %s" % format_guid(header))
        print("GPT header LBA: %d   Backup header LBA: %d" % (targets[0], header["backup_lba"]))
        print("")
        print("%-4s %-20s %-14s %-14s" % ("idx", "name", "first LBA", "last LBA"))
        for idx, name, first_lba, last_lba in list_partitions(dev, header, array):
            print("%-4d %-20s %-14d %-14d" % (idx, name, first_lba, last_lba))


def cmd_relabel(args):
    with GptDevice(args.device, args.sector_size, args.dump_base_lba) as dev:
        targets = resolve_targets(dev, args)

        results = []
        for lba in targets:
            info = patch_one_gpt(dev, lba, args.old_name, args.new_name, args.dry_run)
            if info is None:
                print("  LBA %-10d %r not present in this GPT copy" % (lba, args.old_name))
            else:
                results.append(info)
                print("  LBA %-10d entry #%d: %r -> %r" % (lba, info["index"], args.old_name, args.new_name))
                print("               array CRC32  0x%08x -> 0x%08x" % (info["old_array_crc"], info["new_array_crc"]))
                print("               header CRC32 0x%08x -> 0x%08x" % (info["old_header_crc"], info["new_header_crc"]))

        if not results:
            raise GptError("partition %r not found in any GPT copy" % args.old_name)

        if args.dry_run:
            print("")
            print("Dry run — nothing was written.")
        else:
            print("")
            print("Wrote %d GPT copy/copies. Reboot the device so the firmware re-reads the table." % len(results))

    return 0


def cmd_verify(args):
    with GptDevice(args.device, args.sector_size, args.dump_base_lba) as dev:
        targets = resolve_targets(dev, args)
        ok = True
        for lba in targets:
            header = dev.read_header(lba)
            array, array_len = read_entry_array(dev, header)
            computed = zlib.crc32(bytes(array[:array_len])) & 0xFFFFFFFF
            hdr = dev.read_sectors(lba, 1)
            struct.pack_into("<I", hdr, OFF_HEADER_CRC, 0)
            computed_hdr = zlib.crc32(bytes(hdr[:header["header_size"]])) & 0xFFFFFFFF
            array_ok = computed == header["array_crc"]
            hdr_ok = computed_hdr == header["header_crc"]
            print("GPT at LBA %d: array CRC %s, header CRC %s"
                  % (lba, "OK" if array_ok else "BAD", "OK" if hdr_ok else "BAD"))
            ok = ok and array_ok and hdr_ok
        return 0 if ok else 1


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Relabel a GPT partition (primary and backup) on a device or image file.")
    parser.add_argument("device", help="block device or image file to patch")
    parser.add_argument("old_name", nargs="?", help="current partition label")
    parser.add_argument("new_name", nargs="?", help="new partition label")
    parser.add_argument("--sector-size", type=int, default=DEFAULT_SECTOR_SIZE,
                        help="logical sector size in bytes (default: %d)" % DEFAULT_SECTOR_SIZE)
    parser.add_argument("--dry-run", action="store_true", help="show what would change, write nothing")
    parser.add_argument("--primary-only", action="store_true", help="patch only the primary GPT")
    parser.add_argument("--dump-base-lba", type=int, default=0,
                        help="absolute LBA that maps to offset 0 of the file (partial dumps)")
    parser.add_argument("--header-lba", type=int, default=None,
                        help="absolute LBA of the GPT header to patch (default: 1, the primary)")
    parser.add_argument("--list", action="store_true", help="list partitions and exit")
    parser.add_argument("--verify", action="store_true", help="check GPT CRCs and exit")
    args = parser.parse_args(argv)

    if args.list:
        return cmd_list(args)
    if args.verify:
        return cmd_verify(args)
    if not args.old_name or not args.new_name:
        parser.error("old_name and new_name are required")
    return cmd_relabel(args)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except GptError as exc:
        print("ERROR: %s" % exc, file=sys.stderr)
        sys.exit(1)
    except PermissionError:
        print("ERROR: permission denied — run as root (the whole GPT is rewritten in place).",
              file=sys.stderr)
        sys.exit(1)
    except OSError as exc:
        print("ERROR: %s" % exc, file=sys.stderr)
        sys.exit(1)
