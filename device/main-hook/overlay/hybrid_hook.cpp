/* Shared `main=` hook for every MiSTer hybrid port (MiSTer_hybrid).
 *
 * Replaces the per-port MiSTer_Maldita / MiSTer_CursedCastilla /
 * MiSTer_DonutDodo / MiSTer_CashCowDX builds, which were upstream Main_MiSTer
 * plus this hook with the core name and launcher path compiled in. Here the
 * mapping comes from /media/fat/linux/hybrid.d/<CORENAME>.conf (see
 * hybrid_registry.h), so one binary serves every port:
 *
 *   MiSTer.ini   [CashCowDX]
 *                main=/media/fat/linux/MiSTer_hybrid
 *
 * The call sits after scheduler_wait_fpga_ready(): Maldita measured a wrapper
 * that spawned the engine before that wait wedging the fabric on frame 1 in 3
 * of 5 launches (0 of 5 once moved here).
 *
 * OSD Reset (opt-in per core, osd_reset=<bit> in the registry entry; ported
 * from maldita's maldita_hook.cpp): the one thing this process does beyond the
 * initial spawn. MiSTer's CONF_STR "T" option is a pulse set and cleared inside
 * one HandleUI() call, so build-hps.sh adds a latch to upstream user_io.cpp
 * (user_io_status_trigger_take()) and this hook drains it every iteration. A
 * pulse on the entry's bit restarts the launcher: SIGTERM its process group,
 * SIGKILL after kTermBudgetMs, then remove reset_clear= paths and respawn -
 * stepped one scheduler iteration at a time (hybrid_reset.h) so the OSD never
 * blocks. Nothing touches the FPGA; the RBF stays loaded. Cores without
 * osd_reset= never read the latch and behave exactly as before.
 */

#include "hybrid_hook.h"
#include "hybrid_child.h"
#include "hybrid_registry.h"
#include "hybrid_reset.h"

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <sys/stat.h>
#include <time.h>

#include "user_io.h"

