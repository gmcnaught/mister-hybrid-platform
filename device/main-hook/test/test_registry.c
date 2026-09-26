/* Host test for hybrid_registry.c: cc -I../overlay ../overlay/hybrid_registry.c test_registry.c */
#define _DEFAULT_SOURCE  /* glibc: mkdtemp, setenv under -std=c11 (macOS declares them already) */
#include "hybrid_registry.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static int fails, passes;
#define CHECK(c) do { if (c) passes++; else { fails++; fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #c); } } while (0)

static char dir[256];

static void put(const char *name, const char *body, mode_t mode)
{
    char p[512];
    snprintf(p, sizeof(p), "%s/%s", dir, name);
    FILE *f = fopen(p, "w");
    fputs(body, f);
    fclose(f);
    chmod(p, mode);
}

int main(void)
{
    snprintf(dir, sizeof(dir), "/tmp/hybrid_reg_XXXXXX");
    if (!mkdtemp(dir)) return 2;
    char launcher[400], conf[800];
    snprintf(launcher, sizeof(launcher), "%s/launch.sh", dir);
    put("launch.sh", "#!/bin/sh\n", 0755);
    put("noexec.sh", "#!/bin/sh\n", 0644);

    hybrid_entry_t e;
    char err[256];

    snprintf(conf, sizeof(conf),
             "# comment\n\n  launcher = %s  \nlog=/media/fat/logs/X/launch.log\nnoengine=/x/NOENGINE\nprofile=gm-fabric\nfuture_key=1\n",
             launcher);
    put("CashCowDX.conf", conf, 0644);
    CHECK(hybrid_registry_lookup(dir, "CashCowDX", &e, err, sizeof(err)) == HYBRID_OK);
    CHECK(strcmp(e.launcher, launcher) == 0);
    CHECK(strcmp(e.log, "/media/fat/logs/X/launch.log") == 0);
    CHECK(strcmp(e.noengine, "/x/NOENGINE") == 0);
    CHECK(strcmp(e.profile, "gm-fabric") == 0);

    /* CONF_STR names may contain spaces ("Cursed Castilla"). */
    put("Cursed Castilla.conf", conf, 0644);
    CHECK(hybrid_registry_lookup(dir, "Cursed Castilla", &e, err, sizeof(err)) == HYBRID_OK);
    CHECK(strcmp(e.launcher, launcher) == 0);
    CHECK(hybrid_registry_lookup(dir, " Cursed", &e, err, sizeof(err)) == HYBRID_BAD_CORENAME);
    CHECK(hybrid_registry_lookup(dir, "a/b", &e, err, sizeof(err)) == HYBRID_BAD_CORENAME);

    CHECK(hybrid_registry_lookup(dir, "SNES", &e, err, sizeof(err)) == HYBRID_NO_ENTRY);
    CHECK(hybrid_registry_lookup(dir, "../etc/passwd", &e, err, sizeof(err)) == HYBRID_BAD_CORENAME);
    CHECK(hybrid_registry_lookup(dir, "", &e, err, sizeof(err)) == HYBRID_BAD_CORENAME);
    CHECK(hybrid_registry_lookup(dir, "..", &e, err, sizeof(err)) == HYBRID_BAD_CORENAME);

    put("Rel.conf", "launcher=games/x/launch.sh\n", 0644);
    CHECK(hybrid_registry_lookup(dir, "Rel", &e, err, sizeof(err)) == HYBRID_BAD_ENTRY);
    CHECK(strstr(err, "absolute") != NULL);

    snprintf(conf, sizeof(conf), "launcher=%s/noexec.sh\n", dir);
    put("NoExec.conf", conf, 0644);
    CHECK(hybrid_registry_lookup(dir, "NoExec", &e, err, sizeof(err)) == HYBRID_BAD_ENTRY);
    CHECK(strstr(err, "not executable") != NULL);

    put("Garbage.conf", "this line has no equals sign\n", 0644);
    CHECK(hybrid_registry_lookup(dir, "Garbage", &e, err, sizeof(err)) == HYBRID_BAD_ENTRY);

    char longv[600];
    memset(longv, 'a', sizeof(longv));
    snprintf(conf, sizeof(conf), "launcher=/%.300s\n", longv);
    put("Long.conf", conf, 0644);
    CHECK(hybrid_registry_lookup(dir, "Long", &e, err, sizeof(err)) == HYBRID_BAD_ENTRY);

    put("Missing.conf", "log=/x\n", 0644);
    CHECK(hybrid_registry_lookup(dir, "Missing", &e, err, sizeof(err)) == HYBRID_BAD_ENTRY);

    setenv("MISTER_HYBRID_REGISTRY", dir, 1);
    CHECK(hybrid_registry_lookup(NULL, "CashCowDX", &e, err, sizeof(err)) == HYBRID_OK);

    char cmd[300];
    snprintf(cmd, sizeof(cmd), "rm -rf '%s'", dir);
    if (system(cmd) != 0) fails++;
    printf("hybrid_registry: %d passed, %d failed\n", passes, fails);
    return fails != 0;
}
