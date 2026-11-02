#!/usr/bin/env bash
set -eo pipefail
cd /aosp
# envsetup.sh is not nounset-safe in KitKat.
source build/envsetup.sh
lunch kobo_libra_colour-userdebug
java -version
javac -version
gcc --version | head -1
getconf GNU_LIBC_VERSION
make --version | head -1
# 'droid' also attempts emulator/kernel/images; a chroot needs none of these.
# 'files' installs the selected framework, apps, libraries, init and env rc.
make -j"${JOBS:-2}" BUILD_EMULATOR=false \
    files fs_config out/target/product/libra_colour/system/etc/NOTICE.html.gz
