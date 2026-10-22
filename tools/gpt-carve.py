#!/usr/bin/env python3
"""Carve a new partition out of the tail of an existing one in a GPT.

Used on nabu for the dual-boot layout: the stock table has no unallocated
space (userdata runs to the last usable LBA), so the `linux` partition this
project boots is carved by moving userdata's *end* back into it. The carved
sectors keep their old-filesystem bytes — the ROM reformats the smaller
userdata on the next boot — but the GPT entries, the array CRC32 and the
header CRC32 change for every copy that is patched.

Patches both GPT copies (or one, with --header-lba), recomputing the array
CRC32 and the header CRC32 of each copy it writes. Same bounded-memory and
partial-dump support as the relabel mode of gpt-relabel.py.

Whole disk (patches primary AND backup):

    gpt-carve.py /dev/block/sda --carve linux --carve-source userdata --carve-gib 30

Partial dump (one GPT region pulled off the device):

    gpt-carve.py primary.bin --dump-base-lba 0 --header-lba 1 --primary-only \
        --carve linux --carve-source userdata --carve-gib 30
    gpt-carve.py backup.bin --dump-base-lba 30660603 --header-lba 30660607 \
        --primary-only --carve linux --carve-source userdata --carve-gib 30

Reference: docs/crdroid-reference-2026-05-24.md section 5.
"""
import argparse
import struct
import sys
import uuid
import zlib

from gpt_relabel import (
    ENTRY_NAME_OFFSET, GptDevice, GptError, OFF_ARRAY_CRC, OFF_HEADER_CRC,
    PRIMARY_HEADER_LBA, encode_name, find_partition, format_guid,
    list_partitions, read_entry_array, resolve_targets)

# Linux filesystem data — the standard "your root" partition type.
LINUX_FS_TYPE_GUID = (
    struct.pack("<IHH", 0x0FC63DAF, 0x8483, 0x4772)
    + bytes.fromhex("8E79") + bytes.fromhex("3D69D8477DE4"))

MIN_KEEP_SECTORS = 1024  # refuse to leave the source smaller than this


def find_free_slot(array, header):
    """Return (index, byte offset) of the first all-zero (free) entry."""
    zero = b"\x00" * header["entry_size"]
    for i in range(header["num_entries"]):
        off = i * header["entry_size"]
        if bytes(array[off:off + header["entry_size"]]) == zero:
            return i, off
    return None, None


