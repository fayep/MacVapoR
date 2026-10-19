// Weak stand-ins for functions other work packages are writing, so the runtime links before they
// land: tracking.m (WP1) and compositor.m (WP4). Their real definitions replace these at link
// time; delete this file once both have merged. Without them CLIENT and SERVER can't work, which
// only matters with tune.json "compositor": true.

#import <Foundation/Foundation.h>
#include "compositor.h"
#include "tracking.h"

#define WEAK __attribute__((weak))

WEAK void axr_tracking_attach(const axr_shm_global *g) { (void)g; }
WEAK uint64_t axr_client_ts_for(int64_t display_time) { (void)display_time; return 0; }

WEAK void axr_compositor_start(void) { axr_log("compositor: not built in yet (WP4)"); }
WEAK int axr_compositor_global_fd(void) { return -1; }
WEAK axr_source *axr_compositor_add_source(bool local, pid_t pid) { (void)local, (void)pid; return NULL; }
WEAK NSArray<IOSurface *> *axr_source_slot_surfaces(axr_source *src) { (void)src; return nil; }
WEAK MTLSharedEventHandle *axr_source_frame_event(axr_source *src) { (void)src; return nil; }
WEAK MTLSharedEventHandle *axr_source_release_event(axr_source *src) { (void)src; return nil; }
WEAK int axr_source_session_fd(axr_source *src) { (void)src; return -1; }
WEAK void axr_compositor_remove_source(axr_source *src) { (void)src; }
