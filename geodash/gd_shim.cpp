/*
 * TIC-80 on the Kobo: a tiny libretro front-end.
 *
 * The TIC-80 libretro core (tic80_libretro.so, built by scripts/03-geodash.sh) does all the
 * work: it runs the cart and hands us a finished picture through the libretro video callback.
 * This file
 *   - loads the core (dlopen, or linked in statically when the build only produced a .a),
 *   - answers the core's environment requests (pixel format, directories, options, ...),
 *   - turns the picture into 0x00RRGGBB, enlarges it by an integer factor and gives it to the
 *     VNC server in gd_vnc.c (127.0.0.1 only),
 *   - turns key / pointer events that arrive over VNC into libretro input
 *     (joypad, keyboard, mouse and touch pointer, so it does not matter which one the core reads).
 *
 * Environment (set by lua/appdock_geodash.lua, all optional):
 *   TIC_CART        path of the .tic cart to run (or give it as argv[1])
 *   GD_CORE         path of the core .so (default: <dir of this binary>/../lib/tic80_libretro.so)
 *   GD_OUT_W/H      largest picture we may send; the core picture is enlarged by the biggest
 *                   integer factor that still fits (default 960x960)
 *   GD_SCALE        force the enlargement factor
 *   GD_HZ           logic ticks per second (default: what the core reports, normally 60). The
 *                   core is run at this rate so the game keeps its speed ...
 *   GD_FRAME_MS     ... but a picture is only sent every GD_FRAME_MS ms (default 100): the e-ink
 *                   cannot show more, and the diff + VNC work is what costs time.
 *   GD_TOUCH        "1" (default) = tell the core to use its touch-pointer mouse, "0" = relative mouse
 *   GD_SWAP_RB      "1" = swap red and blue (if the core's colour order turns out to be BGR)
 *
 * Every press stays visible to the core for at least one whole tick, so a very quick tap
 * cannot fall between two polls.
 */
#include <dlfcn.h>
#include <limits.h>
#include <pthread.h>
#include <signal.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#ifndef GD_VNC_PORT
#define GD_VNC_PORT 5963
#endif

extern "C" {
int gdv_start(int w, int h, int port);
void gdv_push(const uint32_t *src, int w, int h);
void gd_on_keysym(int down, unsigned long sym);
void gd_on_pointer(int mask, int x, int y);
}

/* ------------------------------------------------------------------------------------------
 * The small part of libretro.h we need (values are part of the stable libretro ABI).
 * ---------------------------------------------------------------------------------------- */
