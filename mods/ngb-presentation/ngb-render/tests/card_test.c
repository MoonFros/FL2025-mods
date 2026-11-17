/* Host test for the card layout: records every draw call ngb_card.c makes and
 * checks the geometry at real resolutions.
 *
 *   cc -DNGB_HOST_TEST -I src -o card_test tests/card_test.c src/ngb_card.c
 *   ./card_test
 *
 * What it proves: nothing is positioned from a hard-coded 1920x1080, every
 * element stays inside the back buffer at 720p/1080p/1440p/ultrawide/4K, type
 * scales with height, and the "unknown data" paths print the honest label
 * instead of a zero.
 */
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <math.h>
#include <wchar.h>
#include "ngb.h"

/* ------------------------------------------------------------- recording */
typedef struct { float x, y, w, h; DWORD col; int is_text; wchar_t s[160]; float px; } call_t;
static call_t calls[4096];
static int ncalls;
static float cur_w, cur_h;

void ngb_gfx_rect(float x, float y, float w, float h, DWORD argb)
{
    if (ncalls < 4096) {
        call_t *c = &calls[ncalls++];
        memset(c, 0, sizeof *c);
        c->x = x; c->y = y; c->w = w; c->h = h; c->col = argb;
    }
}
void ngb_gfx_grad(float x, float y, float w, float h, DWORD a, DWORD b)
{
    ngb_gfx_rect(x, y, w, h, a);
    (void)b;
}
float ngb_gfx_text(const wchar_t *s, float x, float y, float px, DWORD argb,
                   int weight, int align)
{
    (void)weight;
    float tw = (float)wcslen(s) * px * 0.5f;   /* rough, enough for bounds */
    float dx = x;
    /* mirror the real align handling, otherwise the bounds test would blame
     * the layout for the stub's own sloppiness */
    if (align == 1) dx = x - tw * 0.5f;
    else if (align == 2) dx = x - tw;
    if (ncalls < 4096) {
        call_t *c = &calls[ncalls++];
        memset(c, 0, sizeof *c);
        c->is_text = 1; c->x = dx; c->y = y; c->px = px; c->col = argb;
        wcsncpy(c->s, s, 159);
        c->w = tw;
        c->h = px;
    }
    return tw;
}
float ngb_gfx_text_w(const wchar_t *s, float px, int weight)
{
    (void)weight;
    return (float)wcslen(s) * px * 0.5f;
}
wchar_t *ngb_wide(const char *utf8, wchar_t *buf, int cap)
{
    int i = 0;
    for (; utf8 && utf8[i] && i < cap - 1; i++) buf[i] = (wchar_t)(unsigned char)utf8[i];
    buf[i] = 0;
    return buf;
}
/* the renderer globals the card code does not use, but the linker wants */
int ngb_gfx_width(void) { return (int)cur_w; }
int ngb_gfx_height(void) { return (int)cur_h; }
ngb_cfg_t g_cfg;
volatile LONG g_dead;
volatile LONG g_enabled = 1;
int ngb_state_age_ms(void) { return 42; }
const char *ngb_log_path(void) { return "test.log"; }

/* ---------------------------------------------------------------- checks */
static int fails, checks;
static void ok(int cond, const char *what, const char *detail)
{
    checks++;
    if (!cond) { fails++; printf("FAIL %-46s %s\n", what, detail ? detail : ""); }
    else printf("ok   %-46s %s\n", what, detail ? detail : "");
}

static int have_text(const char *needle)
{
    wchar_t wide[160];
    ngb_wide(needle, wide, 160);
    for (int i = 0; i < ncalls; i++)
        if (calls[i].is_text && wcsstr(calls[i].s, wide)) return 1;
    return 0;
}

