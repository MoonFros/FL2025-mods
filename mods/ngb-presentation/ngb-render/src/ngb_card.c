/* Broadcast card layout.
 *
 * Everything is expressed as a fraction of the real back-buffer height, so the
 * same code is pixel-correct at 1280x720, 1920x1080, 2560x1440, 3440x1440 and
 * on a DPI-scaled desktop. No hard-coded 1920x1080 anywhere.
 *
 * Nothing is invented: every number drawn here comes from state.json. When a
 * field is missing the element is either omitted or explicitly labelled, never
 * filled with a plausible-looking value.
 */
#include "ngb.h"
#include <stdio.h>
#include <string.h>
#include <wchar.h>

/* ------------------------------------------------------------------ theme */
#define COL_BG      0xE6101216u   /* near-black panel, 90% opaque  */
#define COL_BG2     0xF21A1E24u
#define COL_WHITE   0xFFFFFFFFu
#define COL_DIM     0xB0C8CCD4u
#define COL_ACCENT  0xFF3FD0FFu   /* NGB cyan                      */
#define COL_GOAL    0xFF36D96Bu
#define COL_WARN    0xFFFFC14Du
#define COL_TRAP    0xFF1B1F27u

static DWORD team_colour(const char *hex, DWORD fallback)
{
    if (!hex || hex[0] != '#' || strlen(hex) < 7) return fallback;
    unsigned r = 0, g = 0, b = 0;
    if (sscanf(hex + 1, "%2x%2x%2x", &r, &g, &b) != 3) return fallback;
    return 0xFF000000u | (r << 16) | (g << 8) | b;
}

static float clampf(float v, float lo, float hi)
{
    return v < lo ? lo : (v > hi ? hi : v);
}

/* A tiny "scaled pixel" helper: all geometry below is in units of h/1080. */
typedef struct { float w, h, u; } layout;

static float L(layout *l, float px) { return px * l->u; }

static DWORD with_alpha(DWORD c, float a)
{
    unsigned alpha = (unsigned)clampf(a, 0.0f, 1.0f) * 255u;
    return (c & 0x00FFFFFFu) | (alpha << 24);
}

/* --------------------------------------------------------------- helpers */
static void text_at(layout *l, const char *utf8, float x, float y, float px,
                    DWORD col, int weight, int align)
{
    wchar_t buf[128];
    if (!utf8 || !*utf8) return;
    ngb_wide(utf8, buf, 128);
    ngb_gfx_text(buf, x, y, px * l->u, col, weight, align);
}

static float text_width(layout *l, const char *utf8, float px, int weight)
{
    wchar_t buf[128];
    if (!utf8 || !*utf8) return 0;
    ngb_wide(utf8, buf, 128);
    return ngb_gfx_text_w(buf, px * l->u, weight);
}

static void panel(layout *l, float x, float y, float w, float h, float alpha)
{
    ngb_gfx_rect(x, y, w, h, with_alpha(COL_BG, alpha));
}

static void lower_third_bg(layout *l, float x, float y, float w, float h)
{
    /* the broadcast convention: a solid team-coloured slab with a darker base */
    ngb_gfx_rect(x, y, w, h, COL_BG2);
    ngb_gfx_rect(x, y, L(l, 6), h, COL_ACCENT);
}

/* ------------------------------------------------------------------ score */
static void draw_scorebug(layout *l, const ngb_state_t *st)
{
    /* only while the game itself says a match is running: a frozen score bug
     * over the main menu is worse than nothing */
    if (!st->scorebug || !st->live) return;
    float u = l->u;
    float h = 74 * u;
    float w = 300 * u;
    float x = 42 * u;
    float y = 34 * u;

    /* drop shadow + panel */
    ngb_gfx_rect(x + 4 * u, y + 4 * u, w, h, 0x40000000u);
    ngb_gfx_rect(x, y, w, h, 0xE00E1116u);
    ngb_gfx_rect(x, y, w, 3 * u, COL_ACCENT);

    /* home block, clock, away block */
    float seg = w / 3.0f;
    ngb_gfx_rect(x, y + 3 * u, seg, h - 3 * u, 0x30FFFFFFu);

    text_at(l, st->home_abbr, x + seg * 0.5f, y + h * 0.50f, 26, COL_WHITE, 700, 1);
    text_at(l, st->clock, x + seg * 1.5f, y + h * 0.50f, 24, COL_DIM, 400, 1);
    text_at(l, st->away_abbr, x + seg * 2.5f, y + h * 0.50f, 26, COL_WHITE, 700, 1);

    char hs[8], as[8];
    snprintf(hs, sizeof hs, "%d", st->home_score);
    snprintf(as, sizeof as, "%d", st->away_score);
    text_at(l, hs, x + seg * 0.5f, y + 4 * u, 30, 0xFFB9F6FFu, 700, 1);
    text_at(l, as, x + seg * 2.5f, y + 4 * u, 30, 0xFFB9F6FFu, 700, 1);
}

