// Small pieces of the posix surface the runtime names on the web target
// where the system library has none. Descriptor duplication cannot exist
// without a descriptor table to grow, so it reports failure and the
// file-backed cache paths that wanted it stay cleanly disabled.
#pragma once

#include <errno.h>

#ifdef __cplusplus
extern "C" {
#endif

static inline int dup(int fd) {
  (void)fd;
  errno = ENOTSUP;
  return -1;
}

#ifdef __cplusplus
}
#endif
