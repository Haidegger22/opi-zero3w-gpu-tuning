#!/bin/bash
# check-gpu.sh — что за GPU-стек сейчас на плате и чем он занят.
# Ничего не меняет. Требует sudo для чтения clk_summary/dmesg (можно без — тогда пропустит).
set -uo pipefail

SUDO=""
if [ "$(id -u)" -ne 0 ]; then SUDO="sudo -n"; fi

echo "=== система ==="
uname -r
[ -f /etc/os-release ] && . /etc/os-release && echo "$PRETTY_NAME"

echo
echo "=== DRM-устройства ==="
for c in /sys/class/drm/card*/device; do
    [ -e "$c/uevent" ] || continue
    drv=$(grep -m1 '^DRIVER=' "$c/uevent" | cut -d= -f2)
    echo "$(basename "$(dirname "$c")"): ${drv:-?}"
done

echo
echo "=== частоты ==="
if [ -n "$SUDO" ]; then
    $SUDO grep -E 'cpu_dsu|pll-gpu|^\s+gpu0' /sys/kernel/debug/clk/clk_summary 2>/dev/null \
        | awk '{print $1, $5}' | sort -u
else
    echo "(нужен sudo)"
fi

echo
echo "=== что сказал драйвер при загрузке ==="
if [ -n "$SUDO" ]; then
    $SUDO dmesg 2>/dev/null | grep -E 'sunxi_parse_dts clk_rate|sunxiSetVoltage' | tail -3
fi

echo
echo "=== GL renderer ==="
if command -v glxinfo >/dev/null 2>&1; then
    DISPLAY=${DISPLAY:-:0} glxinfo -B 2>/dev/null | grep -E 'OpenGL renderer|OpenGL version'
else
    echo "glxinfo не установлен"
fi

echo
echo "=== WebGL в Chromium (headless) ==="
if command -v chromium >/dev/null 2>&1; then
    timeout 40 chromium --headless=new --no-sandbox --virtual-time-budget=6000 --dump-dom \
      'data:text/html,<canvas id=c></canvas><script>var g=document.getElementById("c").getContext("webgl2");var d=g&&g.getExtension("WEBGL_debug_renderer_info");document.body.innerText=d?g.getParameter(d.UNMASKED_RENDERER_WEBGL):"none";</script>' \
      2>/dev/null | grep -o 'ANGLE[^<]*' | head -1
else
    echo "chromium не установлен"
fi

echo
echo "=== GPU-прерывания за 2 секунды ==="
a=$(grep pvrsrvkm /proc/interrupts 2>/dev/null | awk '{s=0; for(i=2;i<=NF-3;i++) s+=$i; print s}')
sleep 2
b=$(grep pvrsrvkm /proc/interrupts 2>/dev/null | awk '{s=0; for(i=2;i<=NF-3;i++) s+=$i; print s}')
echo "было ${a:-0}, стало ${b:-0}, прирост $((${b:-0}-${a:-0}))"

echo
echo "=== кто держит GPU ==="
if [ -r /sys/kernel/debug/dri/128/clients ] || [ -n "$SUDO" ]; then
    ${SUDO} cat /sys/kernel/debug/dri/128/clients 2>/dev/null | awk 'NR>1{print $1}' | sort | uniq -c
fi

echo
echo "Готово. Если в 'кто держит GPU' нет нужного приложения — оно считает на CPU."
