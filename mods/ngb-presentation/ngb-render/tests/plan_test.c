/* Host test for the hook-installation plan (src/ngb_plan.h).
 *
 * This is the part of hooking that can be tested without Windows or a GPU:
 * the state names the diagnostics report, and the retry schedule that decides
 * whether "not hooked yet" ever becomes "hooked".
 *
 * Build:  cc -DNGB_HOST_TEST -I src -o plan_test tests/plan_test.c
 */
#include "ngb_plan.h"

#include <stdio.h>
#include <string.h>

static int checks = 0;
static int failures = 0;

static void ok(int cond, const char *what)
{
    checks++;
    if (!cond) {
        failures++;
        printf("FAIL %s\n", what);
    }
}

static void eq_str(const char *got, const char *want, const char *what)
{
    checks++;
    if (!got || strcmp(got, want) != 0) {
        failures++;
        printf("FAIL %s (got %s, want %s)\n", what, got ? got : "(null)", want);
    }
}

int main(void)
{
    /* --- the names the log and the diagnostics panel print ---------------- */
    eq_str(ngb_plan_name(NGB_PLAN_NONE), "not-tried", "plan 0 is not-tried");
    eq_str(ngb_plan_name(NGB_PLAN_PROBE_HW), "probe-hardware", "plan 1");
    eq_str(ngb_plan_name(NGB_PLAN_PROBE_WP), "probe-warp", "plan 2");
    eq_str(ngb_plan_name(NGB_PLAN_FACTORY), "factory", "plan 3");
    eq_str(ngb_plan_name(NGB_PLAN_HOOKED), "hooked", "plan 4");
    eq_str(ngb_plan_name(NGB_PLAN_GAVE_UP), "gave-up", "plan 5");
    eq_str(ngb_plan_name(99), "not-tried", "an unknown plan is not-tried");

    /* the two names the Lua panel keys off must exist verbatim: the panel
     * prints "hooked" differently from everything else */
    ok(strcmp(ngb_plan_name(NGB_PLAN_HOOKED), "hooked") == 0,
       "the panel can tell 'hooked' apart");
    ok(strcmp(ngb_plan_name(NGB_PLAN_FACTORY), "factory") == 0,
       "the panel can name the factory route");

    /* --- the retry schedule ---------------------------------------------- */
    ok(ngb_hook_wait_ms(0) == 0, "no wait before the first attempt");
    ok(ngb_hook_wait_ms(1) > 0, "a retry always waits (no spin)");
    ok(ngb_hook_wait_ms(1) == 500, "attempts 1-3 are quick (game is starting)");
    ok(ngb_hook_wait_ms(3) == 500, "attempt 3 is still quick");
    ok(ngb_hook_wait_ms(4) == 2000, "attempt 4 slows down");
    ok(ngb_hook_wait_ms(9) == 2000, "attempt 9 still 2 s");
    ok(ngb_hook_wait_ms(10) == 5000, "steady state is 5 s");
    ok(ngb_hook_wait_ms(10000) == 5000, "and stays 5 s");

    /* monotonically non-decreasing: the loop must never get *more* eager */
    {
        unsigned prev = 0;
        int i;
        for (i = 0; i <= 40; i++) {
            unsigned w = ngb_hook_wait_ms(i);
            ok(w >= prev, "the retry delay never decreases");
            prev = w;
        }
    }

    /* a bounded probe budget: the expensive route does not run forever */
    ok(NGB_PROBE_BUDGET > 0 && NGB_PROBE_BUDGET <= 10,
       "the probe budget is small and non-zero");

    if (failures == 0) {
        printf("PASSED plan: %d checks, 0 failures\n", checks);
        return 0;
    }
    printf("FAILED plan: %d checks, %d failures\n", checks, failures);
    return 1;
}
