#ifndef HYBRID_RESET_H
#define HYBRID_RESET_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* OSD Reset -> engine restart, as a pure state machine (opt-in per core:
 * osd_reset=<status bit> in /media/fat/linux/hybrid.d/<CORENAME>.conf).
 *
 * WHY A STATE MACHINE AND NOT A FUNCTION THAT JUST DOES IT. hybrid_hook_poll()
 * runs on the scheduler's co_poll cothread, cooperatively scheduled against
 * co_ui (HandleUI/OsdUpdate). Blocking there for the seconds a teardown can take
 * freezes the OSD, the input poll and the frame timer — the user would select
 * Reset and watch the menu lock up. So the restart is stepped one scheduler
 * iteration at a time and this unit holds the only state involved, which also
 * makes it testable host-native with no MiSTer symbols (see
 * device/main-hook/test/test_reset.c). Ported from maldita.castilla-mister's
 * maldita_reset.*; enabled per core by osd_reset= in its hybrid.d entry.
 *
 * WHAT A RESET ACTUALLY RESETS. Nothing here touches the FPGA: the RBF stays
 * loaded and there is no core reset (fpga_core_reset() from this process cost us
 * "no signal" and a dead OSD once already). The reset is entirely a consequence
 * of the engine dying and being started again:
 *
 *   - SIGTERM reaches gmloader, whose handler runs mf_fabric_teardown(): wait
 *     for the in-flight batch to ack, zero the command ring, park the control
 *     block against the sequence the fabric last reported.
 *   - The fresh launcher stops any stray engine, waits on the FPGA-ready bit,
 *     and starts a new gmloader, whose mf_fabric_bringup() clears the rings AND
 *     the ~14.75 MiB SRC heap, parks the control block, and proves the fabric
 *     with a zero-command probe batch before the first real frame.
 *   - GameMaker starts from scratch, so the game is back at its first screen.
 *
 * (The gm-fabric engine, gmloader, as the example.) That covers "reset the game,
 * the DDR ring and the control block". A wedged FPGA fabric needs a real
 * reconfigure, which is NOT done here: the launcher's fabric gate (launch_lib.sh)
 * detects a wedged fabric on the fresh engine and does the menu.rbf round-trip, so a Reset onto a jammed fabric still
 * recovers — via the path that is already device-proven, and only when needed.
 */

typedef enum {
	HYBRID_RESET_IDLE = 0,  /* no restart in flight */
	HYBRID_RESET_TERM,      /* SIGTERM sent, waiting for the child to go */
	HYBRID_RESET_KILL,      /* SIGKILL sent, waiting for the child to go */
} hybrid_reset_phase;

typedef enum {
	HYBRID_RESET_ACT_NONE = 0,
	HYBRID_RESET_ACT_TERM,   /* caller: signal the child SIGTERM */
	HYBRID_RESET_ACT_KILL,   /* caller: signal the child SIGKILL */
	HYBRID_RESET_ACT_SPAWN,  /* caller: spawn a fresh launch handler */
} hybrid_reset_action;

typedef struct {
	hybrid_reset_phase phase;
	int64_t deadline_ms;
	int64_t term_budget_ms;
	int64_t kill_budget_ms;
	uint32_t restarts;   /* completed restarts, for the log line */
} hybrid_reset_t;

/* term_budget_ms: how long SIGTERM gets before escalating. The engine's own
 * teardown budget is 250 ms, and killing launch.sh (a shell) is immediate, so
 * seconds here is a cap and not a cost.
 * kill_budget_ms: how long SIGKILL gets before we spawn anyway. Spawning over an
 * unreapable child is safe — the fresh launcher stops stray engines, and the
 * hook removes the reset_clear= paths (its lock) before respawning. */
void hybrid_reset_init(hybrid_reset_t *st, int64_t term_budget_ms, int64_t kill_budget_ms);

/* One scheduler iteration.
 *
 *   requested    a Reset pulse was taken since the last call
 *   child_alive  the launch handler / engine child has not been reaped yet
 *   now_ms       monotonic milliseconds
 *
 * Returns at most one action per call; the caller performs it and calls again on
 * the next iteration. `requested` is deliberately IGNORED while a restart is in
 * flight: a user mashing Reset must not stack restarts, which is how you end up
 * with two engines on one fabric control block. */
hybrid_reset_action hybrid_reset_step(hybrid_reset_t *st, bool requested,
                                        bool child_alive, int64_t now_ms);

#ifdef __cplusplus
}
#endif

#endif /* HYBRID_RESET_H */
