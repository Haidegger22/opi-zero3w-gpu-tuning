# Disciples II на Orange Pi Zero 3W: почему игра не едет на GPU

Короткий разбор эксперимента: можно ли перевести старую 32-битную игру с
программного рендера на PowerVR. Ответ — нет, и вот на чём именно она упирается.

## Исходное состояние

- Игра: Disciples II: Gold, русская версия, каталог `d2-ru-pack/app`, `Discipl2.exe`.
- Запуск: Wine 11 (Hangover) + box64, `WINEPREFIX=~/.wine-hg2`.
- В `Disciple.ini`: `UseD3D=0` — то есть игра идёт по 2D-пути (DirectDraw/GDI).

Замеры на этом состоянии:

| Показатель | Значение |
|---|---|
| CPU процесса | 154–185 % |
| fd на `/dev/dri` у процесса | 0 |
| В списке DRM-клиентов GPU | нет |
| Прерывания `pvrsrvkm` | ~500/с (их даёт Xorg, не игра) |
| Температура | 54–55 °C |

Вывод: игра считает на CPU, GPU занят только рабочим столом.

## Что пробовали

1. Скачали **DXVK-Sarek v1.14.1** (x32) — `ddraw.dll`, `d3d9.dll`, `d3d8.dll`,
   `d3d11.dll`, `dxgi.dll`.
2. Положили DLL рядом с `Discipl2.exe`.
3. В лаунчере заменили overrides с `ddraw=b;d3d9=b` на `ddraw=n,b;d3d9=n,b`.
4. Включили `UseD3D=1` в `Disciple.ini`.
5. Запустили и сняли отладочный вывод (`DXVK_LOG_LEVEL=info`).

## Что получилось

Игра действительно дошла до GPU — в отличие от исходного состояния, у процесса
появилось **9 дескрипторов `/dev/dri`**, Vulkan-устройство создалось, DXVK прочитал
возможности драйвера (`VK_EXT_transform_feedback`, `bufferDeviceAddress` и т.д.).

Но на создании D3D9-устройства всё встало:

```
fixme:vulkan:win32u_vkMapMemory2KHR returned mapping 0x7f58ba0000
                  does not fit 32-bit pointer
err:   DxvkMemoryAllocator: Mapping memory failed with VK_ERROR_OUT_OF_HOST_MEMORY
err:   DxvkMemoryAllocator: Memory allocation failed
err:     Size: 8192  Alignment: 4096  Mem flags: 0x6  Mem types: 0xd
err:     Heap 0: 4 MB allocated, 0 MB used, 11871 MB total
err:   D3D7Interface::CreateDevice: Failed to create the D3D9 device
```

## Почему

32-битный процесс может адресовать только 4 ГБ (2³² байта). Драйвер выделил память
по адресу `0x7f58ba0000` — это ~547 ГБ, за пределы 32-битного указателя. Wine
попытался вернуть этот адрес игре и не смог: `does not fit 32-bit pointer`.

Дело не в объёме памяти (Vulkan показывал 11,8 ГБ доступной кучи) и не в драйвере
PowerVR — он-то как раз отработал. Ограничение в мосте WoW64/box64, который
предоставляет 32-битному приложению 32-битное адресное пространство.

## Итог

- 64-битные приложения через DXVK на этом стеке работают.
- 32-битные — упираются в 4 ГБ и падают на создании устройства.
- Игра возвращена на `UseD3D=0` (софт-рендер), DXVK-библиотеки убраны из каталога.

Откат в нашем случае — скрипт, который убирает DLL, `dxvk.conf` и возвращает
`UseD3D=0` в `Disciple.ini`.
