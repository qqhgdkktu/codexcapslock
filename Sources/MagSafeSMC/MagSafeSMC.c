// SMC access is derived from MagSafe Dark by Mark Kats (MIT License).
// See THIRD_PARTY_NOTICES.md.

#include "MagSafeSMC.h"

#include <IOKit/IOKitLib.h>
#include <string.h>

typedef struct {
    uint8_t major;
    uint8_t minor;
    uint8_t build;
    uint8_t reserved;
    uint16_t release;
} SMCVersion;

typedef struct {
    uint16_t version;
    uint16_t length;
    uint32_t cpuPLimit;
    uint32_t gpuPLimit;
    uint32_t memPLimit;
} SMCPLimitData;

typedef struct {
    uint32_t dataSize;
    uint32_t dataType;
    uint8_t dataAttributes;
} SMCKeyInfoData;

typedef struct {
    uint32_t key;
    SMCVersion vers;
    SMCPLimitData pLimitData;
    SMCKeyInfoData keyInfo;
    uint8_t result;
    uint8_t status;
    uint8_t data8;
    uint32_t data32;
    uint8_t bytes[32];
} SMCParamStruct;

static uint32_t fourcc(const char key[5]) {
    return ((uint32_t)key[0] << 24)
        | ((uint32_t)key[1] << 16)
        | ((uint32_t)key[2] << 8)
        | (uint32_t)key[3];
}

static kern_return_t smc_open(io_connect_t *connection) {
    io_service_t service = IOServiceGetMatchingService(
        kIOMainPortDefault,
        IOServiceMatching("AppleSMC")
    );
    if (service == IO_OBJECT_NULL) {
        return kIOReturnNotFound;
    }

    kern_return_t result = IOServiceOpen(service, mach_task_self(), 0, connection);
    IOObjectRelease(service);
    return result;
}

static kern_return_t smc_call(
    io_connect_t connection,
    SMCParamStruct *input,
    SMCParamStruct *output
) {
    size_t inputSize = sizeof(*input);
    size_t outputSize = sizeof(*output);
    memset(output, 0, sizeof(*output));
    return IOConnectCallStructMethod(
        connection,
        2,
        input,
        inputSize,
        output,
        &outputSize
    );
}

static kern_return_t get_key_info(
    io_connect_t connection,
    uint32_t key,
    SMCKeyInfoData *info
) {
    SMCParamStruct input = {0};
    SMCParamStruct output = {0};
    input.key = key;
    input.data8 = 9;

    kern_return_t result = smc_call(connection, &input, &output);
    if (result == KERN_SUCCESS) {
        *info = output.keyInfo;
    }
    return result;
}

int codex_smc_write_u8(const char key[5], uint8_t value) {
    io_connect_t connection = IO_OBJECT_NULL;
    kern_return_t result = smc_open(&connection);
    if (result != KERN_SUCCESS) {
        return (int)result;
    }

    SMCKeyInfoData info = {0};
    uint32_t encodedKey = fourcc(key);
    result = get_key_info(connection, encodedKey, &info);
    if (result != KERN_SUCCESS) {
        IOServiceClose(connection);
        return (int)result;
    }

    SMCParamStruct input = {0};
    SMCParamStruct output = {0};
    input.key = encodedKey;
    input.data8 = 6;
    input.keyInfo.dataSize = info.dataSize ? info.dataSize : 1;
    input.bytes[0] = value;
    result = smc_call(connection, &input, &output);
    IOServiceClose(connection);
    return (int)result;
}

int codex_smc_read_u8(const char key[5], uint8_t *value) {
    if (value == NULL) {
        return -1;
    }

    io_connect_t connection = IO_OBJECT_NULL;
    kern_return_t result = smc_open(&connection);
    if (result != KERN_SUCCESS) {
        return (int)result;
    }

    SMCKeyInfoData info = {0};
    uint32_t encodedKey = fourcc(key);
    result = get_key_info(connection, encodedKey, &info);
    if (result != KERN_SUCCESS) {
        IOServiceClose(connection);
        return (int)result;
    }

    SMCParamStruct input = {0};
    SMCParamStruct output = {0};
    input.key = encodedKey;
    input.data8 = 5;
    input.keyInfo.dataSize = info.dataSize ? info.dataSize : 1;
    result = smc_call(connection, &input, &output);
    if (result == KERN_SUCCESS) {
        *value = output.bytes[0];
    }
    IOServiceClose(connection);
    return (int)result;
}
