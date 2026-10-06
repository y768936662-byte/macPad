"""Validate, sign and trust all tools before a backed-up atomic installation."""
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import signal
import subprocess
import sys
import tempfile

from validate_macws_executable import validate
from verify_macws_code_pages import verify_code_pages

TOOLS = ('macwsdisplayd', 'macwsinputd', 'macwsinteropd',
         'macwsworkspacectl', 'macws-neofetch')
HASH = re.compile(r'^CDHash=([0-9a-fA-F]{40})$', re.M)
TRUST_HASH = re.compile(r'(?<![0-9a-fA-F])[0-9a-fA-F]{40}(?![0-9a-fA-F])')


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def command(args):
    result = subprocess.run([str(arg) for arg in args], stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, check=False)
    if result.returncode:
        detail = result.stderr.decode('utf-8', errors='replace').strip()
        raise RuntimeError('%s failed (exit %d): %s' %
                           (Path(args[0]).name, result.returncode, detail))
    return result.stdout


def identity(path, arches, expected_entitlements, ldid, run):
    data = Path(path).read_bytes()
    if validate(data) != arches:
        raise RuntimeError('architecture changed: %s' % path)
    verify_code_pages(data)
    hashes = []
    for arch in arches:
        entitlements = plistlib.loads(run([ldid, '-arch', arch, '-e', path]))
        if not isinstance(entitlements, dict) or any(
                entitlements.get(key) != value
                for key, value in expected_entitlements.items()):
            raise RuntimeError('entitlements missing or changed: %s/%s' % (path, arch))
        output = run([ldid, '-arch', arch, '-h', path]).decode('ascii')
        found = HASH.findall(output)
        if len(found) != 1:
            raise RuntimeError('expected one valid CDHash: %s/%s' % (path, arch))
        hashes.append(found[0].lower())
    return tuple(hashes)


def verify_trust(hashes, jbctl, run):
    output = run([jbctl, 'trustcache', 'info']).decode('utf-8', errors='replace')
    present = {value.lower() for value in TRUST_HASH.findall(output)}
    missing = set(hashes) - present
    if missing:
        raise RuntimeError('live trustcache is missing %d final CDHash(es)' % len(missing))


def copy_metadata(source, target):
    shutil.copy2(source, target)
    if hasattr(os, 'chown'):
        info = Path(source).stat()
        os.chown(target, info.st_uid, info.st_gid)


def sync_path(path):
    """Require fsync support; fail before replacement if durability is unavailable."""
    path = Path(path)
    try:
        if path.is_dir():
            descriptor = os.open(path, os.O_RDONLY | getattr(os, 'O_DIRECTORY', 0))
            try:
                os.fsync(descriptor)
            finally:
                os.close(descriptor)
        else:
            with path.open('rb+') as source:
                os.fsync(source.fileno())
    except OSError as error:
        raise RuntimeError('required fsync failed or is unsupported for %s: %s' %
                           (path, error)) from error


def install(package, jb, rootfs, entitlements, ldid, jbctl, run=command, sync=None):
    sync = sync or sync_path
    lock = Path(jb) / '.macws-tools-install.lock'
    try:
        lock.mkdir(mode=0o700)
    except FileExistsError:
        raise RuntimeError('another installer or an interrupted install owns %s' % lock)
    try:
        return install_locked(package, jb, rootfs, entitlements, ldid, jbctl, run, sync)
    finally:
        lock.rmdir()