namespace {

struct retro_game_info { const char *path; const void *data; size_t size; const char *meta; };
struct retro_system_info {
    const char *library_name; const char *library_version; const char *valid_extensions;
    bool need_fullpath; bool block_extract;
};
struct retro_game_geometry { unsigned base_width, base_height, max_width, max_height; float aspect_ratio; };
struct retro_system_timing { double fps; double sample_rate; };
struct retro_system_av_info { retro_game_geometry geometry; retro_system_timing timing; };
struct retro_variable { const char *key; const char *value; };
typedef void (*retro_keyboard_event_t)(bool down, unsigned keycode, uint32_t character, uint16_t key_modifiers);
struct retro_keyboard_callback { retro_keyboard_event_t callback; };
typedef void (*retro_log_printf_t)(int level, const char *fmt, ...);
struct retro_log_callback { retro_log_printf_t log; };

typedef bool (*retro_environment_t)(unsigned cmd, void *data);
typedef void (*retro_video_refresh_t)(const void *data, unsigned width, unsigned height, size_t pitch);
typedef void (*retro_audio_sample_t)(int16_t left, int16_t right);
typedef size_t (*retro_audio_sample_batch_t)(const int16_t *data, size_t frames);
typedef void (*retro_input_poll_t)(void);
typedef int16_t (*retro_input_state_t)(unsigned port, unsigned device, unsigned index, unsigned id);

enum { DEV_JOYPAD = 1, DEV_MOUSE = 2, DEV_KEYBOARD = 3, DEV_POINTER = 6 };
enum { J_B = 0, J_Y = 1, J_SELECT = 2, J_START = 3, J_UP = 4, J_DOWN = 5, J_LEFT = 6, J_RIGHT = 7,
       J_A = 8, J_X = 9, J_L = 10, J_R = 11 };
enum { FMT_0RGB1555 = 0, FMT_XRGB8888 = 1, FMT_RGB565 = 2 };

/* libretro key codes (RETROK_*) */
enum {
    RK_BACKSPACE = 8, RK_TAB = 9, RK_RETURN = 13, RK_ESCAPE = 27, RK_SPACE = 32, RK_DELETE = 127,
    RK_UP = 273, RK_DOWN = 274, RK_RIGHT = 275, RK_LEFT = 276, RK_HOME = 278, RK_END = 279,
    RK_RSHIFT = 303, RK_LSHIFT = 304, RK_RCTRL = 305, RK_LCTRL = 306,
    NKEYS = 512
};

struct Core {
    void (*set_environment)(retro_environment_t);
    void (*set_video_refresh)(retro_video_refresh_t);
    void (*set_audio_sample)(retro_audio_sample_t);
    void (*set_audio_sample_batch)(retro_audio_sample_batch_t);
    void (*set_input_poll)(retro_input_poll_t);
    void (*set_input_state)(retro_input_state_t);
    void (*init)(void);
    void (*deinit)(void);
    unsigned (*api_version)(void);
    void (*get_system_info)(retro_system_info *);
    void (*get_system_av_info)(retro_system_av_info *);
    bool (*load_game)(const retro_game_info *);
    void (*unload_game)(void);
    void (*run)(void);
} C;

#ifdef GD_STATIC_CORE
} /* namespace */
extern "C" {
void retro_set_environment(retro_environment_t);
void retro_set_video_refresh(retro_video_refresh_t);
void retro_set_audio_sample(retro_audio_sample_t);
void retro_set_audio_sample_batch(retro_audio_sample_batch_t);
void retro_set_input_poll(retro_input_poll_t);
void retro_set_input_state(retro_input_state_t);
void retro_init(void);
void retro_deinit(void);
unsigned retro_api_version(void);
void retro_get_system_info(retro_system_info *);
void retro_get_system_av_info(retro_system_av_info *);
bool retro_load_game(const retro_game_info *);
void retro_unload_game(void);
void retro_run(void);
}
namespace {
bool load_core(const char *) {
    C.set_environment = retro_set_environment;       C.set_video_refresh = retro_set_video_refresh;
    C.set_audio_sample = retro_set_audio_sample;     C.set_audio_sample_batch = retro_set_audio_sample_batch;
    C.set_input_poll = retro_set_input_poll;         C.set_input_state = retro_set_input_state;
    C.init = retro_init;                             C.deinit = retro_deinit;
    C.api_version = retro_api_version;               C.get_system_info = retro_get_system_info;
    C.get_system_av_info = retro_get_system_av_info; C.load_game = retro_load_game;
    C.unload_game = retro_unload_game;               C.run = retro_run;
    return true;
}
#else
bool load_core(const char *path) {
    void *h = dlopen(path, RTLD_NOW | RTLD_LOCAL);
    if (!h) { fprintf(stderr, "gd: cannot load core %s: %s\n", path, dlerror()); return false; }
#define SYM(field, name) do { *(void **)&C.field = dlsym(h, name); \
    if (!C.field) { fprintf(stderr, "gd: core lacks %s\n", name); return false; } } while (0)
    SYM(set_environment, "retro_set_environment");
    SYM(set_video_refresh, "retro_set_video_refresh");
    SYM(set_audio_sample, "retro_set_audio_sample");
    SYM(set_audio_sample_batch, "retro_set_audio_sample_batch");
    SYM(set_input_poll, "retro_set_input_poll");
    SYM(set_input_state, "retro_set_input_state");
    SYM(init, "retro_init");
    SYM(deinit, "retro_deinit");
    SYM(api_version, "retro_api_version");
    SYM(get_system_info, "retro_get_system_info");
    SYM(get_system_av_info, "retro_get_system_av_info");
    SYM(load_game, "retro_load_game");
    SYM(unload_game, "retro_unload_game");
    SYM(run, "retro_run");
#undef SYM
    return true;
}
#endif

