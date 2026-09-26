#include "hybrid_registry.h"

#include <ctype.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static void set_err(char *err, size_t errlen, const char *msg, const char *arg)
{
    if (err && errlen) snprintf(err, errlen, "%s%s%s", msg, arg ? ": " : "", arg ? arg : "");
}

static int corename_ok(const char *core)
{
    if (!core || !*core || strlen(core) > 64) return 0;
    if (core[0] == '.' || core[0] == ' ' || core[strlen(core) - 1] == ' ') return 0;
    /* Spaces are allowed inside: CONF_STR names such as "Cursed Castilla". */
    for (const char *p = core; *p; p++)
        if (!(isalnum((unsigned char)*p) || *p == '_' || *p == '-' || *p == '.' || *p == ' ')) return 0;
    return 1;
}

static char *trim(char *s)
{
    while (isspace((unsigned char)*s)) s++;
    char *e = s + strlen(s);
    while (e > s && isspace((unsigned char)e[-1])) *--e = 0;
    return s;
}

static int copy_val(char *dst, size_t cap, const char *val)
{
    size_t n = strlen(val);
    if (n >= cap) return 0;
    memcpy(dst, val, n + 1);
    return 1;
}

/* "0".."31" only: the trigger latch covers the 32-bit (non-extended) status word. */
static int parse_bit(const char *val, int *out)
{
    if (!isdigit((unsigned char)val[0])) return 0;
    char *end;
    long v = strtol(val, &end, 10);
    if (*end || v < 0 || v > 31) return 0;
    *out = (int)v;
    return 1;
}

hybrid_status_t hybrid_registry_lookup(const char *dir, const char *core,
                                       hybrid_entry_t *out, char *err, size_t errlen)
{
    memset(out, 0, sizeof(*out));
    out->osd_reset_bit = -1;
    if (!corename_ok(core)) {
        set_err(err, errlen, "invalid core name", core);
        return HYBRID_BAD_CORENAME;
    }
    if (!dir) {
        const char *env = getenv("MISTER_HYBRID_REGISTRY");
        dir = (env && *env) ? env : HYBRID_REGISTRY_DIR;
    }
    char path[HYBRID_PATH_MAX + 80];
    snprintf(path, sizeof(path), "%s/%s.conf", dir, core);
    FILE *f = fopen(path, "r");
    if (!f) return HYBRID_NO_ENTRY;

    char line[512];
    int lineno = 0, bad = 0;
    while (fgets(line, sizeof(line), f)) {
        lineno++;
        char *s = trim(line);
        if (!*s || *s == '#') continue;
        char *eq = strchr(s, '=');
        if (!eq) { bad = lineno; break; }
        *eq = 0;
        char *key = trim(s), *val = trim(eq + 1);
        int ok = 1;
        if (!strcmp(key, "launcher")) ok = copy_val(out->launcher, sizeof(out->launcher), val);
        else if (!strcmp(key, "log")) ok = copy_val(out->log, sizeof(out->log), val);
        else if (!strcmp(key, "noengine")) ok = copy_val(out->noengine, sizeof(out->noengine), val);
        else if (!strcmp(key, "profile")) ok = copy_val(out->profile, sizeof(out->profile), val);
        else if (!strcmp(key, "osd_reset")) ok = parse_bit(val, &out->osd_reset_bit);
        else if (!strcmp(key, "reset_clear")) {
            ok = out->n_reset_clear < HYBRID_RESET_CLEAR_MAX && val[0] == '/' &&
                 copy_val(out->reset_clear[out->n_reset_clear], HYBRID_PATH_MAX, val);
            if (ok) out->n_reset_clear++;
        }
        /* unknown keys are ignored: newer registry files stay readable by older binaries */
        if (!ok) { bad = lineno; break; }
    }
    fclose(f);
    if (bad) {
        char n[16];
        snprintf(n, sizeof(n), "line %d", bad);
        set_err(err, errlen, "malformed or over-long entry in registry file", n);
        return HYBRID_BAD_ENTRY;
    }
    if (out->launcher[0] != '/') {
        set_err(err, errlen, "launcher= missing or not an absolute path", path);
        return HYBRID_BAD_ENTRY;
    }
    if (access(out->launcher, X_OK) != 0) {
        set_err(err, errlen, "launcher not executable", out->launcher);
        return HYBRID_BAD_ENTRY;
    }
    return HYBRID_OK;
}
