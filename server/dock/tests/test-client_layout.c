/* SPDX-License-Identifier: GPL-3.0-or-later
 * Copyright 2026 125hz
 * Madeira Converter Exception: see LICENSE-EXCEPTION.md */
#include "client_layout.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>
int main(void)
{
    const struct dock_client_layout *jan = dock_client_layout(
        "71b391fe9f3e2006cbc81a5c75eef3eb4186012deabfdb2c8b7e8d4850ecf640");
    const struct dock_client_layout *sep = dock_client_layout(
        "caba4826aa3501039d095aee1843a6bfb270fb43a3ab4455b2d6733223579fee");
    assert(jan && sep && jan != sep && jan->revision == 202601 && sep->revision == 202609);
    assert(!dock_client_layout(NULL) && !dock_client_layout("") && !dock_client_layout("71b391fe"));
    char changed[66]; strcpy(changed, jan->sha256); changed[63] = '1';
    assert(!dock_client_layout(changed));
    strcpy(changed, jan->sha256); strcat(changed, "0");
    assert(!dock_client_layout(changed));
    uintptr_t base = 0x10000000;
    void *vtable[216] = {0}; void **object = vtable;
    vtable[8] = (void *)(base + jan->engine_user);
    assert(dock_method_is(base, &object, 8, jan->engine_user));
    assert(!dock_method_is(base, &object, 8, sep->engine_user));
    assert(!dock_method_is(base, &object, 7, jan->engine_user));
    assert(jan->ceg_request == 0x82a8c0 && sep->ceg_request == 0x84e8b0);
    /* Offline logon: slots 5, 214 and 215, pinned per build. */
    assert(jan->logon_state == 0x7612c0 && jan->can_offline == 0x720330 && jan->logon_offline == 0x81dad0);
    assert(sep->logon_state == 0x77e460 && sep->can_offline == 0x73cbb0 && sep->logon_offline == 0x8415d0);
    vtable[215] = (void *)(base + jan->logon_offline);
    assert(dock_method_is(base, &object, 215, jan->logon_offline));
    assert(!dock_method_is(base, &object, 215, sep->logon_offline));
    assert(!dock_method_is(base, &object, 214, jan->logon_offline));
    assert(!dock_method_is(base + 1, &object, 8, jan->engine_user));
    assert(!dock_method_is(base, NULL, 8, jan->engine_user));
    object = NULL;
    assert(!dock_method_is(base, &object, 8, jan->engine_user));
    puts("PASS: exact client selection, unknown/partial/changed hash rejection and mismatched method rejection");
}
