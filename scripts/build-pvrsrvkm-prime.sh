#!/bin/bash
# build-pvrsrvkm-prime.sh — собрать pvrsrvkm с DRM-PRIME патчем из исходников Radxa.
#
# Использование (на машине, где лежит подготовленное дерево ядра):
#   KERNELDIR=~/linux-6.6.98 ./build-pvrsrvkm-prime.sh
#
# Результат: ./out/pvrsrvkm.ko — копировать на плату в /lib/modules/$(uname -r)/extra/
# и выполнить depmod -a, затем перезагрузить.
set -euo pipefail

KERNELDIR=${KERNELDIR:-}
PATCH_URL=${PATCH_URL:-https://raw.githubusercontent.com/ayiejosh/a733-powervr-fex/trixie/kernel/pvrsrvkm-drm-prime-import.patch}
DEB_URL=${DEB_URL:-https://radxa-repo.github.io/a733-bullseye/pool/main/a/aw-drivers-dkms/img-bxm-dkms_0.1.0-3_all.deb}
WORK=${WORK:-$PWD/work}
OUT=${OUT:-$PWD/out}

[ -n "$KERNELDIR" ] || { echo "Задайте KERNELDIR=<путь к дереву ядра>" >&2; exit 1; }
[ -d "$KERNELDIR" ] || { echo "Нет каталога $KERNELDIR" >&2; exit 1; }
mkdir -p "$WORK" "$OUT"

echo "=== 1. исходники вендорского модуля ==="
if [ ! -d "$WORK/src" ]; then
    curl -fL -o "$WORK/img-bxm-dkms.deb" "$DEB_URL"
    mkdir -p "$WORK/src"
    dpkg-deb -x "$WORK/img-bxm-dkms.deb" "$WORK/src"
fi
SRC=$(find "$WORK/src" -maxdepth 3 -type d -name 'img-bxm-dkms-*' | head -1)
[ -n "$SRC" ] || { echo "Не нашли распакованный исходник" >&2; exit 1; }

echo "=== 2. PRIME-патч ==="
[ -f "$WORK/prime.patch" ] || curl -fL -o "$WORK/prime.patch" "$PATCH_URL"
ENVDIR="$SRC/img-bxm/linux/rogue_km/services/server/env/linux"
( cd "$ENVDIR" && patch -p1 --forward < "$WORK/prime.patch" ) || \
    echo "  патч уже применён или не лёг — проверьте вывод выше"

echo "=== 3. сборка ==="
BUILD_DIR="$SRC/img-bxm/linux/rogue_km/build/linux/sunxi_linux"
make -C "$BUILD_DIR" -j"$(nproc)" BUILD=release \
     KERNEL_CC=gcc KERNEL_LD=ld KERNEL_NM=nm KERNEL_OBJCOPY=objcopy \
     KERNELDIR="$KERNELDIR" KBUILD_MODPOST_WARN=1

KO=$(find "$SRC" -name pvrsrvkm.ko -newermt '-10 minutes' | head -1)
[ -n "$KO" ] || { echo "pvrsrvkm.ko не собрался" >&2; exit 1; }

echo "=== 4. проверка vermagic ==="
VERMAGIC=$(modinfo "$KO" | awk '/^vermagic/{print $2}')
echo "  $KO"
echo "  vermagic: $VERMAGIC"
case "$VERMAGIC" in
    6.6.98-sun60iw2*) ;;
    *) echo "ВНИМАНИЕ: vermagic не совпадает с ядром платы — модуль не загрузится" >&2 ;;
esac

cp "$KO" "$OUT/pvrsrvkm.ko"
echo
echo "Готово: $OUT/pvrsrvkm.ko"
echo "Установка на плате (с бэкапом):"
echo "  sudo cp /lib/modules/\$(uname -r)/extra/pvrsrvkm.ko ~/pvrsrvkm.ko.orig"
echo "  sudo cp pvrsrvkm.ko /lib/modules/\$(uname -r)/extra/ && sudo depmod -a && sudo reboot"