def install_locked(package, jb, rootfs, entitlements, ldid, jbctl, run, sync):
    """Paths are explicit for isolated tests; the device CLI uses fixed paths."""
    package, jb, rootfs = map(Path, (package, jb, rootfs))
    entitlements = Path(entitlements)
    chroot_bin = rootfs / 'usr/local/bin'
    # Do not create a convincing /usr/local/bin under an unmounted rootfs.
    for folder in (jb, chroot_bin, rootfs / 'System/Library/CoreServices'):
        if not folder.is_dir():
            raise RuntimeError('required installed/mounted directory is missing: %s' % folder)
    expected = plistlib.loads(entitlements.read_bytes())
    if not isinstance(expected, dict) or not expected:
        raise RuntimeError('project entitlements must be a nonempty dictionary')
    manifest = json.loads((package / 'macws-tools.build.json').read_text())
    source_arches, source_hashes = {}, {}
    # Preflight every artifact before signing or changing any installed file.
    for tool in TOOLS:
        source = package / tool
        if source.is_symlink() or not source.is_file():
            raise RuntimeError('missing regular artifact: %s' % tool)
        record = manifest.get('tools', {}).get(tool, {})
        if record.get('sha256') != digest(source):
            raise RuntimeError('manifest SHA256 mismatch: %s' % tool)
        if record.get('bytes') != source.stat().st_size:
            raise RuntimeError('manifest size mismatch: %s' % tool)
        source_arches[tool] = validate(source.read_bytes())
        source_hashes[tool] = record['sha256']
        for directory in (jb, chroot_bin):
            target = directory / tool
            if target.is_symlink() or (target.exists() and not target.is_file()):
                raise RuntimeError('refusing nonregular destination: %s' % target)

    transaction = Path(tempfile.mkdtemp(prefix='.macws-tools-install-', dir=jb))
    backup_dir = transaction / 'backups'
    backup_dir.mkdir()
    moves, temporary_paths = [], []
    prepared, all_hashes = {}, []
    try:
        for tool in TOOLS:
            staged = transaction / tool
            shutil.copyfile(package / tool, staged)
            if digest(staged) != source_hashes[tool]:
                raise RuntimeError('source changed after preflight: %s' % tool)
            # Unsigned slices are selected from the header, never from old CDHash.
            for arch in source_arches[tool]:
                run([ldid, '-arch', arch, '-S%s' % entitlements, '-M', staged])
            # Read final identities after all per-slice signing operations settle.
            hashes = identity(staged, source_arches[tool], expected, ldid, run)
            prepared[tool] = (staged, digest(staged), hashes)
            all_hashes.extend(hashes)
        for hash_value in sorted(set(all_hashes)):
            run([jbctl, 'trustcache', 'add', hash_value])
        verify_trust(all_hashes, jbctl, run)

        destinations = []
        for label, directory in (('outer', jb), ('chroot', chroot_bin)):
            for tool in TOOLS:
                target = directory / tool
                backup = backup_dir / ('%s-%s' % (label, tool))
                if target.exists():
                    copy_metadata(target, backup)
                    if digest(target) != digest(backup):
                        raise RuntimeError('backup verification failed: %s' % target)
                else:
                    backup = None
                # mkstemp creates a new inode in the destination filesystem.
                descriptor, name = tempfile.mkstemp(prefix='.%s.new-' % tool, dir=directory)
                os.close(descriptor)
                temporary = Path(name)
                temporary_paths.append(temporary)
                shutil.copyfile(prepared[tool][0], temporary)
                temporary.chmod(0o755)
                if hasattr(os, 'chown'):
                    os.chown(temporary, 0, 0)
                if digest(temporary) != prepared[tool][1]:
                    raise RuntimeError('staged copy verification failed: %s' % target)
                destinations.append((tool, target, backup, temporary))
        # Preserve the exact rollback map for recovery after a power loss/SIGKILL.
        recovery = [{'target': str(target), 'backup': str(backup) if backup else None,
                     'original_sha256': digest(backup) if backup else None,
                     'new_sha256': prepared[tool][1]}
                    for tool, target, backup, temporary in destinations]
        recovery_path = transaction / 'recovery.json'
        recovery_path.write_text(json.dumps(recovery, indent=2))
        for tool, target, backup, temporary in destinations:
            if target.is_symlink() or (backup is None and target.exists()) or (
                    backup is not None and (not target.is_file() or digest(target) != digest(backup))):
                raise RuntimeError('destination changed while preparing: %s' % target)
        # Finish durability barriers before any installed destination is changed.
        # Unsupported directory fsync is a hard error, not an implied guarantee.
        for tool in TOOLS:
            sync(prepared[tool][0])
        for tool, target, backup, temporary in destinations:
            if backup is not None:
                sync(backup)
            sync(temporary)
        sync(recovery_path)
        for directory in (backup_dir, transaction, jb, chroot_bin):
            sync(directory)
        # All ten backups and destination-local copies exist before the first swap.
        for tool, target, backup, temporary in destinations:
            moves.append((target, backup))
            os.replace(temporary, target)
        for directory in (jb, chroot_bin):
            sync(directory)
        for tool, target, backup, temporary in destinations:
            if digest(target) != prepared[tool][1] or identity(
                    target, source_arches[tool], expected, ldid, run) != prepared[tool][2]:
                raise RuntimeError('installed identity verification failed: %s' % target)
        verify_trust(all_hashes, jbctl, run)
    except BaseException as error:
        rollback_errors = []
        for target, backup in reversed(moves):
            try:
                if backup is None:
                    target.unlink(missing_ok=True)
                    sync(target.parent)
                else:
                    descriptor, name = tempfile.mkstemp(prefix='.%s.restore-' % target.name,
                                                        dir=target.parent)
                    os.close(descriptor)
                    restored = Path(name)
                    temporary_paths.append(restored)
                    copy_metadata(backup, restored)
                    sync(restored)
                    os.replace(restored, target)
                    sync(target.parent)
                    if digest(target) != digest(backup):
                        raise RuntimeError('restored bytes differ')
            except BaseException as rollback_error:
                rollback_errors.append('%s: %s' % (target, rollback_error))
        if rollback_errors:
            raise RuntimeError('%s; rollback incomplete; backups: %s; %s' %
                               (error, backup_dir, '; '.join(rollback_errors))) from error
        raise RuntimeError('%s; installed files preserved/restored; backups: %s' %
                           (error, backup_dir)) from error
    finally:
        for path in temporary_paths:
            try:
                path.unlink(missing_ok=True)
            except OSError as cleanup_error:
                print('Temporary cleanup failed: %s: %s' % (path, cleanup_error),
                      file=sys.stderr)
    # Keep the backed-up originals and signed artifacts for an explicit rollback.
    print('All five tools installed, every ARM slice signed and currently trusted.')
    print('Verified backups: %s' % backup_dir)
    return transaction


def interrupted(signum, frame):
    raise RuntimeError('installation interrupted by signal %d' % signum)


def main():
    if len(sys.argv) != 2:
        raise RuntimeError('expected one package directory')
    if not hasattr(os, 'geteuid') or os.geteuid() != 0:
        raise RuntimeError('run as root on the rootless iPad')
    for signum in (signal.SIGTERM, signal.SIGHUP):
        signal.signal(signum, interrupted)
    install(sys.argv[1], '/var/jb/usr/macOS/bin', '/var/mnt/rootfs',
            '/var/jb/usr/macOS/bin/entitlements.plist',
            '/var/jb/usr/bin/ldid', '/var/jb/usr/bin/jbctl')


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        sys.exit('Tool installation failed: %s' % error)
