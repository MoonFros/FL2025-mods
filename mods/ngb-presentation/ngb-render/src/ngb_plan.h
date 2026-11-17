/* ===========================================================================
 *  ngb_plan.h - the hook-installation plan, as pure logic.
 *
 *  Why this is a separate header: the D3D part of hooking cannot be tested on
 *  a build host (no Windows, no GPU), but the *decisions* can. This file is
 *  compiled by tests/plan_test.c with no Windows headers at all, so the retry
 *  schedule and the state names are covered by the suite instead of being
 *  trusted.
 *
 *  The plan, in order:
 *     PROBE_HW  - build a throw-away D3D11 device on the hardware adapter and
 *                 read the swapchain vtable. Fast, but it can fail when the
 *                 process has not initialised Direct3D yet - which is exactly
 *                 when a Sider module runs.
 *     PROBE_WP  - the same probe on WARP (software rasteriser).
 *     FACTORY   - hook IDXGIFactory::CreateSwapChain / CreateSwapChainForHwnd
 *                 and wait for the GAME to create its own swapchain. Needs no
 *                 device of ours, so it survives the case that kills the probe.
 *     HOOKED    - Present is hooked; cards are drawn.
 *     GAVE_UP   - no route worked; the log holds the HRESULTs.
 * ======================================================================== */
#ifndef NGB_PLAN_H
#define NGB_PLAN_H

#define NGB_PLAN_NONE      0
#define NGB_PLAN_PROBE_HW  1
#define NGB_PLAN_PROBE_WP  2
#define NGB_PLAN_FACTORY   3
#define NGB_PLAN_HOOKED    4
#define NGB_PLAN_GAVE_UP   5

/* How many times to rebuild a probe device before leaving it to the factory
 * route. Creating a D3D11 device is not free; six attempts with the backoff
 * below covers the whole of a game's start-up without costing anything after. */
#define NGB_PROBE_BUDGET   6

static const char *ngb_plan_name(int plan)
{
    switch (plan) {
    case NGB_PLAN_PROBE_HW: return "probe-hardware";
    case NGB_PLAN_PROBE_WP: return "probe-warp";
    case NGB_PLAN_FACTORY:  return "factory";
    case NGB_PLAN_HOOKED:   return "hooked";
    case NGB_PLAN_GAVE_UP:  return "gave-up";
    default:                return "not-tried";
    }
}

/* Milliseconds to wait before the next attempt. Cheap to call, and never
 * zero: a zero-delay retry loop on the poll thread would spin a core. */
static unsigned ngb_hook_wait_ms(long attempts)
{
    if (attempts <= 0) return 0;
    if (attempts < 4)  return 500;      /* first second of the game starting */
    if (attempts < 10) return 2000;     /* still loading */
    return 5000;                        /* steady state: cheap background poll */
}

#endif /* NGB_PLAN_H */
