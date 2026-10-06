"""Exercise destructive failure boundaries using temp roots and fake sign/trust tools."""
import contextlib
import hashlib
import io
import json
import os
from pathlib import Path
import plistlib
import struct
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'ci'))
import install_macws_tools as installer
from validate_macws_executable import validate
from verify_macws_code_pages import verify_code_pages


def thin(subtype=0, filetype=2):
    return struct.pack('<8I', 0xFEEDFACF, 0x0100000C, subtype, filetype, 0, 0, 0, 0)


def fat(subtypes=(0, 2), kinds=(2, 2)):
    slices = [thin(subtype, kind) for subtype, kind in zip(subtypes, kinds)]
    return fat_images(slices)


def fat_images(slices):
    start = 8 + 20 * len(slices)
    table = b''
    for image in slices:
        subtype = struct.unpack_from('<I', image, 8)[0]
        table += struct.pack('>5I', 0x0100000C, subtype, start, len(image), 2)
        start += len(image)
    return struct.pack('>2I', 0xCAFEBABE, len(slices)) + table + b''.join(slices)


def images(data):
    if data[:4] != b'\xca\xfe\xba\xbe':
        return [data]
    count = struct.unpack_from('>I', data, 4)[0]
    slices = []
    for index in range(count):
        _, _, offset, size, _ = struct.unpack_from('>5I', data, 8 + index * 20)
        slices.append(data[offset:offset + size])
    return slices


def signed_image(subtype, seed=b''):
    page = bytearray(4096)
    struct.pack_into('<8I', page, 0, 0xFEEDFACF, 0x0100000C, subtype, 2, 1, 16, 0, 0)
    struct.pack_into('<4I', page, 32, 0x1D, 16, 4096, 96)
    page[64:96] = hashlib.sha256(seed).digest()
    directory = struct.pack('>9I4BI', 0xFADE0C02, 76, 0x20001, 0, 44, 0, 0,
                            1, 4096, 32, 2, 0, 12, 0)
    directory += hashlib.sha256(page).digest()
    signature = struct.pack('>5I', 0xFADE0CC0, 96, 1, 0, 20) + directory
    return bytes(page) + signature


class Environment:
    def __init__(self, base, image=None):
        self.package = base / 'package with spaces'
        self.jb = base / 'jb/bin'
        self.root = base / 'rootfs'
        for directory in (self.package, self.jb, self.root / 'usr/local/bin',
                          self.root / 'System/Library/CoreServices'):
            directory.mkdir(parents=True)
        self.ent = self.jb / 'entitlements.plist'
        self.expected = {'com.apple.private.test': True, 'task_for_pid-allow': True}
        self.ent.write_bytes(plistlib.dumps(self.expected))
        for tool in installer.TOOLS:
            (self.package / tool).write_bytes(fat() if image is None else image)
            for directory in (self.jb, self.root / 'usr/local/bin'):
                (directory / tool).write_bytes(('original ' + tool).encode())
        self.write_manifest()
        self.originals = {p: (p.read_bytes(), p.stat().st_ino)
                          for directory in (self.jb, self.root / 'usr/local/bin')
                          for p in (directory / t for t in installer.TOOLS)}
        self.trusted = set()
        self.calls = []
        self.fail_sign = False
        self.missing_ent = False
        self.drop_arm64e = False
        self.reject_add = False
        self.info_fail = False
        self.info_count = 0
        self.drop_after_swap = False
        self.hash_fail = False
        self.sync_calls = []
        self.fail_sync_kind = None
        self.bad_pages_arch = None
        self.sign_noop = False

    def write_manifest(self):
        manifest = {'tools': {tool: {'sha256': installer.digest(self.package / tool),
                                     'bytes': (self.package / tool).stat().st_size}
                              for tool in installer.TOOLS}}
        (self.package / 'macws-tools.build.json').write_text(json.dumps(manifest))

    @staticmethod
    def cdhash(path, arch):
        return hashlib.sha1(Path(path).read_bytes() + arch.encode()).hexdigest()

    def run(self, args):
        args = [str(a) for a in args]
        self.calls.append(args)
        if args[0] == 'ldid':
            arch, operation, target = args[2], args[3], Path(args[-1])
            if operation.startswith('-S'):
                if self.fail_sign and arch == 'arm64e':
                    raise RuntimeError('injected signing failure')
                if self.sign_noop:
                    return b''
                source = target.read_bytes()
                slices = images(source)
                for index, image in enumerate(slices):
                    subtype = struct.unpack_from('<I', image, 8)[0]
                    slice_arch = 'arm64e' if subtype & 0xFFFFFF == 2 else 'arm64'
                    if slice_arch == arch:
                        updated = bytearray(signed_image(subtype, image))
                        if arch == self.bad_pages_arch:
                            updated[512] ^= 1
                        slices[index] = bytes(updated)
                target.write_bytes(fat_images(slices) if len(slices) > 1 else slices[0])
                return b''
            if operation == '-e':
                return plistlib.dumps({} if self.missing_ent else self.expected)
            if operation == '-h':
                return b'CDHash=bad\n' if self.hash_fail else (
                    'CDHash=%s\n' % self.cdhash(target, arch)).encode()
        if args[0] == 'jbctl':
            if args[2] == 'add':
                if self.reject_add:
                    raise RuntimeError('injected add failure')
                self.trusted.add(args[3])
                return b''
            if args[2] == 'info':
                self.info_count += 1
                if self.info_fail:
                    raise RuntimeError('injected info permission failure')
                hashes = self.trusted.copy()
                if self.drop_arm64e or (self.drop_after_swap and self.info_count == 2):
                    hashes -= {self.cdhash(Path(a[-1]), 'arm64e') for a in self.calls
                               if a[0] == 'ldid' and a[3] == '-h'
                               and Path(a[-1]).exists()}
                return ('entries:\n' + '\n'.join(h.upper() for h in hashes)).encode()
        raise AssertionError('unexpected tool invocation: %s' % args)

    def install(self):
        with contextlib.redirect_stdout(io.StringIO()):
            return installer.install(self.package, self.jb, self.root, self.ent,
                                     'ldid', 'jbctl', self.run, self.sync)

    def sync(self, path):
        path = Path(path)
        self.sync_calls.append(path)
        kind = ('directory' if path.is_dir() else
                'recovery' if path.name == 'recovery.json' else
                'backup' if path.parent.name == 'backups' else 'prepared')
        if kind == self.fail_sync_kind:
            raise OSError('injected %s fsync failure' % kind)
        # Windows does not support directory fsync. Inject directory success
        # for orchestration tests; exercise real fsync for all temporary files.
        if not path.is_dir():
            with path.open('rb+') as source:
                os.fsync(source.fileno())

    def assert_originals(self, case):
        for path, (data, inode) in self.originals.items():
            case.assertEqual(path.read_bytes(), data, path)


