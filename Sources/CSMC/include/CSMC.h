#ifndef CSMC_H
#define CSMC_H

#include <stdint.h>

// Layout of the structure the AppleSMC IOKit user client takes for
// selector 2 (kSMCHandleYPCEvent). Both input and output are 80 bytes.

typedef struct {
    uint8_t  major;
    uint8_t  minor;
    uint8_t  build;
    uint8_t  reserved;
    uint16_t release;
} FPSMCVersion;

typedef struct {
    uint16_t version;
    uint16_t length;
    uint32_t cpuPLimit;
    uint32_t gpuPLimit;
    uint32_t memPLimit;
} FPSMCPLimitData;

typedef struct {
    uint32_t dataSize;
    uint32_t dataType;
    uint8_t  dataAttributes;
} FPSMCKeyInfo;

typedef struct {
    uint32_t        key;
    FPSMCVersion    vers;
    FPSMCPLimitData pLimitData;
    FPSMCKeyInfo    keyInfo;
    uint8_t         result;
    uint8_t         status;
    uint8_t         data8;
    uint32_t        data32;
    uint8_t         bytes[32];
} FPSMCParam;

_Static_assert(sizeof(FPSMCParam) == 80, "AppleSMC param struct must be 80 bytes");

enum {
    FPSMCSelectorHandleYPCEvent = 2,
    FPSMCCmdReadBytes = 5,
    FPSMCCmdWriteBytes = 6,
    FPSMCCmdReadIndex = 8,
    FPSMCCmdReadKeyInfo = 9,
};

#endif
