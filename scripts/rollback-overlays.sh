#!/bin/bash
# rollback-overlays.sh — вернуть штатные частоты (DSU 780 МГц, GPU 600 МГц).
set -euo pipefail

OVERLAY_DIR="/boot/dtb-$(uname -r)/allwinner/overlay"
ENV_FILE="/boot/orangepiEnv.txt"
PREFIX="sun60i-a733"
NAMES=("dsu-clk" "gpu-clk")

echo "=== убираю имена из $ENV_FILE ==="
sudo cp "$ENV_FILE" "${ENV_FILE}.bak-$(date +%Y%m%d-%H%M)"
sudo python3 - "$ENV_FILE" "${NAMES[@]}" <<'PY'
import pathlib, sys
env, names = pathlib.Path(sys.argv[1]), sys.argv[2:]
t = env.read_text()
out = []
for line in t.splitlines():
    if line.startswith("overlays="):
        cur = [x for x in line.split("=", 1)[1].split() if x and x not in names]
        line = "overlays=" + " ".join(cur)
    out.append(line)
env.write_text("\n".join(out) + "\n")
print("  " + next((l for l in out if l.startswith("overlays=")), "overlays="))
PY

echo "=== удаляю .dtbo ==="
for name in "${NAMES[@]}"; do
    sudo rm -f "$OVERLAY_DIR/${PREFIX}-${name}.dtbo"
    echo "  удалён ${PREFIX}-${name}.dtbo"
done

echo
echo "Готово. После перезагрузки: DSU 780 МГц, GPU 600 МГц."
