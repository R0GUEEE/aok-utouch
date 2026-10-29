/*
 * aok_ios.c - QEMU-system in a thread, with a display listener and an input
 * bridge that belong to an iOS app rather than to a desktop UI.
 *
 * Built into libqemu-system-aarch64.a's host, linked into AokVM.app.
 * Compiled with the engine's own headers; the only include that is ours is
 * aok_ios.h, and the only symbols we export are the aok_ios_* ones.
 *
 * SPDX-License-Identifier: GPL-2.0-or-later
 */

#include "qemu/osdep.h"

#include <fcntl.h>
#include <pthread.h>
#include <unistd.h>

#ifdef __APPLE__
#include <os/proc.h>
#endif

#include "qapi/error.h"
#include "qemu/main-loop.h"
#include "system/runstate.h"
#include "system/system.h"
#include "ui/console.h"
#include "ui/input.h"
#include "ui/surface.h"

#include "aok_ios.h"

/* 60 Hz scanout. virtio-gpu pushes dirty rects; this only asks the device to
 * look again, it never re-copies the whole framebuffer. */
#define AOK_REFRESH_NS (1000000000ull / 60)

typedef struct AokState {
    aok_ios_frame_cb frame_cb;
    void *frame_ctx;
    aok_ios_resize_cb resize_cb;
    void *resize_ctx;
    aok_ios_exit_cb exit_cb;
    void *exit_ctx;

    char log_path[1024];
    pthread_t thread;
    int thread_valid;
    int running;
    int ready;
    int failed;

    QemuConsole *con;
    int width;
    int height;
} AokState;

static AokState S;

typedef struct AokDpy {
    DisplayChangeListener dcl;
    DisplaySurface *surface;
} AokDpy;

static AokDpy DPY;

typedef enum AokEventKind {
    AOK_EV_KEY,
    AOK_EV_POINTER,
    AOK_EV_BUTTON,
    AOK_EV_PAUSE,
    AOK_EV_RESUME,
    AOK_EV_SHUTDOWN,
} AokEventKind;

static void aok_dpy_update(DisplayChangeListener *dcl, int x, int y, int w, int h)
{
    AokDpy *d = container_of(dcl, AokDpy, dcl);
    DisplaySurface *s = d->surface;

    if (!s || !S.frame_cb) {
        return;
    }

    int sw = surface_width(s);
    int sh = surface_height(s);

    if (x < 0) { w += x; x = 0; }
    if (y < 0) { h += y; y = 0; }
    if (x >= sw || y >= sh) { return; }
    if (x + w > sw) { w = sw - x; }
    if (y + h > sh) { h = sh - y; }
    if (w <= 0 || h <= 0) { return; }

    S.frame_cb(S.frame_ctx,
               (const uint8_t *)surface_data(s) +
                   (size_t)y * surface_stride(s) + (size_t)x * 4,
               (size_t)surface_stride(s), x, y, w, h);
}

static void aok_dpy_switch(DisplayChangeListener *dcl, DisplaySurface *surface)
{
    AokDpy *d = container_of(dcl, AokDpy, dcl);

    d->surface = surface;
    S.width = surface_width(surface);
    S.height = surface_height(surface);

    if (S.resize_cb) {
        S.resize_cb(S.resize_ctx, S.width, S.height);
    }
    aok_dpy_update(dcl, 0, 0, S.width, S.height);
}

static bool aok_dpy_check_format(DisplayChangeListener *dcl,
                                 pixman_format_code_t format)
{
    /* 32bpp, byte order B,G,R,X in memory: what .bgra8Unorm wants. */
    return format == PIXMAN_x8r8g8b8 || format == PIXMAN_a8r8g8b8;
}

static void aok_dpy_refresh(DisplayChangeListener *dcl)
{
    if (S.con) {
        qemu_console_hw_update(S.con);
    }
}

