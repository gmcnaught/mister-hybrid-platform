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

    CHECK(e.osd_reset_bit == -1);          /* no osd_reset=: Reset restart off */
    CHECK(e.n_reset_clear == 0);

    /* OSD Reset opt-in, and a CONF_STR core name with a space */
    snprintf(conf, sizeof(conf),
             "launcher=%s\nosd_reset=19\nreset_clear=/tmp/mh/X.retry\nreset_clear=/tmp/mh/X.lock/pid\nreset_clear=/tmp/mh/X.lock\n",
             launcher);
    put("Maldita Castilla.conf", conf, 0644);
    CHECK(hybrid_registry_lookup(dir, "Maldita Castilla", &e, err, sizeof(err)) == HYBRID_OK);
    CHECK(e.osd_reset_bit == 19);
    CHECK(e.n_reset_clear == 3);
    CHECK(strcmp(e.reset_clear[0], "/tmp/mh/X.retry") == 0);
    CHECK(strcmp(e.reset_clear[2], "/tmp/mh/X.lock") == 0);
    CHECK(hybrid_registry_lookup(dir, " Maldita Castilla", &e, err, sizeof(err)) == HYBRID_BAD_CORENAME);
    CHECK(hybrid_registry_lookup(dir, "Maldita Castilla ", &e, err, sizeof(err)) == HYBRID_BAD_CORENAME);

    const char *bad_bits[] = { "32", "-1", "x", "", "19x", "+3" };
    for (size_t i = 0; i < sizeof(bad_bits) / sizeof(bad_bits[0]); i++) {
        snprintf(conf, sizeof(conf), "launcher=%s\nosd_reset=%s\n", launcher, bad_bits[i]);
        put("BadBit.conf", conf, 0644);
        CHECK(hybrid_registry_lookup(dir, "BadBit", &e, err, sizeof(err)) == HYBRID_BAD_ENTRY);
    }
    snprintf(conf, sizeof(conf), "launcher=%s\nosd_reset=0\n", launcher);
    put("Bit0.conf", conf, 0644);
    CHECK(hybrid_registry_lookup(dir, "Bit0", &e, err, sizeof(err)) == HYBRID_OK && e.osd_reset_bit == 0);
    snprintf(conf, sizeof(conf), "launcher=%s\nreset_clear=tmp/relative\n", launcher);
    put("RelClear.conf", conf, 0644);
    CHECK(hybrid_registry_lookup(dir, "RelClear", &e, err, sizeof(err)) == HYBRID_BAD_ENTRY);
    snprintf(conf, sizeof(conf), "launcher=%s\nreset_clear=/a\nreset_clear=/b\nreset_clear=/c\nreset_clear=/d\nreset_clear=/e\n", launcher);
    put("ManyClear.conf", conf, 0644);
    CHECK(hybrid_registry_lookup(dir, "ManyClear", &e, err, sizeof(err)) == HYBRID_BAD_ENTRY);

    /* CONF_STR names may contain spaces ("Cursed Castilla"). */
    snprintf(conf, sizeof(conf), "launcher=%s\n", launcher);
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

    char rd[64];
    CHECK(hybrid_registry_dir_for_exe("/media/fat/games/gmloader/platform/MiSTer_hybrid", rd, sizeof(rd)));
    CHECK(strcmp(rd, "/media/fat/games/gmloader/platform/hybrid.d") == 0);
    CHECK(!hybrid_registry_dir_for_exe("MiSTer_hybrid", rd, sizeof(rd)));
    CHECK(!hybrid_registry_dir_for_exe("/a/very/long/path/that/does/not/fit/in/the/buffer/MiSTer_hybrid", rd, 16));

    char cmd[300];
    snprintf(cmd, sizeof(cmd), "rm -rf '%s'", dir);
    if (system(cmd) != 0) fails++;
    printf("hybrid_registry: %d passed, %d failed\n", passes, fails);
    return fails != 0;
}
