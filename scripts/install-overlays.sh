#!/bin/bash
# install-overlays.sh — собрать и поставить оверлеи частот (DSU 1027 МГц, GPU 1104 МГц).
# Идемпотентен: повторный запуск ничего не дублирует.
# Откат: ./rollback-overlays.sh
set -euo pipefail

HERE=$(cd "$(dirname "$0")/.." && pwd)
OVERLAY_DIR="/boot/dtb-$(uname -r)/allwinner/overlay"
ENV_FILE="/boot/orangepiEnv.txt"
PREFIX="sun60i-a733"
NAMES=("dsu-clk" "gpu-clk")

[ -d "$OVERLAY_DIR" ] || { echo "Нет каталога оверлеев: $OVERLAY_DIR" >&2; exit 1; }
[ -f "$ENV_FILE" ]     || { echo "Нет $ENV_FILE" >&2; exit 1; }
command -v dtc >/dev/null || { echo "Нужен dtc (apt install device-tree-compiler)" >&2; exit 1; }

echo "=== проверка phandle (должен быть cpupll_ccu) ==="
DTB=$(grep -m1 '^fdtfile=' "$ENV_FILE" | cut -d= -f2)
sudo dtc -I dtb -O dts "/boot/dtb-$(uname -r)/${DTB}" 2>/dev/null \
  | grep -A4 'cpupll_ccu@8870000' | grep -E 'phandle' | head -1 \
  || echo "предупреждение: не удалось проверить phandle, сверьте вручную"

for name in "${NAMES[@]}"; do
    echo "=== $name ==="
    dtc -@ -I dts -O dtb -o "/tmp/${PREFIX}-${name}.dtbo" "$HERE/overlays/${name}.dts"
    sudo cp "/tmp/${PREFIX}-${name}.dtbo" "$OVERLAY_DIR/"
    echo "  установлен $OVERLAY_DIR/${PREFIX}-${name}.dtbo"
done

echo "=== правка $ENV_FILE ==="
sudo cp "$ENV_FILE" "${ENV_FILE}.bak-$(date +%Y%m%d-%H%M)"
sudo python3 - "$ENV_FILE" "${NAMES[@]}" <<'PY'
import pathlib, sys
env, names = pathlib.Path(sys.argv[1]), sys.argv[2:]
t = env.read_text()
line = next((l for l in t.splitlines() if l.startswith("overlays=")), "overlays=")
cur = [x for x in line.split("=", 1)[1].split() if x]
for n in names:
    if n not in cur:
        cur.append(n)
new = "overlays=" + " ".join(cur)
if line in t:
    t = t.replace(line, new)
else:
    t = t.rstrip("\n") + "\n" + new + "\n"
env.write_text(t)
print("  " + new)
PY

echo
echo "Готово. Перезагрузите плату и проверьте:"
echo "  sudo grep cpu_dsu /sys/kernel/debug/clk/clk_summary   # 1027000000"
echo "  sudo dmesg | grep sunxi_parse_dts                     # clk_rate:1104000000"
