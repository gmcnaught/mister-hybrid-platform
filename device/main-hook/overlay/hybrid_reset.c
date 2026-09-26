#include "hybrid_reset.h"

void hybrid_reset_init(hybrid_reset_t *st, int64_t term_budget_ms, int64_t kill_budget_ms)
{
	if (!st) return;
	st->phase = HYBRID_RESET_IDLE;
	st->deadline_ms = 0;
	st->term_budget_ms = term_budget_ms;
	st->kill_budget_ms = kill_budget_ms;
	st->restarts = 0;
}

hybrid_reset_action hybrid_reset_step(hybrid_reset_t *st, bool requested,
                                        bool child_alive, int64_t now_ms)
{
	if (!st) return HYBRID_RESET_ACT_NONE;

	switch (st->phase)
	{
	case HYBRID_RESET_IDLE:
		if (!requested) return HYBRID_RESET_ACT_NONE;
		if (!child_alive)
		{
			/* Nothing to kill — the engine already exited on its own (a crash,
			 * or the user quit it) and nothing respawns it on this path. Reset
			 * is then the only way back into the game, so honour it directly. */
			st->restarts++;
			return HYBRID_RESET_ACT_SPAWN;
		}
		st->phase = HYBRID_RESET_TERM;
		st->deadline_ms = now_ms + st->term_budget_ms;
		return HYBRID_RESET_ACT_TERM;

	case HYBRID_RESET_TERM:
		if (!child_alive)
		{
			st->phase = HYBRID_RESET_IDLE;
			st->restarts++;
			return HYBRID_RESET_ACT_SPAWN;
		}
		if (now_ms >= st->deadline_ms)
		{
			st->phase = HYBRID_RESET_KILL;
			st->deadline_ms = now_ms + st->kill_budget_ms;
			return HYBRID_RESET_ACT_KILL;
		}
		return HYBRID_RESET_ACT_NONE;

	case HYBRID_RESET_KILL:
		/* Spawn once the child is gone, and spawn ANYWAY if even SIGKILL has not
		 * cleared it inside the budget. A child that survives SIGKILL is stuck in
		 * uninterruptible I/O, which on this box means a stalled DDR access — and
		 * leaving the user with no engine at all is strictly worse than starting
		 * one over the top. The fresh launcher stops stray engines (SIGTERM,
		 * then SIGKILL) before it starts anything, and the hook clears its lock
		 * (reset_clear=) first, so the overlap is handled there. */
		if (!child_alive || now_ms >= st->deadline_ms)
		{
			st->phase = HYBRID_RESET_IDLE;
			st->restarts++;
			return HYBRID_RESET_ACT_SPAWN;
		}
		return HYBRID_RESET_ACT_NONE;
	}

	return HYBRID_RESET_ACT_NONE;
}
