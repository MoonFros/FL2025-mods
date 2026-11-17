/* D3D11 drawing for NGB_Render.
 *
 * Design notes:
 *  - We do not create a device or a swapchain. We use the game's own, taken
 *    from the swapchain handed to Present(). Nothing here can change the
 *    game's presentation mode.
 *  - State we touch is saved and restored (render target, viewport, shaders,
 *    input layout, buffers, blend/raster/depth states, topology).
 *  - Text comes from GDI into a cached texture per (string,size,weight). GDI
 *    renders a white mask on black; the shader uses the red channel as alpha
 *    and tints it, which gives anti-aliased type without shipping a font file
 *    and without depending on DirectWrite.
 *  - Shaders are compiled at runtime from d3dcompiler_47.dll (present on
 *    Windows 8.1+ and shipped with the game). If it is missing we log and stay
 *    off - never crash.
 */
#include "ngb.h"
#include <d3d11.h>
#include <dxgi.h>
#include <d3dcompiler.h>
#include <string.h>
#include <stdio.h>

#pragma comment(lib, "d3d11.lib")

/* MinGW declares the interfaces with an explicit vtbl pointer (C layout), so
 * there is no __uuidof here: the IIDs are plain extern symbols. */
#pragma comment(lib, "dxgi.lib")
#pragma comment(lib, "gdi32.lib")

/* ------------------------------------------------------------------ shaders */
static const char *kVS =
"cbuffer CB : register(b0) { float2 screen; float2 pad; };\n"
"struct VSIn { float2 pos : POSITION; float2 uv : TEXCOORD0; };\n"
"struct VSOut { float4 pos : SV_POSITION; float2 uv : TEXCOORD0; };\n"
"VSOut main(VSIn i){\n"
"  VSOut o;\n"
"  o.pos = float4(i.pos.x / screen.x * 2.0 - 1.0,\n"
"                 1.0 - i.pos.y / screen.y * 2.0, 0.0, 1.0);\n"
"  o.uv = i.uv;\n"
"  return o;\n"
"}\n";

static const char *kPS =
"cbuffer CB : register(b0) { float2 screen; float2 pad; float4 color; };\n"
"Texture2D    tex : register(t0);\n"
"SamplerState smp : register(s0);\n"
"float4 main(float4 p : SV_POSITION, float2 uv : TEXCOORD0) : SV_TARGET {\n"
"  float a = tex.Sample(smp, uv).r;\n"          /* white mask / white fill */
"  return float4(color.rgb, color.a * a);\n"
"}\n";

typedef HRESULT (WINAPI *PFN_D3DCOMPILE)(LPCVOID, SIZE_T, LPCSTR, const void*,
                                         void*, LPCSTR, LPCSTR, UINT, UINT,
                                         void**, void**);

/* --------------------------------------------------------------- pipeline */
typedef struct { float x, y, u, v; } vtx_t;
typedef struct { float screen[2]; float pad[2]; float color[4]; } cb_t;

typedef struct {
    ID3D11Texture2D          *tex;
    ID3D11ShaderResourceView *srv;
    int w, h;
    wchar_t key[96];
    int px, weight;
    unsigned long last_use;
} text_ent;

#define TEXT_CACHE 384

static struct {
    int  ready;
    char why[160];

    ID3D11Device        *dev;
    ID3D11DeviceContext *ctx;
    IDXGISwapChain      *sc;
    ID3D11RenderTargetView *rtv;
    int  rt_w, rt_h;

    ID3D11VertexShader *vs;
    ID3D11PixelShader  *ps;
    ID3D11InputLayout  *il;
    ID3D11Buffer       *vb;      /* dynamic, 6 verts per quad */
    ID3D11Buffer       *cb;
    ID3D11SamplerState *smp;
    ID3D11BlendState   *blend;
    ID3D11RasterizerState *rast;
    ID3D11DepthStencilState *ds;
    ID3D11Texture2D    *white;
    ID3D11ShaderResourceView *white_srv;

    /* saved state */
    ID3D11RenderTargetView *s_rtv;
    ID3D11DepthStencilView *s_dsv;
    ID3D11VertexShader *s_vs;
    ID3D11PixelShader  *s_ps;
    ID3D11InputLayout  *s_il;
    ID3D11Buffer       *s_vb, *s_ib, *s_cb;
    ID3D11BlendState   *s_blend;
    ID3D11RasterizerState *s_rast;
    ID3D11DepthStencilState *s_ds;
    ID3D11SamplerState *s_smp;
    D3D11_VIEWPORT      s_vp[8];
    UINT                s_vpn;
    FLOAT               s_blendf[4];
    UINT                s_stencil;
    D3D11_PRIMITIVE_TOPOLOGY s_topo;
    ID3D11ShaderResourceView *s_srv;
    int  saved;