/* ------------------------------------------------------------- goal card */
static void draw_goal_card(layout *l, const ngb_state_t *st, float alpha)
{
    float u = l->u;
    float cardw = l->w * 0.42f;
    float cardh = 190 * u;
    float x = (l->w - cardw) * 0.5f;
    float y = l->h - cardh - 70 * u;

    DWORD accent = (st->ev_detail[0] && !strcmp(st->ev_detail, "own_goal"))
                   ? COL_WARN : COL_GOAL;

    ngb_gfx_rect(x + 5 * u, y + 5 * u, cardw, cardh, with_alpha(0x00000000u, alpha * 0.5f));
    panel(l, x, y, cardw, cardh, alpha * 0.94f);
    ngb_gfx_rect(x, y, cardw, 5 * u, with_alpha(accent, alpha));
    ngb_gfx_rect(x, y, 6 * u, cardh, with_alpha(accent, alpha));

    /* header row: GOAL  |  team abbr  |  minute */
    const char *head = "GOAL";
    if (!strcmp(st->ev_detail, "own_goal")) head = "OWN GOAL";
    else if (!strcmp(st->ev_kind, "motm")) head = "MAN OF THE MATCH";
    text_at(l, head, x + 26 * u, y + 18 * u, 22, with_alpha(accent, alpha), 700, 0);

    if (st->ev_team[0])
        text_at(l, st->ev_team, x + cardw - 26 * u, y + 18 * u, 20,
                with_alpha(COL_DIM, alpha), 400, 2);

    /* the name: the real player, or an explicit statement that we do not know */
    const char *name = st->ev_player_known && st->ev_name[0]
                       ? st->ev_name : "SCORER NOT AVAILABLE";
    text_at(l, name, x + 26 * u, y + 52 * u, 44,
            with_alpha(st->ev_player_known ? COL_WHITE : COL_DIM, alpha), 700, 0);

    /* score line + minute + running tally */
    float lineY = y + 118 * u;
    if (st->ev_score_line[0]) {
        text_at(l, st->ev_score_line, x + 26 * u, lineY, 34,
                with_alpha(COL_ACCENT, alpha), 700, 0);
    }
    char min[32];
    if (st->ev_minute > 0) {
        snprintf(min, sizeof min, "%d'", st->ev_minute);
        text_at(l, min, x + cardw - 26 * u, lineY, 34, with_alpha(COL_WHITE, alpha), 700, 2);
    }

    /* milestone badge (hat-trick, brace, ...) only when the game says so */
    if (st->ev_milestone[0]) {
        float bw = text_width(l, st->ev_milestone, 18, 700) + 28 * u;
        ngb_gfx_rect(x + 26 * u, y + cardh - 44 * u, bw, 28 * u,
                     with_alpha(accent, alpha * 0.22f));
        text_at(l, st->ev_milestone, x + 26 * u + 14 * u, y + cardh - 42 * u, 18,
                with_alpha(accent, alpha), 700, 0);
    }

    /* per-player stats: only when the Lua side validated the stat table */
    if (st->has_stats) {
        char stats[128];
        snprintf(stats, sizeof stats, "%d SHOTS   %d ON TARGET   %d GOALS   %d ASSISTS",
                 st->st_shots, st->st_on_target, st->st_goals, st->st_assists);
        text_at(l, stats, x + cardw - 26 * u, y + cardh - 42 * u, 17,
                with_alpha(COL_DIM, alpha), 400, 2);
    } else {
        text_at(l, "PLAYER DATA UNAVAILABLE", x + cardw - 26 * u, y + cardh - 42 * u,
                15, with_alpha(COL_DIM, alpha * 0.8f), 400, 2);
    }
}

