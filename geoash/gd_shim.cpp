/*
 * GeometryRush on the Kobo: glue between raylib (software renderer, memory
 * platform: it has a framebuffer but NO input system) and the VNC server in
 * gd_vnc.c.
 *
 * The game is compiled unchanged. The linker option --wrap=<symbol> (see
 * scripts/03-geodash.sh) redirects the game's calls to raylib's window/input
 * functions into the __wrap_* functions below:
 *   - InitWindow:  starts the VNC server and works out the pixel layout of
 *                  raylib's read-back (flip / channel order) with a test image
 *   - EndDrawing:  finishes the frame, latches input, sends the picture
     - Is.../Get...: answer from the key/pointer state we receive over VNC
 *
 * Environment (set by lua/appdock_geodash.lua):
 *   GD_OUT_W     widest picture we may send; the game picture is shrunk by an
 *                integer factor (nearest neighbour) until it fits
 *   GD_FPS       frame-rate cap (default 30, the e-ink cannot show more anyway)
 *   GD_FRAME_MS  minimum time between two pictures sent (default 120)
 */
#include <pthread.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include "raylib.h"

#ifndef GD_VNC_PORT
#define GD_VNC_PORT 5963
#endif

extern "C" {
int gdv_start(int w, int h, int port);
void gdv_push(const uint32_t *src, int w, int h);
void __real_InitWindow(int width, int height, const char *title);
void __real_SetTargetFPS(int fps);
void __real_EndDrawing(void);
bool __real_WindowShouldClose(void);
}

namespace {

constexpr int NKEYS = 512;
constexpr int MB0 = 400; /* mouse buttons live at MB0 + button in the same arrays */

pthread_mutex_t g_mtx = PTHREAD_MUTEX_INITIALIZER;
bool g_down[NKEYS], g_press_pend[NKEYS], g_press_vis[NKEYS];
bool g_rel_pend[NKEYS], g_rel_vis[NKEYS], g_pend_up[NKEYS];
unsigned long g_down_frame[NKEYS];
unsigned long g_frame_no;
int g_keyq[64];
unsigned g_kq_w, g_kq_r;
float g_mx, g_my;

int g_scale = 1, g_out_w, g_out_h;
int g_bpp = 4;
bool g_flip_y, g_swap_rb;
uint32_t *g_outbuf;
uint32_t g_last_push_ms;
int g_min_frame_ms = 120;
int g_fps_cap = 30;
volatile sig_atomic_t g_quit;

uint32_t now_ms()
{
    timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint32_t)(ts.tv_sec * 1000u + ts.tv_nsec / 1000000u);
}

void on_term(int) { g_quit = 1; }

int map_key(unsigned long s)
{
    if (s >= 'a' && s <= 'z') return KEY_A + (int)(s - 'a');
    if (s >= 'A' && s <= 'Z') return KEY_A + (int)(s - 'A');
    if (s >= '0' && s <= '9') return KEY_ZERO + (int)(s - '0');
    switch (s) { /* X11 keysyms */
    case 0x20:   return KEY_SPACE;
    case 0xFF0D:
    case 0xFF8D: return KEY_ENTER;
    case 0xFF1B: return KEY_ESCAPE;
    case 0xFF09: return KEY_TAB;
    case 0xFF08: return KEY_BACKSPACE;
    case 0xFFFF: return KEY_DELETE;
    case 0xFF50: return KEY_HOME;
    case 0xFF57: return KEY_END;
    case 0xFF51: return KEY_LEFT;
    case 0xFF52: return KEY_UP;
    case 0xFF53: return KEY_RIGHT;
    case 0xFF54: return KEY_DOWN;
    case 0xFFE1:
    case 0xFFE2: return KEY_LEFT_SHIFT;
    case 0xFFE3:
    case 0xFFE4: return KEY_LEFT_CONTROL;
    default:     return 0;
    }
}

/* Every press stays visible to the game for at least one whole frame: a release
 * that arrives sooner is held back until two frames have ended since the press.
 * Without this a quick touch tap could fall between two (slow) frames. */
void set_down_locked(int idx, bool d)
{
    if (idx <= 0 || idx >= NKEYS) return;
    if (d) {
        g_pend_up[idx] = false;
        if (!g_down[idx]) {
            g_down[idx] = true;
            g_down_frame[idx] = g_frame_no;
            g_press_pend[idx] = true;
        }
    } else if (g_down[idx]) {
        if (g_frame_no >= g_down_frame[idx] + 2) {
            g_down[idx] = false;
            g_rel_pend[idx] = true;
        } else {
            g_pend_up[idx] = true;
        }
    }
}

