#ifndef HYBRID_REGISTRY_H
#define HYBRID_REGISTRY_H

/* Port registry for the shared MiSTer_hybrid main= binary.
 *
 * The registry is the hybrid.d/ directory next to the running binary
 * (/proc/self/exe), so each port installs the binary and its entry inside its
 * own games/<gamedir>/platform/ folder. Nothing lives under /media/fat/linux:
 * the Downloader refuses that root folder for every database except
 * distribution_mister, so update_all could not install it.
 *
 * One file per hybrid core, named for its CONF_STR core name (/tmp/CORENAME):
 *
 *   /media/fat/games/CashCowDX/platform/hybrid.d/CashCowDX.conf
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

#define HYBRID_REGISTRY_SUBDIR "hybrid.d"
/* Linked into the binary (logged on every spawn): CoresMenu.sh and build-hps.sh
 * grep for it to tell MiSTer_hybrid from a renamed stock Main_MiSTer. */
#define HYBRID_REGISTRY_MARK "MiSTer_hybrid registry: <binary dir>/" HYBRID_REGISTRY_SUBDIR
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

/* <dirname of exe>/hybrid.d into out. 0 if exe has no '/' or out is too small. */
int hybrid_registry_dir_for_exe(const char *exe, char *out, size_t outlen);

/* The registry this process uses: $MISTER_HYBRID_REGISTRY when set (tests),
 * else hybrid_registry_dir_for_exe(readlink /proc/self/exe). 0 on failure. */
int hybrid_registry_default_dir(char *out, size_t outlen);

/* Look up <dir>/<core>.conf. dir NULL -> hybrid_registry_default_dir(); if that
 * fails the result is HYBRID_BAD_ENTRY. On HYBRID_BAD_ENTRY, err (if non-NULL)
 * receives a one-line reason. */
hybrid_status_t hybrid_registry_lookup(const char *dir, const char *core,
                                       hybrid_entry_t *out, char *err, size_t errlen);

#ifdef __cplusplus
}
#endif

#endif /* HYBRID_REGISTRY_H */