static void check_bounds(const char *label)
{
    int bad = 0;
    float minx = 1e9f, miny = 1e9f, maxx = -1e9f, maxy = -1e9f;
    for (int i = 0; i < ncalls; i++) {
        call_t *c = &calls[i];
        if (isnan(c->x) || isnan(c->y) || isnan(c->w) || isnan(c->h)) { bad++; continue; }
        if (c->x < minx) minx = c->x;
        if (c->y < miny) miny = c->y;
        if (c->x + c->w > maxx) maxx = c->x + c->w;
        if (c->y + c->h > maxy) maxy = c->y + c->h;
        /* 1px tolerance for the text texture padding */
        if (c->x < -2 || c->y < -2 || c->x + c->w > cur_w + 2 || c->y + c->h > cur_h + 2)
            bad++;
    }
    char detail[160];
    snprintf(detail, sizeof detail, "%d draws, extent %.0f..%.0f x %.0f..%.0f (screen %.0fx%.0f)",
             ncalls, minx, maxx, miny, maxy, cur_w, cur_h);
    ok(bad == 0 && ncalls > 0, label, detail);
}

static void base_state(ngb_state_t *st)
{
    memset(st, 0, sizeof *st);
    strcpy(st->home_abbr, "ARS");
    strcpy(st->away_abbr, "CHE");
    st->home_score = 2;
    st->away_score = 1;
    strcpy(st->clock, "67:12");
    st->live = 1;
    st->scorebug = 1;
    st->master = 1;
    st->units_metric = 1;
    st->style = 0;
    st->valid = 1;
    st->has_event = 1;
    strcpy(st->ev_kind, "goal");
    strcpy(st->ev_name, "M. RASHFORD");
    strcpy(st->ev_team, "ARS");
    strcpy(st->ev_score_line, "3 - 1");
    strcpy(st->ev_milestone, "HAT-TRICK");
    st->ev_minute = 67;
    st->ev_player_known = 1;
    st->ev_remaining = 8.0;
}

