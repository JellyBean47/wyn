/* Minimal D3D12/DXGI probe: which adapter does the runtime expose, and can it
 * create a D3D12 device? Under D3DMetal the adapter is Apple's compatibility
 * adapter; under vkd3d/wined3d it is something else or creation fails. */
#define INITGUID
#include <windows.h>
#include <stdio.h>
#include <d3d12.h>
#include <dxgi1_4.h>

int main(void)
{
    IDXGIFactory4 *factory = NULL;
    HRESULT hr = CreateDXGIFactory1(&IID_IDXGIFactory4, (void **)&factory);
    printf("CreateDXGIFactory1: 0x%08lx\n", (unsigned long)hr);
    if (FAILED(hr)) return 1;

    IDXGIAdapter1 *adapter = NULL;
    for (UINT i = 0; factory->lpVtbl->EnumAdapters1(factory, i, &adapter) != DXGI_ERROR_NOT_FOUND; i++) {
        DXGI_ADAPTER_DESC1 d;
        adapter->lpVtbl->GetDesc1(adapter, &d);
        printf("adapter %u: %ls vendor=0x%04x device=0x%04x vram=%llu MB\n", i, d.Description,
               d.VendorId, d.DeviceId, (unsigned long long)(d.DedicatedVideoMemory >> 20));
        ID3D12Device *dev = NULL;
        hr = D3D12CreateDevice((IUnknown *)adapter, D3D_FEATURE_LEVEL_12_0, &IID_ID3D12Device, (void **)&dev);
        printf("  D3D12CreateDevice(12_0): 0x%08lx\n", (unsigned long)hr);
        if (SUCCEEDED(hr)) dev->lpVtbl->Release(dev);
        adapter->lpVtbl->Release(adapter);
    }
    factory->lpVtbl->Release(factory);
    fflush(stdout);
    Sleep(8000); /* time for lsof on the live process */
    return 0;
}
