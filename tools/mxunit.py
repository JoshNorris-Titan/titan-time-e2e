# Vendored into the test suite from the local titan-analysis toolkit so that
# verify-scheduled-event-config.test.sh is self-contained. The suite is its own
# repository and must not depend on a file living outside both it and the Mendix
# working copy. Stdlib only, no third-party imports.
#
# If the .mxunit format changes with a Mendix major version this reader is what
# breaks first -- and the test using it says so explicitly rather than reporting a
# clean scan from a reader that no longer understands the file.
# -*- coding: utf-8 -*-
"""Recursive reader for Mendix 11 .mxunit typed-binary files.
Format (from titan-analysis/mxparse.py header):
  root:   <4-byte total-length><members...>   payload from offset 4
  member: <tag:1><name cstring \0><value>
    0x02 string : <4 len><len bytes utf8 incl trailing \0>  (len NOT self-inclusive)
    0x03 object : <4 len><payload>  (len SELF-inclusive)
    0x04 list   : <4 len><payload>  (len SELF-inclusive)
    0x05 guid   : <4 len=16><1 discriminator><16 bytes>
    0x08 bool   : <1 byte>
"""
import uuid, struct

def _u32(b, p): return int.from_bytes(b[p:p+4], 'little')

def _cstr(b, p):
    e = b.index(b'\x00', p)
    return b[p:e].decode('utf-8', 'replace'), e + 1

def parse_members(b, start, end):
    """Return list of (name, value) in file order."""
    out, p = [], start
    while p < end:
        tag = b[p]; p += 1
        if p > end: break
        if tag == 0x00:      # container terminator
            break
        try: name, p = _cstr(b, p)
        except ValueError: break
        if tag == 0x02:
            ln = _u32(b, p); p += 4
            out.append((name, b[p:p+ln].decode('utf-8', 'replace').rstrip('\x00'))); p += ln
        elif tag in (0x03, 0x04):
            ln = _u32(b, p)
            inner = parse_members(b, p + 4, p + ln)
            out.append((name, {'__kind': 'obj' if tag == 0x03 else 'list', '__items': inner}))
            p += ln
        elif tag == 0x05:
            ln = _u32(b, p); p += 4
            raw = b[p:p+1+ln]; p += 1 + ln
            g = raw[1:1+ln]
            import uuid as _u
            out.append((name, {'__kind': 'guid', '__hex': g.hex(),
                               '__guid': str(_u.UUID(bytes_le=g)) if ln == 16 else g.hex()}))
        elif tag == 0x08:
            out.append((name, bool(b[p]))); p += 1
        elif tag == 0x0a:   # null marker, zero-length value
            out.append((name, None))
        elif tag == 0x12:   # int64
            out.append((name, int.from_bytes(b[p:p+8], 'little'))); p += 8
        elif tag == 0x10:   # list header (element count marker)
            out.append((name, _u32(b, p))); p += 4
        elif tag == 0x01:   # 4-byte int?
            out.append((name, _u32(b, p))); p += 4
        elif tag == 0x06:   # 8-byte
            out.append((name, int.from_bytes(b[p:p+8], 'little'))); p += 8
        elif tag == 0x07:
            out.append((name, b[p])); p += 1
        else:
            out.append(('__UNKNOWN_TAG_%02x' % tag, name))
            break
    return out

def load(path):
    b = open(path, 'rb').read()
    total = _u32(b, 0)
    return parse_members(b, 4, min(total, len(b)))

def walk(items, path=()):
    """Yield (path, name, value) for every member, recursing into obj/list."""
    for name, val in items:
        yield path, name, val
        if isinstance(val, dict) and val.get('__kind') in ('obj', 'list'):
            yield from walk(val['__items'], path + (name,))
