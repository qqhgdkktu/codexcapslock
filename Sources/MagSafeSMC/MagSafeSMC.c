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

static const char ACLC_KEY[5] = "ACLC";
static const char UI8_TYPE[5] = "ui8 ";

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

static int smc_call(
    io_connect_t connection,
    SMCParamStruct *input,
    SMCParamStruct *output
) {
    size_t inputSize = sizeof(*input);
    size_t outputSize = sizeof(*output);
    memset(output, 0, sizeof(*output));
    kern_return_t transport = IOConnectCallStructMethod(
        connection,
        2,
        input,
        inputSize,
        output,
        &outputSize
    );
    if (transport != KERN_SUCCESS) {
        return (int)transport;
    }
    if (outputSize != sizeof(*output)) {
        return CODEX_SMC_ERROR_OUTPUT_SIZE;
    }
    if (output->result != 0) {
        return CODEX_SMC_ERROR_RESULT;
    }
    if (output->status != 0) {
        return CODEX_SMC_ERROR_STATUS;
    }
    return 0;
}

static int get_key_info(
    io_connect_t connection,
    uint32_t key,
    SMCKeyInfoData *info
) {
    SMCParamStruct input = {0};
    SMCParamStruct output = {0};
    input.key = key;
    input.data8 = 9;

    int result = smc_call(connection, &input, &output);
    if (result == 0) {
        *info = output.keyInfo;
    }
    return result;
}

static int validate_aclc_info(const SMCKeyInfoData *info) {
    if (info->dataSize != 1) {
        return CODEX_SMC_ERROR_KEY_SIZE;
    }
    if (info->dataType != fourcc(UI8_TYPE)) {
        return CODEX_SMC_ERROR_KEY_TYPE;
    }
    return 0;
}

static int read_aclc(io_connect_t connection, uint8_t *value) {
    SMCKeyInfoData info = {0};
    uint32_t encodedKey = fourcc(ACLC_KEY);
    int result = get_key_info(connection, encodedKey, &info);
    if (result != 0) {
        return result;
    }
    result = validate_aclc_info(&info);
    if (result != 0) {
        return result;
    }

    SMCParamStruct input = {0};
    SMCParamStruct output = {0};
    input.key = encodedKey;
    input.data8 = 5;
    input.keyInfo.dataSize = 1;
    result = smc_call(connection, &input, &output);
    if (result == 0) {
        *value = output.bytes[0];
    }
    return result;
}

int codex_smc_set_aclc(uint8_t value) {
    io_connect_t connection = IO_OBJECT_NULL;
    kern_return_t result = smc_open(&connection);
    if (result != KERN_SUCCESS) {
        return (int)result;
    }

    SMCKeyInfoData info = {0};
    uint32_t encodedKey = fourcc(ACLC_KEY);
    int operation = get_key_info(connection, encodedKey, &info);
    if (operation != 0) {
        IOServiceClose(connection);
        return operation;
    }
    operation = validate_aclc_info(&info);
    if (operation != 0) {
        IOServiceClose(connection);
        return operation;
    }

    SMCParamStruct input = {0};
    SMCParamStruct output = {0};
    input.key = encodedKey;
    input.data8 = 6;
    input.keyInfo.dataSize = 1;
    input.bytes[0] = value;
    operation = smc_call(connection, &input, &output);
    if (operation == 0) {
        uint8_t actual = 0;
        operation = read_aclc(connection, &actual);
        if (operation == 0 && actual != value) {
            operation = CODEX_SMC_ERROR_READBACK;
        }
    }
    IOServiceClose(connection);
    return operation;
}

int codex_smc_get_aclc(uint8_t *value) {
    if (value == NULL) {
        return CODEX_SMC_ERROR_ARGUMENT;
    }

    io_connect_t connection = IO_OBJECT_NULL;
    kern_return_t result = smc_open(&connection);
    if (result != KERN_SUCCESS) {
        return (int)result;
    }

    int operation = read_aclc(connection, value);
    IOServiceClose(connection);
    return operation;
}