    text_ent cache[TEXT_CACHE];
    int  cache_n;
    unsigned long use_clock;

    int  frames;
    int  draws_this_frame;
} G;

int ngb_gfx_ready(void) { return G.ready && G.sc != NULL; }
int ngb_gfx_width(void)  { return G.rt_w; }
int ngb_gfx_height(void) { return G.rt_h; }

/* ------------------------------------------------------------------- GDI */
static HDC     s_memdc;
static HBITMAP s_dib;
static void   *s_bits;
static HGDIOBJ s_old_bmp;
static HFONT   s_font;
static int     s_font_px, s_font_weight;
static int     s_dib_w, s_dib_h;

static void gdi_release(void)
{
    if (s_font) { DeleteObject(s_font); s_font = NULL; }
    if (s_memdc) {
        if (s_old_bmp) SelectObject(s_memdc, s_old_bmp);
        if (s_dib) DeleteObject(s_dib);
        DeleteDC(s_memdc);
    }
    s_memdc = NULL; s_dib = NULL; s_bits = NULL; s_old_bmp = NULL;
    s_dib_w = s_dib_h = 0;
}

static int gdi_prepare(int w, int h)
{
    if (s_memdc && s_dib_w >= w && s_dib_h >= h) return 1;
    gdi_release();
    if (w < 8) w = 8;
    if (h < 8) h = 8;
    /* round up so a growing string does not reallocate every frame */
    w = (w + 63) & ~63;
    h = (h + 15) & ~15;
    if (w > 4096) w = 4096;
    if (h > 512) h = 512;

    BITMAPINFO bi;
    ZeroMemory(&bi, sizeof bi);
    bi.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
    bi.bmiHeader.biWidth = w;
    bi.bmiHeader.biHeight = -h;          /* top-down */
    bi.bmiHeader.biPlanes = 1;
    bi.bmiHeader.biBitCount = 32;
    bi.bmiHeader.biCompression = BI_RGB;

    HDC screen = GetDC(NULL);
    s_memdc = CreateCompatibleDC(screen);
    ReleaseDC(NULL, screen);
    if (!s_memdc) return 0;
    s_dib = CreateDIBSection(s_memdc, &bi, DIB_RGB_COLORS, &s_bits, NULL, 0);
    if (!s_dib || !s_bits) return 0;
    s_old_bmp = SelectObject(s_memdc, s_dib);
    SetBkMode(s_memdc, TRANSPARENT);
    SetTextColor(s_memdc, RGB(255, 255, 255));
    s_dib_w = w; s_dib_h = h;
    return 1;
}

static HFONT gdi_font(int px, int weight)
{
    if (s_font && s_font_px == px && s_font_weight == weight) return s_font;
    if (s_font) DeleteObject(s_font);
    /* Segoe UI is on every supported Windows; Arial is the fallback the font
     * mapper picks automatically if it is missing. */
    s_font = CreateFontW(-px, 0, 0, 0, weight, FALSE, FALSE, FALSE,
                         DEFAULT_CHARSET, OUT_TT_PRECIS, CLIP_DEFAULT_PRECIS,
                         ANTIALIASED_QUALITY, DEFAULT_PITCH | FF_DONTCARE,
                         L"Segoe UI");
    if (!s_font)
        s_font = CreateFontW(-px, 0, 0, 0, weight, FALSE, FALSE, FALSE,
                             DEFAULT_CHARSET, OUT_TT_PRECIS, CLIP_DEFAULT_PRECIS,
                             ANTIALIASED_QUALITY, DEFAULT_PITCH | FF_DONTCARE,
                             L"Arial");
    s_font_px = px;
    s_font_weight = weight;
    return s_font;
}

