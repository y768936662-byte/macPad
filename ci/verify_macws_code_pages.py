"""Check every ARM slice using the project's shared CodeDirectory page verifier."""
import importlib.util
from pathlib import Path
import struct
import sys

from validate_macws_executable import validate

# Build-time checkout: reuse the canonical helper. Standalone tool package:
# use the exact same helper copied beside this file by the build script.
shared = Path(__file__).with_name('verify_macho_code_pages.py')
if not shared.is_file():
    shared = Path(__file__).resolve().parents[1] / 'layout/usr/macOS/bin/verify_macho_code_pages.py'
spec = importlib.util.spec_from_file_location('macws_shared_code_pages', shared)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


def verify_code_pages(data):
    arches = validate(data)
    formats = {b'\xca\xfe\xba\xbe': ('>', False), b'\xbe\xba\xfe\xca': ('<', False),
               b'\xca\xfe\xba\xbf': ('>', True), b'\xbf\xba\xfe\xca': ('<', True)}
    magic = data[:4]
    slices = [data]
    if magic in formats:
        endian, wide = formats[magic]
        stride = 32 if wide else 20
        slices = []
        for index in range(len(arches)):
            fields = struct.unpack_from(endian + ('IIQQII' if wide else 'IIIII'),
                                        data, 8 + index * stride)
            slices.append(data[fields[2]:fields[2] + fields[3]])
    directories = 0
    for arch, image in zip(arches, slices):
        try:
            directories += module.verify(image)
        except (ValueError, struct.error) as error:
            raise ValueError('CodeDirectory pages invalid for %s: %s' % (arch, error)) from error
    return directories


if __name__ == '__main__':
    try:
        if len(sys.argv) != 2:
            raise ValueError('expected one executable path')
        count = verify_code_pages(Path(sys.argv[1]).read_bytes())
        print('All ARM CodeDirectory pages verified (%d directories): %s' % (count, sys.argv[1]))
    except (ValueError, OSError) as error:
        sys.exit('Code-page verification failed: %s' % error)