/* ------------------------------------------------------------------------------------------
 * state
 * ---------------------------------------------------------------------------------------- */
pthread_mutex_t g_mtx = PTHREAD_MUTEX_INITIALIZER;

/* written by the VNC thread (under g_mtx) */
bool r_key[NKEYS], r_pend[NKEYS];
bool r_ptr_down, r_ptr_pend;
int r_ptr_mask, r_ptr_x, r_ptr_y;

/* snapshot taken once per tick in poll_cb (main thread only) */
bool s_key[NKEYS], s_prev[NKEYS];
int16_t s_joy[16];
bool s_ptr_pressed;
int s_btn_left, s_btn_right, s_btn_mid;
float s_px, s_py;            /* pointer position in core picture pixels */
int s_mdx, s_mdy;            /* relative mouse movement since last poll */
float s_last_px = -1, s_last_py = -1;
int g_mk = 200;              /* GD_MK: relative mouse gain in percent */

retro_keyboard_event_t g_kbcb;
volatile sig_atomic_t g_quit;
int g_fmt = FMT_0RGB1555;    /* libretro default until the core says otherwise */
const char *g_dir = ".";
char g_core_path[PATH_MAX];
bool g_touch = true, g_swap_rb;

/* video */
bool g_vnc_up;
int g_scale = 1, g_ow, g_oh, g_ox, g_oy;
unsigned g_w0, g_h0;
uint32_t *g_out, *g_row;
size_t g_row_cap;
unsigned g_min_frame_ms = 100;
uint32_t g_last_push_ms;
unsigned long g_pushes, g_ticks;

uint32_t now_ms() {
    timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint32_t)(ts.tv_sec * 1000u + ts.tv_nsec / 1000000u);
}
double now_us() {
    timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec * 1e6 + (double)ts.tv_nsec / 1e3;
}
void on_term(int) { g_quit = 1; }

int env_int(const char *name, int def) {
    const char *v = getenv(name);
    return (v && *v) ? atoi(v) : def;
}

/* X11 keysym (what the VNC side sends) -> libretro key code, 0 = unknown */
int keysym_to_retrok(unsigned long s) {
    if (s >= 'a' && s <= 'z') return (int)s;
    if (s >= 'A' && s <= 'Z') return (int)(s - 'A' + 'a');
    if (s >= '0' && s <= '9') return (int)s;
    switch (s) {
    case 0x20:   return RK_SPACE;
    case 0xFF0D:
    case 0xFF8D: return RK_RETURN;
    case 0xFF1B: return RK_ESCAPE;
    case 0xFF09: return RK_TAB;
    case 0xFF08: return RK_BACKSPACE;
    case 0xFFFF: return RK_DELETE;
    case 0xFF50: return RK_HOME;
    case 0xFF57: return RK_END;
    case 0xFF51: return RK_LEFT;
    case 0xFF52: return RK_UP;
    case 0xFF53: return RK_RIGHT;
    case 0xFF54: return RK_DOWN;
    case 0xFFE1: return RK_LSHIFT;
    case 0xFFE2: return RK_RSHIFT;
    case 0xFFE3: return RK_LCTRL;
    case 0xFFE4: return RK_RCTRL;
    default:     return 0;
    }
}

/* key -> joypad button. TIC-80's own keyboard defaults: Z=A, X=B, A=X, S=Y. */
struct JoyMap { int key; int joy; };
const JoyMap JOYMAP[] = {
    { RK_UP, J_UP }, { RK_DOWN, J_DOWN }, { RK_LEFT, J_LEFT }, { RK_RIGHT, J_RIGHT },
    { 'z', J_A }, { 'x', J_B }, { 'a', J_X }, { 's', J_Y },
    { RK_RETURN, J_START }, { RK_ESCAPE, J_SELECT },
};

/* ------------------------------------------------------------------------------------------
 * libretro callbacks
 * ---------------------------------------------------------------------------------------- */