/* ------------------------------------------------------------- shader load */
static int build_shaders(void)
{
    HMODULE comp = LoadLibraryA("d3dcompiler_47.dll");
    if (!comp) comp = LoadLibraryA("d3dcompiler_46.dll");
    if (!comp) comp = LoadLibraryA("d3dcompiler_43.dll");
    if (!comp) {
        snprintf(G.why, sizeof G.why, "d3dcompiler_47.dll not available");
        return 0;
    }
    PFN_D3DCOMPILE compile = (PFN_D3DCOMPILE)(void *)GetProcAddress(comp, "D3DCompile");
    if (!compile) {
        snprintf(G.why, sizeof G.why, "D3DCompile export missing");
        return 0;
    }

    ID3DBlob *vsb = NULL, *psb = NULL, *err = NULL;
    HRESULT hr = compile(kVS, strlen(kVS), "ngb_vs", NULL, NULL, "main", "vs_4_0",
                         0x00000003 /* OPTIMIZATION_LEVEL3 */, 0, (void **)&vsb, (void **)&err);
    if (FAILED(hr) || !vsb) {
        snprintf(G.why, sizeof G.why, "vertex shader compile failed (0x%08lx)",
                 (unsigned long)hr);
        if (err) err->lpVtbl->Release(err);
        return 0;
    }
    if (err) { err->lpVtbl->Release(err); err = NULL; }

    hr = compile(kPS, strlen(kPS), "ngb_ps", NULL, NULL, "main", "ps_4_0",
                 0x00000003 /* OPTIMIZATION_LEVEL3 */, 0, (void **)&psb, (void **)&err);
    if (FAILED(hr) || !psb) {
        snprintf(G.why, sizeof G.why, "pixel shader compile failed (0x%08lx)",
                 (unsigned long)hr);
        if (err) err->lpVtbl->Release(err);
        vsb->lpVtbl->Release(vsb);
        return 0;
    }
    if (err) err->lpVtbl->Release(err);

    hr = G.dev->lpVtbl->CreateVertexShader(G.dev, vsb->lpVtbl->GetBufferPointer(vsb),
                                           vsb->lpVtbl->GetBufferSize(vsb), NULL, &G.vs);
    if (SUCCEEDED(hr))
        hr = G.dev->lpVtbl->CreatePixelShader(G.dev, psb->lpVtbl->GetBufferPointer(psb),
                                              psb->lpVtbl->GetBufferSize(psb), NULL, &G.ps);
    if (SUCCEEDED(hr)) {
        D3D11_INPUT_ELEMENT_DESC elems[] = {
            { "POSITION", 0, DXGI_FORMAT_R32G32_FLOAT, 0, 0,  D3D11_INPUT_PER_VERTEX_DATA, 0 },
            { "TEXCOORD", 0, DXGI_FORMAT_R32G32_FLOAT, 0, 8,  D3D11_INPUT_PER_VERTEX_DATA, 0 },
        };
        hr = G.dev->lpVtbl->CreateInputLayout(G.dev, elems, 2,
                                              vsb->lpVtbl->GetBufferPointer(vsb),
                                              vsb->lpVtbl->GetBufferSize(vsb), &G.il);
    }
    vsb->lpVtbl->Release(vsb);
    psb->lpVtbl->Release(psb);
    if (FAILED(hr)) {
        snprintf(G.why, sizeof G.why, "shader object creation failed (0x%08lx)",
                 (unsigned long)hr);
        return 0;
    }
    return 1;
}

/* --------------------------------------------------------------- textures */
static int make_text_texture(const wchar_t *s, int px, int weight,
                             int *out_w, int *out_h, ID3D11ShaderResourceView **out_srv)
{
    int len = (int)wcslen(s);
    if (len <= 0 || len > 200) return 0;

    HFONT font = gdi_font(px, weight);
    if (!font) return 0;
    HGDIOBJ oldfont = SelectObject(s_memdc, font);

    SIZE sz = { 0, 0 };
    GetTextExtentPoint32W(s_memdc, s, len, &sz);
    int tw = sz.cx + 4, th = sz.cy + 4;
    if (tw < 4) tw = 4;
    if (th < 4) th = 4;
    if (!gdi_prepare(tw, th)) { SelectObject(s_memdc, oldfont); return 0; }

    /* black background, white glyphs */
    RECT all = { 0, 0, s_dib_w, s_dib_h };
    HBRUSH black = (HBRUSH)GetStockObject(BLACK_BRUSH);
    FillRect(s_memdc, &all, black);
    SetBkMode(s_memdc, TRANSPARENT);
    SetTextColor(s_memdc, RGB(255, 255, 255));
    TextOutW(s_memdc, 2, 2, s, len);
    GdiFlush();

    D3D11_TEXTURE2D_DESC td;
    ZeroMemory(&td, sizeof td);
    td.Width = (UINT)tw;
    td.Height = (UINT)th;
    td.MipLevels = 1;
    td.ArraySize = 1;
    td.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
    td.SampleDesc.Count = 1;
    td.Usage = D3D11_USAGE_DEFAULT;
    td.BindFlags = D3D11_BIND_SHADER_RESOURCE;

    D3D11_SUBRESOURCE_DATA sd;
    ZeroMemory(&sd, sizeof sd);
    sd.pSysMem = s_bits;
    sd.SysMemPitch = (UINT)s_dib_w * 4;

    ID3D11Texture2D *tex = NULL;
    HRESULT hr = G.dev->lpVtbl->CreateTexture2D(G.dev, &td, &sd, &tex);
    SelectObject(s_memdc, oldfont);
    if (FAILED(hr) || !tex) return 0;

    D3D11_SHADER_RESOURCE_VIEW_DESC sv;
    ZeroMemory(&sv, sizeof sv);
    sv.Format = td.Format;
    sv.ViewDimension = D3D11_SRV_DIMENSION_TEXTURE2D;
    sv.Texture2D.MipLevels = 1;

    ID3D11ShaderResourceView *srv = NULL;
    hr = G.dev->lpVtbl->CreateShaderResourceView(G.dev, (ID3D11Resource *)tex, &sv, &srv);
    if (FAILED(hr) || !srv) { tex->lpVtbl->Release(tex); return 0; }

    *out_w = tw; *out_h = th; *out_srv = srv;
    /* the texture owns the GPU copy; the SRV keeps the texture alive */
    tex->lpVtbl->Release(tex);
    return 1;
}

