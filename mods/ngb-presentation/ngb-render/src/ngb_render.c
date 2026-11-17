/* NGB_Render.dll - entry points, hooks, state polling, hotkeys, safety.
 *
 * Loaded by the Sider module (NGB_Presentation.lua) with LoadLibraryA from
 * inside the game process, then called as:
 *     NGB_Start("state_file=...;log_file=...;enabled=1;...")
 *     NGB_GetState()  -> "key=value;key=value"
 *
 * It hooks IDXGISwapChain::Present and ResizeBuffers with MinHook. Present is
 * where the cards are drawn, which is why they appear in exclusive fullscreen,
 * borderless and windowed, focused or not: there is no second window.
 *
 * Safety rules, in order of priority:
 *   1. never crash the game;
 *   2. if anything goes wrong, unhook and say so in ngb-dll.log;
 *   3. never touch saves, EDIT data or game files (we only read state.json and
 *      write render.txt / the log next to it).
 */
#include "ngb.h"
#include "ngb_plan.h"
#include "MinHook.h"
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <d3d11.h>
#include <dxgi.h>
#include <dxgi1_2.h>   /* IDXGIFactory2 / DXGI_SWAP_CHAIN_DESC1 (factory route) */

ngb_cfg_t   g_cfg;
volatile LONG g_dead = 0;
volatile LONG g_enabled = 1;

/* ------------------------------------------------------------------ state */
static CRITICAL_SECTION s_state_lock;
static int      s_state_lock_ok;
static ngb_state_t s_state;           /* guarded by s_state_lock */
static volatile LONG s_state_valid = 0;
static HANDLE   s_poll_thread = NULL;
static volatile LONG s_stop_poll = 0;

/* ------------------------------------------------------------------ hooks */
typedef HRESULT (STDMETHODCALLTYPE *Present_t)(IDXGISwapChain *, UINT, UINT);
typedef HRESULT (STDMETHODCALLTYPE *ResizeBuffers_t)(IDXGISwapChain *, UINT, UINT,
                                                     UINT, DXGI_FORMAT, UINT);
static Present_t      s_present_orig = NULL;
static ResizeBuffers_t s_resize_orig = NULL;
static void         **s_present_target = NULL;   /* vtbl slot, for removal */
static void         **s_resize_target = NULL;
static volatile LONG  s_hooked = 0;
static volatile LONG  s_in_present = 0;
static volatile LONG  s_frames = 0;
static volatile LONG  s_present_faults = 0;
static volatile LONG  s_debug_on = 0;
static volatile LONG  s_demo_until = 0;      /* GetTickCount() while demo shows */
static volatile LONG  s_demo_mode = 0;

/* hook installation plan (see "Finding the swapchain" below); the schedule and
 * the state names are in src/ngb_plan.h, which tests/plan_test.c proves */
static volatile LONG s_plan = NGB_PLAN_NONE;
static volatile LONG s_attempts = 0;
static volatile LONG s_hr_hw = 0;
static volatile LONG s_hr_warp = 0;
static volatile LONG s_factory_ready = 0;
static volatile LONG s_mh_ok = 0;
static volatile LONG s_probe_budget = NGB_PROBE_BUDGET;
static ULONGLONG     s_next_hook_try = 0;
static int hook_attempt(void);

/* swapchain / window report */
static volatile LONG  s_bb_w = 0, s_bb_h = 0;
static HWND           s_hwnd = NULL;
static ULONGLONG      s_last_report = 0;
static ULONGLONG      s_last_hotkey_poll = 0;

/* ---------------------------------------------------------------- logging */
static char s_log_file[MAX_PATH];
static CRITICAL_SECTION s_log_lock;
static int  s_log_lock_ok;

const char *ngb_log_path(void) { return s_log_file; }

void ngb_log(const char *fmt, ...)
{
    char line[1024];
    va_list ap;
    va_start(ap, fmt);
    int n = vsnprintf(line, sizeof line - 2, fmt, ap);
    va_end(ap);
    if (n < 0) return;
    if (n > (int)sizeof line - 3) n = (int)sizeof line - 3;
    line[n++] = '\n';
    line[n] = 0;

    if (g_cfg.debug) {
        OutputDebugStringA("[NGB] ");
        OutputDebugStringA(line);
    }
    if (!s_log_file[0]) return;
    if (s_log_lock_ok) EnterCriticalSection(&s_log_lock);
    HANDLE f = CreateFileA(s_log_file, FILE_APPEND_DATA,
                           FILE_SHARE_READ | FILE_SHARE_WRITE, NULL,
                           OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (f != INVALID_HANDLE_VALUE) {
        DWORD wrote = 0;
        /* keep the log from growing without bound across sessions */
        LARGE_INTEGER sz;
        if (GetFileSizeEx(f, &sz) && sz.QuadPart > (8 * 1024 * 1024)) {
            SetFilePointer(f, 0, NULL, FILE_BEGIN);
            SetEndOfFile(f);
            const char *mark = "=== log truncated (8 MB) ===\n";
            WriteFile(f, mark, (DWORD)strlen(mark), &wrote, NULL);
        }
        SetFilePointer(f, 0, NULL, FILE_END);
        WriteFile(f, line, (DWORD)n, &wrote, NULL);
        CloseHandle(f);
    }
    if (s_log_lock_ok) LeaveCriticalSection(&s_log_lock);
}

static char s_once_keys[32][32];
static int  s_once_n;
void ngb_log_once(const char *key, const char *fmt, ...)
{
    for (int i = 0; i < s_once_n; i++)
        if (!strcmp(s_once_keys[i], key)) return;
    if (s_once_n < 32) {
        strncpy(s_once_keys[s_once_n], key, 31);
        s_once_keys[s_once_n][31] = 0;
        s_once_n++;
    }
    char buf[900];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof buf, fmt, ap);
    va_end(ap);
    ngb_log("%s", buf);
}

