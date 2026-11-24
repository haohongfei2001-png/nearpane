#pragma once
#include <CoreGraphics/CoreGraphics.h>
#include "../../include/nearpane_window_engine.h"
#include "macos.h"

static inline bool nc_occupies_site(NCFrame obstacle, CGRect site, bool measured) {
    CGRect bounds = CGRectMake(obstacle.x, obstacle.y, obstacle.w, obstacle.h);
    // Before the AX move only the maximum footprint is known. Partial overlap can
    // miss the actual sliver; after the move use its independently measured frame.
    return measured ? CGRectIntersectsRect(bounds, site) : CGRectContainsRect(bounds, site);
}

static inline uint32_t nc_site_layer(const NCListed *row, CGRect area, CGWindowLevel icons,
                                     const NCDock *dock, bool ownSidebarAbove, bool measured) {
    if (row->alpha <= 0 || !row->layer || row->layer < icons || !nc_occupies_site(row->frame, area, measured)) return 0;
    if (row->layer < 0) return NP_CORNER_SITE_DESKTOP;
    if (ownSidebarAbove) return 0;
    if (row->pid != dock->pid || row->layer != 20 || !dock->count) return NP_CORNER_SITE_OVERLAY;
    for (unsigned k = 0; k < dock->count; k++)
        if (nc_occupies_site(dock->bars[k], area, measured)) return NP_CORNER_SITE_DOCK;
    return 0;
}