def carve_sectors_for(gib, sector_size):
    """Round <gib> GiB down to whole sectors of <sector_size> bytes."""
    return int((gib * 1024 ** 3) // sector_size)


def carve_one_gpt(dev, hdr_lba, source_name, new_name, new_first_lba, dry_run,
                  unique_guid):
    """Carve the tail of `source_name` into a new `new_name` entry.

    `new_first_lba` is the first absolute LBA of the new partition; the
    source keeps everything up to `new_first_lba - 1` and the new partition
    spans `new_first_lba..source_last`. Returns a dict describing what it
    did, or None when the source is not present in this GPT copy.
    """
    header = dev.read_header(hdr_lba)
    array, array_len = read_entry_array(dev, header)

    sidx, soff = find_partition(array, header, source_name)
    if sidx is None:
        return None
    s_first, s_last = struct.unpack_from("<QQ", array, soff + 32)

    if new_first_lba <= s_first:
        raise GptError(
            "new partition must start above %r (first LBA %d)" % (source_name, s_first))
    if new_first_lba > s_last:
        raise GptError("new_first_lba %d is past %r's last LBA %d"
                       % (new_first_lba, source_name, s_last))
    if s_last - new_first_lba + 1 < MIN_KEEP_SECTORS:
        raise GptError(
            "carved partition would be a sliver with only %d sectors — refusing"
            % (s_last - new_first_lba + 1))
    if new_first_lba - s_first < MIN_KEEP_SECTORS:
        raise GptError(
            "%r would keep a sliver of only %d sectors — refusing"
            % (source_name, new_first_lba - s_first))

    for i, name, first_lba, last_lba in list_partitions(dev, header, array):
        if name == source_name:
            continue
        if new_first_lba <= last_lba and first_lba <= s_last:
            raise GptError(
                "refusing: %r spans LBA %d-%d, overlapping the carve range %d-%d"
                % (name, first_lba, last_lba, new_first_lba, s_last))

    free_idx, free_off = find_free_slot(array, header)
    if free_idx is None:
        raise GptError("no free (all-zero) entry slot in this GPT copy")

    src = bytearray(array[soff:soff + header["entry_size"]])
    struct.pack_into("<Q", src, 40, new_first_lba - 1)   # source: last_lba field

    ent = bytearray(header["entry_size"])
    ent[0:16] = LINUX_FS_TYPE_GUID
    ent[16:32] = unique_guid
    struct.pack_into("<QQQQ", ent, 32, new_first_lba, s_last, 0, 0)
    ent[ENTRY_NAME_OFFSET:] = encode_name(new_name, header["entry_size"])

    info = {
        "header_lba": hdr_lba,
        "source_index": sidx,
        "source_first": s_first,
        "source_last": s_last,
        "new_first": new_first_lba,
        "free_index": free_idx,
    }

    if not dry_run:
        array[soff:soff + header["entry_size"]] = src
        array[free_off:free_off + header["entry_size"]] = ent
        info["old_array_crc"] = header["array_crc"]
        info["new_array_crc"] = zlib.crc32(bytes(array[:array_len])) & 0xFFFFFFFF
        info["old_header_crc"] = header["header_crc"]

        hdr = dev.read_sectors(hdr_lba, 1)
        struct.pack_into("<I", hdr, OFF_ARRAY_CRC, info["new_array_crc"])
        struct.pack_into("<I", hdr, OFF_HEADER_CRC, 0)
        info["new_header_crc"] = zlib.crc32(bytes(hdr[:header["header_size"]])) & 0xFFFFFFFF
        struct.pack_into("<I", hdr, OFF_HEADER_CRC, info["new_header_crc"])

        dev.write_at(header["entries_lba"], array)
        dev.write_at(hdr_lba, hdr)

    return info


def cmd_carve(args):
    with GptDevice(args.device, args.sector_size, args.dump_base_lba) as dev:
        targets = resolve_targets(dev, args)

        # Take the source bounds from the first copy; all copies must agree
        # (they diverge only if one was already tampered with).
        first_hdr = dev.read_header(targets[0])
        array, _ = read_entry_array(dev, first_hdr)
        sidx, soff = find_partition(array, first_hdr, args.carve_source)
        if sidx is None:
            raise GptError("source partition %r not found" % args.carve_source)
        s_first, s_last = struct.unpack_from("<QQ", array, soff + 32)

        if args.carve_gib is not None:
            if args.new_first_lba is not None:
                raise GptError("--carve-gib and --new-first-lba are mutually exclusive")
            if args.carve_gib <= 0:
                raise GptError("--carve-gib must be positive")
            if args.carve_gib * 1024 ** 3 // dev.sector_size >= s_last - s_first:
                raise GptError("--carve-gib is larger than %r itself" % args.carve_source)
            new_first = s_last + 1 - carve_sectors_for(args.carve_gib, dev.sector_size)
        else:
            new_first = args.new_first_lba
            if new_first is None:
                raise GptError("give --carve-gib or --new-first-lba")

        results = []
        if args.unique_guid:
            unique_guid = uuid.UUID(args.unique_guid).bytes_le
        else:
            unique_guid = uuid.uuid4().bytes_le
        for lba in targets:
            info = carve_one_gpt(dev, lba, args.carve_source, args.carve,
                                 new_first, args.dry_run, unique_guid)
            if info is None:
                print("  LBA %-10d %r not present in this GPT copy"
                      % (lba, args.carve_source))
                continue
            results.append(info)
            print("  LBA %-10d %r: last LBA %d -> %d (keeps LBA %d..%d)"
                  % (lba, args.carve_source, info["source_last"],
                     new_first - 1, info["source_first"], new_first - 1))
            print("           %r: LBA %d..%d (%.2f GiB), entry slot #%d"
                  % (args.carve, new_first, info["source_last"],
                     (info["source_last"] - new_first + 1) * dev.sector_size / 1024 ** 3,
                     info["free_index"]))
            if not args.dry_run:
                print("           array CRC32  0x%08x -> 0x%08x   header CRC32 0x%08x -> 0x%08x"
                      % (info["old_array_crc"], info["new_array_crc"],
                         info["old_header_crc"], info["new_header_crc"]))

        if not results:
            raise GptError("source partition %r not found in any GPT copy"
                           % args.carve_source)

        print("")
        if args.dry_run:
            print("Dry run — nothing was written.")
        else:
            print("Wrote %d GPT copy/copies. The ROM must reformat the smaller "
                  "source partition before it is useful again." % len(results))
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Carve a new partition out of the tail of an existing one "
                    "(primary and backup GPT) on a device or image file.")
    parser.add_argument("device", help="block device or image file to patch")
    parser.add_argument("--carve", metavar="NEW_NAME", help="name of the new partition")
    parser.add_argument("--carve-source", metavar="SOURCE_NAME", default="userdata",
                        help="partition whose tail is carved (default: userdata)")
    parser.add_argument("--carve-gib", type=float, default=None,
                        help="size of the new partition in GiB (floor of)")
    parser.add_argument("--new-first-lba", type=int, default=None,
                        help="first LBA of the new partition (instead of --carve-gib)")
    parser.add_argument("--unique-guid", default=None,
                        help="explicit unique GUID for the new partition; pass the SAME "
                             "value to both partial-dump runs so the two GPT copies agree")
    parser.add_argument("--sector-size", type=int, default=4096,
                        help="logical sector size in bytes (default: 4096)")
    parser.add_argument("--dry-run", action="store_true",
                        help="show what would change, write nothing")
    parser.add_argument("--primary-only", action="store_true",
                        help="patch only the primary GPT")
    parser.add_argument("--dump-base-lba", type=int, default=0,
                        help="absolute LBA that maps to offset 0 of the file (partial dumps)")
    parser.add_argument("--header-lba", type=int, default=None,
                        help="absolute LBA of the GPT header to patch (default: 1, the primary)")
    parser.add_argument("--list", action="store_true", help="list partitions and exit")
    parser.add_argument("--verify", action="store_true", help="check GPT CRCs and exit")
    args = parser.parse_args(argv)

    if args.list:
        from gpt_relabel import cmd_list
        return cmd_list(args)
    if args.verify:
        from gpt_relabel import cmd_verify
        return cmd_verify(args)
    if not args.carve:
        parser.error("--carve <NEW_NAME> is required")
        return 2
    return cmd_carve(args)


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