static const DisplayChangeListenerOps aok_dpy_ops = {
    .dpy_name = "aok-ios",
    .dpy_refresh = aok_dpy_refresh,
    .dpy_gfx_update = aok_dpy_update,
    .dpy_gfx_switch = aok_dpy_switch,
    .dpy_gfx_check_format = aok_dpy_check_format,
};

static void aok_event_deliver(AokEventKind kind, int a, int b)
{
    switch (kind) {
    case AOK_EV_KEY:
        if (S.con) {
            qemu_input_event_send_key_linux(S.con, (unsigned int)a, b != 0);
        }
        break;
    case AOK_EV_POINTER:
        if (S.con) {
            qemu_input_queue_abs(S.con, INPUT_AXIS_X, a, 0, INPUT_EVENT_ABS_MAX);
            qemu_input_queue_abs(S.con, INPUT_AXIS_Y, b, 0, INPUT_EVENT_ABS_MAX);
            qemu_input_event_sync();
        }
        break;
    case AOK_EV_BUTTON:
        if (S.con) {
            qemu_input_queue_btn(S.con, (InputButton)a, b != 0);
            qemu_input_event_sync();
        }
        break;
    case AOK_EV_PAUSE:
        if (runstate_is_running()) {
            vm_stop(RUN_STATE_PAUSED);
        }
        break;
    case AOK_EV_RESUME:
        if (runstate_is_paused()) {
            vm_start();
        }
        break;
    case AOK_EV_SHUTDOWN:
        qemu_system_shutdown_request(SHUTDOWN_CAUSE_HOST_UI);
        break;
    }
}

/*
 * Deliver an event from any thread.
 *
 * The Big QEMU Lock is the documented way for a host UI thread to touch device
 * and run-state state: QEMU's own display and input backends run in a thread of
 * their own and take it exactly like this. The alternative - scheduling a
 * bottom half on the main loop's AioContext - needs the main loop to actually
 * be spinning, which it is not while the guest is paused.
 */
static void aok_post(AokEventKind kind, int a, int b)
{
    if (!__atomic_load_n(&S.running, __ATOMIC_ACQUIRE)) {
        return;
    }
    bql_lock();
    aok_event_deliver(kind, a, b);
    bql_unlock();
}

static void *aok_engine_main(void *arg)
{
    char **argv = arg;
    int argc = 0;
    int status;

    while (argv[argc]) {
        argc++;
    }

    if (S.log_path[0]) {
        int fd = open(S.log_path, O_WRONLY | O_CREAT | O_APPEND, 0644);
        if (fd >= 0) {
            dup2(fd, STDOUT_FILENO);
            dup2(fd, STDERR_FILENO);
            close(fd);
        }
    }

    /* From here until qemu_main_loop() returns this thread belongs to QEMU. */
    qemu_init(argc, argv);

    S.con = qemu_console_lookup_by_index(0);
    if (S.con) {
        qemu_console_register_listener(S.con, &DPY.dcl, &aok_dpy_ops);
        qemu_console_listener_set_refresh(&DPY.dcl, AOK_REFRESH_NS);
        if (S.width == 0) {
            S.width = qemu_console_get_width(S.con, 0);
            S.height = qemu_console_get_height(S.con, 0);
        }
    } else {
        S.failed = 1;
    }

    /* Only now is it safe to take the BQL from another thread. */
    __atomic_store_n(&S.running, 1, __ATOMIC_RELEASE);
    __atomic_store_n(&S.ready, 1, __ATOMIC_RELEASE);

    status = qemu_main_loop();
    qemu_cleanup(status);

    S.running = 0;
    __atomic_store_n(&S.thread_valid, 0, __ATOMIC_RELEASE);
    if (S.exit_cb) {
        S.exit_cb(S.exit_ctx, status);
    }
    return NULL;
}

