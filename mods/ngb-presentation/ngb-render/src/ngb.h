/* ===========================================================================
 *  NGB_Render - in-game renderer for Next-Gen Football Broadcast Presentation
 *
 *  Draws the broadcast cards inside the game's own D3D11 frame, so they work
 *  in windowed, borderless and exclusive fullscreen, focused or not, at any
 *  resolution. The module (Lua) loads this DLL into the game process and calls
 *  NGB_Start(); the DLL hooks IDXGISwapChain::Present + ResizeBuffers.
 *
 *  It never reads game memory and never writes game/save files. All content
 *  comes from state.json, which the Lua module writes. If anything goes wrong
 *  it unhooks itself, logs to ngb-dll.log and leaves the game alone.
 * ======================================================================== */
#ifndef NGB_H
#define NGB_H

#define WIN32_LEAN_AND_MEAN
#define _CRT_SECURE_NO_WARNINGS
#include <stdint.h>
#include <stddef.h>

#ifdef NGB_HOST_TEST
/* The JSON reader is compiled on the build host so it can be tested against a
 * real state.json. Only the handful of Windows types it mentions are stubbed. */
typedef unsigned long DWORD;
typedef long LONG;
typedef void *HWND;
typedef struct IDXGISwapChain IDXGISwapChain;
typedef uint64_t ULONGLONG;
#ifndef MAX_PATH
#define MAX_PATH 260
#endif
#else
#include <windows.h>
#endif

#define NGB_VERSION   "2.0.1"

/* ---------------------------------------------------------------- logging */
void ngb_log(const char *fmt, ...);
void ngb_log_once(const char *key, const char *fmt, ...);
const char *ngb_log_path(void);

/* -------------------------------------------------------------- settings  */
typedef struct {
    char state_file[MAX_PATH];
    char log_file[MAX_PATH];
    char dir[MAX_PATH];
    int  debug;
    int  enabled;              /* master switch (ini dll_enabled)            */
    int  hk_selftest;          /* VK code, default F8                        */
    int  hk_diag;              /* VK code, default F7                        */
    int  hk_kill;              /* VK code, default F12                       */
    int  load_timeout_ms;
} ngb_cfg_t;

extern ngb_cfg_t g_cfg;
extern volatile LONG g_dead;      /* 1 = renderer disabled itself (fault)    */
extern volatile LONG g_enabled;   /* runtime toggle (kill-switch hotkey)     */

/* ------------------------------------------------------------ json reader */
/* Minimal, allocation-free reader. Only used on state.json, whose schema we
 * own - it is not a general purpose parser. Every accessor is bounds-checked
 * and returns a default instead of faulting. */
const char *ngb_json_path(const char *root, const char *path);
int   ngb_json_str(const char *root, const char *path, char *out, int cap,
                   const char *def);
int   ngb_json_int(const char *root, const char *path, int def);
double ngb_json_num(const char *root, const char *path, double def);
int   ngb_json_bool(const char *root, const char *path, int def);

/* ---------------------------------------------------------- state struct */
typedef struct {
    /* match */
    char home_abbr[16], away_abbr[16], home_name[32], away_name[32];
    int  home_score, away_score, live;
    char clock[16];
    /* hud */
    int  style, units_metric, master, scorebug, analysis;
    char credit[64], author[32];
    /* event */
    int  has_event;
    int  ev_id, ev_minute, ev_tally, ev_player_known;
    char ev_kind[16], ev_side[12];
    char ev_name[64], ev_shirt[8], ev_team[16];
    char ev_detail[24], ev_score_line[32], ev_result[24];
    char ev_milestone[40];
    double ev_remaining, ev_duration;
    /* shot telemetry */
    int  has_shot;
    double sh_speed_kmh, sh_speed_mph, sh_dist_m, sh_dist_yd;
    double sh_xg, sh_angle, sh_apex_m, sh_hang;
    char sh_outcome[24], sh_origin[16], sh_body[24];
    /* per-player stats (only when the Lua side validated them) */
    int  has_stats, st_shots, st_on_target, st_goals, st_assists, st_minutes;
    /* toast */
    char toast[128];
    /* diagnostics */
    int  schema, state_seq;
    char renderer_state[32], module_version[24];
    ULONGLONG read_tick;      /* GetTickCount64() when the file was parsed   */
    int  valid;
} ngb_state_t;

void ngb_state_refresh(void);              /* called by the poll thread      */
void ngb_state_get(ngb_state_t *out);      /* snapshot under the lock        */
int  ngb_state_age_ms(void);

/* --------------------------------------------------------------- graphics */
typedef struct IDXGISwapChain IDXGISwapChain;

int  ngb_gfx_init(void);
void ngb_gfx_shutdown(void);
void ngb_gfx_shutdown_keep_hook(void);
int  ngb_gfx_ready(void);

/* frame: returns 1 when drawing is possible for this swapchain */
int  ngb_gfx_begin(IDXGISwapChain *sc);
void ngb_gfx_end(void);
int  ngb_gfx_frame_ready(void);
int  ngb_gfx_width(void);
int  ngb_gfx_height(void);

void ngb_gfx_rect(float x, float y, float w, float h, DWORD argb);
void ngb_gfx_grad(float x, float y, float w, float h, DWORD top, DWORD bottom);
/* px = cap height in pixels. align: 0 left, 1 centre, 2 right */
float ngb_gfx_text(const wchar_t *s, float x, float y, float px, DWORD argb,
                   int weight, int align);
float ngb_gfx_text_w(const wchar_t *s, float px, int weight);
wchar_t *ngb_wide(const char *utf8, wchar_t *buf, int cap);

/* ------------------------------------------------------------------ cards */
/* Draws the current state at (w,h). scale is derived from the real backbuffer. */
void ngb_draw_frame(const ngb_state_t *st, float w, float h);
void ngb_draw_demo(float w, float h, int mode);   /* self-test / diag strip   */

#endif /* NGB_H */
