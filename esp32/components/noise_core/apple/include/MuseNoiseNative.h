#pragma once
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
// CryptoKit callback: no credentials or socket state enter the portable core.
typedef int (*MuseCrypto)(int op, const uint8_t *a, size_t an,
  const uint8_t *b, size_t bn, const uint8_t *c, size_t cn,
  const uint8_t *d, size_t dn, uint8_t *out, size_t outn);
void *muse_noise_create(MuseCrypto crypto);
void muse_noise_destroy(void *session);
int muse_noise_handshake(void *session, int step, const uint8_t *input,
  size_t inputn, uint8_t *output, size_t cap, size_t *written);
int muse_noise_request(void *session, int64_t stream, const char *path,
  const uint8_t *body, size_t bodyn, int end);
int muse_noise_body(void *session, int64_t stream, const uint8_t *body,
  size_t bodyn, int end);
int muse_noise_next(void *session, uint8_t *output, size_t cap, size_t *written);
// kind: 0 incomplete, 1 response, 2 body, 3 reset. Copies body before scratch reuse.
int muse_noise_receive(void *session, const uint8_t *input, size_t inputn,
  int *kind, int64_t *stream, int *status, int *end,
  uint8_t *body, size_t cap, size_t *written);
#ifdef __cplusplus
}
#endif