class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.env = Environment(Path(self.temp.name))

    def test_success_both_arches_both_roots_backups_and_new_inodes(self):
        transaction = self.env.install()
        self.assertEqual(len(list((transaction / 'backups').iterdir())), 10)
        for path, (old, inode) in self.env.originals.items():
            self.assertNotEqual(path.stat().st_ino, inode)
            self.assertNotEqual(path.read_bytes(), old)
            self.assertEqual(path.read_bytes(), (transaction / path.name).read_bytes())
        self.assertEqual(self.env.info_count, 2)
        self.assertEqual(len([c for c in self.env.calls if c[0] == 'ldid'
                              and c[3].startswith('-S')]), 10)

    def test_thin_unsigned_arm64e_is_signed_without_prior_cdhash_probe(self):
        for tool in installer.TOOLS:
            (self.env.package / tool).write_bytes(thin(2))
        self.env.write_manifest()
        self.env.install()
        self.assertEqual(self.env.calls[0][3][:2], '-S')
        self.assertTrue(all(c[2] == 'arm64e' for c in self.env.calls if c[0] == 'ldid'))

    def test_dsym_rejected_even_with_correct_manifest(self):
        (self.env.package / installer.TOOLS[-1]).write_bytes(thin(0, 10))
        self.env.write_manifest()
        with self.assertRaisesRegex(ValueError, 'MH_DSYM'):
            self.env.install()
        self.assertEqual(self.env.calls, [])
        self.env.assert_originals(self)

    def test_manifest_mismatch_rejected_before_signing(self):
        (self.env.package / installer.TOOLS[0]).write_bytes(thin(2))
        with self.assertRaisesRegex(RuntimeError, 'SHA256 mismatch'):
            self.env.install()
        self.assertEqual(self.env.calls, [])
        self.env.assert_originals(self)

    def test_signing_error_preserves_every_installed_file(self):
        self.env.fail_sign = True
        with self.assertRaisesRegex(RuntimeError, 'signing failure'):
            self.env.install()
        self.env.assert_originals(self)
        self.assertTrue(all(p.stat().st_ino == inode
                            for p, (_, inode) in self.env.originals.items()))

    def test_missing_entitlements_preserves_every_file(self):
        self.env.missing_ent = True
        with self.assertRaisesRegex(RuntimeError, 'entitlements missing'):
            self.env.install()
        self.env.assert_originals(self)

    def test_bad_final_cdhash_preserves_every_file(self):
        self.env.hash_fail = True
        with self.assertRaisesRegex(RuntimeError, 'valid CDHash'):
            self.env.install()
        self.env.assert_originals(self)

    def test_successful_add_without_live_membership_fails(self):
        self.env.drop_arm64e = True
        with self.assertRaisesRegex(RuntimeError, 'live trustcache is missing'):
            self.env.install()
        self.env.assert_originals(self)

    def test_trust_info_permission_failure_is_fatal(self):
        self.env.info_fail = True
        with self.assertRaisesRegex(RuntimeError, 'info permission failure'):
            self.env.install()
        self.env.assert_originals(self)

    def test_trust_add_failure_is_fatal(self):
        self.env.reject_add = True
        with self.assertRaisesRegex(RuntimeError, 'add failure'):
            self.env.install()
        self.env.assert_originals(self)

    def test_late_membership_loss_rolls_back_both_roots(self):
        self.env.drop_after_swap = True
        with self.assertRaisesRegex(RuntimeError, 'live trustcache is missing'):
            self.env.install()
        self.env.assert_originals(self)

    def test_failure_during_third_swap_rolls_back_earlier_files(self):
        original_replace = installer.os.replace
        calls = 0
        def replacing(source, target):
            nonlocal calls
            calls += 1
            if calls == 3:
                raise OSError('injected third swap failure')
            return original_replace(source, target)
        with patch.object(installer.os, 'replace', replacing):
            with self.assertRaisesRegex(RuntimeError, 'third swap failure'):
                self.env.install()
        self.env.assert_originals(self)

    def test_missing_original_is_removed_on_late_rollback(self):
        missing = self.env.jb / installer.TOOLS[0]
        missing.unlink()
        self.env.originals.pop(missing)
        self.env.drop_after_swap = True
        with self.assertRaisesRegex(RuntimeError, 'live trustcache is missing'):
            self.env.install()
        self.assertFalse(missing.exists())
        self.env.assert_originals(self)

    def test_backup_failure_preserves_every_installed_file(self):
        with patch.object(installer, 'copy_metadata', side_effect=OSError('backup failed')):
            with self.assertRaisesRegex(RuntimeError, 'backup failed'):
                self.env.install()
        self.env.assert_originals(self)

    def test_install_lock_prevents_overlapping_installer(self):
        (self.env.jb / '.macws-tools-install.lock').mkdir()
        with self.assertRaisesRegex(RuntimeError, 'another installer'):
            self.env.install()
        self.assertEqual(self.env.calls, [])
        self.env.assert_originals(self)

    def test_source_changed_after_preflight_is_rejected(self):
        base_run = self.env.run
        def mutating(args):
            if not self.env.calls:
                (self.env.package / installer.TOOLS[-1]).write_bytes(thin())
            return base_run(args)
        self.env.run = mutating
        with self.assertRaisesRegex(RuntimeError, 'source changed after preflight'):
            self.env.install()
        self.env.assert_originals(self)

    def test_hex_substring_does_not_count_as_live_trust(self):
        value = 'a' * 40
        with self.assertRaisesRegex(RuntimeError, 'live trustcache is missing'):
            installer.verify_trust([value], 'jbctl', lambda args: ('f' + value).encode())

    def test_all_recovery_data_synced_before_first_replacement(self):
        original_replace = installer.os.replace
        observed = []
        def replacing(source, target):
            if not observed:
                synced = self.env.sync_calls
                self.assertEqual(len([p for p in synced if p.parent.name == 'backups']), 10)
                self.assertEqual(len([p for p in synced if '.new-' in p.name]), 10)
                self.assertTrue(any(p.name == 'recovery.json' for p in synced))
                self.assertIn(self.env.jb, synced)
                self.assertIn(self.env.root / 'usr/local/bin', synced)
                self.assertTrue(any(p.is_dir() and p.name == 'backups' for p in synced))
            observed.append(Path(target))
            return original_replace(source, target)
        with patch.object(installer.os, 'replace', replacing):
            self.env.install()
        self.assertEqual(len(observed), 10)

    def test_fsync_failures_stop_before_every_installed_mutation(self):
        for kind in ('recovery', 'backup', 'prepared', 'directory'):
            with self.subTest(kind=kind):
                self.env.fail_sync_kind = kind
                with patch.object(installer.os, 'replace') as replacing:
                    with self.assertRaisesRegex(RuntimeError, '%s fsync failure' % kind):
                        self.env.install()
                    replacing.assert_not_called()
                self.env.assert_originals(self)

    def test_real_file_fsync_error_is_not_swallowed(self):
        with patch.object(installer.os, 'fsync', side_effect=OSError('real file sync failure')):
            with self.assertRaisesRegex(RuntimeError, 'real file sync failure'):
                installer.sync_path(self.env.ent)

    def test_signer_success_with_corrupt_second_slice_is_rejected_before_trust(self):
        self.env.bad_pages_arch = 'arm64e'
        with self.assertRaisesRegex(RuntimeError, 'arm64e.*mismatched pages'):
            self.env.install()
        self.env.assert_originals(self)
        self.assertFalse(any(call[0] == 'jbctl' for call in self.env.calls))

    def test_signer_success_without_actual_signature_is_rejected_before_trust(self):
        self.env.sign_noop = True
        with self.assertRaisesRegex(RuntimeError, 'missing LC_CODE_SIGNATURE'):
            self.env.install()
        self.env.assert_originals(self)
        self.assertFalse(any(call[0] == 'jbctl' for call in self.env.calls))


