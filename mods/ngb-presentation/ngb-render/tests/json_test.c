/* Host test for the state.json reader.
 *
 *   cc -DNGB_HOST_TEST -I src -o json_test tests/json_test.c src/ngb_json.c
 *   ./json_test <a real state.json written by NGB_Presentation.lua>
 *
 * Part 1 pins exact values (fixture), part 2 proves that every path the DLL
 * reads still exists in the file the module actually writes - that is the
 * check that catches schema drift, which no amount of careful code survives.
 */
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include "ngb.h"

static int fails;
static int checks;

static void ok(int cond, const char *what, const char *detail)
{
    checks++;
    if (!cond) { fails++; printf("FAIL %-34s %s\n", what, detail ? detail : ""); }
    else printf("ok   %-34s %s\n", what, detail ? detail : "");
}

static void want_str(const char *root, const char *path, const char *want)
{
    char got_[256];
    ngb_json_str(root, path, got_, sizeof got_, "<missing>");
    ok(strcmp(got_, want) == 0, path, got_);
}
static void want_int(const char *root, const char *path, int want)
{
    char d[32];
    int got_ = ngb_json_int(root, path, -99999);
    snprintf(d, sizeof d, "%d (want %d)", got_, want);
    ok(got_ == want, path, d);
}
static void want_num(const char *root, const char *path, double want, double tol)
{
    char d[48];
    double got_ = ngb_json_num(root, path, -99999);
    snprintf(d, sizeof d, "%.3f (want %.3f)", got_, want);
    ok(got_ > want - tol && got_ < want + tol, path, d);
}

static const char *kFixture =
"{"
 " \"v\": 4,"
 " \"seq\": 12,"
 " \"match\": { \"home\": {\"abbr\": \"ARS\", \"score\": 2, \"name\": \"ARSENAL\"},"
 "              \"away\": {\"abbr\": \"CHE\", \"score\": 1},"
 "              \"clock\": \"67:12\" },"
 " \"hud\": { \"units\": \"metric\", \"style\": 1, \"master\": true,"
 "            \"toast\": {\"text\": \"HAT-TRICK \\\"M. Rashford\\\"\", \"hold\": 4.5} },"
 " \"event\": { \"kind\": \"goal\", \"minute\": 67, \"player_known\": true,"
 "              \"player\": {\"name\": \"M. Rashford\", \"shirt\": \"10\", \"minutes\": 67},"
 "              \"scorers\": [ {\"name\": \"a}b\", \"minute\": 12}, {\"name\": \"c\", \"minute\": 3} ],"
 "              \"shot\": {\"speed_kmh\": 112.4, \"xg\": 0.37, \"origin_source\": \"measured\"},"
 "              \"stats\": {\"shots\": 5, \"goals\": 3, \"assists\": 1},"
 "              \"remaining\": 8.25 },"
 " \"diag\": { \"renderer\": \"dll\", \"schema\": 4 }"
 "}";

int main(int argc, char **argv)
{
    printf("--- fixture ---\n");
    const char *b = kFixture;
    want_int(b, "v", 4);
    want_str(b, "match.home.abbr", "ARS");
    want_int(b, "match.home.score", 2);
    want_str(b, "match.clock", "67:12");
    want_str(b, "hud.units", "metric");
    want_int(b, "hud.style", 1);
    want_int(b, "hud.master", 1);
    /* escaped quote inside a string */
    want_str(b, "hud.toast.text", "HAT-TRICK \"M. Rashford\"");
    /* an array before the field we want: the reader must skip it correctly */
    want_str(b, "event.player.name", "M. Rashford");
    want_int(b, "event.minute", 67);
    want_num(b, "event.shot.speed_kmh", 112.4, 0.001);
    want_num(b, "event.shot.xg", 0.37, 0.001);
    want_int(b, "event.stats.shots", 5);
    want_num(b, "event.remaining", 8.25, 0.001);
    want_str(b, "diag.renderer", "dll");
    {
        char tmp[32];
        int present = ngb_json_str(b, "event.not_a_field", tmp, sizeof tmp, "");
        ok(present == 0, "missing path reported absent", "");
        present = ngb_json_str(b, "event.player.nope", tmp, sizeof tmp, "");
        ok(present == 0, "missing nested path absent", "");
        ok(ngb_json_int(b, "absent", 7) == 7, "default returned", "");
    }

    if (argc < 2) {
        printf("\nno state.json given - fixture only\n");
        return fails ? 1 : 0;
    }

    FILE *f = fopen(argv[1], "rb");
    if (!f) { perror("open"); return 2; }
    fseek(f, 0, SEEK_END);
    long n = ftell(f);
    fseek(f, 0, SEEK_SET);
    char *buf = malloc((size_t)n + 1);
    if (fread(buf, 1, (size_t)n, f) != (size_t)n) return 2;
    buf[n] = 0;
    fclose(f);

    printf("\n--- %s (%ld bytes) ---\n", argv[1], n);
    /* every path ngb_render.c reads; if one disappears, the card loses a field
     * silently, which is exactly the class of bug we cannot see in game */
    static const char *paths[] = {
        "v", "seq",
        "match.home.abbr", "match.away.abbr", "match.home.score", "match.away.score",
        "match.clock", "hud.style", "hud.master", "hud.scorebug", "hud.units",
        "hud.credit", "hud.author", "diag.renderer", "status.events",
        "status.data.player_stats", "game.pid", "game.exe",
    };
    for (unsigned i = 0; i < sizeof paths / sizeof *paths; i++) {
        const char *v = ngb_json_path(buf, paths[i]);
        ok(v != NULL, paths[i], v ? "" : "MISSING FROM state.json");
    }
    /* truncation sweep:every offset, nothing may read out of bounds */
    for (long cut = 1; cut < n; cut += 7) {
        char save = buf[cut];
        buf[cut] = 0;
        char tmp[256];
        for (unsigned i = 0; i < sizeof paths / sizeof *paths; i++)
            ngb_json_str(buf, paths[i], tmp, sizeof tmp, "");
        buf[cut] = save;
    }
    ok(1, "truncation sweep", "no crash");
    free(buf);

    printf("\n%s (%d checks, %d failures)\n", fails ? "FAILED" : "PASSED", checks, fails);
    return fails ? 1 : 0;
}
