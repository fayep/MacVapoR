// Windows half of the DXMT shared-texture test: makes a shared 2-layer texture on a DXMT
// D3D11 device, clears layer 0 red and layer 1 green, and prints the bootstrap name DXMT
// registered its Mach port under, then waits so the macOS half can open it.
//
// x86_64-w64-mingw32-gcc share_texture.c -o share_texture.exe -ld3d11 -ldxgi -luuid
#define COBJMACROS
#include <windows.h>
#include <d3d11.h>
#include <dxgi.h>
#include <stdio.h>

// From Wine's ddk/d3dkmthk.h; mingw ships no D3DKMT headers.
typedef UINT D3DKMT_HANDLE;
typedef struct { LUID AdapterLuid; D3DKMT_HANDLE hAdapter; } D3DKMT_OPENADAPTERFROMLUID;
typedef struct {
    union { D3DKMT_HANDLE hAdapter; VOID *pAdapter; };
    UINT Flags;
    D3DKMT_HANDLE hDevice;
    VOID *pCommandBuffer;
    UINT CommandBufferSize;
    VOID *pAllocationList;
    UINT AllocationListSize;
    VOID *pPatchLocationList;
    UINT PatchLocationListSize;
} D3DKMT_CREATEDEVICE;
typedef struct {
    D3DKMT_HANDLE hDevice;
    D3DKMT_HANDLE hGlobalShare;
    void *pPrivateRuntimeData;
    UINT PrivateRuntimeDataSize;
    UINT TotalPrivateDriverDataSize;
    UINT ResourcePrivateDriverDataSize;
    UINT NumAllocations;
} D3DKMT_QUERYRESOURCEINFO;
// Looked up in gdi32 by name: mingw's d3d11 import library also lists them, and DXMT's d3d11.dll
// does not implement them.
static NTSTATUS (WINAPI *D3DKMTOpenAdapterFromLuid)(D3DKMT_OPENADAPTERFROMLUID *);
static NTSTATUS (WINAPI *D3DKMTCreateDevice)(D3DKMT_CREATEDEVICE *);
static NTSTATUS (WINAPI *D3DKMTQueryResourceInfo)(D3DKMT_QUERYRESOURCEINFO *);
typedef struct {
    D3DKMT_HANDLE hAllocation;
    const void *pPrivateDriverData;
    UINT PrivateDriverDataSize;
    UINT64 GpuVirtualAddress;
    ULONG_PTR Reserved[6];
} D3DDDI_OPENALLOCATIONINFO2;
typedef struct {
    D3DKMT_HANDLE hDevice;
    D3DKMT_HANDLE hGlobalShare;
    UINT NumAllocations;
    D3DDDI_OPENALLOCATIONINFO2 *pOpenAllocationInfo2;
    void *pPrivateRuntimeData;
    UINT PrivateRuntimeDataSize;
    void *pResourcePrivateDriverData;
    UINT ResourcePrivateDriverDataSize;
    void *pTotalPrivateDriverDataBuffer;
    UINT TotalPrivateDriverDataBufferSize;
    D3DKMT_HANDLE hResource;
} D3DKMT_OPENRESOURCE;
typedef struct {
    D3DKMT_HANDLE hDevice;
    D3DKMT_HANDLE hResource;
    const D3DKMT_HANDLE *phAllocationList;
    UINT AllocationCount;
} D3DKMT_DESTROYALLOCATION;
static NTSTATUS (WINAPI *D3DKMTOpenResource2)(D3DKMT_OPENRESOURCE *);
static NTSTATUS (WINAPI *D3DKMTDestroyAllocation)(const D3DKMT_DESTROYALLOCATION *);

// DXMT's SharedResourceData (src/d3d11/d3d11_texture_device.cpp), which it stores as the
// shared allocation's private runtime data.
typedef struct {
    UINT Width, Height, MipLevels, ArraySize;
    DXGI_FORMAT Format;
    DXGI_SAMPLE_DESC SampleDesc;
    D3D11_USAGE Usage;
    UINT BindFlags, CPUAccessFlags, MiscFlags;
    UINT TextureLayout;   // D3D11_TEXTURE_LAYOUT
} TEXTURE2D_DESC1;
typedef struct {
    char mach_port_name[54];
    D3D11_RESOURCE_DIMENSION dimension;
    union { TEXTURE2D_DESC1 desc2d; char pad[48]; } desc;   // DXMT's 3D desc is smaller
    D3DKMT_HANDLE mutex_handle;
} SharedResourceData;

#define CHECK(hr, what) do { if (FAILED(hr)) { printf("FAIL %s: 0x%08lx\n", what, (unsigned long)(hr)); return 1; } } while (0)

