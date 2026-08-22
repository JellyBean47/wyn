#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>
#include <string.h>

struct enum_ctx { HWND best; int best_area; char title[256]; };
static BOOL CALLBACK enum_proc(HWND hwnd, LPARAM lp)
{
    struct enum_ctx *ctx=(struct enum_ctx*)lp; char title[256]; RECT rc; int area;
    if (!IsWindowVisible(hwnd)) return TRUE;
    GetWindowTextA(hwnd, title, sizeof(title));
    if (!title[0]) return TRUE;
    if (!strstr(title,"Ubisoft") && !strstr(title,"Connect")) return TRUE;
    GetWindowRect(hwnd,&rc);
    area=(rc.right-rc.left)*(rc.bottom-rc.top);
    printf("found %p %dx%d '%s'\n", hwnd, rc.right-rc.left, rc.bottom-rc.top, title);
    if (area > ctx->best_area) { ctx->best_area=area; ctx->best=hwnd; strncpy(ctx->title,title,255); }
    return TRUE;
}

int main(int argc, char **argv)
{
    struct enum_ctx ctx={0};
    HWND hwnd; HDC hdc; RECT rc; HBRUSH br; int mode = 0;
    /* modes: 0=fill client red, 1=fill window, 2=layered update */
    if (argc>1) mode = atoi(argv[1]);
    EnumWindows(enum_proc,(LPARAM)&ctx);
    hwnd=ctx.best;
    if (!hwnd){ fprintf(stderr,"no hwnd\n"); return 2; }
    GetClientRect(hwnd,&rc);
    printf("target %p '%s' client=%dx%d mode=%d\n", hwnd, ctx.title, rc.right, rc.bottom, mode);

    if (mode == 2) {
        /* UpdateLayeredWindow with solid magenta bitmap */
        BITMAPINFO bmi; void *bits; HDC screen, mem; HBITMAP dib, old;
        SIZE size; POINT pt_src={0,0}, pt_dst; BLENDFUNCTION blend; RECT wr;
        int w,h,x,y;
        GetWindowRect(hwnd,&wr); w=wr.right-wr.left; h=wr.bottom-wr.top;
        /* ensure layered */
        SetWindowLongW(hwnd, GWL_EXSTYLE, GetWindowLongW(hwnd,GWL_EXSTYLE)|WS_EX_LAYERED);
        ZeroMemory(&bmi,sizeof(bmi));
        bmi.bmiHeader.biSize=sizeof(BITMAPINFOHEADER);
        bmi.bmiHeader.biWidth=w; bmi.bmiHeader.biHeight=-h;
        bmi.bmiHeader.biPlanes=1; bmi.bmiHeader.biBitCount=32; bmi.bmiHeader.biCompression=BI_RGB;
        screen=GetDC(NULL); mem=CreateCompatibleDC(screen);
        dib=CreateDIBSection(mem,&bmi,DIB_RGB_COLORS,&bits,NULL,0);
        old=SelectObject(mem,dib);
        {
          DWORD *p=bits; int i,n=w*h;
          for(i=0;i<n;i++) p[i]=0xFFFF00FF; /* opaque magenta BGRA? actually 0xAARRGGBB in DIB often as 0xAARRGGBB little = BGRA: FF 00 FF FF */
          for(i=0;i<n;i++) p[i]=0xFFFF00FF;
        }
        size.cx=w; size.cy=h; pt_dst.x=wr.left; pt_dst.y=wr.top;
        blend.BlendOp=AC_SRC_OVER; blend.BlendFlags=0; blend.SourceConstantAlpha=255; blend.AlphaFormat=0;
        if (!UpdateLayeredWindow(hwnd, screen, &pt_dst, &size, mem, &pt_src, 0, &blend, ULW_ALPHA))
            printf("UpdateLayeredWindow failed %lu\n", GetLastError());
        else
            printf("UpdateLayeredWindow OK magenta %dx%d\n", w,h);
        SelectObject(mem,old); DeleteObject(dib); DeleteDC(mem); ReleaseDC(NULL,screen);
        return 0;
    }

    hdc = (mode==1) ? GetWindowDC(hwnd) : GetDC(hwnd);
    if (!hdc){ fprintf(stderr,"GetDC fail\n"); return 3; }
    br = CreateSolidBrush(RGB(255,0,128)); /* hot pink */
    FillRect(hdc, &rc, br);
    /* also GDI rectangle border */
    SelectObject(hdc, GetStockObject(WHITE_PEN));
    Rectangle(hdc, 10,10, rc.right-10, rc.bottom-10);
    GdiFlush();
    DeleteObject(br);
    ReleaseDC(hwnd, hdc);
    /* force redraw */
    RedrawWindow(hwnd, NULL, NULL, RDW_INVALIDATE|RDW_UPDATENOW|RDW_ALLCHILDREN);
    InvalidateRect(hwnd, NULL, TRUE);
    UpdateWindow(hwnd);
    printf("FillRect hotpink done; GdiFlush+RedrawWindow\n");
    Sleep(500);
    return 0;
}
