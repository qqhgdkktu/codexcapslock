#ifndef CODEX_CAPSLOCK_MAGSAFE_SMC_H
#define CODEX_CAPSLOCK_MAGSAFE_SMC_H

#include <stdint.h>

enum {
    CODEX_SMC_ERROR_ARGUMENT = -1,
    CODEX_SMC_ERROR_OUTPUT_SIZE = -2,
    CODEX_SMC_ERROR_RESULT = -3,
    CODEX_SMC_ERROR_STATUS = -4,
    CODEX_SMC_ERROR_KEY_SIZE = -5,
    CODEX_SMC_ERROR_KEY_TYPE = -6,
    CODEX_SMC_ERROR_READBACK = -7,
};

int codex_smc_set_aclc(uint8_t value);
int codex_smc_get_aclc(uint8_t *value);

#endif
