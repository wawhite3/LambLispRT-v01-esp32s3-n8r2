// Copyright 2026 by Frobenius Norm LLC 2026-10-03
// GENERATED from scm/features/llloader-vocab.scm by w3_ai_scripts/llip_vocab_gen.py -- DO NOT EDIT
//
// The loader's LLIP frame vocabulary, generated from scm/features/llloader-vocab.scm --
// a SIBLING of the move vocabulary, deliberately (owner, 2026-09-30): a bootloader and a
// 4WD have no reason to version together, and coupling them would let a move-program edit
// invalidate this header inside the trusted root.
//
// THE LIMITS BELOW ARE THE SECURITY ARGUMENT MADE STRUCTURAL.  The only string form is
// exactly 64 hex characters -- a sha256 -- so a literal cannot carry a payload; the depth is
// fixed at 2 so the reader needs no stack and no recursion; and the frame is bounded so
// there is nothing to exhaust.  A reader that accepts more than this is a different reader.

#pragma once

#include <stddef.h>

#define LLLOADER_MAX_FRAME_BYTES 512
#define LLLOADER_MAX_FIELDS      12
#define LLLOADER_MAX_DEPTH       2
#define LLLOADER_MAX_SYMBOL      24
#define LLLOADER_SHA256_HEX      64

// NVS keys of the loader<->VM handshake, namespace "ota-p125".  Spelled once, in the
// vocabulary.  A key misspelt on either side is not an error anywhere -- nvs_get returns
// NOT_FOUND and the reader takes its default -- so the handshake degrades to "nothing
// pending" in silence.  The VM's half is src/ll_ota_loader_contract.h, from this source.
#define LLLOADER_KEY_PENDING_UPDATE  "pending_update"   // u8
#define LLLOADER_KEY_INSTALL_TRIES   "install_tries"   // u8
#define LLLOADER_KEY_DEATH_REASON    "death_reason"   // str
#define LLLOADER_KEY_DEATH_COUNT     "death_count"   // u8

typedef enum {
    LLLOADER_ACT_NORMAL,
    LLLOADER_ACT_INSTALL,
    LLLOADER_ACT_RECOVER,
    LLLOADER_ACT_CONSOLE,
    LLLOADER_ACT_COUNT
} llloader_action_t;

static const char *const llloader_action_t_names[] = {
    "normal",
    "install",
    "recover",
    "console",
};

typedef enum {
    LLLOADER_RUNG_AUX_FS,
    LLLOADER_RUNG_NETWORK,
    LLLOADER_RUNG_BLE_CONSOLE,
    LLLOADER_RUNG_CONSOLE_UART,
    LLLOADER_RUNG_COUNT
} llloader_rung_t;

static const char *const llloader_rung_t_names[] = {
    "aux-fs",
    "network",
    "ble-console",
    "console-uart",
};

typedef enum {
    LLLOADER_SLOT_FACTORY,
    LLLOADER_SLOT_OTA_0,
    LLLOADER_SLOT_OTA_1,
    LLLOADER_SLOT_COUNT
} llloader_slot_t;

static const char *const llloader_slot_t_names[] = {
    "factory",
    "ota_0",
    "ota_1",
};

// Field value types, from llloader-field-types.  `hex` is the ONLY non-atomic form and
// it is exactly LLLOADER_SHA256_HEX characters -- there is no string literal in this
// grammar at all, so a literal cannot carry a payload.
typedef enum {
    LLLOADER_FT_INTEGER,
    LLLOADER_FT_SYMBOL,
    LLLOADER_FT_BOOLEAN,
    LLLOADER_FT_HEX,
} llloader_field_type_t;

// frame tag -> kind.  A `query` is read-only; a `command` sets the pending action the
// loader already reads from NVS and requires an authenticated session.
typedef enum { LLLOADER_FK_QUERY, LLLOADER_FK_COMMAND, LLLOADER_FK_REPLY } llloader_frame_kind_t;

typedef struct {
    const char *tag;
    llloader_frame_kind_t kind;
    const char *const *fields;
    const llloader_field_type_t *types;
    size_t nfields;
} llloader_frame_t;

