# 🔥 Orange Pi Zero 3W — GPU: что реально работает, PRIME-патч и разгон

> Практический разбор графики на Orange Pi Zero 3W (Allwinner A733): вендорский
> стек PowerVR, патч `pvrsrvkm` для DRM-PRIME, оверлеи частот (DSU 780 → 1027 МГц,
> GPU 600 → 1104 МГц) и честный ответ на вопрос «это приложение считает GPU или CPU».
> Всё проверено на живой плате, числа — из замеров, а не из документации.

```
                  ┌──────────────────────────────────────────────┐
   Chromium ──────┤ ANGLE (Vulkan)  →  libVK_IMG  (Vulkan 1.3)   │
   glmark2-es2 ───┤ EGL/GLES        →  PowerVR BXM-4-64 MC1      │
   GLX (zink) ────┤ Mesa 25.0.7+zink1 → libVK_IMG                │
                  └──────────────────────────────────────────────┘
                                   ▲
                        /dev/dri/card1 (pvrsrvkm)
                                   ▲
        DTB overlays: dsu-clk 780→1027 МГц · gpu-clk 600→1104 МГц @ 990 мВ
```

## Почему так, а не иначе

Мы прошли три пути, и только один оказался рабочим.

**1. Открытый драйвер `apercel`.** Собрали модуль, подняли открытую прошивку
`rogue_36.56.104.183_v1.fw` — драйвер завёлся, Vulkan 1.3 заработал. Но кадр в окно
он не отдаёт: в сборке Mesa нет связи с дисплейным контроллером sunxi, Xorg падает
с `No DRI3 support detected` и `AIGLX: Screen 0 is not DRI2 capable`. В окне —
чёрный экран, работает только offscreen. Для рабочего стола бесполезно.

**2. Вендорский стек `pvrsrvkm`.** Работает: окно, X11, GLES, zink. Ограничения —
нет GLX в чистом виде (zink через GLX упирается в DRI3), нет Wayland-расширений.

