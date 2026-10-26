/*
 * VNC server half of the GeometryRush port (plain C, no raylib here).
 * Same idea as doom/doomgeneric_vnc.c: publish a 0x00RRGGBB frame buffer
 * through libvncserver on 127.0.0.1 ONLY (no password) and forward key and
 * pointer events to gd_shim.cpp.
 */
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <arpa/inet.h>
#include <netinet/in.h>
#include <rfb/rfb.h>

extern void gd_on_keysym(int down, unsigned long sym);
extern void gd_on_pointer(int mask, int x, int y);

static rfbScreenInfoPtr g_screen;
static uint32_t *g_shadow;
static int g_w, g_h;

static void on_key(rfbBool down, rfbKeySym sym, rfbClientPtr cl)
{
    (void)cl;
    gd_on_keysym(down ? 1 : 0, (unsigned long)sym);
}

static void on_ptr(int mask, int x, int y, rfbClientPtr cl)
{
    (void)cl;
    gd_on_pointer(mask, x, y);
}

int gdv_start(int w, int h, int port)
{
    int argc = 0;
    g_w = w; g_h = h;
    signal(SIGPIPE, SIG_IGN);

    g_shadow = calloc((size_t)w * h, 4);
    g_screen = rfbGetScreen(&argc, NULL, w, h, 8, 3, 4);
    if (!g_shadow || !g_screen) {
        fprintf(stderr, "gd-vnc: out of memory\n");
        return -1;
    }
    g_screen->frameBuffer = (char *)calloc((size_t)w * h, 4);
    g_screen->desktopName = "GeometryRush";
    g_screen->alwaysShared = TRUE;
    g_screen->kbdAddEvent = on_key;
    g_screen->ptrAddEvent = on_ptr;

    /* our buffer is native-endian 0x00RRGGBB */
    g_screen->serverFormat.redShift = 16;
    g_screen->serverFormat.greenShift = 8;
    g_screen->serverFormat.blueShift = 0;
    g_screen->serverFormat.redMax = g_screen->serverFormat.greenMax =
        g_screen->serverFormat.blueMax = 255;

    /* Security: no password, so listen on loopback ONLY. */
    g_screen->autoPort = FALSE;
    g_screen->port = port;
    g_screen->listenInterface = htonl(INADDR_LOOPBACK);

    rfbInitServer(g_screen);
    if (g_screen->listenSock == RFB_INVALID_SOCKET) {
        fprintf(stderr, "gd-vnc: cannot listen on 127.0.0.1:%d (is 'lo' up?)\n", port);
        return -1;
    }
    rfbRunEventLoop(g_screen, -1, TRUE); /* serve clients in a background thread */
    fprintf(stderr, "gd-vnc: %dx%d on 127.0.0.1:%d\n", w, h, port);
    return 0;
}

/* src: w*h pixels, 0x00RRGGBB, top row first. Only changed rows are sent. */
void gdv_push(const uint32_t *src, int w, int h)
{
    int y0 = -1, y1 = -1;
    if (!g_screen || w != g_w || h != g_h) return;
    for (int y = 0; y < h; y++) {
        if (memcmp(src + (size_t)y * w, g_shadow + (size_t)y * w, (size_t)w * 4) != 0) {
            if (y0 < 0) y0 = y;
            y1 = y;
        }
    }
    if (y0 < 0) return;
    size_t off = (size_t)y0 * w, n = (size_t)(y1 - y0 + 1) * w;
    memcpy(g_shadow + off, src + off, n * 4);
    memcpy(g_screen->frameBuffer + off * 4, src + off, n * 4);
    rfbMarkRectAsModified(g_screen, 0, y0, w, y1 + 1);
}
