# engine/aok-ios

The iOS platform layer: one C file plus a header, compiled into AokVM.app and
linked against `libqemu-system-aarch64.a`.

## Why it is not inside QEMU's meson build

It could be — `system_ss.add(files(...))` in `system/meson.build` would work —
but then every upstream rebase would have to re-apply a patch to QEMU. Instead
the app's Xcode target compiles `aok_ios.c` with QEMU's headers on its search
path (`build/qemu-ios`, `src/qemu/include`, `build/ios-sysroot/include`), which
is enough: the file only uses public headers plus the generated
`config-host.h`.

## What it does

| Function | Mechanism |
|---|---|
| owns the VM thread | `pthread_create` → `qemu_init(argc, argv)` → `qemu_main_loop()` → `qemu_cleanup()` |
| presents pixels | `qemu_console_register_listener(console 0, ...)` with a `DisplayChangeListener`; `dpy_gfx_update` hands Swift a pointer and a dirty rect, valid for the call only |
| drives scanout timing | `qemu_console_listener_set_refresh(dcl, 1e9/60)`; `dpy_refresh` → `qemu_console_hw_update()` |
| accepts input | `qemu_input_event_send_key_linux`, `qemu_input_queue_abs`, `qemu_input_queue_btn`, each posted through `aio_bh_schedule_oneshot()` so it runs on the main loop |
| pauses | `vm_stop(RUN_STATE_PAUSED)` / `vm_start()`, posted the same way |
| logs | `dup2` of stdout/stderr onto `Documents/Logs/engine.log` before `qemu_init` |

Two rules that are easy to break and expensive to debug:

1. The frame callback runs with the guest vCPU stopped. Copy and return. Do not
   call any `aok_ios_*` function from inside it.
2. Anything that touches QEMU state from the app's side must go through
   `aok_post()`; the `aio_bh_*` call is the only cross-thread door into the
   engine's main loop.

## Symbols the app needs

`qemu_init`, `qemu_main_loop`, `qemu_cleanup` (`include/system/system.h`),
`qemu_console_*` and the listener API (`include/ui/console.h`), input
(`include/ui/input.h`), `qemu_get_aio_context` (`qemu/main-loop.h`),
`aio_bh_schedule_oneshot` (`block/aio.h`), `vm_stop`/`vm_start`
(`system/runstate.h`), `qemu_system_shutdown_request` (`system/runstate.h`).

## Header drift

QEMU renames things between minor releases — in this tree `graphic_hw_update`
became `qemu_console_hw_update`, and `displaychangelistener_register` became
`qemu_console_register_listener`. Grep before assuming:

```sh
rg -n 'qemu_console_hw_update|qemu_console_register_listener' src/qemu/{include,ui} | head
```
