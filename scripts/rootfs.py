#!/usr/bin/env python3
"""Stage and image AOSP files; each phase is explicit to keep root scope small."""
import argparse
import os
from pathlib import Path
import shutil
import stat
import struct
import subprocess

REQUIRED = ('init', 'init.rc', 'init.environ.rc', 'default.prop',
    'system/build.prop', 'system/bin/app_process', 'system/bin/servicemanager',
    'system/bin/surfaceflinger', 'system/bin/installd',
    'system/lib/libkobofb.so', 'system/lib/hw/gralloc.default.so',
    'system/lib/egl/libGLES_android.so', 'system/framework/framework.jar')


def arm_elf(path, static=False):
    data = path.read_bytes()
    if len(data) < 52 or data[:7] != b'\x7fELF\x01\x01\x01' or struct.unpack_from('<H', data, 18)[0] != 40:
        raise ValueError('expected little-endian ELF32 ARM: ' + str(path))
    if static:
        offset = struct.unpack_from('<I', data, 28)[0]
        size, count = struct.unpack_from('<HH', data, 42)
        if count == 0 or size < 32 or offset + size * count > len(data):
            raise ValueError('invalid executable program headers: ' + str(path))
        for index in range(count):
            if struct.unpack_from('<I', data, offset + size * index)[0] in (2, 3):
                raise ValueError('host helper must be static, without PT_DYNAMIC or PT_INTERP: ' + str(path))


def validate(stage):
    for name in REQUIRED:
        if not (stage / name).is_file():
            raise ValueError('missing Android rootfs component: ' + name)
    for name in ('init', 'system/bin/app_process', 'system/bin/surfaceflinger',
                 'system/lib/libkobofb.so', 'system/lib/egl/libGLES_android.so',
                 'system/lib/hw/gralloc.default.so'):
        arm_elf(stage / name)
    for name in ('kobo-vnc', 'kobo-container'):
        arm_elf(stage / 'system/bin' / name, static=True)
    initrc = (stage / 'init.rc').read_text()
    if 'service zygote ' not in initrc or 'service surfaceflinger ' not in initrc:
        raise ValueError('dedicated init.rc missing framework services')
    if 'import /init.usb.rc' in initrc or 'mount sysfs' in initrc:
        raise ValueError('unsafe stock init configuration')
    if (stage / 'system/lib/egl/egl.cfg').read_text().strip() != '0 0 android':
        raise ValueError('software EGL configuration required')
    if list((stage / 'system/lib').glob('**/*_emulation.so')):
        raise ValueError('Goldfish/emulation graphics driver unexpectedly installed')
    if 'BOOTCLASSPATH' not in (stage / 'init.environ.rc').read_text():
        raise ValueError('generated framework BOOTCLASSPATH missing')
    if not any((stage / 'system').glob('**/Launcher2.apk')):
        raise ValueError('Launcher2.apk missing')
    for app in ('Settings', 'SystemUI', 'LatinIME', 'PackageInstaller', 'SettingsProvider'):
        if not any((stage / 'system').glob('**/' + app + '.apk')):
            raise ValueError('required framework app missing: ' + app)


def prepare(product, stage):
    if not (product / 'root/init').is_file() or not (product / 'system/build.prop').is_file():
        raise ValueError('AOSP build output incomplete')
    if stage.exists():
        shutil.rmtree(stage)
    shutil.copytree(product / 'root', stage, symlinks=True)
    # Never unpack system.img: it may be sparse and is not the chroot root.
    if (stage / 'system').exists():
        shutil.rmtree(stage / 'system')
    shutil.copytree(product / 'system', stage / 'system', symlinks=True)
    for name in ('dev', 'dev/socket', 'dev/pts', 'dev/kobo', 'dev/input', 'proc', 'sys',
                 'data', 'cache', 'mnt', 'storage', 'storage/emulated', 'storage/emulated/0'):
        (stage / name).mkdir(parents=True, exist_ok=True)
    (stage / 'kobo-chroot').write_text('android-4.4.4_r2\n')
    validate(stage)


def file_list(stage):
    # Symlinks are represented as files, not followed outside the staging root.
    for path in sorted(stage.rglob('*')):
        relative = path.relative_to(stage).as_posix()
        if any(ch.isspace() for ch in relative):
            raise ValueError('fs_config cannot encode whitespace in path: ' + relative)
        yield relative + ('/' if path.is_dir() and not path.is_symlink() else '')


def apply_config(stage, config):
    if os.geteuid() != 0:
        raise ValueError('apply-config requires root to preserve Android uid/gid')
    expected = {name.rstrip('/') for name in file_list(stage)}
    seen = set()
    for line in config.read_text().splitlines():
        fields = line.split()
        if len(fields) < 4:
            raise ValueError('invalid fs_config row: ' + line)
        name, uid, gid, mode, *attrs = fields
        if name not in expected or name in seen or Path(name).is_absolute() or '..' in Path(name).parts:
            raise ValueError('unexpected fs_config path: ' + name)
        seen.add(name)
        path = stage / name
        os.chown(path, int(uid), int(gid), follow_symlinks=False)
        if not path.is_symlink():
            os.chmod(path, int(mode, 8))
            for attr in attrs:
                if attr.startswith('capabilities='):
                    caps = int(attr.split('=', 1)[1], 0)
                    if caps:
                        value = struct.pack('<IIIII', 0x02000001, caps & 0xffffffff, 0, caps >> 32, 0)
                        os.setxattr(path, 'security.capability', value, follow_symlinks=False)
    if seen != expected:
        raise ValueError('fs_config did not cover all staged paths')
    os.chown(stage, 0, 0)
    os.chmod(stage, 0o755)


def image(stage, destination, size_mib):
    if not 384 <= size_mib <= 4095:
        raise ValueError('rootfs size must be between 384 and 4095 MiB for FAT32')
    destination.parent.mkdir(parents=True, exist_ok=True)
    with destination.open('wb') as output:
        output.truncate(size_mib * 1024 * 1024)
    # Explicit old-kernel-safe feature set, no modern defaults such as 64bit,
    # metadata_csum, metadata_csum_seed or orphan_file. -d keeps staged owners,
    # permissions, symlinks, capabilities and file contents inside ext4.
    subprocess.run(['mke2fs', '-q', '-t', 'ext4', '-F', '-b', '4096', '-m', '0',
        '-L', 'kobo-android', '-O',
        'none,has_journal,ext_attr,resize_inode,dir_index,filetype,extent,sparse_super,large_file,uninit_bg',
        '-E', 'lazy_itable_init=0,lazy_journal_init=0', '-d', str(stage), str(destination)], check=True)
    subprocess.run(['e2fsck', '-fn', str(destination)], check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('phase', choices=('prepare', 'list', 'apply-config', 'image'))
    parser.add_argument('--stage', required=True, type=Path)
    parser.add_argument('--product', type=Path)
    parser.add_argument('--config', type=Path)
    parser.add_argument('--output', type=Path)
    parser.add_argument('--size-mib', type=int, default=768)
    args = parser.parse_args()
    try:
        if args.phase == 'prepare': prepare(args.product, args.stage)
        elif args.phase == 'list': print('\n'.join(file_list(args.stage)))
        elif args.phase == 'apply-config': apply_config(args.stage, args.config)
        elif args.phase == 'image': image(args.stage, args.output, args.size_mib)
    except (ValueError, OSError, subprocess.CalledProcessError) as exc:
        parser.exit(1, str(exc) + '\n')


if __name__ == '__main__':
    main()
