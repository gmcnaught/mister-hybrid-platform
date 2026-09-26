/* Host test for hybrid_reset.c (ported from maldita.castilla-mister maldita_reset_test.cpp):
 * cc -Ioverlay overlay/hybrid_reset.c test/test_reset.c */
/* Host-native tests for the OSD Reset -> engine restart state machine.
 *
 * The machine is pure (no syscalls, no clock of its own), so every ordering the
 * device can produce is reachable here by choosing `child_alive` and `now_ms`.
 * The properties worth pinning are the ones whose violation costs a device
 * session: never two spawns for one press, never a spawn while the old engine
 * is still alive, and never a press that leaves the feature permanently stuck.
 */

#include "hybrid_reset.h"

#include <stdio.h>
#include <string.h>

static int g_fail = 0;

static void check(const char *what, long got, long want)
{
	if (got == want) {
		printf("  ok   — %s\n", what);
	} else {
		printf("  FAIL — %s (got %ld, want %ld)\n", what, got, want);
		g_fail++;
	}
}

static const char *act_name(hybrid_reset_action a)
{
	switch (a) {
	case HYBRID_RESET_ACT_NONE:  return "NONE";
	case HYBRID_RESET_ACT_TERM:  return "TERM";
	case HYBRID_RESET_ACT_KILL:  return "KILL";
	case HYBRID_RESET_ACT_SPAWN: return "SPAWN";
	}
	return "?";
}

static void check_act(const char *what, hybrid_reset_action got, hybrid_reset_action want)
{
	if (got == want) {
		printf("  ok   — %s\n", what);
	} else {
		printf("  FAIL — %s (got %s, want %s)\n", what, act_name(got), act_name(want));
		g_fail++;
	}
}

/* The healthy case: press Reset, the engine takes SIGTERM and dies, we spawn. */
static void test_happy_path(void)
{
	puts("happy path — TERM then SPAWN when the child goes");
	hybrid_reset_t st;
	hybrid_reset_init(&st, 3000, 2000);

	check_act("idle with no request does nothing",
	          hybrid_reset_step(&st, false, true, 0), HYBRID_RESET_ACT_NONE);
	check_act("press -> SIGTERM",
	          hybrid_reset_step(&st, true, true, 0), HYBRID_RESET_ACT_TERM);
	check_act("still alive at 100ms -> wait",
	          hybrid_reset_step(&st, false, true, 100), HYBRID_RESET_ACT_NONE);
	check_act("child gone -> SPAWN",
	          hybrid_reset_step(&st, false, false, 300), HYBRID_RESET_ACT_SPAWN);
	check("one restart counted", st.restarts, 1);
	/* The caller has spawned by now, so the child is alive again. */
	check_act("back to idle, no spurious action",
	          hybrid_reset_step(&st, false, true, 400), HYBRID_RESET_ACT_NONE);
}

/* THE property that matters most. A user mashing Reset must not stack
 * restarts — every extra SPAWN is another engine racing for one fabric control
 * block, which is the documented dual-engine corruption (C_DONE running
 * backwards). Presses during a restart are dropped, not queued. */
static void test_mashing_yields_one_restart(void)
{
	puts("mashing Reset during a restart yields exactly one spawn");
	hybrid_reset_t st;
	hybrid_reset_init(&st, 3000, 2000);

	int spawns = 0, terms = 0;
	hybrid_reset_action a;

	a = hybrid_reset_step(&st, true, true, 0);
	if (a == HYBRID_RESET_ACT_TERM) terms++;

	/* Ten more presses while the child is still shutting down. */
	for (int i = 1; i <= 10; i++) {
		a = hybrid_reset_step(&st, true, true, i * 10);
		if (a == HYBRID_RESET_ACT_SPAWN) spawns++;
		if (a == HYBRID_RESET_ACT_TERM) terms++;
	}
	a = hybrid_reset_step(&st, true, false, 200);
	if (a == HYBRID_RESET_ACT_SPAWN) spawns++;

	check("exactly one SIGTERM", terms, 1);
	check("exactly one spawn", spawns, 1);
	check("exactly one restart counted", st.restarts, 1);
}

/* A spawn must never be issued while the old child is still alive — that is the
 * two-engines-on-one-control-block failure, reached from the other direction. */
static void test_never_spawns_over_a_live_child(void)
{
	puts("no spawn while the child is still alive (within budget)");
	hybrid_reset_t st;
	hybrid_reset_init(&st, 3000, 2000);

	int bad = 0;
	hybrid_reset_step(&st, true, true, 0);          /* TERM */
	for (int64_t t = 1; t < 3000; t += 37)
		if (hybrid_reset_step(&st, false, true, t) == HYBRID_RESET_ACT_SPAWN) bad++;
	check("spawns issued over a live child", bad, 0);
}