void frame_end_input()
{
    pthread_mutex_lock(&g_mtx);
    g_frame_no++;
    for (int i = 0; i < NKEYS; i++) {
        g_press_vis[i] = g_press_pend[i]; g_press_pend[i] = false;
        g_rel_vis[i] = g_rel_pend[i];     g_rel_pend[i] = false;
        if (g_pend_up[i] && g_frame_no >= g_down_frame[i] + 2) {
            g_pend_up[i] = false;
            g_down[i] = false;
            g_rel_vis[i] = true;
        }
        if (g_press_vis[i] && i < MB0) {
            unsigned next = (g_kq_w + 1) % 64;
            if (next != g_kq_r) { g_keyq[g_kq_w] = i; g_kq_w = next; }
        }
    }
    pthread_mutex_unlock(&g_mtx);
}

bool get_flag(const bool *arr, int idx)
{
    if (idx < 0 || idx >= NKEYS) return false;
    pthread_mutex_lock(&g_mtx);
    bool v = arr[idx];
    pthread_mutex_unlock(&g_mtx);
    return v;
}

/* Which byte of a pixel is the strong one? 0/1/2, or -1 if it is not "pure" colour. */
int dominant(const uint8_t *p)
{
    int m = 0;
    for (int i = 1; i < 3; i++) if (p[i] > p[m]) m = i;
    if (p[m] < 200) return -1;
    for (int i = 0; i < 3; i++) if (i != m && p[i] > 80) return -1;
    return m;
}

/* raylib's software-renderer read-back may be upside down and BGR instead of RGB
 * (docs of the bindings say so, but I could not test it here). So draw a red
 * square in the top-left corner once and look at where/how it comes back. */
void calibrate(int w, int h)
{
    BeginDrawing();
    ClearBackground(Color{0, 0, 0, 255});
    DrawRectangle(0, 0, 16, 16, Color{255, 0, 0, 255});
    __real_EndDrawing();

    Image img = LoadImageFromScreen();
    if (!img.data) { fprintf(stderr, "gd: LoadImageFromScreen failed\n"); exit(1); }
    if (img.format == PIXELFORMAT_UNCOMPRESSED_R8G8B8A8) g_bpp = 4;
    else if (img.format == PIXELFORMAT_UNCOMPRESSED_R8G8B8) g_bpp = 3;
    else { fprintf(stderr, "gd: unsupported read-back format %d\n", (int)img.format); exit(1); }

    const uint8_t *px = (const uint8_t *)img.data;
    const size_t stride = (size_t)img.width * g_bpp;
    int top = dominant(px + 2 * g_bpp);                              /* inside the square, top row */
    int bot = dominant(px + (size_t)(img.height - 1 - 2) * stride + 2 * g_bpp); /* mirrored position */
    if (top >= 0) { g_flip_y = false; g_swap_rb = (top == 2); }
    else if (bot >= 0) { g_flip_y = true; g_swap_rb = (bot == 2); }
    else fprintf(stderr, "gd: calibration inconclusive, assuming upright RGB\n");
    fprintf(stderr, "gd: read-back %dx%d bpp=%d flipY=%d swapRB=%d\n",
            img.width, img.height, g_bpp, (int)g_flip_y, (int)g_swap_rb);
    UnloadImage(img);
    (void)w; (void)h;
}

void push_frame()
{
    uint32_t now = now_ms();
    if (now - g_last_push_ms < (uint32_t)g_min_frame_ms) return;
    g_last_push_ms = now;

    Image img = LoadImageFromScreen();
    if (!img.data) return;
    const uint8_t *px = (const uint8_t *)img.data;
    const int iw = img.width, ih = img.height;
    const size_t stride = (size_t)iw * g_bpp;
    for (int y = 0; y < g_out_h; y++) {
        int sy = y * g_scale;
        if (sy >= ih) sy = ih - 1;
        if (g_flip_y) sy = ih - 1 - sy;
        const uint8_t *row = px + (size_t)sy * stride;
        uint32_t *dst = g_outbuf + (size_t)y * g_out_w;
        for (int x = 0; x < g_out_w; x++) {
            int sx = x * g_scale;
            if (sx >= iw) sx = iw - 1;
            const uint8_t *p = row + (size_t)sx * g_bpp;
            uint32_t r = p[0], g = p[1], b = p[2];
            if (g_swap_rb) { uint32_t t = r; r = b; b = t; }
            dst[x] = (r << 16) | (g << 8) | b;
        }
    }
    UnloadImage(img);
    gdv_push(g_outbuf, g_out_w, g_out_h);
}

} // namespace

