/* D3D11 probe for scripts/smoke-runtime.sh: which d3d11.dll actually loaded
 * (native DXMT/DXVK from system32, or Wine's builtin), does it create a
 * hardware device, and can it present — a device alone says nothing about the
 * DXGI half, which is where a game's frames reach the screen. */
#define INITGUID
#include <windows.h>
#include <stdio.h>
#include <d3d11.h>
#include <dxgi.h>

int main(void)
{
    WNDCLASSA wc = {0};
    wc.lpfnWndProc = DefWindowProcA;
    wc.hInstance = GetModuleHandleA(NULL);
    wc.lpszClassName = "WynProbe";
    RegisterClassA(&wc);
    HWND hwnd = CreateWindowA("WynProbe", "Wyn D3D11 probe", WS_OVERLAPPEDWINDOW,
                              0, 0, 320, 240, NULL, NULL, wc.hInstance, NULL);

    DXGI_SWAP_CHAIN_DESC sd = {0};
    sd.BufferCount = 2;
    sd.BufferDesc.Width = 320;
    sd.BufferDesc.Height = 240;
    sd.BufferDesc.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
    sd.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
    sd.OutputWindow = hwnd;
    sd.SampleDesc.Count = 1;
    sd.Windowed = TRUE;
    sd.SwapEffect = DXGI_SWAP_EFFECT_DISCARD;

    ID3D11Device *dev = NULL;
    ID3D11DeviceContext *ctx = NULL;
    IDXGISwapChain *swap = NULL;
    D3D_FEATURE_LEVEL fl = 0;
    HRESULT hr = D3D11CreateDeviceAndSwapChain(NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, 0, NULL, 0,
                                               D3D11_SDK_VERSION, &sd, &swap, &dev, &fl, &ctx);
    char path[MAX_PATH] = "";
    GetModuleFileNameA(GetModuleHandleA("d3d11.dll"), path, MAX_PATH);
    printf("d3d11.dll loaded from: %s\n", path);
    printf("D3D11CreateDevice(HARDWARE): 0x%08lx feature level 0x%x\n", (unsigned long)hr, fl);
    if (SUCCEEDED(hr)) {
        IDXGIDevice *dxgi = NULL;
        if (SUCCEEDED(dev->lpVtbl->QueryInterface(dev, &IID_IDXGIDevice, (void **)&dxgi))) {
            IDXGIAdapter *adapter = NULL;
            if (SUCCEEDED(dxgi->lpVtbl->GetAdapter(dxgi, &adapter))) {
                DXGI_ADAPTER_DESC d;
                adapter->lpVtbl->GetDesc(adapter, &d);
                printf("adapter: %ls vendor=0x%04x device=0x%04x\n", d.Description, d.VendorId, d.DeviceId);
                adapter->lpVtbl->Release(adapter);
            }
            dxgi->lpVtbl->Release(dxgi);
        }
        /* Clear the back buffer and present a few frames. */
        ID3D11Texture2D *back = NULL;
        ID3D11RenderTargetView *rtv = NULL;
        HRESULT present = E_FAIL;
        if (SUCCEEDED(swap->lpVtbl->GetBuffer(swap, 0, &IID_ID3D11Texture2D, (void **)&back)) &&
            SUCCEEDED(dev->lpVtbl->CreateRenderTargetView(dev, (ID3D11Resource *)back, NULL, &rtv))) {
            const float teal[4] = {0.0f, 0.5f, 0.5f, 1.0f};
            for (int i = 0; i < 10; i++) {
                ctx->lpVtbl->OMSetRenderTargets(ctx, 1, &rtv, NULL);
                ctx->lpVtbl->ClearRenderTargetView(ctx, rtv, teal);
                present = swap->lpVtbl->Present(swap, 0, 0);
                if (FAILED(present)) break;
            }
        }
        printf("Present x10: 0x%08lx\n", (unsigned long)present);
        if (rtv) rtv->lpVtbl->Release(rtv);
        if (back) back->lpVtbl->Release(back);
    }
    fflush(stdout);
    Sleep(6000); /* time for lsof */
    return FAILED(hr);
}
