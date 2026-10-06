"""Check embedded CodeDirectory page hashes, not CMS or launch policy."""
import hashlib
import struct
import sys
from pathlib import Path


class FormatError(ValueError):
    pass


class InvalidPages(ValueError):
    pass


def verify(data):
    def words(blob, offset, count, endian):
        if offset < 0 or offset + count * 4 > len(blob):
            raise FormatError('truncated signature or Mach-O structure')
        return struct.unpack_from(endian + 'I' * count, blob, offset)

    magic, cpu, _, _, count, extent, _, _ = words(data, 0, 8, '<')
    if magic != 0xFEEDFACF or cpu != 0x0100000C:
        raise FormatError('expected a thin ARM64 Mach-O')
    if count > 4096 or 32 + extent > len(data):
        raise FormatError('invalid load-command extent')
    cursor = 32
    signature = None
    for _ in range(count):
        cmd, size = words(data, cursor, 2, '<')
        if size < 8 or cursor + size > 32 + extent:
            raise FormatError('invalid load-command size')
        if cmd == 0x1D:
            if size < 16 or signature is not None:
                raise FormatError('invalid or duplicate LC_CODE_SIGNATURE')
            signature = words(data, cursor + 8, 2, '<')
        cursor += size
    if signature is None:
        raise InvalidPages('missing LC_CODE_SIGNATURE')
    offset, size = signature
    if offset + size > len(data):
        raise FormatError('signature lies outside image')
    sig = data[offset:offset + size]
    magic, total, count = words(sig, 0, 3, '>')
    if magic != 0xFADE0CC0 or total > len(sig) or count > 64 or 12 + count * 8 > total:
        raise FormatError('invalid signature superblob')
    directories = 0
    for index in range(count):
        _, start = words(sig, 12 + index * 8, 2, '>')
        magic, length = words(sig, start, 2, '>')
        if start < 12 + count * 8 or start + length > total or length < 8:
            raise FormatError('invalid signature slot bounds')
        if magic != 0xFADE0C02:
            continue
        blob = sig[start:start + length]
        _, _, version, _, hashes, _, _, pages, limit = words(blob, 0, 9, '>')
        if len(blob) < 44:
            raise FormatError('short CodeDirectory')
        hash_size, hash_type, _, exponent = struct.unpack_from('4B', blob, 36)
        algorithm = {1: 'sha1', 2: 'sha256', 3: 'sha256', 4: 'sha384'}.get(hash_type)
        expected_size = {1: 20, 2: 32, 3: 20, 4: 48}.get(hash_type)
        if algorithm is None or hash_size != expected_size or exponent != 12:
            raise FormatError('unsupported CodeDirectory hash or page format')
        if version >= 0x20100 and words(blob, 44, 1, '>')[0] != 0:
            raise FormatError('scatter CodeDirectory is unsupported')
        if limit == 0 or limit > offset or pages != (limit + 4095) // 4096:
            raise FormatError('invalid CodeDirectory code extent')
        if hashes < 44 or hashes + pages * hash_size > len(blob):
            raise FormatError('invalid CodeDirectory hash table')
        bad = []
        for page in range(pages):
            digest = hashlib.new(algorithm, data[page * 4096:min((page + 1) * 4096, limit)]).digest()[:hash_size]
            stored = blob[hashes + page * hash_size:hashes + (page + 1) * hash_size]
            if digest != stored:
                bad.append(page)
        if bad:
            raise InvalidPages('CodeDirectory hash type %d has mismatched pages: %s' % (hash_type, bad))
        directories += 1
    if directories == 0:
        raise InvalidPages('no CodeDirectory found')
    return directories


if __name__ == '__main__':
    try:
        count = verify(Path(sys.argv[1]).read_bytes())
        print('CodeDirectory pages verified (%d directories): %s' % (count, sys.argv[1]))
    except InvalidPages as error:
        print('Invalid code pages: %s' % error, file=sys.stderr)
        sys.exit(1)
    except (OSError, FormatError, IndexError) as error:
        print('Cannot verify code pages: %s' % error, file=sys.stderr)
        sys.exit(2)