void log_cb(int level, const char *fmt, ...) {
    if (level < 1) return; /* skip DEBUG */
    va_list ap; va_start(ap, fmt);
    fputs("core: ", stderr); vfprintf(stderr, fmt, ap);
    va_end(ap);
}

const char *variable_value(const char *key) {
    if (!strcmp(key, "tic80_mouse")) return g_touch ? "enabled" : "disabled";
    if (!strcmp(key, "tic80_mouse_cursor")) return "arrow";
    if (!strcmp(key, "tic80_mouse_hide_delay")) return "disabled";
    return nullptr;
}

bool env_cb(unsigned cmd, void *data) {
    switch (cmd & 0xFFFF) { /* strip the EXPERIMENTAL / PRIVATE flags */
    case 3:  if (data) *(bool *)data = true; return true;                       /* GET_CAN_DUPE */
    case 6:  case 60: return true;                                              /* SET_MESSAGE(_EXT) */
    case 7:  g_quit = 1; return true;                                           /* SHUTDOWN */
    case 8:  return true;                                                       /* SET_PERFORMANCE_LEVEL */
    case 9:  case 30: case 31: if (data) *(const char **)data = g_dir; return true; /* system/assets/save dir */
    case 10: {                                                                  /* SET_PIXEL_FORMAT */
        int f = *(int *)data;
        if (f == FMT_0RGB1555 || f == FMT_XRGB8888 || f == FMT_RGB565) { g_fmt = f; return true; }
        return false;
    }
    case 11: return true;                                                       /* SET_INPUT_DESCRIPTORS */
    case 12: if (data) g_kbcb = ((retro_keyboard_callback *)data)->callback; return true; /* SET_KEYBOARD_CALLBACK */
    case 15: {                                                                  /* GET_VARIABLE */
        retro_variable *v = (retro_variable *)data;
        v->value = v->key ? variable_value(v->key) : nullptr;
        return v->value != nullptr;
    }
    case 16: return true;                                                       /* SET_VARIABLES */
    case 17: if (data) *(bool *)data = false; return true;                      /* GET_VARIABLE_UPDATE */
    case 18: return true;                                                       /* SET_SUPPORT_NO_GAME */
    case 19: if (data) *(const char **)data = g_core_path; return true;         /* GET_LIBRETRO_PATH */
    case 24: if (data) *(uint64_t *)data = (1u << DEV_JOYPAD) | (1u << DEV_MOUSE) | (1u << DEV_KEYBOARD) | (1u << DEV_POINTER);
             return true;                                                       /* GET_INPUT_DEVICE_CAPABILITIES */
    case 27: if (data) ((retro_log_callback *)data)->log = log_cb; return true; /* GET_LOG_INTERFACE */
    case 32: case 37: return true;                                              /* SET_SYSTEM_AV_INFO / SET_GEOMETRY */
    case 35: return true;                                                       /* SET_CONTROLLER_INFO */
    case 39: if (data) *(unsigned *)data = 0; return true;                      /* GET_LANGUAGE: English */
    case 44: return true;                                                       /* SET_SERIALIZATION_QUIRKS */
    case 52: if (data) *(unsigned *)data = 0; return true;                      /* GET_CORE_OPTIONS_VERSION: v0 */
    default: return false;
    }
}

void audio_sample_cb(int16_t, int16_t) {}
size_t audio_batch_cb(const int16_t *, size_t frames) { return frames; } /* no sound on the e-reader */