/* ------------------------------------------------------------- shot card */
static void draw_shot_card(layout *l, const ngb_state_t *st, float alpha)
{
    float u = l->u;
    float cardw = l->w * 0.30f;
    float cardh = 132 * u;
    float x = l->w - cardw - 60 * u;
    float y = l->h - cardh - 70 * u;

    panel(l, x, y, cardw, cardh, alpha * 0.92f);
    ngb_gfx_rect(x, y, 6 * u, cardh, with_alpha(COL_ACCENT, alpha));

    const char *head = "SHOT";
    if (!strcmp(st->sh_outcome, "on_target")) head = "SHOT ON TARGET";
    else if (!strcmp(st->sh_outcome, "off_target")) head = "SHOT OFF TARGET";
    text_at(l, head, x + 22 * u, y + 14 * u, 18, with_alpha(COL_ACCENT, alpha), 700, 0);
    text_at(l, st->ev_player_known ? st->ev_name : "SHOOTER UNKNOWN",
            x + 22 * u, y + 40 * u, 28,
            with_alpha(st->ev_player_known ? COL_WHITE : COL_DIM, alpha), 700, 0);

    if (st->has_shot) {
        char buf[96];
        if (st->units_metric)
            snprintf(buf, sizeof buf, "%.0f km/h   %.1f m", st->sh_speed_kmh, st->sh_dist_m);
        else
            snprintf(buf, sizeof buf, "%.0f mph   %.1f yd", st->sh_speed_mph, st->sh_dist_yd);
        text_at(l, buf, x + 22 * u, y + 78 * u, 22, with_alpha(COL_WHITE, alpha), 400, 0);

        snprintf(buf, sizeof buf, "xG %.2f   %.0f\u00b0", st->sh_xg, st->sh_angle);
        text_at(l, buf, x + cardw - 22 * u, y + 78 * u, 18, with_alpha(COL_DIM, alpha), 400, 2);

        /* say where the numbers came from: measured vs modelled */
        const char *src = (st->sh_origin[0] && !strcmp(st->sh_origin, "measured"))
                          ? "MEASURED" : "MODELLED";
        text_at(l, src, x + 22 * u, y + cardh - 30 * u, 14,
                with_alpha(COL_DIM, alpha * 0.75f), 400, 0);
    }
}

/* ------------------------------------------------------------ result card */
static void draw_result_card(layout *l, const ngb_state_t *st, float alpha)
{
    float u = l->u;
    float cardw = l->w * 0.46f;
    float cardh = 150 * u;
    float x = (l->w - cardw) * 0.5f;
    float y = l->h * 0.30f;

    panel(l, x, y, cardw, cardh, alpha * 0.9f);
    ngb_gfx_rect(x, y, cardw, 4 * u, with_alpha(COL_ACCENT, alpha));

    /* the module sends kind="fulltime" with result="half_time"/"full_time" */
    const char *head = "FULL TIME";
    if (st->ev_result[0] && !strcmp(st->ev_result, "half_time")) head = "HALF TIME";
    text_at(l, head, x + cardw * 0.5f, y + 18 * u, 20, with_alpha(COL_DIM, alpha), 700, 1);

    char score[32];
    snprintf(score, sizeof score, "%s  %d - %d  %s",
             st->home_abbr, st->home_score, st->away_score, st->away_abbr);
    text_at(l, score, x + cardw * 0.5f, y + 56 * u, 44, with_alpha(COL_WHITE, alpha), 700, 1);

    if (st->ev_result[0])
        text_at(l, st->ev_result, x + cardw * 0.5f, y + 108 * u, 18,
                with_alpha(COL_ACCENT, alpha), 400, 1);
}

/* ------------------------------------------------------------------ toast */
static void draw_toast(layout *l, const ngb_state_t *st)
{
    float u = l->u;
    float tw = text_width(l, st->toast, 20, 700);
    float w = tw + 56 * u;
    float h = 44 * u;
    float x = (l->w - w) * 0.5f;
    float y = 120 * u;
    ngb_gfx_rect(x, y, w, h, 0xE0101418u);
    ngb_gfx_rect(x, y, w, 2 * u, COL_ACCENT);
    text_at(l, st->toast, x + 28 * u, y + 12 * u, 20, COL_WHITE, 700, 0);
}