static text_ent *cache_lookup(const wchar_t *s, int px, int weight)
{
    for (int i = 0; i < G.cache_n; i++) {
        text_ent *e = &G.cache[i];
        if (e->px == px && e->weight == weight && wcscmp(e->key, s) == 0) {
            e->last_use = ++G.use_clock;
            return e;
        }
    }
    return NULL;
}

static text_ent *cache_add(const wchar_t *s, int px, int weight)
{
    int w = 0, h = 0;
    ID3D11ShaderResourceView *srv = NULL;
    if (!make_text_texture(s, px, weight, &w, &h, &srv)) return NULL;

    text_ent *slot = NULL;
    if (G.cache_n < TEXT_CACHE) slot = &G.cache[G.cache_n++];
    else {
        /* evict least recently used */
        unsigned long best = ~0ul;
        for (int i = 0; i < G.cache_n; i++)
            if (G.cache[i].last_use < best) { best = G.cache[i].last_use; slot = &G.cache[i]; }
        if (slot && slot->srv) { slot->srv->lpVtbl->Release(slot->srv); slot->srv = NULL; }
    }
    if (!slot) { srv->lpVtbl->Release(srv); return NULL; }

    wcsncpy(slot->key, s, 95);
    slot->key[95] = 0;
    slot->px = px; slot->weight = weight;
    slot->w = w; slot->h = h;
    slot->srv = srv;
    slot->last_use = ++G.use_clock;
    return slot;
}

static void cache_clear(void)
{
    for (int i = 0; i < G.cache_n; i++) {
        if (G.cache[i].srv) G.cache[i].srv->lpVtbl->Release(G.cache[i].srv);
        G.cache[i].srv = NULL;
    }
    G.cache_n = 0;
}

/* ------------------------------------------------------------------ init */
int ngb_gfx_init(void)
{
    if (G.ready) return 1;
    snprintf(G.why, sizeof G.why, "not hooked yet");
    return 0;
}

void ngb_gfx_shutdown(void)
{
    cache_clear();
    gdi_release();
#define REL(x) if (x) { x->lpVtbl->Release(x); x = NULL; }
    REL(G.rtv); REL(G.vs); REL(G.ps); REL(G.il); REL(G.vb); REL(G.cb);
    REL(G.smp); REL(G.blend); REL(G.rast); REL(G.ds); REL(G.white_srv); REL(G.white);
    REL(G.s_rtv); REL(G.s_dsv); REL(G.s_vs); REL(G.s_ps); REL(G.s_il);
    REL(G.s_vb); REL(G.s_ib); REL(G.s_cb); REL(G.s_blend); REL(G.s_rast);
    REL(G.s_ds); REL(G.s_smp); REL(G.s_srv);
#undef REL
    if (G.ctx) { G.ctx->lpVtbl->Release(G.ctx); G.ctx = NULL; }
    if (G.dev) { G.dev->lpVtbl->Release(G.dev); G.dev = NULL; }
    G.sc = NULL;
    G.ready = 0;
}