/* ------------------------------------------------- events from gd_vnc.c ---- */
extern "C" void gd_on_keysym(int down, unsigned long sym)
{
    int k = map_key(sym);
    if (!k) return;
    pthread_mutex_lock(&g_mtx);
    set_down_locked(k, down != 0);
    pthread_mutex_unlock(&g_mtx);
}

extern "C" void gd_on_pointer(int mask, int x, int y)
{
    pthread_mutex_lock(&g_mtx);
    g_mx = (float)(x * g_scale);
    g_my = (float)(y * g_scale);
    set_down_locked(MB0 + 0, (mask & 1) != 0);
    set_down_locked(MB0 + 1, (mask & 4) != 0);
    set_down_locked(MB0 + 2, (mask & 2) != 0);
    pthread_mutex_unlock(&g_mtx);
}

/* ------------------------------------------- wrapped raylib functions ---- */
extern "C" {

void __wrap_InitWindow(int width, int height, const char *title)
{
    signal(SIGTERM, on_term);
    signal(SIGINT, on_term);
    if (const char *e = getenv("GD_FPS")) { int v = atoi(e); if (v > 0) g_fps_cap = v; }
    if (const char *e = getenv("GD_FRAME_MS")) { int v = atoi(e); if (v > 0) g_min_frame_ms = v; }

    __real_InitWindow(width, height, title);
    const int gw = GetScreenWidth(), gh = GetScreenHeight();
    calibrate(gw, gh);

    int max_w = 0;
    if (const char *e = getenv("GD_OUT_W")) max_w = atoi(e);
    g_scale = 1;
    while (max_w > 0 && gw / g_scale > max_w) g_scale++;
    g_out_w = gw / g_scale;
    g_out_h = gh / g_scale;
    g_outbuf = (uint32_t *)calloc((size_t)g_out_w * g_out_h, 4);
    if (!g_outbuf || gdv_start(g_out_w, g_out_h, GD_VNC_PORT) != 0) exit(1);
    __real_SetTargetFPS(g_fps_cap);
}

void __wrap_SetTargetFPS(int fps)
{
    __real_SetTargetFPS((fps <= 0 || fps > g_fps_cap) ? g_fps_cap : fps);
}

void __wrap_EndDrawing(void)
{
    __real_EndDrawing();
    frame_end_input();
    push_frame();
}

bool __wrap_WindowShouldClose(void) { return g_quit || __real_WindowShouldClose(); }

bool __wrap_IsKeyPressed(int key)         { return get_flag(g_press_vis, key); }
bool __wrap_IsKeyPressedRepeat(int)       { return false; }
bool __wrap_IsKeyDown(int key)            { return get_flag(g_down, key); }
bool __wrap_IsKeyReleased(int key)        { return get_flag(g_rel_vis, key); }
bool __wrap_IsKeyUp(int key)              { return !get_flag(g_down, key); }
int  __wrap_GetCharPressed(void)          { return 0; }

int __wrap_GetKeyPressed(void)
{
    int k = 0;
    pthread_mutex_lock(&g_mtx);
    if (g_kq_r != g_kq_w) { k = g_keyq[g_kq_r]; g_kq_r = (g_kq_r + 1) % 64; }
    pthread_mutex_unlock(&g_mtx);
    return k;
}

bool __wrap_IsMouseButtonPressed(int b)   { return get_flag(g_press_vis, MB0 + b); }
bool __wrap_IsMouseButtonDown(int b)      { return get_flag(g_down, MB0 + b); }
bool __wrap_IsMouseButtonReleased(int b)  { return get_flag(g_rel_vis, MB0 + b); }
bool __wrap_IsMouseButtonUp(int b)        { return !get_flag(g_down, MB0 + b); }

int __wrap_GetMouseX(void)
{
    pthread_mutex_lock(&g_mtx); int v = (int)g_mx; pthread_mutex_unlock(&g_mtx); return v;
}
int __wrap_GetMouseY(void)
{
    pthread_mutex_lock(&g_mtx); int v = (int)g_my; pthread_mutex_unlock(&g_mtx); return v;
}
Vector2 __wrap_GetMousePosition(void)
{
    pthread_mutex_lock(&g_mtx); Vector2 v = { g_mx, g_my }; pthread_mutex_unlock(&g_mtx); return v;
}
Vector2 __wrap_GetMouseDelta(void)        { return Vector2{ 0.0f, 0.0f }; }
float   __wrap_GetMouseWheelMove(void)    { return 0.0f; }

} // extern "C"