/* SIGTERM ignored -> escalate at the budget, then spawn when it finally dies. */
static void test_escalates_to_sigkill(void)
{
	puts("SIGTERM ignored — escalate to SIGKILL at the budget");
	hybrid_reset_t st;
	hybrid_reset_init(&st, 3000, 2000);

	check_act("press -> SIGTERM", hybrid_reset_step(&st, true, true, 0),
	          HYBRID_RESET_ACT_TERM);
	check_act("just under the budget -> wait",
	          hybrid_reset_step(&st, false, true, 2999), HYBRID_RESET_ACT_NONE);
	check_act("at the budget -> SIGKILL",
	          hybrid_reset_step(&st, false, true, 3000), HYBRID_RESET_ACT_KILL);
	check_act("only one SIGKILL",
	          hybrid_reset_step(&st, false, true, 3100), HYBRID_RESET_ACT_NONE);
	check_act("child finally gone -> SPAWN",
	          hybrid_reset_step(&st, false, false, 3200), HYBRID_RESET_ACT_SPAWN);
}

/* Unkillable child (stuck in uninterruptible DDR I/O). Leaving the user with no
 * engine at all is worse than starting one over the top: launch.sh reaps strays
 * and takes the launch lock over from a dead owner before it starts anything. */
static void test_spawns_anyway_after_sigkill_budget(void)
{
	puts("child survives SIGKILL — spawn anyway rather than leave no engine");
	hybrid_reset_t st;
	hybrid_reset_init(&st, 3000, 2000);

	hybrid_reset_step(&st, true, true, 0);            /* TERM */
	hybrid_reset_step(&st, false, true, 3000);        /* KILL, deadline 5000 */
	check_act("still waiting at 4999",
	          hybrid_reset_step(&st, false, true, 4999), HYBRID_RESET_ACT_NONE);
	check_act("budget blown -> SPAWN anyway",
	          hybrid_reset_step(&st, false, true, 5000), HYBRID_RESET_ACT_SPAWN);
	check("restart counted", st.restarts, 1);
}

/* Reset with no engine running (it crashed, and nothing on this path respawns
 * it) must start one — that is the only way back into the game. */
static void test_reset_with_no_child_spawns(void)
{
	puts("Reset with no live child spawns directly");
	hybrid_reset_t st;
	hybrid_reset_init(&st, 3000, 2000);

	check_act("press with dead child -> SPAWN",
	          hybrid_reset_step(&st, true, false, 0), HYBRID_RESET_ACT_SPAWN);
	check("restart counted", st.restarts, 1);
	check("stays idle", st.phase, HYBRID_RESET_IDLE);
}

/* The feature must survive being used repeatedly — a state machine that ends up
 * parked in TERM or KILL would silently stop honouring Reset for the session. */
static void test_repeated_resets(void)
{
	puts("five consecutive resets all complete");
	hybrid_reset_t st;
	hybrid_reset_init(&st, 3000, 2000);

	int64_t t = 0;
	for (int i = 0; i < 5; i++) {
		check_act("press -> SIGTERM", hybrid_reset_step(&st, true, true, t),
		          HYBRID_RESET_ACT_TERM);
		t += 200;
		check_act("child gone -> SPAWN", hybrid_reset_step(&st, false, false, t),
		          HYBRID_RESET_ACT_SPAWN);
		t += 200;
	}
	check("five restarts counted", st.restarts, 5);
	check("idle at the end", st.phase, HYBRID_RESET_IDLE);
}

static void test_null_is_inert(void)
{
	puts("NULL state is inert");
	check_act("step(NULL) does nothing",
	          hybrid_reset_step(NULL, true, true, 0), HYBRID_RESET_ACT_NONE);
	hybrid_reset_init(NULL, 1, 1);   /* must not crash */
	puts("  ok   — init(NULL) does not crash");
}

int main(void)
{
	test_happy_path();
	test_mashing_yields_one_restart();
	test_never_spawns_over_a_live_child();
	test_escalates_to_sigkill();
	test_spawns_anyway_after_sigkill_budget();
	test_reset_with_no_child_spawns();
	test_repeated_resets();
	test_null_is_inert();

	if (g_fail) {
		printf("\nhybrid_reset: %d FAILURE(S)\n", g_fail);
		return 1;
	}
	puts("\nhybrid_reset OSD-Reset restart policy OK");
	return 0;
}
