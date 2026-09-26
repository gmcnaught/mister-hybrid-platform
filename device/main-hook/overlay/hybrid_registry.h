#ifndef HYBRID_REGISTRY_H
#define HYBRID_REGISTRY_H

/* Port registry for the shared MiSTer_hybrid main= binary.
 *
 * One file per hybrid core, named for its CONF_STR core name (/tmp/CORENAME):
 *
 *   /media/fat/linux/hybrid.d/CashCowDX.conf
 *     launcher=/media/fat/games/CashCowDX/launch.sh     (required, absolute, executable)
 *     log=/media/fat/logs/CashCowDX/launch.log          (optional; launcher stdout/stderr)
 *     noengine=/media/fat/games/CashCowDX/NOENGINE      (optional; if this file exists, do not start)
 *     profile=gm-fabric                                  (informational; launch.sh checks it)
 *     osd_reset=19                  (optional; CONF_STR "T" status bit of an OSD Reset
 *                                   option: pressing it restarts the launcher, see hybrid_reset.h)
 *     reset_clear=/tmp/x.retry      (optional, repeatable up to HYBRID_RESET_CLEAR_MAX, in
 *                                   order: files removed, or empty dirs rmdir'ed, before an
 *                                   OSD-Reset respawn - the launcher's lock and retry mark)
 *
 * The core name may contain spaces ("Maldita Castilla" is a CONF_STR name), not
 * at either end.
 * key=value, '#' comments, no quoting. The same file is sourceable by sh.
 * Rendered from the port's mister-port.toml by `mister-platform render`. */

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

#define HYBRID_REGISTRY_DIR "/media/fat/linux/hybrid.d"
#define HYBRID_PATH_MAX 256
#define HYBRID_RESET_CLEAR_MAX 4

typedef struct {
    char launcher[HYBRID_PATH_MAX];
    char log[HYBRID_PATH_MAX];
    char noengine[HYBRID_PATH_MAX];
    char profile[64];
    int  osd_reset_bit;   /* 0..31, or -1: no OSD Reset restart for this core */
    int  n_reset_clear;
    char reset_clear[HYBRID_RESET_CLEAR_MAX][HYBRID_PATH_MAX];
} hybrid_entry_t;

typedef enum {
    HYBRID_OK = 0,
    HYBRID_NO_ENTRY,       /* no <core>.conf: not a hybrid core, run as stock MiSTer */
    HYBRID_BAD_CORENAME,   /* empty, over 64 chars, outside [A-Za-z0-9_.- ], or space at either end */
    HYBRID_BAD_ENTRY,      /* unreadable, malformed, launcher missing/not absolute, bad osd_reset/reset_clear */
} hybrid_status_t;

/* Look up <dir>/<core>.conf. dir NULL -> HYBRID_REGISTRY_DIR (overridable at
 * runtime with $MISTER_HYBRID_REGISTRY for tests). On HYBRID_BAD_ENTRY, err
 * (if non-NULL) receives a one-line reason. */
hybrid_status_t hybrid_registry_lookup(const char *dir, const char *core,
                                       hybrid_entry_t *out, char *err, size_t errlen);

#ifdef __cplusplus
}
#endif

#endif /* HYBRID_REGISTRY_H */
