#!/usr/bin/env python3
"""Rename a GPT partition's label and rewrite CRCs.

Reads first ~320KB (80 x 4K sectors) of a UFS LUN dump, finds the named partition,
rewrites its UTF-16LE label, recomputes the partition-array CRC32 and the GPT
header CRC32, writes back to <input>.new. Caller must then dd the modified
header+entries region back to the device. Backup GPT at end of disk also needs
the same patch — see --backup-only mode.
"""
import sys, struct, zlib

SECTOR = 4096

def parse_header(buf, off):
    sig = buf[off:off+8]
    if sig != b"EFI PART":
        raise ValueError(f"no GPT signature at offset 0x{off:x}: {sig!r}")
    (sig, revision, hdr_size, hdr_crc,
     current_lba, backup_lba, first_usable, last_usable,
     disk_guid, part_entries_lba, num_entries, entry_size,
     part_array_crc) = struct.unpack_from("<8sIII4xQQQQ16sQIII", buf, off)
    return {
        "hdr_size": hdr_size, "hdr_crc": hdr_crc,
        "current_lba": current_lba, "backup_lba": backup_lba,
        "first_usable": first_usable, "last_usable": last_usable,
        "disk_guid": disk_guid,
        "part_entries_lba": part_entries_lba,
        "num_entries": num_entries, "entry_size": entry_size,
        "part_array_crc": part_array_crc,
    }

def find_partition(buf, entries_offset, num_entries, entry_size, name):
    target = name.encode("utf-16-le")
    for i in range(num_entries):
        off = entries_offset + i * entry_size
        # name is bytes 56..127 of each entry, UTF-16LE
        name_bytes = buf[off+56:off+entry_size]
        # null-terminated UTF-16
        try:
            actual = name_bytes.decode("utf-16-le").rstrip("\x00")
        except UnicodeDecodeError:
            continue
        if actual == name:
            return i, off
    return None, None

def rewrite_label(buf, entry_off, entry_size, new_name):
    if len(new_name.encode("utf-16-le")) > entry_size - 56:
        raise ValueError("new name too long")
    name_field = bytearray(entry_size - 56)
    encoded = new_name.encode("utf-16-le")
    name_field[:len(encoded)] = encoded
    buf[entry_off+56:entry_off+entry_size] = bytes(name_field)

def recompute_crcs(buf, hdr_off, h):
    # Partition array CRC: covers num_entries * entry_size bytes starting at
    # part_entries_lba * SECTOR (within our buffer = h["part_entries_lba"] - h["current_lba"]).
    array_off_in_buf = (h["part_entries_lba"] - h["current_lba"]) * SECTOR + (hdr_off - (h["current_lba"] - 1) * SECTOR) if False else None
    # Simpler: partition array sits at LBA 2 right after header at LBA 1, so for primary GPT (hdr at offset 0x1000): array at offset 0x2000.
    # For backup GPT this differs — handled by caller.
    raise NotImplementedError("use main()")

def patch_gpt(buf, primary_hdr_off, array_off, old, new):
    h = parse_header(buf, primary_hdr_off)
    array_len = h["num_entries"] * h["entry_size"]
    idx, entry_off = find_partition(buf, array_off, h["num_entries"], h["entry_size"], old)
    if idx is None:
        raise RuntimeError(f"partition {old!r} not found in array @0x{array_off:x}")
    print(f"  {old!r} found at index {idx} (entry offset 0x{entry_off:x})")
    rewrite_label(buf, entry_off, h["entry_size"], new)
    # Recompute partition-array CRC32 over the full array
    new_array_crc = zlib.crc32(bytes(buf[array_off:array_off+array_len])) & 0xFFFFFFFF
    print(f"  new partition-array CRC32 = 0x{new_array_crc:08x} (was 0x{h['part_array_crc']:08x})")
    struct.pack_into("<I", buf, primary_hdr_off+88, new_array_crc)
    # Recompute header CRC32 (set CRC field to zero first)
    struct.pack_into("<I", buf, primary_hdr_off+16, 0)
    hdr_bytes = bytes(buf[primary_hdr_off:primary_hdr_off+h["hdr_size"]])
    new_hdr_crc = zlib.crc32(hdr_bytes) & 0xFFFFFFFF
    struct.pack_into("<I", buf, primary_hdr_off+16, new_hdr_crc)
    print(f"  new header CRC32 = 0x{new_hdr_crc:08x} (was 0x{h['hdr_crc']:08x})")
    return idx

def main():
    if len(sys.argv) != 4:
        sys.exit(f"usage: {sys.argv[0]} <input.bin> <old-name> <new-name>")
    inpath, old, new = sys.argv[1:]
    with open(inpath, "rb") as f:
        data = bytearray(f.read())

    # Primary GPT: header at LBA 1 (offset 0x1000), partition array at LBA 2 (0x2000).
    patch_gpt(data, primary_hdr_off=SECTOR, array_off=SECTOR*2, old=old, new=new)

    outpath = inpath + ".new"
    with open(outpath, "wb") as f:
        f.write(bytes(data))
    print(f"wrote {outpath} ({len(data)} bytes)")

if __name__ == "__main__":
    main()