namespace {

constexpr const char *kFallbackLog = "/media/fat/logs/MiSTer_hybrid.log";

/* SIGTERM budget before SIGKILL, and SIGKILL budget before respawning anyway
 * (maldita's values: the launcher's own reap budget is 2-3 s, gmloader's
 * teardown 250 ms, so a healthy engine is gone well inside either). */
constexpr int64_t kTermBudgetMs = 3000;
constexpr int64_t kKillBudgetMs = 2000;

pid_t g_child = -1;
bool  g_decided = false;
char  g_log[HYBRID_PATH_MAX] = "";
/* The entry we spawned from. Reset is armed only when WE started the launcher
 * and the entry opted in: a refusal (no entry, NOENGINE) must not be undone by
 * an OSD press. */
hybrid_entry_t  g_entry;
bool            g_reset_armed = false;
hybrid_reset_t  g_reset;

/* write(2) to stderr and the port's launch log: MiSTer's stdio goes to /dev/console. */
void hlog(const char *msg)
{
    char buf[400];
    int n = snprintf(buf, sizeof(buf), "hybrid_hook: %s\n", msg);
    if (n <= 0) return;
    size_t len = (size_t)(n >= (int)sizeof(buf) ? (int)sizeof(buf) - 1 : n);
    (void)!write(STDERR_FILENO, buf, len);
    int fd = open(g_log[0] ? g_log : kFallbackLog, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0644);
    if (fd < 0) return;
    (void)!write(fd, buf, len);
    close(fd);
}

/* mkdir -p for the log file's directory (the SD card may be fresh). */
void make_log_dir(const char *log)
{
    char d[HYBRID_PATH_MAX];
    snprintf(d, sizeof(d), "%s", log);
    char *slash = strrchr(d, '/');
    if (!slash || slash == d) return;
    *slash = 0;
    for (char *p = d + 1; *p; p++)
        if (*p == '/') { *p = 0; mkdir(d, 0755); *p = '/'; }
    mkdir(d, 0755);
}

int64_t now_ms()
{
    struct timespec ts;
    /* MONOTONIC: MiSTer steps the wall clock from NTP shortly after boot. */
    if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0) return 0;
    return (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

bool spawn_launcher(const char *core)
{
    char buf[400];
    char *const argv[] = { g_entry.launcher, NULL };
    g_child = hybrid_child_spawn(argv, g_log[0] ? g_log : NULL);
    if (g_child < 0) snprintf(buf, sizeof(buf), "core %s: FAILED to spawn %s", core, g_entry.launcher);
    else snprintf(buf, sizeof(buf), "core %s (%s): spawned %s pid=%d", core, g_entry.profile, g_entry.launcher, (int)g_child);
    hlog(buf);
    return g_child > 0;
}

/* reset_clear= paths, in order: a file is unlinked, an (empty) directory rmdir'ed.
 * The launcher's lock and fabric-retry mark: a deliberate Reset must not inherit
 * a spent retry budget, nor stand down on a lock held by a child that survived
 * SIGKILL. Safe because we just stopped the only launcher of this core load. */
void clear_reset_paths()
{
    for (int i = 0; i < g_entry.n_reset_clear; i++)
    {
        const char *p = g_entry.reset_clear[i];
        if (unlink(p) != 0 && (errno == EISDIR || errno == EPERM)) rmdir(p);
    }
}

void decide_and_spawn()
{
    const char *core = user_io_get_core_name();
    hybrid_entry_t &e = g_entry;
    char err[300] = "";
    char buf[400];
    switch (hybrid_registry_lookup(NULL, core, &e, err, sizeof(err)))
    {
    case HYBRID_NO_ENTRY:
        /* Not a hybrid core (or its port is not installed): behave as stock MiSTer. */
        return;
    case HYBRID_BAD_CORENAME:
    case HYBRID_BAD_ENTRY:
        make_log_dir(kFallbackLog);
        snprintf(buf, sizeof(buf), "core '%s': registry entry rejected (%s) - not starting an engine",
                 core ? core : "", err);
        hlog(buf);
        return;
    case HYBRID_OK:
        break;
    }
    if (e.log[0]) {
        snprintf(g_log, sizeof(g_log), "%s", e.log);
        make_log_dir(g_log);
    }

    struct stat st;
    if (e.noengine[0] && stat(e.noengine, &st) == 0)
    {
        snprintf(buf, sizeof(buf), "%s present - not starting %s", e.noengine, e.launcher);
        hlog(buf);
        return;
    }

    if (!spawn_launcher(core)) return;
    if (e.osd_reset_bit >= 0)
    {
        g_reset_armed = true;
        hybrid_reset_init(&g_reset, kTermBudgetMs, kKillBudgetMs);
        user_io_status_trigger_take();   /* drop any pulse from before we armed */
        snprintf(buf, sizeof(buf), "OSD Reset armed on status bit %d", e.osd_reset_bit);
        hlog(buf);
    }
}

void reset_poll()
{
    /* Drain the latch every iteration, mid-restart too: hybrid_reset_step ignores
     * a request while a restart is in flight, so a mashed second press is dropped
     * rather than queued behind the first. */
    const bool requested =
        (user_io_status_trigger_take() & (1u << g_entry.osd_reset_bit)) != 0;
    char buf[160];
    switch (hybrid_reset_step(&g_reset, requested, g_child > 0, now_ms()))
    {
    case HYBRID_RESET_ACT_TERM:
        snprintf(buf, sizeof(buf), "OSD Reset - restarting the engine (SIGTERM group %d)", (int)g_child);
        hlog(buf);
        hybrid_child_signal_group(g_child, SIGTERM);
        break;
    case HYBRID_RESET_ACT_KILL:
        hlog("OSD Reset - launcher ignored SIGTERM, SIGKILL");
        hybrid_child_signal_group(g_child, SIGKILL);
        break;
    case HYBRID_RESET_ACT_SPAWN:
        snprintf(buf, sizeof(buf), "OSD Reset - respawning the launcher (restart #%u)", g_reset.restarts);
        hlog(buf);
        clear_reset_paths();
        /* A failed respawn leaves g_child -1 and Reset armed: the next press retries. */
        spawn_launcher(user_io_get_core_name());
        break;
    case HYBRID_RESET_ACT_NONE:
        break;
    }
}

} // namespace

void hybrid_hook_poll(void)
{
    if (!g_decided)
    {
        /* One decision per exec, whatever it is: re-deciding could start a
         * second engine on the same fabric control block. */
        g_decided = true;
        decide_and_spawn();
        return;
    }

    if (g_child > 0)
    {
        int code = 0;
        if (hybrid_child_reap(g_child, &code))
        {
            char buf[64];
            snprintf(buf, sizeof(buf), "launcher exited rc=%d", code);
            hlog(buf);
            g_child = -1;
        }
    }
    /* After the reap: the child's liveness is the restart step's input. */
    if (g_reset_armed) reset_poll();
}