static const char *const llloader_fields_ota_state[] = { "seq" };
static const llloader_field_type_t llloader_types_ota_state[] = { LLLOADER_FT_INTEGER };
static const char *const llloader_fields_ota_ladder[] = { "seq" };
static const llloader_field_type_t llloader_types_ota_ladder[] = { LLLOADER_FT_INTEGER };
static const char *const llloader_fields_ota_install[] = { "seq", "slot", "size", "sha256", "golden" };
static const llloader_field_type_t llloader_types_ota_install[] = { LLLOADER_FT_INTEGER, LLLOADER_FT_SYMBOL, LLLOADER_FT_INTEGER, LLLOADER_FT_HEX, LLLOADER_FT_BOOLEAN };
static const char *const llloader_fields_ota_recover[] = { "seq", "golden" };
static const llloader_field_type_t llloader_types_ota_recover[] = { LLLOADER_FT_INTEGER, LLLOADER_FT_BOOLEAN };
static const char *const llloader_fields_ota_ack[] = { "seq", "accepted", "pending", "reason" };
static const llloader_field_type_t llloader_types_ota_ack[] = { LLLOADER_FT_INTEGER, LLLOADER_FT_BOOLEAN, LLLOADER_FT_SYMBOL, LLLOADER_FT_SYMBOL };
static const char *const llloader_fields_ota_result[] = { "seq", "rung", "digest", "action", "slot" };
static const llloader_field_type_t llloader_types_ota_result[] = { LLLOADER_FT_INTEGER, LLLOADER_FT_SYMBOL, LLLOADER_FT_SYMBOL, LLLOADER_FT_SYMBOL, LLLOADER_FT_SYMBOL };
static const char *const llloader_fields_ota_progress[] = { "seq", "rung", "bytes", "of" };
static const llloader_field_type_t llloader_types_ota_progress[] = { LLLOADER_FT_INTEGER, LLLOADER_FT_SYMBOL, LLLOADER_FT_INTEGER, LLLOADER_FT_INTEGER };
static const char *const llloader_fields_ota_death[] = { "seq", "reason", "count" };
static const llloader_field_type_t llloader_types_ota_death[] = { LLLOADER_FT_INTEGER, LLLOADER_FT_SYMBOL, LLLOADER_FT_INTEGER };
static const char *const llloader_fields_ota_status[] = { "seq", "slot", "image", "pending", "tries", "reason", "count" };
static const llloader_field_type_t llloader_types_ota_status[] = { LLLOADER_FT_INTEGER, LLLOADER_FT_SYMBOL, LLLOADER_FT_SYMBOL, LLLOADER_FT_SYMBOL, LLLOADER_FT_INTEGER, LLLOADER_FT_SYMBOL, LLLOADER_FT_INTEGER };
static const char *const llloader_fields_ota_rung[] = { "seq", "rung", "order" };
static const llloader_field_type_t llloader_types_ota_rung[] = { LLLOADER_FT_INTEGER, LLLOADER_FT_SYMBOL, LLLOADER_FT_INTEGER };

static const llloader_frame_t llloader_frames[] = {
    { "ota-state", LLLOADER_FK_QUERY, llloader_fields_ota_state, llloader_types_ota_state, 1 },
    { "ota-ladder", LLLOADER_FK_QUERY, llloader_fields_ota_ladder, llloader_types_ota_ladder, 1 },
    { "ota-install", LLLOADER_FK_COMMAND, llloader_fields_ota_install, llloader_types_ota_install, 5 },
    { "ota-recover", LLLOADER_FK_COMMAND, llloader_fields_ota_recover, llloader_types_ota_recover, 2 },
    { "ota-ack", LLLOADER_FK_REPLY, llloader_fields_ota_ack, llloader_types_ota_ack, 4 },
    { "ota-result", LLLOADER_FK_REPLY, llloader_fields_ota_result, llloader_types_ota_result, 5 },
    { "ota-progress", LLLOADER_FK_REPLY, llloader_fields_ota_progress, llloader_types_ota_progress, 4 },
    { "ota-death", LLLOADER_FK_REPLY, llloader_fields_ota_death, llloader_types_ota_death, 3 },
    { "ota-status", LLLOADER_FK_REPLY, llloader_fields_ota_status, llloader_types_ota_status, 7 },
    { "ota-rung", LLLOADER_FK_REPLY, llloader_fields_ota_rung, llloader_types_ota_rung, 3 },
};

#define LLLOADER_NFRAMES (sizeof(llloader_frames)/sizeof(llloader_frames[0]))
