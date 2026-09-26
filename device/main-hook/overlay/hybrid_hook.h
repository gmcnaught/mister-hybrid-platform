#ifndef HYBRID_HOOK_H
#define HYBRID_HOOK_H

#ifdef __cplusplus
extern "C" {
#endif

/* Called from scheduler_co_poll() right after scheduler_wait_fpga_ready()
 * returns (inserted by device/main-hook/build-hps.sh). On the first call it
 * looks the loaded core up in the hybrid.d registry and spawns that port's
 * launcher; afterwards it only reaps it. */
void hybrid_hook_poll(void);

#ifdef __cplusplus
}
#endif

#endif /* HYBRID_HOOK_H */
