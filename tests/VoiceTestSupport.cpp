#include "VoiceTestSupport.h"
#include "external_sender.h"
#include <cstdlib>
#include <cstring>
using discord::dave::test::ExternalSender;
static uint8_t *copy(const std::vector<uint8_t>& bytes, size_t *length) {
    *length = bytes.size();
    auto result = static_cast<uint8_t *>(malloc(bytes.size()));
    if (result) memcpy(result, bytes.data(), bytes.size());
    return result;
}
void *voice_test_sender_create(uint64_t group) { return new ExternalSender(1, group); }
void voice_test_sender_destroy(void *sender) { delete static_cast<ExternalSender *>(sender); }
uint8_t *voice_test_external(void *sender, size_t *length) {
    return copy(static_cast<ExternalSender *>(sender)->GetMarshalledExternalSender(), length);
}
uint8_t *voice_test_proposal(void *sender, const uint8_t *package, size_t length, size_t *out) {
    return copy(static_cast<ExternalSender *>(sender)->ProposeAdd(0, {package, package + length}), out);
}
uint8_t *voice_test_split(void *sender, const uint8_t *message, size_t length, int welcome, size_t *out) {
    auto pair = static_cast<ExternalSender *>(sender)->SplitCommitWelcome({message, message + length});
    return copy(welcome ? pair.second : pair.first, out);
}
void voice_test_free(void *pointer) { free(pointer); }