int aok_ios_start(const char *const *args, int count)
{
    char **argv;
    int i;

    if (S.running || __atomic_load_n(&S.thread_valid, __ATOMIC_ACQUIRE)) {
        return -1;
    }

    argv = g_new0(char *, (size_t)count + 1);
    for (i = 0; i < count; i++) {
        argv[i] = g_strdup(args[i]);
    }

    S.ready = 0;
    S.failed = 0;
    __atomic_store_n(&S.thread_valid, 1, __ATOMIC_RELEASE);

    if (pthread_create(&S.thread, NULL, aok_engine_main, argv) != 0) {
        for (i = 0; i < count; i++) {
            g_free(argv[i]);
        }
        g_free(argv);
        __atomic_store_n(&S.thread_valid, 0, __ATOMIC_RELEASE);
        return -2;
    }
#if defined(__linux__)
    pthread_setname_np(S.thread, "aok-engine");
#else
    /* Darwin's pthread_setname_np names the *current* thread only. */
    pthread_setname_np("aok-engine");
#endif
    return 0;
}

int aok_ios_wait_ready(int timeout_ms)
{
    int waited = 0;

    while (waited < timeout_ms) {
        if (__atomic_load_n(&S.ready, __ATOMIC_ACQUIRE)) {
            return S.failed ? -1 : 1;
        }
        if (!__atomic_load_n(&S.thread_valid, __ATOMIC_ACQUIRE)) {
            return -1;
        }
        usleep(20 * 1000);
        waited += 20;
    }
    return 0;
}

int aok_ios_is_ready(void) { return __atomic_load_n(&S.ready, __ATOMIC_ACQUIRE); }
int aok_ios_is_running(void) { return __atomic_load_n(&S.running, __ATOMIC_ACQUIRE); }

void aok_ios_set_frame_cb(aok_ios_frame_cb cb, void *ctx)
{
    S.frame_cb = cb;
    S.frame_ctx = ctx;
}

void aok_ios_set_resize_cb(aok_ios_resize_cb cb, void *ctx)
{
    S.resize_cb = cb;
    S.resize_ctx = ctx;
}

void aok_ios_set_exit_cb(aok_ios_exit_cb cb, void *ctx)
{
    S.exit_cb = cb;
    S.exit_ctx = ctx;
}

void aok_ios_set_log_path(const char *path)
{
    if (!path) {
        S.log_path[0] = 0;
        return;
    }
    g_strlcpy(S.log_path, path, sizeof(S.log_path));
}

void aok_ios_pause(void) { aok_post(AOK_EV_PAUSE, 0, 0); }
void aok_ios_resume(void) { aok_post(AOK_EV_RESUME, 0, 0); }
void aok_ios_shutdown(void) { aok_post(AOK_EV_SHUTDOWN, 0, 0); }

void aok_ios_quit(void)
{
    /* The graceful path is a shutdown request; the guest's init answers it.
     * A guest that ignores it keeps running, which is what you want when the
     * user only backgrounded the app. */
    aok_post(AOK_EV_SHUTDOWN, 0, 0);
}

void aok_ios_key_linux(unsigned int linux_keycode, int down)
{
    aok_post(AOK_EV_KEY, (int)linux_keycode, down ? 1 : 0);
}

void aok_ios_pointer_abs(int x, int y)
{
    if (x < 0) { x = 0; }
    if (x > INPUT_EVENT_ABS_MAX) { x = INPUT_EVENT_ABS_MAX; }
    if (y < 0) { y = 0; }
    if (y > INPUT_EVENT_ABS_MAX) { y = INPUT_EVENT_ABS_MAX; }
    aok_post(AOK_EV_POINTER, x, y);
}

void aok_ios_pointer_button(int button, int down)
{
    aok_post(AOK_EV_BUTTON, button, down ? 1 : 0);
}

long aok_ios_available_memory(void)
{
#ifdef __APPLE__
    size_t available = os_proc_available_memory();
    return available > 0 ? (long)available : 0;
#else
    return 0;
#endif
}

void aok_ios_display_size(int *width, int *height)
{
    if (width) { *width = S.width; }
    if (height) { *height = S.height; }
}