int main(void)
{
    struct { int w, h; const char *label; } res[] = {
        { 1280, 720,  "720p" },
        { 1920, 1080, "1080p" },
        { 2560, 1440, "1440p" },
        { 3440, 1440, "ultrawide 3440x1440" },
        { 3840, 2160, "4K" },
        { 1024, 768,  "4:3 1024x768" },
    };
    ngb_state_t st;

    for (unsigned r = 0; r < sizeof res / sizeof *res; r++) {
        cur_w = (float)res[r].w; cur_h = (float)res[r].h;
        ncalls = 0;
        base_state(&st);
        ngb_draw_frame(&st, cur_w, cur_h);
        check_bounds(res[r].label);
        ok(have_text("GOAL"), "goal card headline", res[r].label);
        ok(have_text("M. RASHFORD"), "real scorer name shown", res[r].label);
        ok(have_text("3 - 1"), "score line shown", res[r].label);
        ok(have_text("67'"), "minute shown", res[r].label);
        ok(have_text("HAT-TRICK"), "milestone badge shown", res[r].label);
        ok(!have_text("SCORER NOT AVAILABLE"), "no placeholder when the name is known", "");
        /* nothing may claim stats when they were not validated */
        ok(!have_text("SHOTS") || have_text("PLAYER DATA UNAVAILABLE"),
           "unvalidated stats never drawn", res[r].label);
    }

    /* type must scale with the back buffer, not be fixed */
    cur_w = 1920; cur_h = 1080; ncalls = 0; base_state(&st);
    ngb_draw_frame(&st, cur_w, cur_h);
    float px1080 = 0;
    for (int i = 0; i < ncalls; i++) if (calls[i].is_text) { px1080 = calls[i].px; break; }
    cur_w = 3840; cur_h = 2160; ncalls = 0;
    ngb_draw_frame(&st, cur_w, cur_h);
    float px2160 = 0;
    for (int i = 0; i < ncalls; i++) if (calls[i].is_text) { px2160 = calls[i].px; break; }
    {
        char d[80];
        snprintf(d, sizeof d, "%.1f px at 1080p, %.1f px at 4K", px1080, px2160);
        ok(px2160 > px1080 * 1.8f, "type scales with the back buffer", d);
    }

    /* unknown scorer: explicit, not invented */
    cur_w = 1920; cur_h = 1080; ncalls = 0; base_state(&st);
    st.ev_player_known = 0;
    strcpy(st.ev_name, "");
    ngb_draw_frame(&st, cur_w, cur_h);
    ok(have_text("SCORER NOT AVAILABLE"), "unknown scorer labelled, not invented", "");

    /* validated stats are drawn; unvalidated ones are replaced by a label */
    ncalls = 0; base_state(&st);
    st.has_stats = 1; st.st_shots = 5; st.st_goals = 3; st.st_assists = 1; st.st_on_target = 4;
    ngb_draw_frame(&st, cur_w, cur_h);
    ok(have_text("5 SHOTS") && have_text("3 GOALS"), "validated stats drawn", "");
    ncalls = 0; base_state(&st); st.has_stats = 0;
    ngb_draw_frame(&st, cur_w, cur_h);
    ok(have_text("PLAYER DATA UNAVAILABLE") && !have_text("0 SHOTS"),
       "no '0 shots / 2 goals' card", "");

    /* no live match -> no score bug over the menus */
    ncalls = 0; base_state(&st); st.live = 0; st.has_event = 0;
    ngb_draw_frame(&st, cur_w, cur_h);
    ok(ncalls == 0, "nothing drawn outside a live match", "");

    /* presentation off draws nothing */
    ncalls = 0; base_state(&st); st.master = 0;
    ngb_draw_frame(&st, cur_w, cur_h);
    ok(ncalls == 0, "master off draws nothing", "");

    /* every event kind must be drawable without touching memory it does not own */
    const char *kinds[] = { "goal", "shot", "motm", "fulltime" };
    for (int k = 0; k < 4; k++) {
        for (unsigned r = 0; r < sizeof res / sizeof res[r]; r++) {
            cur_w = (float)res[r].w; cur_h = (float)res[r].h; ncalls = 0;
            base_state(&st);
            strcpy(st.ev_kind, kinds[k]);
            st.has_shot = 1;
            st.sh_speed_kmh = 112.4; st.sh_speed_mph = 69.8;
            st.sh_dist_m = 24.5; st.sh_dist_yd = 26.8;
            st.sh_xg = 0.37; st.sh_angle = 18.5;
            strcpy(st.sh_outcome, "on_target");
            strcpy(st.sh_origin, "measured");
            ngb_draw_frame(&st, cur_w, cur_h);
            char label[96];
            snprintf(label, sizeof label, "%s card at %s", kinds[k], res[r].label);
            check_bounds(label);
        }
    }

    /* shot card must state where its numbers came from */
    cur_w = 1920; cur_h = 1080; ncalls = 0; base_state(&st);
    strcpy(st.ev_kind, "shot");
    st.has_shot = 1; st.sh_speed_kmh = 112.4; st.sh_dist_m = 24.5;
    st.sh_xg = 0.37; st.sh_angle = 18.5;
    strcpy(st.sh_outcome, "off_target");
    strcpy(st.sh_origin, "estimated");
    ngb_draw_frame(&st, cur_w, cur_h);
    ok(have_text("MODELLED"), "modelled telemetry labelled", "");
    ok(have_text("SHOT OFF TARGET"), "shot outcome shown", "");

    /* the self-test card must be unmistakable */
    for (int mode = 0; mode < 2; mode++) {
        cur_w = 1920; cur_h = 1080; ncalls = 0;
        ngb_draw_demo(cur_w, cur_h, mode);
        check_bounds(mode == 0 ? "self-test card bounds" : "diagnostics strip bounds");
    }
    cur_w = 1920; cur_h = 1080; ncalls = 0;
    ngb_draw_demo(cur_w, cur_h, 0);
    ok(have_text("DEMO") && have_text("NOT REAL DATA"), "self-test is stamped DEMO", "");

    printf("\n%s (%d checks, %d failures)\n", fails ? "FAILED" : "PASSED", checks, fails);
    return fails ? 1 : 0;
}