/* --------------------------------------------------------------- helpers */
static void mkdir_for(const char *path)
{
    char dir[MAX_PATH];
    strncpy(dir, path, MAX_PATH - 1);
    dir[MAX_PATH - 1] = 0;
    for (char *p = dir + 3; *p; p++) {
        if (*p == '\\' || *p == '/') {
            char save = *p;
            *p = 0;
            CreateDirectoryA(dir, NULL);
            *p = save;
        }
    }
}

static void write_report(void)
{
    if (!g_cfg.dir[0]) return;
    char path[MAX_PATH];
    snprintf(path, sizeof path, "%srender.txt", g_cfg.dir);
    mkdir_for(path);
    HANDLE f = CreateFileA(path, GENERIC_WRITE, FILE_SHARE_READ, NULL,
                           CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (f == INVALID_HANDLE_VALUE) return;
    char buf[512];
    int n = snprintf(buf, sizeof buf,
                     "version=%s\nhwnd=0x%llX\nbackbuffer=%dx%d\nfps=%d\nframes=%d\n"
                     "enabled=%d\nfaults=%d\nstate_age_ms=%d\nlog=%s\n",
                     NGB_VERSION, (unsigned long long)(uintptr_t)s_hwnd,
                     (int)s_bb_w, (int)s_bb_h, 0, (int)s_frames,
                     g_enabled ? 1 : 0, (int)s_present_faults,
                     ngb_state_age_ms(), s_log_file);
    DWORD wrote = 0;
    WriteFile(f, buf, (DWORD)n, &wrote, NULL);
    CloseHandle(f);
}

/* --------------------------------------------------------------- state IO */
/* write time of state.json, in ms since 1601 (see ngb_state_age_ms) */
static ULONGLONG s_file_stamp_ms;
static int       s_file_stamp_ok;

static int read_whole_file(const char *path, char **out)
{
    *out = NULL;
    HANDLE f = CreateFileA(path, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE |
                           FILE_SHARE_DELETE, NULL, OPEN_EXISTING,
                           FILE_ATTRIBUTE_NORMAL, NULL);
    if (f == INVALID_HANDLE_VALUE) return 0;
    LARGE_INTEGER sz;
    if (!GetFileSizeEx(f, &sz) || sz.QuadPart <= 0 || sz.QuadPart > (4 << 20)) {
        CloseHandle(f);
        return 0;
    }
    FILETIME ft;
    if (GetFileTime(f, NULL, NULL, &ft)) {
        ULARGE_INTEGER u;
        u.LowPart = ft.dwLowDateTime;
        u.HighPart = ft.dwHighDateTime;
        /* 100 ns units since 1601 -> ms since 1601 */
        s_file_stamp_ms = (ULONGLONG)(u.QuadPart / 10000ULL);
        s_file_stamp_ok = 1;
    }
    char *buf = (char *)malloc((size_t)sz.QuadPart + 1);
    if (!buf) { CloseHandle(f); return 0; }
    DWORD got = 0;
    if (!ReadFile(f, buf, (DWORD)sz.QuadPart, &got, NULL)) {
        free(buf);
        CloseHandle(f);
        return 0;
    }
    buf[got] = 0;
    CloseHandle(f);
    *out = buf;
    return 1;
}

static void parse_state(const char *root, ngb_state_t *st)
{
    memset(st, 0, sizeof *st);
    st->schema = ngb_json_int(root, "v", 0);

    ngb_json_str(root, "match.home.abbr", st->home_abbr, sizeof st->home_abbr, "");
    ngb_json_str(root, "match.away.abbr", st->away_abbr, sizeof st->away_abbr, "");
    ngb_json_str(root, "match.home.name", st->home_name, sizeof st->home_name, "");
    ngb_json_str(root, "match.away.name", st->away_name, sizeof st->away_name, "");
    st->live = ngb_json_bool(root, "match.live", 0);
    st->home_score = ngb_json_int(root, "match.home.score", 0);
    st->away_score = ngb_json_int(root, "match.away.score", 0);
    ngb_json_str(root, "match.clock", st->clock, sizeof st->clock, "");

    st->style = ngb_json_int(root, "hud.style", 0);
    st->master = ngb_json_bool(root, "hud.master", 1);
    st->scorebug = ngb_json_bool(root, "hud.scorebug", 1);
    st->analysis = ngb_json_bool(root, "hud.analysis", 1);
    {
        char units[16];
        ngb_json_str(root, "hud.units", units, sizeof units, "metric");
        st->units_metric = !strcmp(units, "metric");
    }
    ngb_json_str(root, "hud.credit", st->credit, sizeof st->credit, "");
    ngb_json_str(root, "hud.author", st->author, sizeof st->author, "");
    ngb_json_str(root, "hud.toast.text", st->toast, sizeof st->toast, "");

    const char *ev = ngb_json_path(root, "event");
    st->has_event = ev != NULL;
    if (st->has_event) {
        st->ev_id = ngb_json_int(root, "event.id", 0);
        ngb_json_str(root, "event.kind", st->ev_kind, sizeof st->ev_kind, "");
        ngb_json_str(root, "event.side", st->ev_side, sizeof st->ev_side, "");
        st->ev_minute = ngb_json_int(root, "event.minute", 0);
        st->ev_tally = ngb_json_int(root, "event.tally", 0);
        st->ev_player_known = ngb_json_bool(root, "event.player_known", 0);
        ngb_json_str(root, "event.player.name", st->ev_name, sizeof st->ev_name, "");
        ngb_json_str(root, "event.player.shirt", st->ev_shirt, sizeof st->ev_shirt, "");
        ngb_json_str(root, "event.team.abbr", st->ev_team, sizeof st->ev_team, "");
        ngb_json_str(root, "event.detail", st->ev_detail, sizeof st->ev_detail, "goal");
        ngb_json_str(root, "event.score_line", st->ev_score_line, sizeof st->ev_score_line, "");
        ngb_json_str(root, "event.result", st->ev_result, sizeof st->ev_result, "");
        ngb_json_str(root, "event.milestone.label", st->ev_milestone,
                     sizeof st->ev_milestone, "");
        st->ev_remaining = ngb_json_num(root, "event.remaining", 0);
        st->ev_duration = ngb_json_num(root, "event.duration", 0);

        const char *sh = ngb_json_path(root, "event.shot");
        st->has_shot = sh != NULL;
        if (st->has_shot) {
            st->sh_speed_kmh = ngb_json_num(root, "event.shot.speed_kmh", 0);
            st->sh_speed_mph = ngb_json_num(root, "event.shot.speed_mph", 0);
            st->sh_dist_m = ngb_json_num(root, "event.shot.distance_m", 0);
            st->sh_dist_yd = ngb_json_num(root, "event.shot.distance_yd", 0);
            st->sh_xg = ngb_json_num(root, "event.shot.xg", 0);
            st->sh_angle = ngb_json_num(root, "event.shot.angle_deg", 0);
            st->sh_apex_m = ngb_json_num(root, "event.shot.apex_m", 0);
            st->sh_hang = ngb_json_num(root, "event.shot.hang_s", 0);
            ngb_json_str(root, "event.shot.outcome", st->sh_outcome,
                         sizeof st->sh_outcome, "");
            ngb_json_str(root, "event.shot.origin_source", st->sh_origin,
                         sizeof st->sh_origin, "");
            ngb_json_str(root, "event.shot.body", st->sh_body, sizeof st->sh_body, "");
        }

        /* stats are only present when the Lua side validated the table */
        const char *stats = ngb_json_path(root, "event.stats");
        if (stats) {
            st->has_stats = 1;
            st->st_shots = ngb_json_int(root, "event.stats.shots", 0);
            st->st_on_target = ngb_json_int(root, "event.stats.on_target", 0);
            st->st_goals = ngb_json_int(root, "event.stats.goals", 0);
            st->st_assists = ngb_json_int(root, "event.stats.assists", 0);
            st->st_minutes = ngb_json_int(root, "event.player.minutes", 0);
        }
    }

    st->state_seq = ngb_json_int(root, "seq", 0);
    ngb_json_str(root, "diag.renderer", st->renderer_state, sizeof st->renderer_state, "");
    ngb_json_str(root, "version", st->module_version, sizeof st->module_version, "");
    st->read_tick = GetTickCount64();
    st->valid = 1;
}

void ngb_state_refresh(void)
{
    if (!g_cfg.state_file[0]) return;
    char *text = NULL;
    if (!read_whole_file(g_cfg.state_file, &text)) return;
    if (strlen(text) < 8) { free(text); return; }

    ngb_state_t st;
    parse_state(text, &st);
    free(text);

    if (s_state_lock_ok) EnterCriticalSection(&s_state_lock);
    memcpy(&s_state, &st, sizeof st);
    if (s_state_lock_ok) LeaveCriticalSection(&s_state_lock);
    InterlockedExchange(&s_state_valid, 1);
}

void ngb_state_get(ngb_state_t *out)
{
    if (!out) return;
    memset(out, 0, sizeof *out);
    if (s_state_lock_ok) EnterCriticalSection(&s_state_lock);
    memcpy(out, &s_state, sizeof *out);
    if (s_state_lock_ok) LeaveCriticalSection(&s_state_lock);
}

/* Age of the data, measured from the *file's* last write - not from when we
 * read it. A module that stopped writing (game closed, module error) must make
 * the cards disappear rather than freeze the last score line on screen. */
int ngb_state_age_ms(void)
{
    ngb_state_t st;
    ngb_state_get(&st);
    if (!st.valid || !s_file_stamp_ok) return -1;

    FILETIME now_ft;
    GetSystemTimeAsFileTime(&now_ft);
    ULARGE_INTEGER now;
    now.LowPart = now_ft.dwLowDateTime;
    now.HighPart = now_ft.dwHighDateTime;
    ULONGLONG now_ms = (ULONGLONG)(now.QuadPart / 10000ULL);
    if (now_ms < s_file_stamp_ms) return 0;
    ULONGLONG age = now_ms - s_file_stamp_ms;
    if (age > 600000ULL) age = 600000ULL;
    return (int)age;
}

/* Poll thread: keeps file IO off the render thread. A 100 ms cadence is well
 * inside the 10 Hz the Lua side writes at, and a missed read costs nothing
 * because the previous state stays valid. */
static DWORD WINAPI poll_thread(LPVOID param)
{
    (void)param;
    while (!InterlockedCompareExchange(&s_stop_poll, 0, 0)) {
        __try {
            ngb_state_refresh();
            ULONGLONG now = GetTickCount64();
            if (!InterlockedCompareExchange(&s_hooked, 1, 1)
                    && now >= s_next_hook_try) {
                /* the wait comes from ngb_plan.h, so the schedule is tested */
                LONG n = InterlockedCompareExchange(&s_attempts, 0, 0);
                s_next_hook_try = now + ngb_hook_wait_ms((long)n);
                hook_attempt();
            }
            if (now - s_last_report >= 1000) {
                s_last_report = now;
                write_report();
            }
        } __except (EXCEPTION_EXECUTE_HANDLER) {
            ngb_log("poll thread caught an exception - continuing");
        }
        for (int i = 0; i < 10 && !InterlockedCompareExchange(&s_stop_poll, 0, 0); i++)
            Sleep(10);
    }
    return 0;
}

/* ------------------------------------------------------------ hotkeys */
static void poll_hotkeys(void)
{
    ULONGLONG now = GetTickCount64();
    if (now - s_last_hotkey_poll < 40) return;
    s_last_hotkey_poll = now;

    if (g_cfg.hk_kill > 0 && (GetAsyncKeyState(g_cfg.hk_kill) & 0x8000)) {
        LONG v = InterlockedExchange(&g_enabled, g_enabled ? 0 : 1);
        ngb_log("kill-switch hotkey (VK 0x%02X): renderer %s", g_cfg.hk_kill,
                v ? "ENABLED" : "DISABLED - the game is untouched, cards are off");
        write_report();
        Sleep(250);
    }
    if (g_cfg.hk_selftest > 0 && (GetAsyncKeyState(g_cfg.hk_selftest) & 0x8000)) {
        InterlockedExchange(&s_demo_mode, 0);
        InterlockedExchange(&s_demo_until, (LONG)GetTickCount() + 6000);
        ngb_log("self-test hotkey (VK 0x%02X): drawing a DEMO card through the real path",
                g_cfg.hk_selftest);
        Sleep(250);
    }
    if (g_cfg.hk_diag > 0 && (GetAsyncKeyState(g_cfg.hk_diag) & 0x8000)) {
        InterlockedExchange(&s_demo_mode, 1);
        InterlockedExchange(&s_demo_until, (LONG)GetTickCount() + 8000);
        ngb_log("diagnostics hotkey (VK 0x%02X): drawing the renderer diagnostics strip",
                g_cfg.hk_diag);
        Sleep(250);
    }
}

/* ------------------------------------------------------------- drawing */
static void draw_for(IDXGISwapChain *sc)
{
    if (!g_enabled || g_dead) return;
    if (!ngb_gfx_begin(sc)) return;

    ngb_state_t st;
    ngb_state_get(&st);

    float w = (float)ngb_gfx_width();
    float h = (float)ngb_gfx_height();

    LONG demo = s_demo_until;
    if (demo && (LONG)(GetTickCount() - (ULONG)demo) < 0) {
        ngb_draw_demo(w, h, (int)s_demo_mode);
    } else if (demo) {
        InterlockedExchange(&s_demo_until, 0);
    }

    if (st.valid) {
        int age = ngb_state_age_ms();
        /* a state file that stopped updating means the game is not in a match
         * or the module unloaded: draw nothing rather than freeze the last
         * score line on screen */
        if (age >= 0 && age < 3000) ngb_draw_frame(&st, w, h);
    }

    ngb_gfx_end();
}

/* ------------------------------------------------------------- the hooks */
static HRESULT STDMETHODCALLTYPE present_hook(IDXGISwapChain *sc, UINT sync, UINT flags)
{
    if (InterlockedCompareExchange(&s_in_present, 1, 0) != 0) {
        /* re-entered (a second Present from inside our own draw): pass through */
        return s_present_orig(sc, sync, flags);
    }

    /* The SEH frame is real hardware SEH (clang/MSVC __try). If the draw path
     * faults, the game never sees it: we log, mark the renderer dead, and the
     * Present call returns exactly as the game expects. */
    __try {
        InterlockedIncrement(&s_frames);
        poll_hotkeys();
        draw_for(sc);
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        InterlockedIncrement(&s_present_faults);
        if (InterlockedExchange(&g_dead, 1) == 0) {
            ngb_log("FATAL: exception 0x%08lX inside the Present hook. "
                    "Renderer disabled, game left running.",
                    (unsigned long)GetExceptionCode());
            write_report();
        }
    }

    InterlockedExchange(&s_in_present, 0);
    return s_present_orig(sc, sync, flags);
}

static void report_swapchain(IDXGISwapChain *sc)
{
    DXGI_SWAP_CHAIN_DESC d;
    if (FAILED(sc->lpVtbl->GetDesc(sc, &d))) return;
    if (d.BufferDesc.Width)  InterlockedExchange(&s_bb_w, (LONG)d.BufferDesc.Width);
    if (d.BufferDesc.Height) InterlockedExchange(&s_bb_h, (LONG)d.BufferDesc.Height);
    if (d.OutputWindow) s_hwnd = d.OutputWindow;
}

static HRESULT STDMETHODCALLTYPE resize_hook(IDXGISwapChain *sc, UINT count, UINT w,
                                             UINT h, DXGI_FORMAT fmt, UINT flags)
{
    /* Release every size-dependent object *before* the buffers change, then
     * rebuild on the next Present. Skipping this is the classic cause of a
     * black screen after an alt-tab or a resolution change. */
    if (ngb_gfx_ready()) ngb_gfx_shutdown_keep_hook();
    HRESULT hr = s_resize_orig(sc, count, w, h, fmt, flags);
    if (w && h) {
        InterlockedExchange(&s_bb_w, (LONG)w);
        InterlockedExchange(&s_bb_h, (LONG)h);
    }
    ngb_log("ResizeBuffers(%ux%u) -> 0x%08lX", w, h, (unsigned long)hr);
    return hr;
}

/* ---------------------------------------------------------------------------
 *  Finding the swapchain
 *
 *  Two independent routes, because the first one can fail:
 *
 *   1. PROBE - build a throw-away D3D11 device + swapchain and read its vtable.
 *      Cheap when it works. It does NOT always work: called from a Sider module
 *      at start-up this failed on a real machine with "could not create a probe
 *      swapchain", because no D3D device exists in the process yet and the
 *      driver has not been initialised. Retrying later is fine, but it is not
 *      something to bet the whole feature on.
 *
 *   2. FACTORY - hook IDXGIFactory::CreateSwapChain / CreateSwapChainForHwnd and
 *      wait for the GAME to create its own swapchain. IDXGI factory vtables are
 *      shared per dxgi.dll, so hooking one instance's vtable catches every
 *      factory in the process - including the ones the game already made and
 *      the internal one behind D3D11CreateDeviceAndSwapChain. No device of our
 *      own is needed, which is exactly why it works when the probe does not.
 *
 *  The two are tried in order and retried in the background, so "not yet" is
 *  never reported as "never". The schedule and the state names live in
 *  src/ngb_plan.h so that tests/plan_test.c can prove them without Windows.
 * ------------------------------------------------------------------------- */

/* pointers for the factory detours */
typedef HRESULT (STDMETHODCALLTYPE *CreateSwapChain_t)(IDXGIFactory *, IUnknown *,
                                                       DXGI_SWAP_CHAIN_DESC *,
                                                       IDXGISwapChain **);
typedef HRESULT (STDMETHODCALLTYPE *CreateSwapChainForHwnd_t)(
        IDXGIFactory2 *, IUnknown *, HWND, const DXGI_SWAP_CHAIN_DESC1 *,
        const DXGI_SWAP_CHAIN_FULLSCREEN_DESC *, IDXGIOutput *, IDXGISwapChain1 **);
static CreateSwapChain_t          s_create_orig = NULL;
static CreateSwapChainForHwnd_t   s_create_hwnd_orig = NULL;
static void                     **s_create_target = NULL;
static void                     **s_create_hwnd_target = NULL;

/* Is this address really inside that module? Used to refuse a vtable slot that
 * is not what we think it is - one wrong index would hook an arbitrary
 * function, and that is a crash, not a missing card. */
static int in_module(HMODULE mod, const void *p)
{
    if (!mod || !p) return 0;
    IMAGE_DOS_HEADER *dos = (IMAGE_DOS_HEADER *)mod;
    if (dos->e_magic != IMAGE_DOS_SIGNATURE) return 0;
    IMAGE_NT_HEADERS *nt = (IMAGE_NT_HEADERS *)((BYTE *)mod + dos->e_lfanew);
    if (nt->Signature != IMAGE_NT_SIGNATURE) return 0;
    const BYTE *base = (const BYTE *)mod;
    const BYTE *end = base + nt->OptionalHeader.SizeOfImage;
    const BYTE *q = (const BYTE *)p;
    return q >= base && q < end;
}

static int ensure_minhook(void)
{
    if (InterlockedCompareExchange(&s_mh_ok, 1, 1)) return 1;
    MH_STATUS st = MH_Initialize();
    if (st != MH_OK) {
        ngb_log("MinHook initialisation failed (status %d) - cannot hook anything",
                (int)st);
        return 0;
    }
    InterlockedExchange(&s_mh_ok, 1);
    return 1;
}

/* Hook one swapchain's vtable. Safe to call when already hooked. */
static int hook_swapchain_vtbl(void **present, void **resize, const char *why)
{
    if (InterlockedCompareExchange(&s_hooked, 1, 1)) return 1;
    if (!present) return 0;
    if (!ensure_minhook()) return 0;

    s_present_target = present;
    s_resize_target = resize;

    if (MH_CreateHook((LPVOID)present, (LPVOID)present_hook,
                      (LPVOID *)&s_present_orig) != MH_OK) {
        ngb_log("MH_CreateHook(Present) failed (found via %s)", why);
        return 0;
    }
    if (resize && MH_CreateHook((LPVOID)resize, (LPVOID)resize_hook,
                                (LPVOID *)&s_resize_orig) != MH_OK)
        ngb_log("MH_CreateHook(ResizeBuffers) failed - size changes will blank "
                "the cards for a frame instead of crashing");
    if (MH_EnableHook(MH_ALL_HOOKS) != MH_OK) {
        ngb_log("MH_EnableHook failed (found via %s)", why);
        return 0;
    }
    InterlockedExchange(&s_hooked, 1);
    InterlockedExchange(&s_plan, NGB_PLAN_HOOKED);
    ngb_log("hooks installed via %s: Present=%p ResizeBuffers=%p", why,
            (void *)present, (void *)resize);
    return 1;
}

/* Route 1: a probe device. Returns 0 and reports the HRESULT when it fails. */
static int probe_vtbl(D3D_DRIVER_TYPE driver, void ***present, void ***resize,
                      HRESULT *out_hr)
{
    *present = NULL;
    *resize = NULL;
    if (out_hr) *out_hr = S_OK;

    DXGI_SWAP_CHAIN_DESC sd;
    ZeroMemory(&sd, sizeof sd);
    sd.BufferCount = 2;
    sd.BufferDesc.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
    sd.BufferDesc.Width = 8;
    sd.BufferDesc.Height = 8;
    sd.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
    /* A private, never-shown window. Using GetForegroundWindow() here would
     * create a swapchain on whatever the player happens to have in front -
     * possibly the game itself - which is a good way to break its
     * presentation. This window is destroyed again before we return. */
    HWND probe = CreateWindowExA(WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE, "STATIC",
                                 "ngb-probe", WS_POPUP, 0, 0, 8, 8, NULL, NULL,
                                 NULL, NULL);
    if (!probe) {
        DWORD err = GetLastError();
        if (out_hr) *out_hr = HRESULT_FROM_WIN32(err);
        ngb_log("probe window could not be created (error %lu)", (unsigned long)err);
        return 0;
    }
    sd.OutputWindow = probe;
    sd.SampleDesc.Count = 1;
    sd.Windowed = TRUE;
    sd.SwapEffect = DXGI_SWAP_EFFECT_DISCARD;

    ID3D11Device *dev = NULL;
    ID3D11DeviceContext *ctx = NULL;
    IDXGISwapChain *sc = NULL;
    D3D_FEATURE_LEVEL fl;
    D3D_FEATURE_LEVEL want = D3D_FEATURE_LEVEL_11_0;

    HRESULT hr = D3D11CreateDeviceAndSwapChain(NULL, driver, NULL, 0, &want, 1,
                                               D3D11_SDK_VERSION, &sd, &sc, &dev,
                                               &fl, &ctx);
    DestroyWindow(probe);
    if (FAILED(hr) || !sc) {
        if (out_hr) *out_hr = hr;
        if (ctx) ctx->lpVtbl->Release(ctx);
        if (dev) dev->lpVtbl->Release(dev);
        return 0;
    }

    void **vtbl = *(void ***)sc;
    *present = (void **)vtbl[8];      /* IDXGISwapChain::Present        */
    *resize  = (void **)vtbl[13];     /* IDXGISwapChain::ResizeBuffers  */

    sc->lpVtbl->Release(sc);
    if (ctx) ctx->lpVtbl->Release(ctx);
    if (dev) dev->lpVtbl->Release(dev);
    if (!*present) return 0;
    return 1;
}

/* ---------------------------------------------------------------------------
 *  Route 2: the factory. The game's own swapchain is the one we want anyway.
 * ------------------------------------------------------------------------- */
static void factory_swapchain_seen(IDXGISwapChain *sc)
{
    if (!sc || InterlockedCompareExchange(&s_hooked, 1, 1)) return;
    void **vtbl = *(void ***)sc;
    if (!vtbl) return;
    HMODULE dxgi = GetModuleHandleA("dxgi.dll");
    if (!in_module(dxgi, (void *)vtbl[8])) {
        ngb_log("the game's swapchain vtable is not in dxgi.dll - not hooking");
        return;
    }
    if (hook_swapchain_vtbl((void **)vtbl[8], (void **)vtbl[13],
                            "the game's own swapchain")) {
        /* our job here is done: stop intercepting swapchain creation */
        if (s_create_target) MH_DisableHook((LPVOID)s_create_target);
        if (s_create_hwnd_target) MH_DisableHook((LPVOID)s_create_hwnd_target);
    }
}

static HRESULT STDMETHODCALLTYPE create_swapchain_hook(IDXGIFactory *self,
                                                       IUnknown *device,
                                                       DXGI_SWAP_CHAIN_DESC *desc,
                                                       IDXGISwapChain **out)
{
    HRESULT hr = s_create_orig(self, device, desc, out);
    if (SUCCEEDED(hr) && out && *out) factory_swapchain_seen(*out);
    return hr;
}

static HRESULT STDMETHODCALLTYPE create_swapchain_hwnd_hook(
        IDXGIFactory2 *self, IUnknown *device, HWND hwnd,
        const DXGI_SWAP_CHAIN_DESC1 *desc,
        const DXGI_SWAP_CHAIN_FULLSCREEN_DESC *fs, IDXGIOutput *restrict_to,
        IDXGISwapChain1 **out)
{
    HRESULT hr = s_create_hwnd_orig(self, device, hwnd, desc, fs, restrict_to, out);
    if (SUCCEEDED(hr) && out && *out)
        factory_swapchain_seen((IDXGISwapChain *)*out);
    return hr;
}

static int install_factory_hooks(void)
{
    if (InterlockedCompareExchange(&s_factory_ready, 1, 1)) return 1;
    if (!ensure_minhook()) return 0;

    HMODULE dxgi = GetModuleHandleA("dxgi.dll");
    if (!dxgi) dxgi = LoadLibraryA("dxgi.dll");
    if (!dxgi) {
        ngb_log("dxgi.dll is not loaded - the factory route is not available");
        return 0;
    }

    IDXGIFactory1 *factory = NULL;
    HRESULT hr = CreateDXGIFactory1(&IID_IDXGIFactory1, (void **)&factory);
    if (FAILED(hr) || !factory) {
        ngb_log("CreateDXGIFactory1 failed (0x%08lX) - the factory route is not "
                "available", (unsigned long)hr);
        return 0;
    }

    void **vtbl = *(void ***)factory;
    void **create      = (void **)vtbl[10];   /* CreateSwapChain        */
    void **create_hwnd = (void **)vtbl[11];   /* CreateSwapChainForHwnd */

    /* refuse anything that is not where it should be */
    if (!in_module(dxgi, (void *)create) || !in_module(dxgi, (void *)create_hwnd)) {
        ngb_log("the factory vtable does not look like dxgi.dll (10=%p 11=%p) - "
                "not hooking it", (void *)create, (void *)create_hwnd);
        factory->lpVtbl->Release(factory);
        return 0;
    }

    if (MH_CreateHook((LPVOID)create, (LPVOID)create_swapchain_hook,
                      (LPVOID *)&s_create_orig) != MH_OK) {
        ngb_log("MH_CreateHook(CreateSwapChain) failed");
        factory->lpVtbl->Release(factory);
        return 0;
    }
    s_create_target = create;
    if (MH_CreateHook((LPVOID)create_hwnd, (LPVOID)create_swapchain_hwnd_hook,
                      (LPVOID *)&s_create_hwnd_orig) != MH_OK)
        ngb_log("MH_CreateHook(CreateSwapChainForHwnd) failed - only the plain "
                "path will be watched");
    else
        s_create_hwnd_target = create_hwnd;
    if (MH_EnableHook((LPVOID)create) != MH_OK) {
        ngb_log("MH_EnableHook(CreateSwapChain) failed");
        factory->lpVtbl->Release(factory);
        return 0;
    }
    if (s_create_hwnd_target) MH_EnableHook((LPVOID)create_hwnd);
    factory->lpVtbl->Release(factory);

    InterlockedExchange(&s_factory_ready, 1);
    InterlockedExchange(&s_plan, NGB_PLAN_FACTORY);
    ngb_log("waiting for the game to create its swapchain (factory hook is in "
            "place) - the cards hook themselves when it does");
    return 1;
}

/* One attempt. Returns 1 = hooked, 2 = pending (factory is waiting), 0 = not
 * yet (will be retried). */
static int hook_attempt(void)
{
    if (InterlockedCompareExchange(&s_hooked, 1, 1)) return 1;
    LONG n = InterlockedIncrement(&s_attempts);

    if (InterlockedCompareExchange(&s_probe_budget, 0, 0) > 0) {
        void **present = NULL, **resize = NULL;
        HRESULT hr = S_OK;
        InterlockedExchange(&s_plan, NGB_PLAN_PROBE_HW);
        if (probe_vtbl(D3D_DRIVER_TYPE_HARDWARE, &present, &resize, &hr)) {
            return hook_swapchain_vtbl(present, resize, "a probe swapchain");
        }
        InterlockedExchange(&s_hr_hw, (LONG)hr);
        ngb_log("probe swapchain (hardware) failed: hr=0x%08lX, trying WARP",
                (unsigned long)hr);

        InterlockedExchange(&s_plan, NGB_PLAN_PROBE_WP);
        if (probe_vtbl(D3D_DRIVER_TYPE_WARP, &present, &resize, &hr)) {
            return hook_swapchain_vtbl(present, resize, "a probe swapchain (WARP)");
        }
        InterlockedExchange(&s_hr_warp, (LONG)hr);
        ngb_log("probe swapchain (WARP) failed: hr=0x%08lX", (unsigned long)hr);
        InterlockedDecrement(&s_probe_budget);
        if (InterlockedCompareExchange(&s_probe_budget, 0, 0) <= 0)
            ngb_log("probe route exhausted after %ld attempts - switching to the "
                    "factory route until the game creates its swapchain", (long)n);
    }

    if (install_factory_hooks()) return 2;

    if (!InterlockedCompareExchange(&s_hooked, 1, 1)) {
        InterlockedExchange(&s_plan, NGB_PLAN_GAVE_UP);
        ngb_log("no route to the swapchain worked - nothing will be drawn. "
                "Send this log; the HRESULTs above say why.");
    }
    return 0;
}

static void remove_hooks(void)
{
    if (s_create_target) MH_DisableHook((LPVOID)s_create_target);
    if (s_create_hwnd_target) MH_DisableHook((LPVOID)s_create_hwnd_target);
    if (!InterlockedCompareExchange(&s_hooked, 0, 1)) return;
    MH_DisableHook(MH_ALL_HOOKS);
    MH_Uninitialize();
    InterlockedExchange(&s_mh_ok, 0);
    ngb_log("hooks removed");
}

/* --------------------------------------------------------------- config */
static void parse_cfg(const char *text)
{
    memset(&g_cfg, 0, sizeof g_cfg);
    g_cfg.enabled = 1;
    g_cfg.hk_selftest = VK_F8;
    g_cfg.hk_diag = VK_F7;
    g_cfg.hk_kill = VK_F12;

    const char *p = text;
    while (p && *p) {
        /* accept ';' and newlines: the Lua module sends ';', a hand-edited
         * config may use lines */
        while (*p == ';' || *p == '\r' || *p == '\n' || *p == ' ') p++;
        const char *eq = strchr(p, '=');
        if (!eq) break;
        const char *end = p;
        while (*end && *end != ';' && *end != '\n' && *end != '\r') end++;
        if (strchr(p, ';') && strchr(p, ';') < end) end = strchr(p, ';');
        int klen = (int)(eq - p);
        int vlen = (int)(end - eq - 1);
        if (vlen < 0) vlen = 0;

        char key[48], val[MAX_PATH * 2];
        if (klen < (int)sizeof key) {
            memcpy(key, p, klen);
            key[klen] = 0;
            if (vlen > (int)sizeof val - 1) vlen = (int)sizeof val - 1;
            memcpy(val, eq + 1, vlen);
            val[vlen] = 0;

            if (!strcmp(key, "state_file")) { strncpy(g_cfg.state_file, val, MAX_PATH - 1); }
            else if (!strcmp(key, "log_file")) { strncpy(g_cfg.log_file, val, MAX_PATH - 1); }
            else if (!strcmp(key, "dir")) { strncpy(g_cfg.dir, val, MAX_PATH - 1); }
            else if (!strcmp(key, "debug")) g_cfg.debug = atoi(val);
            else if (!strcmp(key, "enabled")) g_cfg.enabled = atoi(val);
            else if (!strcmp(key, "hotkey_selftest")) g_cfg.hk_selftest = strtol(val, NULL, 0);
            else if (!strcmp(key, "hotkey_diag")) g_cfg.hk_diag = strtol(val, NULL, 0);
            else if (!strcmp(key, "hotkey_kill")) g_cfg.hk_kill = strtol(val, NULL, 0);
        }
        p = end;
    }
    strncpy(s_log_file, g_cfg.log_file, MAX_PATH - 1);
    InterlockedExchange(&g_enabled, g_cfg.enabled ? 1 : 0);
}

/* ------------------------------------------------------------- exports */
__declspec(dllexport) const char *NGB_Version(void)
{
    return NGB_VERSION;
}

__declspec(dllexport) int NGB_Start(const char *config)
{
    static volatile LONG s_started = 0;
    if (InterlockedCompareExchange(&s_started, 1, 0) != 0) {
        /* already started in this process: harmless, do not hook twice */
        ngb_log("NGB_Start called again - already running, ignoring");
        return 1;
    }
    InitializeCriticalSection(&s_log_lock);
    s_log_lock_ok = 1;
    InitializeCriticalSection(&s_state_lock);
    s_state_lock_ok = 1;

    parse_cfg(config ? config : "");
    mkdir_for(s_log_file);
    ngb_log("=== NGB_Render %s starting (pid %lu) ===", NGB_VERSION,
            (unsigned long)GetCurrentProcessId());
    ngb_log("state file: %s", g_cfg.state_file[0] ? g_cfg.state_file : "(not set)");
    ngb_log("enabled=%d hotkeys: selftest=0x%02X diag=0x%02X kill=0x%02X",
            g_cfg.enabled, g_cfg.hk_selftest, g_cfg.hk_diag, g_cfg.hk_kill);

    if (!g_cfg.enabled) {
        ngb_log("dll_enabled = 0 in the ini: not installing hooks (the module "
                "keeps working, nothing is drawn)");
        return 1;
    }

    /* Read the state file once before hooking, so the first frame drawn is
     * already correct and a broken file is reported up front. */
    ngb_state_refresh();
    if (!InterlockedCompareExchange(&s_state_valid, 1, 1))
        ngb_log("state.json not readable yet - the renderer keeps trying, "
                "and the HUD will appear as soon as a match starts");

    /* One attempt now - it usually succeeds instantly when the game is already
     * up - then the poll thread keeps retrying. Never return 0 here: 0 makes
     * the Lua module fall back to the C# window, which is not what we want.
     * "not hooked yet" is a state, not a failure, and the diagnostics panel
     * shows it as hooks=0 until it resolves. */
    int r = hook_attempt();
    if (r == 1) {
        ngb_log("renderer active: cards are drawn inside the game's own frame "
                "(windowed, borderless and fullscreen, focused or not)");
    } else if (r == 2) {
        ngb_log("renderer waiting: the factory hook is in place, the cards will "
                "appear on the first frame after the game creates its swapchain");
    } else {
        ngb_log("renderer not hooked yet (plan=%s) - retrying in the background; "
                "the game runs normally meanwhile", ngb_plan_name((int)s_plan));
    }

    s_stop_poll = 0;
    s_poll_thread = CreateThread(NULL, 0, poll_thread, NULL, 0, NULL);
    if (!s_poll_thread)
        ngb_log("state poll thread could not start - state is read on the "
                "render thread instead (slower, still safe)");
    return 1;
}

__declspec(dllexport) const char *NGB_GetState(void)
{
    static char buf[512];
    ngb_state_t st;
    ngb_state_get(&st);
    int age = ngb_state_age_ms();
    snprintf(buf, sizeof buf,
             "version=%s;hooks=%d;enabled=%d;faults=%d;frames=%d;backbuffer=%dx%d;"
             "state_age_ms=%d;state_seq=%d;dead=%d;read=1;query=1;"
             "hook_plan=%s;hook_tries=%ld;hr_hw=0x%08lX;hr_warp=0x%08lX;log=%s",
             NGB_VERSION, (int)s_hooked, g_enabled ? 1 : 0,
             (int)s_present_faults, (int)s_frames, (int)s_bb_w, (int)s_bb_h,
             age, st.state_seq, g_dead ? 1 : 0, ngb_plan_name((int)s_plan),
             (long)s_attempts, (unsigned long)(DWORD)s_hr_hw,
             (unsigned long)(DWORD)s_hr_warp, s_log_file);
    return buf;
}

/* ---------------------------------------------------------------------------
 *  Safe memory access for the Lua module.
 *
 *  Sider's own `memory.read` is `ffi.string(addr, len)`: a straight
 *  dereference, so one wrong address is an access violation and the game dies.
 *  ReadProcessMemory on our own process never faults - it returns FALSE and a
 *  partial count instead - and VirtualQuery only describes pages. Exposing both
 *  through this DLL is what makes the module's memory reads crash-proof.
 * ------------------------------------------------------------------------- */
__declspec(dllexport) unsigned int NGB_Read(unsigned long long addr, void *buf,
                                            unsigned int len)
{
    SIZE_T got = 0;
    if (!buf || len == 0 || len > (1u << 20) || addr < 0x10000ULL) return 0;
    if (!ReadProcessMemory(GetCurrentProcess(), (LPCVOID)(uintptr_t)addr, buf,
                           len, &got))
        return (unsigned int)got;          /* partial read: caller checks */
    return (unsigned int)got;
}

__declspec(dllexport) unsigned int NGB_Write(unsigned long long addr, const void *buf,
                                             unsigned int len)
{
    SIZE_T wrote = 0;
    DWORD old = 0;
    if (!buf || len == 0 || len > (1u << 20) || addr < 0x10000ULL) return 0;
    /* only pages the module already decided are legitimate; we still ask for
     * write access explicitly so a read-only page is not a crash */
    VirtualProtect((LPVOID)(uintptr_t)addr, len, PAGE_EXECUTE_READWRITE, &old);
    BOOL ok = WriteProcessMemory(GetCurrentProcess(), (LPVOID)(uintptr_t)addr,
                                 buf, len, &wrote);
    VirtualProtect((LPVOID)(uintptr_t)addr, len, old, &old);
    if (!ok) return (unsigned int)wrote;
    return (unsigned int)wrote;
}

__declspec(dllexport) unsigned int NGB_Query(unsigned long long addr,
                                             unsigned long long *base,
                                             unsigned long long *size,
                                             unsigned int *protect)
{
    MEMORY_BASIC_INFORMATION mbi;
    if (!base || !size) return 0;
    if (VirtualQuery((LPCVOID)(uintptr_t)addr, &mbi, sizeof mbi) == 0) {
        *base = addr;
        *size = 0;
        if (protect) *protect = 0;
        return 0;
    }
    *base = (unsigned long long)(uintptr_t)mbi.BaseAddress;
    *size = (unsigned long long)mbi.RegionSize;
    if (protect) *protect = (unsigned int)mbi.Protect;
    return 1;
}

__declspec(dllexport) void NGB_Stop(void)
{
    if (s_poll_thread) {
        InterlockedExchange(&s_stop_poll, 1);
        WaitForSingleObject(s_poll_thread, 1500);
        CloseHandle(s_poll_thread);
        s_poll_thread = NULL;
    }
    remove_hooks();
    ngb_gfx_shutdown();
    ngb_log("renderer stopped");
}

BOOL APIENTRY DllMain(HMODULE mod, DWORD reason, LPVOID reserved)
{
    (void)reserved;
    if (reason == DLL_PROCESS_ATTACH) {
        DisableThreadLibraryCalls(mod);
        s_debug_on = 0;
    }
    return TRUE;
}
