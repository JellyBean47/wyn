/*
 * Inspect Connect HWND GDI state after login (WS_EX_LAYERED, DC bitmap size, etc.)
 *   x86_64-w64-mingw32-gcc -O2 -o Tools/bin/present_hwnd_inspect.exe \
 *       Tools/present_hwnd_inspect.c -lgdi32 -luser32
 */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>
#include <string.h>

struct enum_ctx { HWND best; int best_area; char title[256]; };

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
        strncpy(ctx->title, title, 255);
    }
    return TRUE;
}

static void describe_dc(const char *tag, HDC hdc, HWND expect_hwnd)
{
    HWND from;
    HBITMAP bm;
    BITMAP b;
    int objtype;
    if (!hdc) {
        printf("%s: hdc=NULL\n", tag);
        return;
    }
    from = WindowFromDC(hdc);
    bm = (HBITMAP)GetCurrentObject(hdc, OBJ_BITMAP);
    objtype = GetObjectType(hdc);
    printf("%s: hdc=%p WindowFromDC=%p expect=%p type=%d",
           tag, (void *)hdc, (void *)from, (void *)expect_hwnd, objtype);
    if (bm && GetObjectW(bm, sizeof(b), &b))
        printf(" bitmap=%dx%d bpp=%d", b.bmWidth, b.bmHeight, b.bmBitsPixel);
    else
        printf(" bitmap=none/fail");
    printf("\n");
}

int main(void)
{
    struct enum_ctx ctx = {0};
    HWND hwnd;
    HDC hdc, wdc, mem;
    HBITMAP dib, old;
    BITMAPINFO bmi;
    void *bits;
    RECT rc, wr;
    LONG style, ex;
    DWORD *p;
    int w, h, i, n, nonzero = 0;

    EnumWindows(enum_proc, (LPARAM)&ctx);
    hwnd = ctx.best;
    if (!hwnd) {
        fprintf(stderr, "no hwnd\n");
        return 2;
    }
    GetClientRect(hwnd, &rc);
    GetWindowRect(hwnd, &wr);
    style = GetWindowLongW(hwnd, GWL_STYLE);
    ex = GetWindowLongW(hwnd, GWL_EXSTYLE);
    printf("hwnd=%p '%s'\n", (void *)hwnd, ctx.title);
    printf("client=%dx%d window=%dx%d style=0x%08lx ex=0x%08lx%s%s\n",
           rc.right, rc.bottom,
           wr.right - wr.left, wr.bottom - wr.top,
           (unsigned long)style, (unsigned long)ex,
           (ex & WS_EX_LAYERED) ? " WS_EX_LAYERED" : "",
           (ex & WS_EX_TRANSPARENT) ? " WS_EX_TRANSPARENT" : "");

    hdc = GetDC(hwnd);
    describe_dc("GetDC", hdc, hwnd);
    wdc = GetWindowDC(hwnd);
    describe_dc("GetWindowDC", wdc, hwnd);

    w = rc.right;
    h = rc.bottom;
    if (w > 0 && h > 0 && hdc) {
        ZeroMemory(&bmi, sizeof(bmi));
        bmi.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
        bmi.bmiHeader.biWidth = w;
        bmi.bmiHeader.biHeight = -h;
        bmi.bmiHeader.biPlanes = 1;
        bmi.bmiHeader.biBitCount = 32;
        bmi.bmiHeader.biCompression = BI_RGB;
        mem = CreateCompatibleDC(hdc);
        dib = CreateDIBSection(mem, &bmi, DIB_RGB_COLORS, &bits, NULL, 0);
        old = SelectObject(mem, dib);
        BitBlt(mem, 0, 0, w, h, hdc, 0, 0, SRCCOPY);
        GdiFlush();
        p = (DWORD *)bits;
        n = w * h;
        for (i = 0; i < n; i++)
            if (p[i] & 0x00FFFFFF) nonzero++;
        printf("BitBlt(GetDC) nonzero_rgb=%d/%d (%.2f%%) center=%08lx\n",
               nonzero, n, 100.0 * nonzero / n,
               n ? (unsigned long)p[(h / 2) * w + (w / 2)] : 0);
        SelectObject(mem, old);
        DeleteObject(dib);
        DeleteDC(mem);
    }

    if (hdc) ReleaseDC(hwnd, hdc);
    if (wdc) ReleaseDC(hwnd, wdc);
    return 0;
}