/* Build (once) the device-dependent objects for this swapchain. */
static int ensure_device(IDXGISwapChain *sc)
{
    ID3D11Device *dev = NULL;
    if (FAILED(sc->lpVtbl->GetDevice(sc, &IID_ID3D11Device, (void **)&dev)) || !dev) {
        snprintf(G.why, sizeof G.why, "swapchain has no D3D11 device (not D3D11?)");
        return 0;
    }
    if (G.dev && G.dev != dev) {
        /* device changed (the game recreated it): throw everything away */
        dev->lpVtbl->Release(dev);
        ngb_gfx_shutdown_keep_hook();
        return 0;
    }
    if (!G.dev) {
        G.dev = dev;
        G.dev->lpVtbl->GetImmediateContext(G.dev, &G.ctx);
        if (!G.ctx) { snprintf(G.why, sizeof G.why, "no immediate context"); return 0; }
        if (!build_shaders()) return 0;

        D3D11_BUFFER_DESC bd;
        ZeroMemory(&bd, sizeof bd);
        bd.Usage = D3D11_USAGE_DYNAMIC;
        bd.BindFlags = D3D11_BIND_VERTEX_BUFFER;
        bd.CPUAccessFlags = D3D11_CPU_ACCESS_WRITE;
        bd.ByteWidth = sizeof(vtx_t) * 6;
        if (FAILED(G.dev->lpVtbl->CreateBuffer(G.dev, &bd, NULL, &G.vb))) {
            snprintf(G.why, sizeof G.why, "vertex buffer creation failed");
            return 0;
        }
        ZeroMemory(&bd, sizeof bd);
        bd.Usage = D3D11_USAGE_DYNAMIC;
        bd.BindFlags = D3D11_BIND_CONSTANT_BUFFER;
        bd.CPUAccessFlags = D3D11_CPU_ACCESS_WRITE;
        bd.ByteWidth = sizeof(cb_t);
        if (FAILED(G.dev->lpVtbl->CreateBuffer(G.dev, &bd, NULL, &G.cb))) {
            snprintf(G.why, sizeof G.why, "constant buffer creation failed");
            return 0;
        }

        D3D11_SAMPLER_DESC samp;
        ZeroMemory(&samp, sizeof samp);
        samp.Filter = D3D11_FILTER_MIN_MAG_MIP_LINEAR;
        samp.AddressU = samp.AddressV = samp.AddressW = D3D11_TEXTURE_ADDRESS_CLAMP;
        samp.MaxLOD = D3D11_FLOAT32_MAX;
        if (FAILED(G.dev->lpVtbl->CreateSamplerState(G.dev, &samp, &G.smp))) return 0;

        D3D11_BLEND_DESC bld;
        ZeroMemory(&bld, sizeof bld);
        bld.RenderTarget[0].BlendEnable = TRUE;
        bld.RenderTarget[0].SrcBlend = D3D11_BLEND_SRC_ALPHA;
        bld.RenderTarget[0].DestBlend = D3D11_BLEND_INV_SRC_ALPHA;
        bld.RenderTarget[0].BlendOp = D3D11_BLEND_OP_ADD;
        bld.RenderTarget[0].SrcBlendAlpha = D3D11_BLEND_ONE;
        bld.RenderTarget[0].DestBlendAlpha = D3D11_BLEND_INV_SRC_ALPHA;
        bld.RenderTarget[0].BlendOpAlpha = D3D11_BLEND_OP_ADD;
        bld.RenderTarget[0].RenderTargetWriteMask = D3D11_COLOR_WRITE_ENABLE_ALL;
        if (FAILED(G.dev->lpVtbl->CreateBlendState(G.dev, &bld, &G.blend))) return 0;

        D3D11_RASTERIZER_DESC rs;
        ZeroMemory(&rs, sizeof rs);
        rs.FillMode = D3D11_FILL_SOLID;
        rs.CullMode = D3D11_CULL_NONE;
        rs.DepthClipEnable = TRUE;
        rs.ScissorEnable = FALSE;
        if (FAILED(G.dev->lpVtbl->CreateRasterizerState(G.dev, &rs, &G.rast))) return 0;

        D3D11_DEPTH_STENCIL_DESC dsd;
        ZeroMemory(&dsd, sizeof dsd);
        dsd.DepthEnable = FALSE;
        dsd.StencilEnable = FALSE;
        if (FAILED(G.dev->lpVtbl->CreateDepthStencilState(G.dev, &dsd, &G.ds))) return 0;

        /* 1x1 white texture: solid fills sample it and get alpha 1 */
        D3D11_TEXTURE2D_DESC td;
        ZeroMemory(&td, sizeof td);
        td.Width = td.Height = 1;
        td.MipLevels = 1;
        td.ArraySize = 1;
        td.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
        td.SampleDesc.Count = 1;
        td.Usage = D3D11_USAGE_IMMUTABLE;
        td.BindFlags = D3D11_BIND_SHADER_RESOURCE;
        UINT32 white = 0xFFFFFFFF;
        D3D11_SUBRESOURCE_DATA sd2;
        ZeroMemory(&sd2, sizeof sd2);
        sd2.pSysMem = &white;
        sd2.SysMemPitch = 4;
        if (FAILED(G.dev->lpVtbl->CreateTexture2D(G.dev, &td, &sd2, &G.white))) return 0;
        D3D11_SHADER_RESOURCE_VIEW_DESC sv;
        ZeroMemory(&sv, sizeof sv);
        sv.Format = td.Format;
        sv.ViewDimension = D3D11_SRV_DIMENSION_TEXTURE2D;
        sv.Texture2D.MipLevels = 1;
        if (FAILED(G.dev->lpVtbl->CreateShaderResourceView(G.dev, (ID3D11Resource *)G.white,
                                                          &sv, &G.white_srv))) return 0;
    } else {
        dev->lpVtbl->Release(dev);
    }
    G.sc = sc;
    return 1;
}

