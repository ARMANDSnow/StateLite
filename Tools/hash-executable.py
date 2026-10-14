#!/usr/bin/env python3
"""Hash thin arm64 Mach-O file-backed sections; code signature is not a section.
This binds helper to build content across ad-hoc bundle signing. Not a substitute
for a trusted signing identity or kernel audit-token authentication.
"""
import hashlib, struct, sys
b = open(sys.argv[1], 'rb').read()
magic, cpu, sub, typ, count, length, flags, reserved = struct.unpack_from('<8I', b)
assert magic == 0xfeedfacf and cpu == 0x100000c
assert 32 + length <= len(b)
h = hashlib.sha256(); pos = 32; seen = 0
for _ in range(count):
    cmd, size = struct.unpack_from('<II', b, pos)
    assert size >= 8 and pos + size <= 32 + length
    if cmd == 0x19:
        nsects = struct.unpack_from('<I', b, pos + 64)[0]
        assert 72 + nsects * 80 <= size
        for i in range(nsects):
            s = pos + 72 + i * 80
            name, seg, addr, n, offset, align, reloc, nreloc, flags, _, _, _ = struct.unpack_from('<16s16sQQ8I', b, s)
            if flags & 0xff in (1, 12, 18) or n == 0: continue
            assert offset > 0 and offset + n <= len(b)
            h.update(seg); h.update(name); h.update(struct.pack('<Q', n)); h.update(b[offset:offset+n]); seen += 1
    pos += size
assert seen > 0
print(h.hexdigest())
