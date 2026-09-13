#include <stdint.h>
#include <stddef.h>
#ifndef __cplusplus
#include "../VoiceNative/include/TinyCordVoiceNative.h"
#endif
#ifdef __cplusplus
extern "C" {
#endif
void *voice_test_sender_create(uint64_t group);
void voice_test_sender_destroy(void *sender);
uint8_t *voice_test_external(void *sender, size_t *length);
uint8_t *voice_test_proposal(void *sender, const uint8_t *package, size_t length, size_t *out_length);
uint8_t *voice_test_split(void *sender, const uint8_t *message, size_t length, int welcome, size_t *out_length);
void voice_test_free(void *pointer);
#ifdef __cplusplus
}
#endif
