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
 * Not yet here: maldita's OSD-Reset engine restart (maldita_reset.*), which
 * also needs an upstream user_io.cpp edit. Ports that need it keep their own
 * build until it is ported.
 */

#include "hybrid_hook.h"
#include "hybrid_child.h"
#include "hybrid_registry.h"

#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <sys/stat.h>

#include "user_io.h"

namespace {

constexpr const char *kFallbackLog = "/media/fat/logs/MiSTer_hybrid.log";

pid_t g_child = -1;
bool  g_decided = false;
char  g_log[HYBRID_PATH_MAX] = "";

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

void decide_and_spawn()
{
    const char *core = user_io_get_core_name();
    hybrid_entry_t e;
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

    char *const argv[] = { e.launcher, NULL };
    g_child = hybrid_child_spawn(argv, g_log[0] ? g_log : NULL);

    if (g_child < 0) snprintf(buf, sizeof(buf), "core %s: FAILED to spawn %s", core, e.launcher);
    else snprintf(buf, sizeof(buf), "core %s (%s): spawned %s pid=%d", core, e.profile, e.launcher, (int)g_child);
    hlog(buf);
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
}
