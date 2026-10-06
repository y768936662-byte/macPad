import hashlib
import importlib.util
import struct
import unittest
from pathlib import Path

path = Path(__file__).resolve().parents[1] / 'layout/usr/macOS/bin/verify_macho_code_pages.py'
spec = importlib.util.spec_from_file_location('code_pages', path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


def image():
    page = bytearray(4096)
    struct.pack_into('<8I', page, 0, 0xFEEDFACF, 0x0100000C, 0, 2, 1, 16, 0, 0)
    struct.pack_into('<4I', page, 32, 0x1D, 16, 4096, 96)
    directory = struct.pack('>9I4BI', 0xFADE0C02, 76, 0x20001, 0, 44, 0, 0, 1, 4096, 32, 2, 0, 12, 0)
    directory += hashlib.sha256(page).digest()
    signature = struct.pack('>5I', 0xFADE0CC0, 96, 1, 0, 20) + directory
    return bytes(page) + signature


class CodePagesTests(unittest.TestCase):
    def test_valid(self):
        self.assertEqual(module.verify(image()), 1)

    def test_header_mutation(self):
        data = bytearray(image())
        struct.pack_into('<I', data, 8, 2)
        with self.assertRaises(module.InvalidPages):
            module.verify(data)

    def test_empty_signature(self):
        data = bytearray(image())
        struct.pack_into('>I', data, 4104, 0)
        with self.assertRaises(module.InvalidPages):
            module.verify(data)

    def test_zero_pages(self):
        data = bytearray(image())
        struct.pack_into('>I', data, 4116 + 28, 0)
        with self.assertRaises(module.FormatError):
            module.verify(data)

    def test_signature_outside_file(self):
        data = bytearray(image())
        struct.pack_into('<I', data, 44, 10000)
        with self.assertRaises(module.FormatError):
            module.verify(data)

    def test_truncated_image(self):
        with self.assertRaises(module.FormatError):
            module.verify(b'')


if __name__ == '__main__':
    unittest.main()
