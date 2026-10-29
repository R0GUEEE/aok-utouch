/*
 * aok_ios.h - the only surface the Swift app sees of the VM engine.
 *
 * Everything here is C so it can be called straight from Swift through the
 * bridging header. No Foundation types cross this boundary.
 *
 * Threading contract:
 *   - aok_ios_start() may be called from any thread; it creates the engine
 *     thread and returns immediately.
 *   - the frame/resize/exit callbacks run on the engine thread. The frame
 *     callback hands out a pointer into the guest's scanout memory that is
 *     valid only for the duration of the call. Copy, then return.
 *   - every aok_ios_* input call may be called from any thread; the event is
 *     marshalled into QEMU's main loop before it is delivered.
 */
#ifndef AOK_IOS_H
#define AOK_IOS_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Pixels arrive as 32-bit XRGB/ARGB little-endian: byte order B,G,R,X. */
typedef void (*aok_ios_frame_cb)(void *ctx, const uint8_t *base, size_t stride,
                                 int x, int y, int w, int h);
typedef void (*aok_ios_resize_cb)(void *ctx, int width, int height);
typedef void (*aok_ios_exit_cb)(void *ctx, int status);

void aok_ios_set_frame_cb(aok_ios_frame_cb cb, void *ctx);
void aok_ios_set_resize_cb(aok_ios_resize_cb cb, void *ctx);
void aok_ios_set_exit_cb(aok_ios_exit_cb cb, void *ctx);

/* Redirect the engine's stderr (QEMU's error_report output) to a file. */
void aok_ios_set_log_path(const char *path);

/* argv must be NUL-terminated strings; count excludes the terminating NULL.
 * Returns 0 when the engine thread was created, -1 if one is already running,
 * -2 if the thread could not be created. */
int aok_ios_start(const char *const *args, int count);

/* Blocks until qemu_init() has returned (the machine is built and the console
 * exists) or the timeout expires. 1 = ready, 0 = timed out, -1 = failed. */
int aok_ios_wait_ready(int timeout_ms);

/* Requested from the engine thread by the ready handshake. */
int aok_ios_is_ready(void);
int aok_ios_is_running(void);

void aok_ios_pause(void);
void aok_ios_resume(void);
void aok_ios_shutdown(void);   /* guest ACPI/paravirt shutdown request */
void aok_ios_quit(void);       /* abandon the VM: qemu_cleanup on the engine thread */

/* Input. Keycodes are Linux evdev codes (KEY_A = 30, see input-event-codes.h). */
void aok_ios_key_linux(unsigned int linux_keycode, int down);

/* Normalised absolute pointer, 0..32767 on both axes (QEMU's ABS range). */
void aok_ios_pointer_abs(int x, int y);
void aok_ios_pointer_button(int button, int down);

/* Bytes iOS says we may still allocate (os_proc_available_memory()). */
long aok_ios_available_memory(void);

/* Guest display size, so the host can letterbox and scale input. */
void aok_ios_display_size(int *width, int *height);

#ifdef __cplusplus
}
#endif

#endif /* AOK_IOS_H */