/* forward declaration: keeps ensure_device readable */
void ngb_gfx_shutdown_keep_hook(void)
{
    cache_clear();
    gdi_release();
#define REL(x) if (x) { x->lpVtbl->Release(x); x = NULL; }
    REL(G.rtv); REL(G.vs); REL(G.ps); REL(G.il); REL(G.vb); REL(G.cb);
    REL(G.smp); REL(G.blend); REL(G.rast); REL(G.ds); REL(G.white_srv); REL(G.white);
#undef REL
    if (G.ctx) { G.ctx->lpVtbl->Release(G.ctx); G.ctx = NULL; }
    if (G.dev) { G.dev->lpVtbl->Release(G.dev); G.dev = NULL; }
    G.sc = NULL;
    G.ready = 0;
    G.saved = 0;
}

/* ------------------------------------------------------------- frame setup */
int ngb_gfx_begin(IDXGISwapChain *sc)
{
    if (!sc) return 0;
    if (!ensure_device(sc)) return 0;

    ID3D11Texture2D *back = NULL;
    if (FAILED(sc->lpVtbl->GetBuffer(sc, 0, &IID_ID3D11Texture2D, (void **)&back)) || !back) {
        snprintf(G.why, sizeof G.why, "GetBuffer(0) failed");
        return 0;
    }
    D3D11_TEXTURE2D_DESC td;
    back->lpVtbl->GetDesc(back, &td);

    if (!G.rtv || G.rt_w != (int)td.Width || G.rt_h != (int)td.Height) {
        if (G.rtv) { G.rtv->lpVtbl->Release(G.rtv); G.rtv = NULL; }
        if (FAILED(G.dev->lpVtbl->CreateRenderTargetView(G.dev, (ID3D11Resource *)back,
                                                        NULL, &G.rtv))) {
            back->lpVtbl->Release(back);
            snprintf(G.why, sizeof G.why, "CreateRenderTargetView failed");
            return 0;
        }
        G.rt_w = (int)td.Width;
        G.rt_h = (int)td.Height;
        cache_clear();          /* text was rasterised for the old size */
        ngb_log("render target: %dx%d", G.rt_w, G.rt_h);
    }
    back->lpVtbl->Release(back);

    /* ---- save the game's state ---- */
    if (G.saved) {
        /* previous frame ended without restoring (should not happen) */
        G.saved = 0;
    }
    if (G.s_rtv) { G.s_rtv->lpVtbl->Release(G.s_rtv); G.s_rtv = NULL; }
    if (G.s_dsv) { G.s_dsv->lpVtbl->Release(G.s_dsv); G.s_dsv = NULL; }
    G.ctx->lpVtbl->OMGetRenderTargets(G.ctx, 1, &G.s_rtv, &G.s_dsv);
    G.ctx->lpVtbl->VSGetShader(G.ctx, &G.s_vs, NULL, NULL);
    G.ctx->lpVtbl->PSGetShader(G.ctx, &G.s_ps, NULL, NULL);
    G.ctx->lpVtbl->IAGetInputLayout(G.ctx, &G.s_il);
    G.ctx->lpVtbl->IAGetVertexBuffers(G.ctx, 0, 1, &G.s_vb, NULL, NULL);
    G.ctx->lpVtbl->IAGetIndexBuffer(G.ctx, &G.s_ib, NULL, NULL);
    G.ctx->lpVtbl->VSGetConstantBuffers(G.ctx, 0, 1, &G.s_cb);
    G.ctx->lpVtbl->OMGetBlendState(G.ctx, &G.s_blend, G.s_blendf, &G.s_stencil);
    G.ctx->lpVtbl->RSGetState(G.ctx, &G.s_rast);
    G.ctx->lpVtbl->OMGetDepthStencilState(G.ctx, &G.s_ds, NULL);
    G.ctx->lpVtbl->PSGetSamplers(G.ctx, 0, 1, &G.s_smp);
    G.ctx->lpVtbl->PSGetShaderResources(G.ctx, 0, 1, &G.s_srv);
    G.s_vpn = 8;
    G.ctx->lpVtbl->RSGetViewports(G.ctx, &G.s_vpn, G.s_vp);
    G.ctx->lpVtbl->IAGetPrimitiveTopology(G.ctx, &G.s_topo);

    /* ---- set ours ---- */
    ID3D11RenderTargetView *rtv = G.rtv;
    G.ctx->lpVtbl->OMSetRenderTargets(G.ctx, 1, &rtv, NULL);
    D3D11_VIEWPORT vp;
    vp.TopLeftX = vp.TopLeftY = 0.0f;
    vp.Width = (float)G.rt_w;
    vp.Height = (float)G.rt_h;
    vp.MinDepth = 0.0f; vp.MaxDepth = 1.0f;
    G.ctx->lpVtbl->RSSetViewports(G.ctx, 1, &vp);
    G.ctx->lpVtbl->IASetInputLayout(G.ctx, G.il);
    G.ctx->lpVtbl->IASetPrimitiveTopology(G.ctx, D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
    UINT stride = sizeof(vtx_t), off = 0;
    ID3D11Buffer *vb = G.vb;
    G.ctx->lpVtbl->IASetVertexBuffers(G.ctx, 0, 1, &vb, &stride, &off);
    G.ctx->lpVtbl->VSSetShader(G.ctx, G.vs, NULL, 0);
    G.ctx->lpVtbl->PSSetShader(G.ctx, G.ps, NULL, 0);
    ID3D11Buffer *cb = G.cb;
    G.ctx->lpVtbl->VSSetConstantBuffers(G.ctx, 0, 1, &cb);
    G.ctx->lpVtbl->PSSetConstantBuffers(G.ctx, 0, 1, &cb);
    G.ctx->lpVtbl->PSSetSamplers(G.ctx, 0, 1, &G.smp);
    float bf[4] = { 1, 1, 1, 1 };
    G.ctx->lpVtbl->OMSetBlendState(G.ctx, G.blend, bf, 0xFFFFFFFF);
    G.ctx->lpVtbl->OMSetDepthStencilState(G.ctx, G.ds, 0);
    G.ctx->lpVtbl->RSSetState(G.ctx, G.rast);

    G.saved = 1;
    G.draws_this_frame = 0;
    G.ready = 1;
    return 1;
}

void ngb_gfx_end(void)
{
    if (!G.saved) return;
    ID3D11ShaderResourceView *none = NULL;
    G.ctx->lpVtbl->PSSetShaderResources(G.ctx, 0, 1, &none);
    G.ctx->lpVtbl->OMSetRenderTargets(G.ctx, 1, &G.s_rtv, G.s_dsv);
    G.ctx->lpVtbl->VSSetShader(G.ctx, G.s_vs, NULL, 0);
    G.ctx->lpVtbl->PSSetShader(G.ctx, G.s_ps, NULL, 0);
    G.ctx->lpVtbl->IASetInputLayout(G.ctx, G.s_il);
    G.ctx->lpVtbl->IASetVertexBuffers(G.ctx, 0, 1, &G.s_vb, NULL, NULL);
    G.ctx->lpVtbl->IASetIndexBuffer(G.ctx, G.s_ib, DXGI_FORMAT_UNKNOWN, 0);
    G.ctx->lpVtbl->VSSetConstantBuffers(G.ctx, 0, 1, &G.s_cb);
    G.ctx->lpVtbl->OMSetBlendState(G.ctx, G.s_blend, G.s_blendf, G.s_stencil);
    G.ctx->lpVtbl->RSSetState(G.ctx, G.s_rast);
    G.ctx->lpVtbl->OMSetDepthStencilState(G.ctx, G.s_ds, 0);
    G.ctx->lpVtbl->PSSetSamplers(G.ctx, 0, 1, &G.s_smp);
    G.ctx->lpVtbl->PSSetShaderResources(G.ctx, 0, 1, &G.s_srv);
    G.ctx->lpVtbl->RSSetViewports(G.ctx, G.s_vpn, G.s_vp);
    G.ctx->lpVtbl->IASetPrimitiveTopology(G.ctx, G.s_topo);

#define RELS(x) if (x) { x->lpVtbl->Release(x); x = NULL; }
    RELS(G.s_rtv); RELS(G.s_dsv); RELS(G.s_vs); RELS(G.s_ps); RELS(G.s_il);
    RELS(G.s_vb); RELS(G.s_ib); RELS(G.s_cb); RELS(G.s_blend); RELS(G.s_rast);
    RELS(G.s_ds); RELS(G.s_smp); RELS(G.s_srv);
#undef RELS
    G.saved = 0;
}

/* ------------------------------------------------------------------- draws */
static void quad(ID3D11ShaderResourceView *srv, float x, float y, float w, float h,
                 DWORD argb, int is_gradient, DWORD argb2)
{
    if (!G.ctx || !G.vb || !G.cb) return;
    if (w <= 0 || h <= 0) return;
    if (srv == NULL) srv = G.white_srv;
    if (!srv) return;

    /* gradient is faked with a vertical alpha ramp on the vertex colour: the
     * shader multiplies texture alpha by the constant colour, so we issue two
     * quads (top half / bottom half) only when the colours differ. */
    if (is_gradient && argb != argb2) {
        float half = h * 0.5f;
        quad(srv, x, y, w, half, argb, 0, 0);
        quad(srv, x, y + half, w, h - half, argb2, 0, 0);
        return;
    }

    D3D11_MAPPED_SUBRESOURCE m;
    vtx_t *v;
    if (FAILED(G.ctx->lpVtbl->Map(G.ctx, (ID3D11Resource *)G.vb, 0, D3D11_MAP_WRITE_DISCARD,
                                  0, &m)) || !m.pData) return;
    v = (vtx_t *)m.pData;
    float x2 = x + w, y2 = y + h;
    v[0].x = x;  v[0].y = y;  v[0].u = 0; v[0].v = 0;
    v[1].x = x2; v[1].y = y;  v[1].u = 1; v[1].v = 0;
    v[2].x = x2; v[2].y = y2; v[2].u = 1; v[2].v = 1;
    v[3].x = x;  v[3].y = y;  v[3].u = 0; v[3].v = 0;
    v[4].x = x2; v[4].y = y2; v[4].u = 1; v[4].v = 1;
    v[5].x = x;  v[5].y = y2; v[5].u = 0; v[5].v = 1;
    G.ctx->lpVtbl->Unmap(G.ctx, (ID3D11Resource *)G.vb, 0);

    cb_t c;
    c.screen[0] = (float)G.rt_w;
    c.screen[1] = (float)G.rt_h;
    c.pad[0] = c.pad[1] = 0;
    c.color[0] = ((argb >> 16) & 0xFF) / 255.0f;
    c.color[1] = ((argb >> 8) & 0xFF) / 255.0f;
    c.color[2] = (argb & 0xFF) / 255.0f;
    c.color[3] = ((argb >> 24) & 0xFF) / 255.0f;
    D3D11_MAPPED_SUBRESOURCE mc;
    if (FAILED(G.ctx->lpVtbl->Map(G.ctx, (ID3D11Resource *)G.cb, 0, D3D11_MAP_WRITE_DISCARD,
                                  0, &mc)) || !mc.pData) return;
    memcpy(mc.pData, &c, sizeof c);
    G.ctx->lpVtbl->Unmap(G.ctx, (ID3D11Resource *)G.cb, 0);

    G.ctx->lpVtbl->PSSetShaderResources(G.ctx, 0, 1, &srv);
    G.ctx->lpVtbl->Draw(G.ctx, 6, 0);
    G.draws_this_frame++;
}

void ngb_gfx_rect(float x, float y, float w, float h, DWORD argb)
{
    quad(G.white_srv, x, y, w, h, argb, 0, 0);
}

void ngb_gfx_grad(float x, float y, float w, float h, DWORD top, DWORD bottom)
{
    quad(G.white_srv, x, y, w, h, top, 1, bottom);
}

float ngb_gfx_text_w(const wchar_t *s, float px, int weight)
{
    if (!s || !*s) return 0;
    if (!gdi_prepare(16, 16)) return 0;
    HFONT f = gdi_font((int)(px + 0.5f), weight);
    if (!f) return 0;
    HGDIOBJ old = SelectObject(s_memdc, f);
    SIZE sz = { 0, 0 };
    GetTextExtentPoint32W(s_memdc, s, (int)wcslen(s), &sz);
    SelectObject(s_memdc, old);
    return (float)sz.cx;
}

float ngb_gfx_text(const wchar_t *s, float x, float y, float px, DWORD argb,
                   int weight, int align)
{
    if (!s || !*s || px < 4) return 0;
    int ipx = (int)(px + 0.5f);
    text_ent *e = cache_lookup(s, ipx, weight);
    if (!e) e = cache_add(s, ipx, weight);
    if (!e) return 0;

    float tw = (float)e->w - 4.0f;       /* 2px padding each side */
    float th = (float)e->h - 4.0f;
    float dx = x;
    if (align == 1) dx = x - tw * 0.5f;
    else if (align == 2) dx = x - tw;
    /* the 2px padding is inside the quad, so shift by it */
    quad(e->srv, dx - 2.0f, y - 2.0f, (float)e->w, (float)e->h, argb, 0, 0);
    return tw;
}

/* --------------------------------------------------------------- helpers */
wchar_t *ngb_wide(const char *utf8, wchar_t *buf, int cap)
{
    if (!buf || cap <= 0) return buf;
    buf[0] = 0;
    if (!utf8) return buf;
    /* state.json strings are UTF-8; names may carry accents */
    int n = MultiByteToWideChar(CP_UTF8, 0, utf8, -1, buf, cap);
    if (n <= 0) {
        buf[0] = 0;
        MultiByteToWideChar(CP_ACP, 0, utf8, -1, buf, cap);
    }
    buf[cap - 1] = 0;
    return buf;
}
