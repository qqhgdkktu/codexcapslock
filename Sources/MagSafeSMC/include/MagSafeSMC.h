#ifndef CODEX_CAPSLOCK_MAGSAFE_SMC_H
#define CODEX_CAPSLOCK_MAGSAFE_SMC_H

#include <stdint.h>

int codex_smc_write_u8(const char key[5], uint8_t value);
int codex_smc_read_u8(const char key[5], uint8_t *value);

#endif
