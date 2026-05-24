#!/usr/bin/env python3
"""Properly fix the backup GPT in our 5-LBA tail dump.

Pulled with `dd skip=30660603 count=5` so the file is LBAs 30660603..30660607:
  bytes 0x0000..0x1FFF: LBAs 30660603-30660604 (unused tail padding)
  bytes 0x2000..0x3FFF: LBAs 30660605-30660606 (backup partition entries, 64*128=8192 bytes)
  bytes 0x4000..0x4FFF: LBA 30660607 (backup GPT header)
"""
import sys, struct, zlib

ENTRIES_OFF = 0x2000
ENTRY_SIZE = 128
NUM_ENTRIES = 64
ARRAY_LEN = NUM_ENTRIES * ENTRY_SIZE  # 8192
HDR_OFF = 0x4000

def main():
    inpath = sys.argv[1]
    old = sys.argv[2]
    new = sys.argv[3]
    with open(inpath, "rb") as f:
        data = bytearray(f.read())

    # Find entry
    target = old.encode("utf-16-le")
    found = None
    for i in range(NUM_ENTRIES):
        off = ENTRIES_OFF + i * ENTRY_SIZE
        name_bytes = data[off+56:off+ENTRY_SIZE]
        try:
            actual = name_bytes.decode("utf-16-le").rstrip("\x00")
        except UnicodeDecodeError:
            continue
        if actual == old:
            found = (i, off)
            break
    if found is None:
        sys.exit(f"{old!r} not found in backup entries")
    idx, entry_off = found
    print(f"  backup: {old!r} at index {idx} (offset 0x{entry_off:x})")

    # Rewrite the label
    new_field = bytearray(ENTRY_SIZE - 56)
    enc = new.encode("utf-16-le")
    new_field[:len(enc)] = enc
    data[entry_off+56:entry_off+ENTRY_SIZE] = bytes(new_field)

    # Recompute partition-array CRC (over exactly 8192 bytes of actual entries)
    arr_crc = zlib.crc32(bytes(data[ENTRIES_OFF:ENTRIES_OFF+ARRAY_LEN])) & 0xFFFFFFFF
    print(f"  backup array CRC32 = 0x{arr_crc:08x}")

    # Patch backup header
    if data[HDR_OFF:HDR_OFF+8] != b"EFI PART":
        sys.exit(f"no GPT sig at header offset 0x{HDR_OFF:x}")
    hdr_size = struct.unpack_from("<I", data, HDR_OFF+12)[0]
    struct.pack_into("<I", data, HDR_OFF+88, arr_crc)        # part_array_crc
    struct.pack_into("<I", data, HDR_OFF+16, 0)              # zero hdr_crc
    new_hdr_crc = zlib.crc32(bytes(data[HDR_OFF:HDR_OFF+hdr_size])) & 0xFFFFFFFF
    struct.pack_into("<I", data, HDR_OFF+16, new_hdr_crc)
    print(f"  backup header CRC32 = 0x{new_hdr_crc:08x}")

    outpath = inpath + ".fixed"
    with open(outpath, "wb") as f:
        f.write(bytes(data))
    print(f"wrote {outpath}")

if __name__ == "__main__":
    main()