class HeaderTests(unittest.TestCase):
    def test_valid_thin_and_fat(self):
        self.assertEqual(validate(thin()), ('arm64',))
        self.assertEqual(validate(thin(0x80000002)), ('arm64e',))
        self.assertEqual(validate(fat()), ('arm64', 'arm64e'))

    def test_bad_mixed_fat(self):
        with self.assertRaisesRegex(ValueError, 'MH_DSYM'):
            validate(fat(kinds=(2, 10)))

    def test_fat_table_mismatch(self):
        image = bytearray(fat())
        struct.pack_into('>I', image, 12, 2)
        with self.assertRaisesRegex(ValueError, 'disagrees'):
            validate(bytes(image))

    def test_overlap_is_rejected(self):
        image = bytearray(fat(subtypes=(0, 0)))
        struct.pack_into('>I', image, 36, 48)
        with self.assertRaisesRegex(ValueError, 'overlapping'):
            validate(bytes(image))

    def test_duplicate_architecture_is_rejected(self):
        with self.assertRaisesRegex(ValueError, 'duplicate'):
            validate(fat(subtypes=(0, 0)))

    def test_build_publication_rejects_thin_and_accepts_both_slices(self):
        with tempfile.TemporaryDirectory() as directory:
            image = Path(directory) / 'tool'
            validator = Path(__file__).resolve().parents[1] / 'ci/validate_macws_executable.py'
            for data, succeeds in ((thin(), False), (thin(2), False), (fat(), True)):
                image.write_bytes(data)
                result = subprocess.run([sys.executable, str(validator), '--require-universal',
                                         str(image)], capture_output=True, text=True)
                self.assertEqual(result.returncode == 0, succeeds)
                if not succeeds:
                    self.assertIn('requires both arm64 and arm64e', result.stderr)