/* ---------------------------------------------------------------- frame */
void ngb_draw_frame(const ngb_state_t *st, float w, float h)
{
    layout l;
    l.w = w; l.h = h;
    l.u = clampf(h / 1080.0f, 0.45f, 3.0f);

    if (!st || !st->master) return;

    if (st->toast[0]) draw_toast(&l, st);

    if (!st->has_event) {
        draw_scorebug(&l, st);
        return;
    }

    /* the running score bug is always up; cards come and go */
    draw_scorebug(&l, st);

    /* fade in/out from the remaining time, so a card never pops */
    float alpha = 1.0f;
    if (st->ev_remaining < 0.6f) alpha = clampf((float)(st->ev_remaining / 0.6f), 0.0f, 1.0f);

    if (!strcmp(st->ev_kind, "goal") || !strcmp(st->ev_kind, "motm"))
        draw_goal_card(&l, st, alpha);
    else if (!strcmp(st->ev_kind, "shot"))
        draw_shot_card(&l, st, alpha);
    else if (!strcmp(st->ev_kind, "fulltime"))
        draw_result_card(&l, st, alpha);
}

/* ------------------------------------------------------- self-test / diag */
/* F8: proves the render path with data that is obviously a sample. */
void ngb_draw_demo(float w, float h, int mode)
{
    layout l;
    l.w = w; l.h = h;
    l.u = clampf(h / 1080.0f, 0.45f, 3.0f);
    float u = l.u;

    if (mode == 1) {
        /* diagnostics strip: what the renderer itself can see */
        char line[8][96];
        int n = 0;
        snprintf(line[n++], 96, "NGB RENDERER %s   DIRECT3D 11", NGB_VERSION);
        snprintf(line[n++], 96, "backbuffer     %dx%d", (int)w, (int)h);
        snprintf(line[n++], 96, "state file     %s", g_cfg.state_file[0] ? g_cfg.state_file : "(none)");
        snprintf(line[n++], 96, "state age      %d ms", ngb_state_age_ms());
        snprintf(line[n++], 96, "renderer       %s", g_enabled ? "enabled" : "KILLED (F12)");
        snprintf(line[n++], 96, "faults         %s", g_dead ? "YES - DISABLED" : "none");
        snprintf(line[n++], 96, "log            %s", ngb_log_path());

        float bw = 0;
        for (int i = 0; i < n; i++) {
            float tw = text_width(&l, line[i], 16, 400);
            if (tw > bw) bw = tw;
        }
        float bx = 40 * u, by = 40 * u;
        float bh = (float)n * 24 * u + 28 * u;
        ngb_gfx_rect(bx, by, bw + 44 * u, bh, 0xE6000000u);
        ngb_gfx_rect(bx, by, bw + 44 * u, 3 * u, COL_ACCENT);
        for (int i = 0; i < n; i++)
            text_at(&l, line[i], bx + 22 * u, by + 16 * u + (float)i * 24 * u, 16,
                    i == 0 ? COL_ACCENT : COL_WHITE, i == 0 ? 700 : 400, 0);
        return;
    }

    /* mode 0: a full sample goal card, stamped DEMO */
    float cardw = l.w * 0.42f;
    float cardh = 190 * u;
    float x = (l.w - cardw) * 0.5f;
    float y = l.h - cardh - 70 * u;

    ngb_gfx_rect(x, y, cardw, cardh, 0xEE101318u);
    ngb_gfx_rect(x, y, cardw, 5 * u, COL_GOAL);
    ngb_gfx_rect(x, y, 6 * u, cardh, COL_GOAL);

    text_at(&l, "GOAL", x + 26 * u, y + 18 * u, 22, COL_GOAL, 700, 0);
    text_at(&l, "SELF-TEST", x + cardw - 26 * u, y + 18 * u, 20, COL_DIM, 400, 2);
    text_at(&l, "SAMPLE PLAYER", x + 26 * u, y + 52 * u, 44, COL_WHITE, 700, 0);
    text_at(&l, "DEMO 0 - 0", x + 26 * u, y + 118 * u, 34, COL_ACCENT, 700, 0);
    text_at(&l, "45'", x + cardw - 26 * u, y + 118 * u, 34, COL_WHITE, 700, 2);

    /* the badge that makes it impossible to mistake for real data */
    float bw = text_width(&l, "DEMO - NOT REAL DATA", 18, 700) + 32 * u;
    ngb_gfx_rect(x + 26 * u, y + cardh - 46 * u, bw, 30 * u, 0x50FFC14Du);
    text_at(&l, "DEMO - NOT REAL DATA", x + 42 * u, y + cardh - 42 * u, 18,
            COL_WARN, 700, 0);

    text_at(&l, "renderer OK - this card proves the draw path works",
            l.w * 0.5f, y - 40 * u, 20, COL_DIM, 400, 1);
}
