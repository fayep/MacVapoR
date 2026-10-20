// The dashboard's panel in vapord: a world-locked panel of status and buttons, pointed at with a
// laser from a controller or a bare hand's pinch ray. vapord.m reads the runtime's state, finds
// the pointers and acts on what's pressed; this lays the panel out, draws it and hit-tests it.
// See docs/compositor.md, "Dashboard".
#pragma once
#import <Metal/Metal.h>
#include <simd/simd.h>
#include <stdbool.h>

#include "alvrxr_ext.h"

// The buttons, and what pressing each asks for.
enum { DASH_NONE, DASH_STANDING, DASH_SEATED, DASH_LOWER, DASH_HIGHER, DASH_RECENTER, DASH_QUIT, DASH_CLOSE, DASH_BUTTONS };

typedef struct {
    bool valid;                // aimed this frame
    simd_float3 origin, dir;   // the ray, dir a unit vector
    bool down;                 // trigger or pinch held
} dash_pointer;

typedef struct {
    bool show, hit;
    simd_float3 from, to;      // the beam, to where it meets the panel or fades out
} dash_beam;

bool dash_init(id<MTLDevice> dev, id<MTLCommandQueue> q);
// Puts the panel ahead of the head, facing it; it stays there until placed again.
void dash_place(simd_float3 head, simd_float3 forward);
// The panel's content: the runtime's state, and the seated eye height the Seated button sets.
void dash_set_state(const XrDashboardStateALVRXR *st, float seated);
// Hit-tests the pointers and fills their beams; returns the button pressed this frame, if any,
// and the hand that pressed it.
int dash_point(const dash_pointer p[2], dash_beam beams[2], int *hand);
// Where a button's centre is in the world, for tests to aim at.
simd_float3 dash_button_centre(int button);
// Draws the panel (premultiplied, slightly translucent), redrawing its picture first if what it
// shows changed. camera is objects.metal's Camera: view and projection.
void dash_draw(id<MTLRenderCommandEncoder> enc, const simd_float4x4 camera[2], id<MTLDepthStencilState> depth);
const char *dash_button_name(int button);

// The "Loading" panel, shown while a game loads behind the lounge (XrDashboardStateALVRXR.loading):
// placed ahead of the head when it appears and world-locked there; drawn with the game's name at
// the given opacity (vapord pulses it).
void dash_loading_place(simd_float3 head, simd_float3 forward);
void dash_loading_draw(id<MTLRenderCommandEncoder> enc, const simd_float4x4 camera[2], id<MTLDepthStencilState> depth,
                       const char program[AXR_NAME_MAX], float opacity);
