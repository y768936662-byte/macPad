"""Reject debug symbols and non-ARM executable artifacts before publication."""
import argparse
import struct
import sys
from pathlib import Path


def validate(data):
    def image(offset, size):
        if offset < 0 or size < 32 or offset + size > len(data):
            raise ValueError('invalid Mach-O slice bounds')
        magic = data[offset:offset + 4]
        endian = {b'\xcf\xfa\xed\xfe': '<', b'\xfe\xed\xfa\xcf': '>'}.get(magic)
        if not endian:
            raise ValueError('expected a 64-bit Mach-O slice')
        _, cpu, subtype, kind = struct.unpack_from(endian + '4I', data, offset)
        if cpu != 0x0100000C or (subtype & 0x00FFFFFF) not in (0, 2):
            raise ValueError('expected arm64 or arm64e')
        if kind != 2:
            raise ValueError('expected MH_EXECUTE (2), got filetype %d%s' %
                             (kind, ' (MH_DSYM/debug symbols)' if kind == 10 else ''))
        return cpu, subtype & 0x00FFFFFF

    magic = data[:4]
    formats = {b'\xca\xfe\xba\xbe': ('>', False), b'\xbe\xba\xfe\xca': ('<', False),
               b'\xca\xfe\xba\xbf': ('>', True), b'\xbf\xba\xfe\xca': ('<', True)}
    if magic not in formats:
        cpu, subtype = image(0, len(data))
        return ('arm64e' if subtype == 2 else 'arm64',)
    endian, wide = formats[magic]
    count = struct.unpack_from(endian + 'I', data, 4)[0]
    stride = 32 if wide else 20
    if not count or count > 16 or 8 + count * stride > len(data):
        raise ValueError('invalid fat architecture table')
    architectures = []
    ranges = []
    table_end = 8 + count * stride
    for index in range(count):
        fields = struct.unpack_from(endian + ('IIQQII' if wide else 'IIIII'), data, 8 + index * stride)
        cpu, subtype = image(fields[2], fields[3])
        if fields[0] != cpu or (fields[1] & 0x00FFFFFF) != subtype:
            raise ValueError('fat architecture table disagrees with slice header')
        start, end = fields[2], fields[2] + fields[3]
        if start < table_end or any(start < old_end and end > old_start
                                    for old_start, old_end in ranges):
            raise ValueError('overlapping fat slice bounds')
        arch = 'arm64e' if subtype == 2 else 'arm64'
        if arch in architectures:
            raise ValueError('duplicate fat architecture')
        architectures.append(arch)
        ranges.append((start, end))
    return tuple(architectures)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--require-universal', action='store_true',
                        help='require exactly arm64 and arm64e for build publication')
    parser.add_argument('filenames', nargs='+')
    args = parser.parse_args()
    try:
        for filename in args.filenames:
            architectures = validate(Path(filename).read_bytes())
            if args.require_universal and set(architectures) != {'arm64', 'arm64e'}:
                raise ValueError('publication requires both arm64 and arm64e executable slices')
            print('ARM executable validated:', filename)
    except (ValueError, struct.error, OSError) as error:
        sys.exit('Artifact validation failed: %s' % error)
