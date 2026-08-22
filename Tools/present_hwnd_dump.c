/*
 * Dump Ubisoft Connect HWND client pixels via BitBlt (same wineserver).
 * If GDI has login bits but Cocoa doesn't, this file is non-flat and inject
 * can push them via setColorImage (present bridge).
 *
 *   x86_64-w64-mingw32-gcc -O2 -o Tools/bin/present_hwnd_dump.exe \
 *       Tools/present_hwnd_dump.c -lgdi32 -luser32
 *   wine64 present_hwnd_dump.exe [out.bgra]   # default C:\windows\temp\fly-login.bgra
 */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>
#include <string.h>

struct enum_ctx { HWND best; int best_area; };

static BOOL CALLBACK enum_proc(HWND hwnd, LPARAM lp)
{
    struct enum_ctx *ctx = (struct enum_ctx *)lp;
    char title[256];
    RECT rc;
    int area;
    if (!IsWindowVisible(hwnd)) return TRUE;
    GetWindowTextA(hwnd, title, sizeof(title));
    if (!strstr(title, "Ubisoft") && !strstr(title, "Connect")) return TRUE;
    GetClientRect(hwnd, &rc);
    area = rc.right * rc.bottom;
    if (area > ctx->best_area) {
        ctx->best_area = area;
        ctx->best = hwnd;
    }
    return TRUE;
}

int main(int argc, char **argv)
{
    struct enum_ctx ctx = {0};
    HWND hwnd;
    HDC hdc, mem;
    HBITMAP dib, old;
    BITMAPINFO bmi;
    void *bits;
    RECT rc;
    FILE *f;
    const char *path = argc > 1 ? argv[1] : "C:\\windows\\temp\\fly-login.bgra";
    int w, h, n;
    DWORD *p;
    unsigned nonzero = 0;
    unsigned i;

    EnumWindows(enum_proc, (LPARAM)&ctx);
    hwnd = ctx.best;
    if (!hwnd) {
        fprintf(stderr, "no hwnd\n");
        return 2;
    }
    GetClientRect(hwnd, &rc);
    w = rc.right;
    h = rc.bottom;
    printf("dump hwnd=%p client=%dx%d -> %s\n", (void *)hwnd, w, h, path);
    if (w < 8 || h < 8) return 3;

    ZeroMemory(&bmi, sizeof(bmi));
    bmi.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
    bmi.bmiHeader.biWidth = w;
    bmi.bmiHeader.biHeight = -h;
    bmi.bmiHeader.biPlanes = 1;
    bmi.bmiHeader.biBitCount = 32;
    bmi.bmiHeader.biCompression = BI_RGB;

    hdc = GetDC(hwnd);
    mem = CreateCompatibleDC(hdc);
    dib = CreateDIBSection(mem, &bmi, DIB_RGB_COLORS, &bits, NULL, 0);
    old = SelectObject(mem, dib);
    BitBlt(mem, 0, 0, w, h, hdc, 0, 0, SRCCOPY);
    GdiFlush();

    n = w * h;
    p = (DWORD *)bits;
    for (i = 0; i < (unsigned)n; i++) {
        if ((p[i] & 0x00FFFFFF) != 0) nonzero++;
    }
    printf("nonzero_rgb=%u / %d (%.1f%%)\n", nonzero, n, 100.0 * nonzero / n);

    f = fopen(path, "wb");
    if (!f) {
        fprintf(stderr, "open %s failed\n", path);
        return 4;
    }
    fwrite(&w, 4, 1, f);
    fwrite(&h, 4, 1, f);
    fwrite(bits, 4, n, f);
    fclose(f);

    SelectObject(mem, old);
    DeleteObject(dib);
    DeleteDC(mem);
    ReleaseDC(hwnd, hdc);
    return nonzero ? 0 : 5;
}
