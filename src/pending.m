// Weak stand-ins for compositor.m (WP4), so the runtime links before it lands: its real
// definitions replace these at link time; delete this file once it has merged. Without it SERVER
// has no compositor, which only matters with tune.json "compositor": true.

#import <Foundation/Foundation.h>
#include "compositor.h"

#define WEAK __attribute__((weak))

WEAK void axr_compositor_start(void) { axr_log("compositor: not built in yet (WP4)"); }
WEAK int axr_compositor_global_fd(void) { return -1; }
WEAK axr_source *axr_compositor_add_source(bool local, pid_t pid) { (void)local, (void)pid; return NULL; }
WEAK NSArray<IOSurface *> *axr_source_slot_surfaces(axr_source *src) { (void)src; return nil; }
WEAK MTLSharedEventHandle *axr_source_frame_event(axr_source *src) { (void)src; return nil; }
WEAK MTLSharedEventHandle *axr_source_release_event(axr_source *src) { (void)src; return nil; }
WEAK int axr_source_session_fd(axr_source *src) { (void)src; return -1; }
WEAK void axr_compositor_remove_source(axr_source *src) { (void)src; }
