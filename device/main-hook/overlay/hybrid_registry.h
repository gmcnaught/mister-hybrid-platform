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
 *
 * key=value, '#' comments, no quoting. The same file is sourceable by sh.
 * Rendered from the port's mister-port.toml by `mister-platform render`. */

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

#define HYBRID_REGISTRY_DIR "/media/fat/linux/hybrid.d"
#define HYBRID_PATH_MAX 256

typedef struct {
    char launcher[HYBRID_PATH_MAX];
    char log[HYBRID_PATH_MAX];
    char noengine[HYBRID_PATH_MAX];
    char profile[64];
} hybrid_entry_t;

typedef enum {
    HYBRID_OK = 0,
    HYBRID_NO_ENTRY,       /* no <core>.conf: not a hybrid core, run as stock MiSTer */
    HYBRID_BAD_CORENAME,   /* empty or contains characters outside [A-Za-z0-9_.-] */
    HYBRID_BAD_ENTRY,      /* unreadable, malformed, or launcher missing/not absolute */
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