int main(void) {
    HMODULE gdi = LoadLibraryA("gdi32.dll");
    D3DKMTOpenAdapterFromLuid = (void *)GetProcAddress(gdi, "D3DKMTOpenAdapterFromLuid");
    D3DKMTCreateDevice = (void *)GetProcAddress(gdi, "D3DKMTCreateDevice");
    D3DKMTQueryResourceInfo = (void *)GetProcAddress(gdi, "D3DKMTQueryResourceInfo");
    D3DKMTOpenResource2 = (void *)GetProcAddress(gdi, "D3DKMTOpenResource2");
    D3DKMTDestroyAllocation = (void *)GetProcAddress(gdi, "D3DKMTDestroyAllocation");
    if (!D3DKMTOpenAdapterFromLuid || !D3DKMTCreateDevice || !D3DKMTQueryResourceInfo) {
        printf("FAIL D3DKMT functions not found in gdi32\n");
        return 1;
    }
    ID3D11Device *dev;
    ID3D11DeviceContext *ctx;
    D3D_FEATURE_LEVEL fl;
    CHECK(D3D11CreateDevice(NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, 0, NULL, 0, D3D11_SDK_VERSION, &dev, &fl, &ctx),
          "D3D11CreateDevice");

    D3D11_TEXTURE2D_DESC td = {256, 256, 1, 2, DXGI_FORMAT_R8G8B8A8_UNORM, {1, 0}, D3D11_USAGE_DEFAULT,
                               D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE, 0, D3D11_RESOURCE_MISC_SHARED};
    ID3D11Texture2D *tex;
    CHECK(ID3D11Device_CreateTexture2D(dev, &td, NULL, &tex), "CreateTexture2D (shared, 2 layers)");

    const float colors[2][4] = {{1, 0, 0, 1}, {0, 1, 0, 1}};
    for (UINT i = 0; i < 2; i++) {
        D3D11_RENDER_TARGET_VIEW_DESC rd = {0};
        rd.Format = td.Format;
        rd.ViewDimension = D3D11_RTV_DIMENSION_TEXTURE2DARRAY;
        rd.Texture2DArray.FirstArraySlice = i;
        rd.Texture2DArray.ArraySize = 1;
        ID3D11RenderTargetView *rtv;
        CHECK(ID3D11Device_CreateRenderTargetView(dev, (ID3D11Resource *)tex, &rd, &rtv), "CreateRenderTargetView");
        ID3D11DeviceContext_ClearRenderTargetView(ctx, rtv, colors[i]);
        ID3D11RenderTargetView_Release(rtv);
    }
    ID3D11DeviceContext_Flush(ctx);

    IDXGIResource *res;
    CHECK(ID3D11Texture2D_QueryInterface(tex, &IID_IDXGIResource, (void **)&res), "QueryInterface IDXGIResource");
    HANDLE share;
    CHECK(IDXGIResource_GetSharedHandle(res, &share), "GetSharedHandle");

    IDXGIDevice *dxgi_dev;
    IDXGIAdapter *adapter;
    DXGI_ADAPTER_DESC ad;
    CHECK(ID3D11Device_QueryInterface(dev, &IID_IDXGIDevice, (void **)&dxgi_dev), "QueryInterface IDXGIDevice");
    CHECK(IDXGIDevice_GetAdapter(dxgi_dev, &adapter), "GetAdapter");
    CHECK(IDXGIAdapter_GetDesc(adapter, &ad), "GetDesc");

    D3DKMT_OPENADAPTERFROMLUID oa = {ad.AdapterLuid, 0};
    NTSTATUS st = D3DKMTOpenAdapterFromLuid(&oa);
    if (st) { printf("FAIL D3DKMTOpenAdapterFromLuid 0x%08lx\n", (unsigned long)st); return 1; }
    D3DKMT_CREATEDEVICE cd = {0};
    cd.hAdapter = oa.hAdapter;
    st = D3DKMTCreateDevice(&cd);
    if (st) { printf("FAIL D3DKMTCreateDevice 0x%08lx\n", (unsigned long)st); return 1; }

    SharedResourceData data = {0};
    D3DKMT_QUERYRESOURCEINFO q = {cd.hDevice, (D3DKMT_HANDLE)(UINT_PTR)share, &data, sizeof data};
    st = D3DKMTQueryResourceInfo(&q);
    if (st) { printf("FAIL D3DKMTQueryResourceInfo 0x%08lx (size %u)\n", (unsigned long)st, q.PrivateRuntimeDataSize); return 1; }
    // As DXMT's own import does: the query gives the size, opening the resource gives the data.
    D3DDDI_OPENALLOCATIONINFO2 alloc = {0};
    D3DKMT_OPENRESOURCE open = {0};
    open.hDevice = cd.hDevice;
    open.hGlobalShare = (D3DKMT_HANDLE)(UINT_PTR)share;
    open.NumAllocations = 1;
    open.pOpenAllocationInfo2 = &alloc;
    open.pPrivateRuntimeData = &data;
    open.PrivateRuntimeDataSize = q.PrivateRuntimeDataSize;
    st = D3DKMTOpenResource2(&open);
    if (st) { printf("FAIL D3DKMTOpenResource2 0x%08lx\n", (unsigned long)st); return 1; }
    D3DKMT_DESTROYALLOCATION destroy = {cd.hDevice, open.hResource, NULL, 0};
    D3DKMTDestroyAllocation(&destroy);

    printf("feature level %x, shared handle %p, private data %u bytes (expected %u)\n", fl, share,
           q.PrivateRuntimeDataSize, (unsigned)sizeof data);
    printf("dimension %d, %ux%u, %u layers, format %d\n", data.dimension, data.desc.desc2d.Width,
           data.desc.desc2d.Height, data.desc.desc2d.ArraySize, data.desc.desc2d.Format);
    printf("PORT %s\n", data.mach_port_name);
    fflush(stdout);
    Sleep(60000);
    return 0;
}
