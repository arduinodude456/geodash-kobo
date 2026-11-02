#!/usr/bin/env python3
"""Patch only the exact android-4.4.4_r2 files; never silently accept drift."""
import argparse
import hashlib
import json
import re
from pathlib import Path

MARKER = "KOBO_CHROOT_ANDROID_444_R2_V1"
PRUNE = "adb adbd bootanimation healthd init.rc reboot vold vdc netd ndc dhcpcd dhcpcd-run-hooks dnsmasq mtpd pppd racoon sdcard ip-up-vpn Home sensorservice".split()


def replace_once(text, old, new):
    if text.count(old) != 1:
        raise ValueError("patch anchor missing or ambiguous: " + old[:90])
    return text.replace(old, new, 1)


def replace_function(text, signature, body):
    pattern = re.escape(signature) + r"\n\{.*?^\}"
    text, count = re.subn(pattern, lambda m: signature + "\n{\n" + body + "\n}", text, count=1, flags=re.M | re.S)
    if count != 1:
        raise ValueError("function anchor missing: " + signature)
    return text


def patch_init(text):
    for line in (
        '    mount("tmpfs", "/dev", "tmpfs", MS_NOSUID, "mode=0755");',
        '    mount("devpts", "/dev/pts", "devpts", 0, NULL);',
        '    mount("proc", "/proc", "proc", 0, NULL);',
        '    mount("sysfs", "/sys", "sysfs", 0, NULL);',
    ):
        text = replace_once(text, line, "    /* " + MARKER + ": private mount prepared by supervisor. */")
    text = replace_once(text, '    get_hardware_name(hardware, &revision);\n\n    process_kernel_cmdline();',
        '    /* ' + MARKER + ': never consume Kobo boot cmdline or discover host hardware. */\n'
        '    strlcpy(hardware, "kobo_libra_colour", sizeof(hardware));\n'
        '    property_set("ro.hardware", hardware);\n'
        '    property_set("ro.bootmode", "unknown");\n'
        '    property_set("ro.factorytest", "0");')
    start = text.index('    union selinux_callback cb;', text.index('int main('))
    end_anchor = '    restorecon_recursive("/sys");'
    end = text.index(end_anchor, start) + len(end_anchor)
    text = text[:start] + '    /* ' + MARKER + ': no SELinux setup, policy load or host relabeling. */' + text[end:]
    text = replace_function(text, 'static bool selinux_is_disabled(void)', '    return true; /* Dedicated chroot; never manipulate host SELinux. */')
    text = replace_function(text, 'int selinux_reload_policy(void)', '    return -1; /* Host policy is never ours. */')
    text = replace_function(text, 'static void selinux_initialize(void)', '    return; /* Host policy is never ours. */')
    # ueventd never runs; waiting for its coldboot marker and reseeding host RNG
    # is inappropriate. Properties and signal_init remain queued unchanged.
    for name in ('wait_for_coldboot_done', 'mix_hwrng_into_linux_rng', 'keychord_init', 'console_init'):
        anchor = f'    queue_builtin_action({name}_action, "{name}");'
        if anchor not in text:
            raise ValueError('missing bootstrap action: ' + name)
        text = text.replace(anchor, '    /* ' + MARKER + ': skip ' + name + '. */')
    # KitKat queues these directly in main(), unlike newer Android releases
    # whose init.rc needs an on late-init trigger chain. Do not double-queue.
    for required in ('property_init();', 'property_service_init_action', 'signal_init_action',
                     'action_for_each_trigger("post-fs-data", action_add_queue_tail);',
                     'action_for_each_trigger("boot", action_add_queue_tail);'):
        if required not in text:
            raise ValueError('critical init bootstrap removed: ' + required)
    return text


def patch_build(text):
    start = text.index('# Check for the corrent jdk\n')
    end = text.index('# Check for the correct version of java\n', start)
    text = text[:start] + '# ' + MARKER + ': OpenJDK7 compatibility, Java source/target unchanged.\n' + text[end:]
    if text.count(r'1\.6') != 2:
        raise ValueError('unexpected Java version gates')
    text = text.replace(r'1\.6', r'1\.7').replace('Java SE 1.6.', 'OpenJDK 1.7.').replace('version is: 1.6.', 'version is: 1.7.')
    anchor = '  product_MODULES := $(PRODUCTS.$(INTERNAL_PRODUCT).PRODUCT_PACKAGES)'
    addition = '\n'.join((
        anchor,
        '  # ' + MARKER + ': filter after inheritance, before required deps expand.',
        '  ifeq ($(TARGET_PRODUCT),kobo_libra_colour)',
        '    product_MODULES := $(filter-out ' + ' '.join(PRUNE) + ',$(product_MODULES))',
        '  endif',
    ))
    return replace_once(text, anchor, addition)


