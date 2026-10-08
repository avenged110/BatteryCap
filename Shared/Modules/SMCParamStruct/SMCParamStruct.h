// MARK: - SMCParamStruct.h
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
//
// The AppleSMC user-client interface: selector numbers, result codes, and the parameter
// block passed to `IOConnectCallStructMethod`. Every value and field layout here is fixed
// by AppleSMC.kext's ABI — the kernel reads this block byte for byte — so none of it may
// change. Written independently for BatteryCap to replace an APSL-2.0 header, whose
// license is not GPL-compatible. Field names are kept as the ABI's conventional names so
// callers are unaffected.

#ifndef BATTERYCAP_SMCPARAMSTRUCT_H
#define BATTERYCAP_SMCPARAMSTRUCT_H

#include <stdint.h>
#include <IOKit/IOTypes.h>
#include <IOKit/IOKitLib.h>

__BEGIN_DECLS

// Result codes reported in `SMCParamStruct.result`.
enum {
    kSMCSuccess     = 0,
    kSMCError       = 1,
    kSMCKeyNotFound = 0x84,
};

// Selectors: the struct-method index passed alongside the parameter block.
enum {
    kSMCUserClientOpen  = 0,
    kSMCUserClientClose = 1,
    kSMCHandleYPCEvent  = 2,
    kSMCReadKey         = 5,
    kSMCWriteKey        = 6,
    kSMCGetKeyCount     = 7,
    kSMCGetKeyFromIndex = 8,
    kSMCGetKeyInfo      = 9,
};

typedef struct SMCVersion {
    uint8_t  major;
    uint8_t  minor;
    uint8_t  build;
    uint8_t  reserved;
    uint16_t release;
} SMCVersion;

typedef struct SMCPLimitData {
    uint16_t version;
    uint16_t length;
    uint32_t cpuPLimit;
    uint32_t gpuPLimit;
    uint32_t memPLimit;
} SMCPLimitData;

typedef struct SMCKeyInfoData {
    uint32_t dataSize;
    uint32_t dataType;
    uint8_t  dataAttributes;
} SMCKeyInfoData;

// The parameter block, in and out. Natural alignment is part of the ABI: the kernel
// expects the same padding the compiler inserts here (80 bytes in total).
typedef struct {
    uint32_t       key;
    SMCVersion     vers;
    SMCPLimitData  pLimitData;
    SMCKeyInfoData keyInfo;
    uint8_t        result;
    uint8_t        status;
    uint8_t        data8;
    uint32_t       data32;
    uint8_t        bytes[32];
} SMCParamStruct;

_Static_assert(sizeof(SMCParamStruct) == 80, "SMCParamStruct must match AppleSMC's ABI");

__END_DECLS

#endif // BATTERYCAP_SMCPARAMSTRUCT_H
