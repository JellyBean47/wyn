/*
 * Stupid-simple present probe: ONE opaque HWND at Connect login client size.
 * No Ubisoft, no CEF, no Steam — only frankea Wine → macdrv → Cocoa.
 *
 * Build:
 *   x86_64-w64-mingw32-gcc -O2 -o Tools/bin/present_login_size_probe.exe \
 *       Tools/present_login_size_probe.c -lgdi32 -luser32
 *
 * Modes (argv[1]):
 *   0 = opaque GDI FillRect (default) — login-like layered=0 path
 *   1 = UpdateLayeredWindow solid magenta — splash-like layered path
 *   2 = StretchBlt from DIB into client DC (CEF-ish blit)
 *
 * Optional argv[2]=width argv[3]=height (default 1454x934).
 * Stays up argv[4] seconds (default 20) then exits.
 */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>

static int g_mode;
static int g_w = 1454;
static int g_h = 934;

static void paint_gdi(HWND hwnd)
{
    HDC hdc = GetDC(hwnd);
    RECT rc;
    HBRUSH br;
    GetClientRect(hwnd, &rc);
    br = CreateSolidBrush(RGB(255, 0, 128));
    FillRect(hdc, &rc, br);
    DeleteObject(br);
    SelectObject(hdc, GetStockObject(WHITE_PEN));
    SelectObject(hdc, GetStockObject(NULL_BRUSH));
    Rectangle(hdc, 8, 8, rc.right - 8, rc.bottom - 8);
    GdiFlush();
    ReleaseDC(hwnd, hdc);
}

static void paint_stretch(HWND hwnd)
{
    HDC hdc, mem;
    BITMAPINFO bmi;
    void *bits;
    HBITMAP dib, old;
    RECT rc;
    int w, h, i, n;
    DWORD *p;

    GetClientRect(hwnd, &rc);
    w = rc.right;
    h = rc.bottom;
    if (w < 1 || h < 1) return;

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
    p = (DWORD *)bits;
    n = w * h;
    for (i = 0; i < n; i++) {
        int x = i % w, y = i / w;
        /* checker so we can see StretchBlt, not just flat fill */
        p[i] = ((x ^ y) & 32) ? 0xFF00FF80 : 0xFF8000FF;
    }
    StretchBlt(hdc, 0, 0, w, h, mem, 0, 0, w, h, SRCCOPY);
    GdiFlush();
    SelectObject(mem, old);
    DeleteObject(dib);
    DeleteDC(mem);
    ReleaseDC(hwnd, hdc);
}

static void paint_layered(HWND hwnd)
{
    BITMAPINFO bmi;
    void *bits;
    HDC screen, mem;
    HBITMAP dib, old;
    SIZE size;
    POINT pt_src = {0, 0}, pt_dst;
    BLENDFUNCTION blend;
    RECT wr;
    int w, h, i, n;
    DWORD *p;

    GetWindowRect(hwnd, &wr);
    w = wr.right - wr.left;
    h = wr.bottom - wr.top;
    SetWindowLongW(hwnd, GWL_EXSTYLE, GetWindowLongW(hwnd, GWL_EXSTYLE) | WS_EX_LAYERED);

    ZeroMemory(&bmi, sizeof(bmi));
    bmi.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
    bmi.bmiHeader.biWidth = w;
    bmi.bmiHeader.biHeight = -h;
    bmi.bmiHeader.biPlanes = 1;
    bmi.bmiHeader.biBitCount = 32;
    bmi.bmiHeader.biCompression = BI_RGB;

    screen = GetDC(NULL);
    mem = CreateCompatibleDC(screen);
    dib = CreateDIBSection(mem, &bmi, DIB_RGB_COLORS, &bits, NULL, 0);
    old = SelectObject(mem, dib);
    p = (DWORD *)bits;
    n = w * h;
    for (i = 0; i < n; i++) p[i] = 0xFFFF00FF; /* opaque magenta */

    size.cx = w;
    size.cy = h;
    pt_dst.x = wr.left;
    pt_dst.y = wr.top;
    blend.BlendOp = AC_SRC_OVER;
    blend.BlendFlags = 0;
    blend.SourceConstantAlpha = 255;
    blend.AlphaFormat = 0;
    if (!UpdateLayeredWindow(hwnd, screen, &pt_dst, &size, mem, &pt_src, 0, &blend, ULW_ALPHA))
        printf("UpdateLayeredWindow failed %lu\n", GetLastError());
    else
        printf("UpdateLayeredWindow OK %dx%d\n", w, h);

    SelectObject(mem, old);
    DeleteObject(dib);
    DeleteDC(mem);
    ReleaseDC(NULL, screen);
}