def patch_builtins(text):
    return replace_function(text, 'int do_powerctl(int nargs, char **args)',
        '    /* ' + MARKER + ': container lifecycle belongs to Kobo supervisor. */\n'
        '    (void)nargs; (void)args;\n    return -EPERM;')


def patch_runtimes(text):
    return replace_once(text, 'PRODUCT_RUNTIMES += runtime_libart', '# ' + MARKER + ': Dalvik only; do not install experimental ART. ')


def patch_hwui(text):
    text = replace_once(text, 'public static boolean sRendererDisabled = false;',
        'public static boolean sRendererDisabled = true; // ' + MARKER)
    text = replace_once(text, 'public static boolean sSystemRendererDisabled = false;',
        'public static boolean sSystemRendererDisabled = true; // ' + MARKER)
    text = replace_once(text, 'public static boolean isAvailable() {\n        return GLES20Canvas.isAvailable();\n    }',
        'public static boolean isAvailable() {\n        return false; // ' + MARKER + ': software GLES1 only\n    }')
    return replace_once(text,
        'static HardwareRenderer create(boolean translucent) {\n            if (GLES20Canvas.isAvailable()) {\n                return new Gl20Renderer(translucent);\n            }\n            return null;\n        }',
        'static HardwareRenderer create(boolean translucent) {\n            return null; // ' + MARKER + ': no GLES2 renderer\n        }')


PATCHES = {
    'system/core/init/init.c': ('4be94186689812b9ff57fb0631bc7a09c8a3b158092e930236e91faed4fed92f', patch_init),
    'system/core/init/builtins.c': ('d91fd5fe1c75f4bff7f9f62f20b8614bfe255bb5607b5e474ab61b4127799376', patch_builtins),
    'build/core/main.mk': ('73247e80c48566b5eea6acbb574d52c86948f1d2de4de62cf0c11b1fd91b8130', patch_build),
    'build/target/product/core_minimal.mk': ('bddc09cd752741e91c463dc23a09c618ade8aaee5b352288c9e0bbd023a73797', patch_runtimes),
    'frameworks/base/core/java/android/view/HardwareRenderer.java': ('d4e1e471a3b1a22e1b8b4ac239acd15731bf944a8ae33ba3fa0001ddb813318f', patch_hwui),
}


def digest(data):
    return hashlib.sha256(data).hexdigest()


def apply(root, record):
    # Originals are retained locally so reruns can verify both sides, not just
    # trust a marker an unrelated modification could leave behind.
    plans = []
    for relative, (expected, transform) in PATCHES.items():
        path = root / relative
        backup = path.with_name(path.name + '.kobo-original')
        original = backup.read_bytes() if backup.exists() else path.read_bytes()
        if digest(original) != expected:
            raise ValueError('source hash mismatch (wrong release or modified file): ' + relative)
        patched = transform(original.decode('utf-8')).encode('utf-8')
        current = path.read_bytes()
        if current not in (original, patched):
            raise ValueError('refusing to overwrite local changes: ' + relative)
        plans.append((path, backup, original, patched, relative))
    records = []
    for path, backup, original, patched, relative in plans:
        if not backup.exists():
            backup.write_bytes(original)
        path.write_bytes(patched)
        records.append({'path': relative, 'original_sha256': digest(original), 'patched_sha256': digest(patched)})
    record.parent.mkdir(parents=True, exist_ok=True)
    record.write_text(json.dumps({'release': 'android-4.4.4_r2', 'marker': MARKER, 'patches': records}, indent=2) + '\n')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('aosp', type=Path)
    parser.add_argument('--record', type=Path, required=True)
    args = parser.parse_args()
    try:
        apply(args.aosp.resolve(), args.record)
    except (OSError, ValueError) as exc:
        parser.exit(1, str(exc) + '\n')


if __name__ == '__main__':
    main()
