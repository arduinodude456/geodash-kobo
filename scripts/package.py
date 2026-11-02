#!/usr/bin/env python3
"""Assemble a FAT-safe tar.gz installer with checksums and source provenance."""
import argparse
import gzip
import hashlib
import json
from pathlib import Path
import shutil
import tarfile
import zipfile
from rootfs import arm_elf


def sha256(path):
    value = hashlib.sha256()
    with path.open('rb') as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b''):
            value.update(chunk)
    return value.hexdigest()


def require(path):
    if not path.is_file() or path.stat().st_size == 0:
        raise ValueError('required packaging input missing or empty: ' + str(path))
    return path


def validate_compressed_image(path, expected_size):
    with gzip.open(path, 'rb') as source:
        header = source.read(4096)
        if len(header) < 1082 or header[1080:1082] != b'\x53\xef':
            raise ValueError('rootfs payload is not an ext4 filesystem')
        total = len(header)
        for chunk in iter(lambda: source.read(1024 * 1024), b''):
            total += len(chunk)
        if total != expected_size:
            raise ValueError('uncompressed rootfs size mismatch')


def copy_file(source, target, executable=False):
    require(source)
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(source, target)
    target.chmod(0o755 if executable else 0o644)


def package(root, build, product, dist):
    inputs = [build / item for item in ('rootfs.img.gz', 'rootfs.img.gz.sha256', 'rootfs.size',
        'source-manifest.xml', 'AOSP-RELEASE.txt', 'REPO-REVISION.txt', 'patches.json', 'build-container.json')]
    for path in inputs:
        require(path)
    # Compressed input must be intact, not a renamed tar/system sparse image.
    size = int((build / 'rootfs.size').read_text().strip())
    if size < 384 * 1024 * 1024 or size > 4095 * 1024 * 1024 or size % (1024 * 1024):
        raise ValueError('invalid uncompressed rootfs size')
    expected = (build / 'rootfs.img.gz.sha256').read_text().split()
    if len(expected) != 2 or expected[1] != 'rootfs.img.gz' or expected[0] != sha256(build / 'rootfs.img.gz'):
        raise ValueError('rootfs image checksum mismatch')
    validate_compressed_image(build / 'rootfs.img.gz', size)
    for helper in ('kobo-vnc', 'kobo-container'):
        arm_elf(require(product / 'system/bin' / helper), static=True)
    required_runtime = ('android.sh', 'install.sh', 'config')
    for name in required_runtime:
        require(root / 'runtime' / name)
    require(root / 'lua/appdock_android.lua')
    for name in ('main.lua', '_meta.lua'):
        require(root / 'lua/android.koplugin' / name)
    require(root / 'README.md')
    require(root / 'LICENSE')
    # The actual build aggregates third-party notices. Do not ship just our MIT
    # license as though it covered Android's other components.
    notice = require(product / 'system/etc/NOTICE.html.gz')
    dist.mkdir(parents=True, exist_ok=True)
    pkg = dist / 'pkg'
    if pkg.exists():
        shutil.rmtree(pkg)
    android = pkg / '.adds/android'
    for name in ('rootfs.img.gz', 'rootfs.img.gz.sha256', 'rootfs.size'):
        copy_file(build / name, android / name)
    for name in required_runtime:
        copy_file(root / 'runtime' / name, android / name, executable=name.endswith('.sh'))
    for helper in ('kobo-vnc', 'kobo-container'):
        copy_file(product / 'system/bin' / helper, android / 'bin' / helper, executable=True)
    probe = product / 'system/bin/kobo-probe'
    if probe.is_file():
        arm_elf(probe, static=True)
        copy_file(probe, android / 'bin/kobo-probe', executable=True)
    copy_file(root / 'lua/appdock_android.lua', android / 'lua/appdock_android.lua')
    copy_file(root / 'lua/appdock_android.lua', pkg / 'lua/appdock_android.lua')
    for name in ('main.lua', '_meta.lua'):
        copy_file(root / 'lua/android.koplugin' / name, pkg / '.adds/koreader/plugins/android.koplugin' / name)
    for name in ('README.md', 'LICENSE'):
        copy_file(root / name, android / name)
        copy_file(root / name, pkg / name)
    if (root / 'docs').is_dir():
        shutil.copytree(root / 'docs', android / 'docs')
        shutil.copytree(root / 'docs', pkg / 'docs')
    copy_file(notice, android / 'licenses/AOSP-NOTICE.html.gz')
    copy_file(root / 'android/SOURCES.md', android / 'provenance/SOURCES.md')
    for path in inputs[3:]:
        copy_file(path, android / 'provenance' / path.name)
    # Include the small local modifications needed to reproduce the build.
    shutil.copytree(root / 'native', android / 'src/native', ignore=shutil.ignore_patterns('build', '__pycache__'))
    copy_file(root / 'runtime/kobo-container.c', android / 'src/runtime/kobo-container.c')
    shutil.copytree(root / 'android/device', android / 'src/android/device')
    shutil.copytree(root / 'scripts', android / 'src/scripts', ignore=shutil.ignore_patterns('__pycache__'))
    files = []
    for path in sorted(pkg.rglob('*')):
        if path.is_file():
            files.append({'path': path.relative_to(pkg).as_posix(), 'size': path.stat().st_size, 'sha256': sha256(path)})
    manifest = {'format': 1, 'aosp_release': 'android-4.4.4_r2', 'architecture': 'ARM32',
        'rootfs_bytes': size, 'hardware_tested': False, 'files': files}
    (pkg / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    # This file lists every payload file, including manifest.json, but not itself.
    checksum_lines = [sha256(path) + '  ' + path.relative_to(pkg).as_posix() for path in sorted(pkg.rglob('*')) if path.is_file()]
    (pkg / 'SHA256SUMS').write_text('\n'.join(checksum_lines) + '\n')
    archive = dist / 'kobo-android-kitkat.tar.gz'
    # Tar includes .adds by explicit path, not a wildcard that omits dotfiles.
    with archive.open('wb') as output, gzip.GzipFile(filename='', mode='wb', fileobj=output, mtime=0, compresslevel=6) as compressed:
        with tarfile.open(fileobj=compressed, mode='w', format=tarfile.PAX_FORMAT) as tar:
            for path in sorted(pkg.iterdir()):
                tar.add(path, arcname=path.name)
    (dist / (archive.name + '.sha256')).write_text(sha256(archive) + '  ' + archive.name + '\n')
    installer = dist / 'android-kobo.zip'
    # rootfs is already gzip-compressed; ZIP_STORED avoids double compression.
    with zipfile.ZipFile(installer, 'w', compression=zipfile.ZIP_STORED) as zipped:
        for path in sorted(pkg.rglob('*')):
            if path.is_file():
                zipped.write(path, arcname=path.relative_to(pkg).as_posix())
    (dist / (installer.name + '.sha256')).write_text(sha256(installer) + '  ' + installer.name + '\n')
    return archive


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('root', 'build', 'product-out', 'dist'):
        parser.add_argument('--' + name, required=True, type=Path)
    args = parser.parse_args()
    try:
        print(package(args.root, args.build, args.product_out, args.dist))
    except (OSError, ValueError) as exc:
        parser.exit(1, str(exc) + '\n')


if __name__ == '__main__':
    main()