void poll_cb() {
    pthread_mutex_lock(&g_mtx);
    for (int i = 0; i < NKEYS; i++) { s_key[i] = r_key[i] || r_pend[i]; r_pend[i] = false; }
    s_ptr_pressed = r_ptr_down || r_ptr_pend;
    r_ptr_pend = false;
    int mask = r_ptr_mask, rx = r_ptr_x, ry = r_ptr_y;
    pthread_mutex_unlock(&g_mtx);

    memset(s_joy, 0, sizeof s_joy);
    for (const JoyMap &m : JOYMAP) if (s_key[m.key]) s_joy[m.joy] = 1;

    /* pointer position in core picture pixels */
    if (g_scale > 0 && g_w0) {
        float px = (float)(rx - g_ox) / g_scale, py = (float)(ry - g_oy) / g_scale;
        if (px < 0) px = 0; if (px > g_w0 - 1) px = (float)g_w0 - 1;
        if (py < 0) py = 0; if (py > g_h0 - 1) py = (float)g_h0 - 1;
        /* relative-mouse mode: the core moves its cursor only 100/g_mk of what we send -> compensate */
        float k = g_mk / 100.0f, qx = px * k, qy = py * k;
        if (s_last_px < 0) { s_last_px = qx; s_last_py = qy; }
        s_mdx = (int)(qx - s_last_px); s_mdy = (int)(qy - s_last_py);
        s_last_px += s_mdx; s_last_py += s_mdy;
        s_px = px; s_py = py;
    }
    s_btn_left = s_ptr_pressed ? 1 : 0;
    s_btn_mid = (mask & 2) ? 1 : 0;
    s_btn_right = (mask & 4) ? 1 : 0;

    if (g_kbcb) {
        for (int i = 1; i < NKEYS; i++) {
            if (s_key[i] != s_prev[i]) {
                s_prev[i] = s_key[i];
                g_kbcb(s_key[i], (unsigned)i, (i >= 32 && i < 127) ? (uint32_t)i : 0, 0);
            }
        }
    } else {
        memcpy(s_prev, s_key, sizeof s_prev);
    }
}

int16_t input_state_cb(unsigned port, unsigned device, unsigned index, unsigned id) {
    if (port != 0) return 0;
    switch (device & 0xFF) {
    case DEV_JOYPAD:
        if (id == 256) { /* RETRO_DEVICE_ID_JOYPAD_MASK */
            int16_t m = 0;
            for (int i = 0; i < 16; i++) if (s_joy[i]) m |= (int16_t)(1 << i);
            return m;
        }
        return id < 16 ? s_joy[id] : 0;
    case DEV_MOUSE:
        switch (id) {
        case 0: return (int16_t)s_mdx;
        case 1: return (int16_t)s_mdy;
        case 2: return (int16_t)s_btn_left;
        case 3: return (int16_t)s_btn_right;
        case 6: return (int16_t)s_btn_mid;
        default: return 0;
        }
    case DEV_KEYBOARD:
        return id < NKEYS ? s_key[id] : 0;
    case DEV_POINTER:
        if (index != 0 || !g_w0) return 0;
        switch (id) {
        case 0: return (int16_t)((s_px + 0.5f) / g_w0 * 65534.0f - 32767.0f);
        case 1: return (int16_t)((s_py + 0.5f) / g_h0 * 65534.0f - 32767.0f);
        case 2: return (int16_t)s_btn_left;
        case 3: return 1;
        default: return 0;
        }
    default:
        return 0;
    }
}

/* ------------------------------------------------------------------------------------------
 * video: core picture -> 0x00RRGGBB, integer enlargement, VNC
 * ---------------------------------------------------------------------------------------- */
inline uint32_t conv_pixel(const uint8_t *p) {
    uint32_t r, g, b;
    switch (g_fmt) {
    case FMT_XRGB8888: {
        uint32_t v = *(const uint32_t *)p;
        r = (v >> 16) & 255; g = (v >> 8) & 255; b = v & 255;
        break;
    }
    case FMT_RGB565: {
        uint32_t v = *(const uint16_t *)p;
        r = (v >> 11) & 31; g = (v >> 5) & 63; b = v & 31;
        r = (r << 3) | (r >> 2); g = (g << 2) | (g >> 4); b = (b << 3) | (b >> 2);
        break;
    }
    default: { /* 0RGB1555 */
        uint32_t v = *(const uint16_t *)p;
        r = (v >> 10) & 31; g = (v >> 5) & 31; b = v & 31;
        r = (r << 3) | (r >> 2); g = (g << 3) | (g >> 2); b = (b << 3) | (b >> 2);
        break;
    }
    }
    return g_swap_rb ? ((b << 16) | (g << 8) | r) : ((r << 16) | (g << 8) | b);
}