static void do_paint(HWND hwnd)
{
    if (g_mode == 1) paint_layered(hwnd);
    else if (g_mode == 2) paint_stretch(hwnd);
    else paint_gdi(hwnd);
}

static LRESULT CALLBACK WndProc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp)
{
    switch (msg) {
    case WM_CREATE:
        SetTimer(hwnd, 1, 250, NULL);
        return 0;
    case WM_TIMER:
        KillTimer(hwnd, 1);
        do_paint(hwnd);
        return 0;
    case WM_PAINT: {
        PAINTSTRUCT ps;
        BeginPaint(hwnd, &ps);
        EndPaint(hwnd, &ps);
        do_paint(hwnd);
        return 0;
    }
    case WM_DESTROY:
        PostQuitMessage(0);
        return 0;
    }
    return DefWindowProcW(hwnd, msg, wp, lp);
}

int main(int argc, char **argv)
{
    WNDCLASSW wc;
    HWND hwnd;
    MSG msg;
    int hold = 20;
    DWORD t0;
    RECT rc = {0, 0, 0, 0};
    DWORD style = WS_OVERLAPPEDWINDOW | WS_VISIBLE;

    if (argc > 1) g_mode = atoi(argv[1]);
    if (argc > 2) g_w = atoi(argv[2]);
    if (argc > 3) g_h = atoi(argv[3]);
    if (argc > 4) hold = atoi(argv[4]);

    ZeroMemory(&wc, sizeof(wc));
    wc.lpfnWndProc = WndProc;
    wc.hInstance = GetModuleHandleW(NULL);
    wc.hCursor = LoadCursor(NULL, IDC_ARROW);
    wc.hbrBackground = (HBRUSH)(COLOR_WINDOW + 1);
    wc.lpszClassName = L"FlyPresentLoginSize";
    if (!RegisterClassW(&wc)) {
        printf("RegisterClass failed %lu\n", GetLastError());
        return 1;
    }

    rc.right = g_w;
    rc.bottom = g_h;
    AdjustWindowRect(&rc, style & ~WS_VISIBLE, FALSE);
    hwnd = CreateWindowExW(
        0, wc.lpszClassName, L"Fly present probe (login size)",
        style,
        80, 80, rc.right - rc.left, rc.bottom - rc.top,
        NULL, NULL, wc.hInstance, NULL);
    if (!hwnd) {
        printf("CreateWindow failed %lu\n", GetLastError());
        return 2;
    }

    printf("probe hwnd=%p mode=%d client=%dx%d hold=%ds\n",
           (void *)hwnd, g_mode, g_w, g_h, hold);
    fflush(stdout);
    ShowWindow(hwnd, SW_SHOW);
    UpdateWindow(hwnd);
    do_paint(hwnd);

    t0 = GetTickCount();
    while (GetTickCount() - t0 < (DWORD)hold * 1000) {
        while (PeekMessageW(&msg, NULL, 0, 0, PM_REMOVE)) {
            if (msg.message == WM_QUIT) return 0;
            TranslateMessage(&msg);
            DispatchMessageW(&msg);
        }
        Sleep(50);
    }
    DestroyWindow(hwnd);
    return 0;
}
