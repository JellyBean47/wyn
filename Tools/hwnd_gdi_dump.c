#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static BOOL save_bmp(const char *path, HBITMAP hbmp, HDC hdc)
{
    BITMAP bm; BITMAPFILEHEADER hdr; BITMAPINFOHEADER bi; BITMAPINFO info;
    DWORD img_size, wrote; HANDLE file; void *bits; BOOL ok;
    if (!GetObjectW(hbmp, sizeof(bm), &bm)) return FALSE;
    ZeroMemory(&bi, sizeof(bi));
    bi.biSize = sizeof(bi); bi.biWidth = bm.bmWidth; bi.biHeight = bm.bmHeight;
    bi.biPlanes = 1; bi.biBitCount = 32; bi.biCompression = BI_RGB;
    img_size = ((bm.bmWidth * 32 + 31) / 32) * 4 * bm.bmHeight;
    bits = malloc(img_size); if (!bits) return FALSE;
    ZeroMemory(&info, sizeof(info)); info.bmiHeader = bi;
    if (!GetDIBits(hdc, hbmp, 0, bm.bmHeight, bits, &info, DIB_RGB_COLORS)) { free(bits); return FALSE; }
    hdr.bfType = 0x4D42; hdr.bfOffBits = sizeof(hdr) + sizeof(bi);
    hdr.bfSize = hdr.bfOffBits + img_size; hdr.bfReserved1 = hdr.bfReserved2 = 0;
    file = CreateFileA(path, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (file == INVALID_HANDLE_VALUE) { free(bits); return FALSE; }
    ok = WriteFile(file, &hdr, sizeof(hdr), &wrote, NULL)
      && WriteFile(file, &bi, sizeof(bi), &wrote, NULL)
      && WriteFile(file, bits, img_size, &wrote, NULL);
    CloseHandle(file); free(bits); return ok;
}

static void analyze(HBITMAP hbmp, HDC hdc, const char *tag)
{
    BITMAP bm; BITMAPINFO info; DWORD *px; DWORD n,i,nonzero=0,rgb_nz=0,alpha_lo=0;
    unsigned long long sa=0,sr=0,sg=0,sb=0;
    if (!GetObjectW(hbmp, sizeof(bm), &bm)) return;
    n = (DWORD)bm.bmWidth * (DWORD)bm.bmHeight;
    px = malloc(n*4); if (!px) return;
    ZeroMemory(&info, sizeof(info));
    info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
    info.bmiHeader.biWidth = bm.bmWidth;
    info.bmiHeader.biHeight = -bm.bmHeight;
    info.bmiHeader.biPlanes = 1; info.bmiHeader.biBitCount = 32; info.bmiHeader.biCompression = BI_RGB;
    if (!GetDIBits(hdc, hbmp, 0, bm.bmHeight, px, &info, DIB_RGB_COLORS)) { free(px); return; }
    for (i=0;i<n;i++) {
        DWORD c=px[i]; BYTE a=(BYTE)(c>>24), r=(BYTE)(c>>16), g=(BYTE)(c>>8), b=(BYTE)c;
        sa+=a; sr+=r; sg+=g; sb+=b;
        if (r|g|b|a) nonzero++;
        if (r|g|b) rgb_nz++;
        if (a<5) alpha_lo++;
    }
    printf("%s size=%dx%d rgb_nz=%.1f%% any_nz=%.1f%% alpha_lo=%.1f%% avg_bgra_as_rgba=(%llu,%llu,%llu,%llu)\n",
           tag, bm.bmWidth, bm.bmHeight, 100.0*rgb_nz/n, 100.0*nonzero/n, 100.0*alpha_lo/n,
           sr/n, sg/n, sb/n, sa/n);
    free(px);
}

struct enum_ctx { HWND best; int best_area; char title[256]; int want_large; };
static BOOL CALLBACK enum_proc(HWND hwnd, LPARAM lp)
{
    struct enum_ctx *ctx=(struct enum_ctx*)lp; char title[256]; RECT rc; int area; DWORD pid=0;
    if (!IsWindowVisible(hwnd)) return TRUE;
    GetWindowTextA(hwnd, title, sizeof(title));
    if (!title[0]) return TRUE;
    if (!strstr(title,"Ubisoft") && !strstr(title,"Connect") && !strstr(title,"Uplay")) return TRUE;
    GetWindowThreadProcessId(hwnd,&pid); GetWindowRect(hwnd,&rc);
    area=(rc.right-rc.left)*(rc.bottom-rc.top);
    printf("found hwnd=%p pid=%lu %dx%d title='%s'\n", hwnd,(unsigned long)pid,rc.right-rc.left,rc.bottom-rc.top,title);
    if (ctx->want_large && (rc.right-rc.left)<1000) return TRUE;
    if (area>ctx->best_area){ ctx->best_area=area; ctx->best=hwnd; strncpy(ctx->title,title,sizeof(ctx->title)-1);} 
    return TRUE;
}

static int dump_one(HWND hwnd, const char *out, int use_client)
{
    RECT rc; int w,h; HDC hdc_win, hdc_mem; HBITMAP hbmp, old;
    if (use_client) GetClientRect(hwnd,&rc); else GetWindowRect(hwnd,&rc);
    w = use_client ? rc.right-rc.left : rc.right-rc.left;
    h = use_client ? rc.bottom-rc.top : rc.bottom-rc.top;
    if (!use_client){ /* window rect is screen coords; size still ok */ }
    printf("dumping hwnd=%p %s %dx%d -> %s\n", hwnd, use_client?"client":"window", w,h,out);
    hdc_win = use_client ? GetDC(hwnd) : GetWindowDC(hwnd);
    if (!hdc_win){ fprintf(stderr,"GetDC failed\n"); return 3; }
    hdc_mem = CreateCompatibleDC(hdc_win);
    hbmp = CreateCompatibleBitmap(hdc_win, w, h);
    old = SelectObject(hdc_mem, hbmp);
    BitBlt(hdc_mem, 0,0,w,h, hdc_win, 0,0, SRCCOPY);
    printf("capture=BitBlt\n");
    analyze(hbmp, hdc_mem, use_client?"client":"window");
    if (!save_bmp(out, hbmp, hdc_mem)) fprintf(stderr,"save failed %lu\n", GetLastError());
    else printf("wrote %s\n", out);
    SelectObject(hdc_mem, old); DeleteObject(hbmp); DeleteDC(hdc_mem); ReleaseDC(hwnd, hdc_win);
    return 0;
}

int main(int argc, char **argv)
{
    struct enum_ctx ctx={0};
    const char *out = argc>1?argv[1]:"C:\\fly-gdi.bmp";
    ctx.want_large = (argc>2 && !strcmp(argv[2],"large"));
    EnumWindows(enum_proc,(LPARAM)&ctx);
    if (!ctx.best){ fprintf(stderr,"no hwnd\n"); return 2; }
    dump_one(ctx.best, out, 0);
    /* also client */
    {
      char out2[512]; snprintf(out2,sizeof(out2),"%s.client.bmp", out);
      /* simpler second path */
      char buf[512];
      if (strlen(out)<500){ strcpy(buf,out); /* replace .bmp */ char *p=strrchr(buf,'.'); if(p) strcpy(p,"-client.bmp"); else strcat(buf,"-client.bmp"); dump_one(ctx.best, buf, 1); }
    }
    return 0;
}