bool start_video(unsigned w, unsigned h) {
    int out_w = env_int("GD_OUT_W", 960), out_h = env_int("GD_OUT_H", 960);
    int s = env_int("GD_SCALE", 0);
    if (s <= 0) {
        int sx = out_w / (int)w, sy = out_h / (int)h;
        s = sx < sy ? sx : sy;
    }
    if (s < 1) s = 1;
    g_scale = s; g_ow = (int)w * s; g_oh = (int)h * s; g_w0 = w; g_h0 = h;
    g_ox = g_oy = 0;
    g_out = (uint32_t *)calloc((size_t)g_ow * g_oh, 4);
    if (!g_out) return false;
    if (gdv_start(g_ow, g_oh, GD_VNC_PORT) != 0) return false;
    fprintf(stderr, "gd: core picture %ux%u (format %d), sent as %dx%d (x%d)\n", w, h, g_fmt, g_ow, g_oh, s);
    g_vnc_up = true;
    return true;
}

void video_cb(const void *data, unsigned w, unsigned h, size_t pitch) {
    if (!data || !w || !h) return; /* duplicated frame */
    uint32_t t = now_ms();
    if (!g_vnc_up) {
        if (!start_video(w, h)) { g_quit = 1; return; }
    } else if (t - g_last_push_ms < g_min_frame_ms) {
        return;
    }
    g_last_push_ms = t;

    const int s = g_scale;
    const int dw = (int)w * s, dh = (int)h * s;
    const int ox = (g_ow - dw) / 2, oy = (g_oh - dh) / 2; /* only differs if the picture size changes */
    if (w != g_w0 || h != g_h0) memset(g_out, 0, (size_t)g_ow * g_oh * 4);
    if (g_row_cap < (size_t)dw) {
        free(g_row);
        g_row = (uint32_t *)malloc((size_t)dw * 4);
        g_row_cap = g_row ? (size_t)dw : 0;
        if (!g_row) { g_quit = 1; return; }
    }
    const size_t bpp = (g_fmt == FMT_XRGB8888) ? 4 : 2;
    const int x_from = ox < 0 ? -ox : 0;
    const int x_to = (ox + dw > g_ow) ? (g_ow - ox) : dw;
    for (unsigned y = 0; y < h; y++) {
        const int dy0 = oy + (int)y * s;
        if (dy0 >= g_oh || dy0 + s <= 0) continue;
        const uint8_t *src = (const uint8_t *)data + y * pitch;
        for (unsigned x = 0; x < w; x++) {
            uint32_t px = conv_pixel(src + x * bpp);
            for (int k = 0; k < s; k++) g_row[x * s + k] = px;
        }
        if (x_to <= x_from) continue;
        for (int k = 0; k < s; k++) {
            int dy = dy0 + k;
            if (dy < 0 || dy >= g_oh) continue;
            memcpy(g_out + (size_t)dy * g_ow + ox + x_from, g_row + x_from, (size_t)(x_to - x_from) * 4);
        }
    }
    gdv_push(g_out, g_ow, g_oh);
    g_pushes++;
}

} /* namespace */

/* ------------------------------------------------------------------------------------------
 * input from the VNC thread
 * ---------------------------------------------------------------------------------------- */
extern "C" void gd_on_keysym(int down, unsigned long sym) {
    int c = keysym_to_retrok(sym);
    if (c <= 0 || c >= NKEYS) return;
    pthread_mutex_lock(&g_mtx);
    if (down) { if (!r_key[c]) r_pend[c] = true; r_key[c] = true; }
    else r_key[c] = false;
    pthread_mutex_unlock(&g_mtx);
}

extern "C" void gd_on_pointer(int mask, int x, int y) {
    pthread_mutex_lock(&g_mtx);
    bool d = (mask & 1) != 0;
    if (d && !r_ptr_down) r_ptr_pend = true;
    r_ptr_down = d;
    r_ptr_mask = mask; r_ptr_x = x; r_ptr_y = y;
    pthread_mutex_unlock(&g_mtx);
}

/* ------------------------------------------------------------------------------------------
 * main
 * ---------------------------------------------------------------------------------------- */