**3. Гибрид (выбран).** Вендорский драйвер + PRIME-патч из репозитория
[ayiejosh/a733-powervr-fex](https://github.com/ayiejosh/a733-powervr-fex) + оверлеи
частот из того же репозитория. Результат: рабочий стол на GPU, аппаратный GLES в окне,
WebGL в Chromium через ANGLE-Vulkan, +15 % в glmark2 после разгона.

## Что понадобится

- Orange Pi Zero 3W, Debian 13 (trixie), ядро `6.6.98-sun60iw2`;
- доступ по SSH и `sudo`;
- на машине сборки (любой ARM64-хост с тем же ядром в исходниках) — `git`, `build-essential`;
- ~2 ГБ на плате свободного места (Mesa, модули, прошивка).

Проверить базу:

```bash
uname -r                                   # 6.6.98-sun60iw2
cat /sys/class/drm/card1/device/uevent     # DRIVER=pvrsrvkm
glxinfo -B | grep "OpenGL renderer"
```

Ожидаемо: `zink Vulkan 1.3 (PowerVR B-Series BXM-4-64 MC1)`.

## Часть 1. Проверить, что GPU вообще есть и чем он занят

Ключевой инструмент — не «на глаз», а файловые дескрипторы процесса:

```bash
P=$(pgrep -x myapp | head -1)
sudo ls -l /proc/$P/fd | grep dri      # пусто → приложение GPU не открывало
sudo cat /sys/kernel/debug/dri/128/clients
grep pvrsrvkm /proc/interrupts         # растёт только когда GPU реально считает
```

Если у процесса нет fd на `/dev/dri` — он считает на CPU, что бы ни показывал
`glxinfo` в соседнем терминале.

Готовый скрипт: [`scripts/check-gpu.sh`](scripts/check-gpu.sh) — печатает ядро,
драйвер, частоты, renderer, WebGL-пробу Chromium и счётчик прерываний GPU.

## Часть 2. PRIME-патч pvrsrvkm

Патч `pvrsrvkm-drm-prime-import.patch` лежит в
[ayiejosh/a733-powervr-fex](https://github.com/ayiejosh/a733-powervr-fex)
(ветка `trixie`, каталог `kernel/`). Он добавляет `pvr_gem_prime_import`, чтобы
буферы можно было делить между вендорским драйвером и zink.

Исходников `img-bxm-dkms` на образе Zero 3W нет, поэтому берём их из пакета Radxa:

```bash
curl -L -o /tmp/img-bxm-dkms.deb \
  https://radxa-repo.github.io/a733-bullseye/pool/main/a/aw-drivers-dkms/img-bxm-dkms_0.1.0-3_all.deb
dpkg-deb -x /tmp/img-bxm-dkms.deb /tmp/imgbxm
```

Сборка против нашего дерева ядра (у нас оно уже подготовлено `modules_prepare`):

```bash
cd /tmp/imgbxm/usr/src/img-bxm-dkms-0.1.0-3/img-bxm/linux/rogue_km/services/server/env/linux
patch -p1 < /path/to/pvrsrvkm-drm-prime-import.patch

cd ../../build/linux/sunxi_linux
make -j4 BUILD=release KERNELDIR=/path/to/linux-6.6.98 \
     KBUILD_MODPOST_WARN=1
```

Две грабли, на которых мы стояли:

- `KERNELDIR` должен указывать на **подготовленное дерево** (`modules_prepare`), иначе
  сборка падает на `Module.symvers`;
- `KBUILD_MODPOST_WARN=1` обязателен: в дереве нет полного `Module.symvers`, без флага
  modpost обрывает сборку.

Проверка перед установкой — vermagic должен совпасть с ядром платы:

```bash
modinfo .../pvrsrvkm.ko | grep vermagic   # 6.6.98-sun60iw2 SMP preempt mod_unload aarch64
```

Установка: бэкап старого модуля → копирование в `/lib/modules/$(uname -r)/extra/` →
`depmod -a` → перезагрузка. Скрипт: [`scripts/build-pvrsrvkm-prime.sh`](scripts/build-pvrsrvkm-prime.sh).

> ⚠️ Выгружать и загружать `pvrsrvkm` на живой GPU нельзя: плата зависает так, что
> помогает только выключение питания. Только перезагрузка.

## Часть 3. Разгон: оверлеи DSU и GPU

### Что это даёт

- **DSU (L3 + шина когерентности):** в этом ядре нет драйвера `CONFIG_AW_SUNXI_DSUFREQ`,
  поэтому шина остаётся на 780 МГц, пока ядра работают на 1,8–2,0 ГГц.
  Оверлей поднимает её до **1027 МГц**. Замеры авторов: L3 +19 %, DRAM +38 %,
  запуск потока в FEX быстрее на 32 %.
- **GPU:** `pvrsrvkm` читает `clk_rate` из узла GPU и без него падает на 600 МГц.
  Оверлей ставит **1104 МГц** и поднимает питание рейла до **990 мВ**.

### Установка

```bash
dtc -@ -I dts -O dtb -o sun60i-a733-dsu-clk.dtbo overlays/dsu-clk.dts
dtc -@ -I dts -O dtb -o sun60i-a733-gpu-clk.dtbo overlays/gpu-clk.dts
sudo cp sun60i-a733-*.dtbo /boot/dtb-$(uname -r)/allwinner/overlay/
```

В `/boot/orangepiEnv.txt` добавить имена оверлеев (без префикса):

```
overlays=i2c0 dsu-clk gpu-clk
```

Перезагрузка. Проверка:

```bash
sudo grep cpu_dsu /sys/kernel/debug/clk/clk_summary        # 1027000000
sudo dmesg | grep sunxi_parse_dts                           # clk_rate:1104000000
sudo grep -E "^\s+gpu0\s" /sys/kernel/debug/clk/clk_summary # 1104000000
```

Скрипт: [`scripts/install-overlays.sh`](scripts/install-overlays.sh),
откат: [`scripts/rollback-overlays.sh`](scripts/rollback-overlays.sh).

### Важно про phandle

Оверлеи ссылаются на часы числовым phandle: `<0x05 0x03>` = `cpupll_ccu@8870000`,
третий клок (DSU). На нашем DTB это значение совпало. **Всегда проверяйте** перед
установкой — иначе оверлей молча перенаправит не тот клок:

```bash
sudo dtc -I dtb -O dts /boot/dtb-$(uname -r)/allwinner/sun60i-a733-orangepi-zero3w.dtb \
  | grep -B2 -A4 cpupll_ccu
```

## Часть 4. Результаты замеров

| Что | До | После |
|---|---|---|
| DSU | 780 МГц | 1027 МГц |
| GPU | 600 МГц | 1104 МГц @ 990 мВ |
| glmark2-es2, offscreen | 522 | **602** (+15 %) |
| WebGL в Chromium | работает | работает |
| Температура под 4 потоками | 62,4 °C | 62–65 °C (без изменений) |

Автор оверлеев на своём железе получил больше (`glmark2` 659 → 826), у нас сцена
другая — цифры зависят от набора тестов. Главное: рост стабильный, ошибок драйвера нет.

## Часть 5. Что работает на GPU, а что нет

**Работает:**

- Chromium/WebGL через `ANGLE (Imagination Technologies, Vulkan 1.3.277, PowerVR B-Series)`;
- `glmark2-es2` — и в окне, и offscreen;
- Vulkan-приложения (`libVK_IMG`, driverID `IMAGINATION_PROPRIETARY`);
- zink через GLX — с оговоркой: `glxgears` падает на `failed to create dri3 screen`,
  а `glmark2-es2` (EGL) работает.

**Не работает:**

- GPU-композитный десктоп (X11 или Wayland) — дедлок ядра, известная проблема вендорского DDK;
- окна Wayland — у драйвера нет Wayland-расширений поверхности;
- GLX-приложения, которым нужен DRI3.

## Часть 6. Почему 32-битные игры не едут на GPU

Мы попробовали перевести Disciples II (32-битная, DirectDraw) на GPU через
[DXVK-Sarek](https://github.com/pythonlover02/DXVK-Sarek) x32. Игра дошла до GPU
(9 дескрипторов `/dev/dri`), Vulkan-устройство создалось, но:

```
fixme:vulkan:win32u_vkMapMemory2KHR returned mapping 0x7f58ba0000
                  does not fit 32-bit pointer
err: DxvkMemoryAllocator: Mapping memory failed with VK_ERROR_OUT_OF_HOST_MEMORY
err: D3D7Interface::CreateDevice: Failed to create the D3D9 device
```

Драйвер отдаёт память по адресу выше 4 ГБ, а 32-битный процесс туда не достаёт.
Это ограничение моста WoW64/box64, а не PowerVR. 64-битные приложения через DXVK
работают, 32-битные — упираются в адресное пространство.

Подробности: [`docs/disciples2-dxvk.md`](docs/disciples2-dxvk.md).

## Часть 7. Chromium: почему не открывался редактор Tinkercad

Симптом: WebGL в headless-пробе работает (`ANGLE … PowerVR`), а в обычном окне
редактор не открывается и в консоли:

```
Uncaught Error: WebGL not detected
THREE.WebGLRenderer: Error creating WebGL context.
```

В логе GPU-процесса — вот это:

```
glEGLImageTargetTexture2DOES: EGL image internal format is not supported as a texture
Attempt to access an uninitialized SharedImage. WebGLDrawingBuffer
WebGL: CONTEXT_LOST_WEBGL: loseContext: context lost
```

Контекст создаётся, но общий буфер (SharedImage) через EGLImage на вендорском
драйвере не поднимается — и WebGL теряет контекст сразу после создания.

**Что помогло:** `--in-process-gpu`. GPU-процесс перестаёт ходить через проблемный
путь обмена изображениями, и редактор открывается на железе (Chromium держит
21 файловый дескриптор `/dev/dri` и виден в списке GPU-клиентов).

Прописать постоянно — в `/etc/chromium.d/gpu-vulkan`:

```bash
export CHROMIUM_FLAGS="$CHROMIUM_FLAGS --use-angle=vulkan --enable-features=Vulkan --in-process-gpu"
```

Что **не** помогло (проверено): `--use-angle=gl` — WebGL не создаётся вообще
(zink упирается в `failed to load driver: sunxi-drm`); `--disable-gpu-compositing` —
ошибки EGLImage остаются.

## Частые проблемы

| Проблема | Решение |
|---|---|
| `glx: failed to create dri3 screen` | Это GLX через zink. Используйте EGL/GLES (`glmark2-es2`) или ANGLE в Chromium |
| `Unsupported fw info version 2` | Вендорская прошивка не подходит открытому драйверу, нужен заголовок v3 |
| Плата зависла после `modprobe -r pvrsrvkm` | Только выключение питания. Не трогать модуль на живой GPU |
| GPU остался на 600 МГц | Нет свойства `clk_rate` в DT — нужен оверлей `gpu-clk` |
| `overlays=` не подхватился | Имена без префикса `sun60i-a733-`; `.dtbo` — в `/boot/dtb-<версия>/allwinner/overlay/` |
| После оверлея нет изображения | Убрать оверлеи из `orangepiEnv.txt`, перезагрузить |
| DXVK: `VK_ERROR_OUT_OF_HOST_MEMORY` | 32-битный процесс, см. Часть 6 |
| Tinkercad: «WebGL not detected» в окне | `--in-process-gpu`, см. Часть 7 |

## Альтернативы

- **Только вендорский стек без патча** — проще, но zink не получает PRIME-импорт.
- **Открытый `apercel`** — даёт Vulkan без блоба, но не умеет выводить кадр в окно
  (нет kmsro/sunxi). Годится для offscreen-вычислений и headless-рендера.
- **Wayland/sway** — на этом стеке не работает: живой GPU-композитор вешает ядро.

## Благодарности

Без этих людей и проектов работа не сдвинулась бы:

- **[ayiejosh/a733-powervr-fex](https://github.com/ayiejosh/a733-powervr-fex)** —
  оверлеи частот `dsu-clk` и `gpu-clk`, PRIME-патч `pvrsrvkm`, подробные замеры и
  разбор того, почему GPU-десктоп вешает ядро. Спасибо за то, что вся тяжёлая
  работа по реверсу A733 выложена открыто.
- **[pythonlover02/DXVK-Sarek](https://github.com/pythonlover02/DXVK-Sarek)** —
  сборки DXVK для слабых GPU; именно они дали возможность проверить 32-битный путь
  и честно увидеть предел адресного пространства.
- **[TumRedSun/apercel](https://github.com/TumRedSun/apercel)** — открытый драйвер
  PowerVR для A733, на котором мы убедились, что Vulkan offscreen работает.
- **Radxa** — за пакет `img-bxm-dkms` в
  [radxa/allwinner-debian](https://github.com/radxa/allwinner-debian) и репозиторий
  `radxa-repo.github.io`, откуда взяты исходники вендорского модуля.
- **Сообщество Mesa** — за zink, который позволяет гонять GL через Vulkan на
  железе без родного GL-драйвера.
- **Imagination Technologies** — за открытую прошивку `rogue_36.56.104.183_v1.fw`.

## Лицензия

MIT. Патчи и оверлеи — из перечисленных выше репозиториев, с сохранением их условий.
