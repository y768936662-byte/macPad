#ifndef MACWS_PRODUCTION_POLICY_H
#define MACWS_PRODUCTION_POLICY_H

#include <stdbool.h>
#include <string.h>

// Production features survive a clean launch environment. An explicit zero
// is reserved for a controlled diagnostic opt-out; absence is never off.
static inline bool MacWSProductionDefaultEnabled(const char *value) {
    return !value || strcmp(value, "0") != 0;
}

// Defined once by mac_hooks.m so native driver selection stays consistent
// across allocation, texture, compiler and library-routing translation units.
bool macws_agx_native_enabled(void);

// Codex AGX-desktop plan: host MTLSim routing switch. Defined by mac_hooks.m;
// when true, WS must skip native AGX entirely (see macws_agx_native_enabled).
bool macws_metal_host_mode_enabled(void);

#endif