static void *read_file(const char *path, size_t *size) {
    FILE *f = fopen(path, "rb");
    if (!f) return nullptr;
    fseek(f, 0, SEEK_END);
    long n = ftell(f);
    fseek(f, 0, SEEK_SET);
    if (n < 0) { fclose(f); return nullptr; }
    void *buf = malloc((size_t)n ? (size_t)n : 1);
    if (!buf || fread(buf, 1, (size_t)n, f) != (size_t)n) { fclose(f); free(buf); return nullptr; }
    fclose(f);
    *size = (size_t)n;
    return buf;
}

int main(int argc, char **argv) {
    const char *cart = argc > 1 ? argv[1] : getenv("TIC_CART");
    if (!cart || !*cart) {
        fprintf(stderr, "gd: no cart given (argument or TIC_CART)\n");
        return 2;
    }
    g_touch = env_int("GD_TOUCH", 1) != 0;
    g_mk = env_int("GD_MK", 200);
    g_swap_rb = env_int("GD_SWAP_RB", 0) != 0;
    g_min_frame_ms = (unsigned)env_int("GD_FRAME_MS", 100);

    signal(SIGTERM, on_term);
    signal(SIGINT, on_term);
    signal(SIGPIPE, SIG_IGN);

    /* where is the core? */
    const char *envcore = getenv("GD_CORE");
    if (envcore && *envcore) {
        snprintf(g_core_path, sizeof g_core_path, "%s", envcore);
    } else {
        char exe[PATH_MAX];
        ssize_t n = readlink("/proc/self/exe", exe, sizeof exe - 1);
        if (n <= 0) { fprintf(stderr, "gd: cannot find own path, set GD_CORE\n"); return 2; }
        exe[n] = 0;
        char *slash = strrchr(exe, '/');
        if (slash) *slash = 0;
        snprintf(g_core_path, sizeof g_core_path, "%s/../lib/tic80_libretro.so", exe);
    }
    if (!load_core(g_core_path)) return 2;
    fprintf(stderr, "gd: libretro API %u, core %s\n", C.api_version(), g_core_path);

    C.set_environment(env_cb);
    C.set_video_refresh(video_cb);
    C.set_audio_sample(audio_sample_cb);
    C.set_audio_sample_batch(audio_batch_cb);
    C.set_input_poll(poll_cb);
    C.set_input_state(input_state_cb);
    C.init();

    size_t size = 0;
    void *data = read_file(cart, &size);
    if (!data) { fprintf(stderr, "gd: cannot read cart %s\n", cart); return 3; }
    retro_system_info si; memset(&si, 0, sizeof si);
    C.get_system_info(&si);
    fprintf(stderr, "gd: %s %s, loading %s (%zu bytes)\n",
            si.library_name ? si.library_name : "?", si.library_version ? si.library_version : "?", cart, size);
    retro_game_info gi = { cart, data, size, nullptr };
    if (!C.load_game(&gi)) { fprintf(stderr, "gd: the core refused the cart %s\n", cart); return 3; }

    retro_system_av_info av; memset(&av, 0, sizeof av);
    C.get_system_av_info(&av);
    double hz = (double)env_int("GD_HZ", 0);
    if (hz <= 0) hz = av.timing.fps > 1.0 ? av.timing.fps : 60.0;
    fprintf(stderr, "gd: geometry %ux%u, %.1f ticks/s, a picture every >= %u ms\n",
            av.geometry.base_width, av.geometry.base_height, hz, g_min_frame_ms);

    const double tick_us = 1e6 / hz;
    double next = now_us();
    double stat_t0 = next;
    while (!g_quit) {
        C.run();
        g_ticks++;
        next += tick_us;
        double now = now_us();
        if (next > now) usleep((useconds_t)(next - now));
        else if (now - next > 250000.0) next = now; /* far behind: do not try to catch up */
        if (now - stat_t0 >= 5e6) {
            fprintf(stderr, "gd-stat: %.1f ticks/s, %.1f pictures/s\n",
                    g_ticks * 1e6 / (now - stat_t0), g_pushes * 1e6 / (now - stat_t0));
            g_ticks = g_pushes = 0; stat_t0 = now;
        }
    }
    C.unload_game();
    C.deinit();
    fprintf(stderr, "gd: bye\n");
    return 0;
}