class CodePageTests(unittest.TestCase):
    def test_valid_signed_thin_and_both_fat_slices(self):
        self.assertEqual(verify_code_pages(signed_image(0)), 1)
        self.assertEqual(verify_code_pages(signed_image(2)), 1)
        self.assertEqual(verify_code_pages(fat_images([signed_image(0), signed_image(2)])), 2)

    def test_corrupt_code_is_rejected_even_when_code_directory_is_unchanged(self):
        original = signed_image(2)
        changed = bytearray(original)
        changed[1024] ^= 1
        self.assertEqual(original[4096:], bytes(changed[4096:]))
        with self.assertRaisesRegex(ValueError, 'arm64e.*mismatched pages'):
            verify_code_pages(bytes(changed))

    def test_corrupt_second_fat_slice_is_checked(self):
        corrupt = bytearray(signed_image(2))
        corrupt[1024] ^= 1
        with self.assertRaisesRegex(ValueError, 'arm64e.*mismatched pages'):
            verify_code_pages(fat_images([signed_image(0), bytes(corrupt)]))

    def test_second_fat_slice_without_signature_is_rejected(self):
        with self.assertRaisesRegex(ValueError, 'arm64e.*missing LC_CODE_SIGNATURE'):
            verify_code_pages(fat_images([signed_image(0), thin(2)]))

    def test_standalone_package_uses_copied_shared_verifier(self):
        with tempfile.TemporaryDirectory() as directory:
            package = Path(directory)
            root = Path(__file__).resolve().parents[1]
            for name in ('verify_macws_code_pages.py', 'validate_macws_executable.py'):
                (package / name).write_bytes((root / 'ci' / name).read_bytes())
            (package / 'verify_macho_code_pages.py').write_bytes(
                (root / 'layout/usr/macOS/bin/verify_macho_code_pages.py').read_bytes())
            executable = package / 'tool'
            executable.write_bytes(fat_images([signed_image(0), signed_image(2)]))
            result = subprocess.run([sys.executable, str(package / 'verify_macws_code_pages.py'),
                                     str(executable)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('2 directories', result.stdout)


if __name__ == '__main__':
    unittest.main(verbosity=2)
