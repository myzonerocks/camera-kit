// The gzip wrapper libANGLE expects here comes from a Chromium
// third_party/zlib checkout pulled by gclient, not from ANGLE's own git
// tree, so the archive this project vendors from doesn't carry it. This
// implements the same zlib_internal surface against system zlib.

#ifndef GOSSLENS_ADAPTERS_ANGLE_COMPRESSION_UTILS_PORTABLE_H_
#define GOSSLENS_ADAPTERS_ANGLE_COMPRESSION_UTILS_PORTABLE_H_

#include <zlib.h>

#include <cstddef>
#include <cstdint>

namespace zlib_internal {

enum WrapperType { ZLIB, GZIP, ZRAW };

uLong GzipExpectedCompressedSize(uLong uncompressed_size);
uint32_t GetGzipUncompressedSize(const uint8_t *compressed_data, size_t compressed_size);

int CompressHelper(WrapperType type,
                    Bytef *dest,
                    uLongf *dest_length,
                    const Bytef *source,
                    uLong source_length,
                    int compression_level,
                    alloc_func alloc,
                    free_func free_fn);

int UncompressHelper(WrapperType type,
                      Bytef *dest,
                      uLongf *dest_length,
                      const Bytef *source,
                      uLong source_length);

inline int GzipCompressHelper(Bytef *dest,
                               uLongf *dest_length,
                               const Bytef *source,
                               uLong source_length,
                               alloc_func alloc,
                               free_func free_fn)
{
    return CompressHelper(GZIP, dest, dest_length, source, source_length, Z_DEFAULT_COMPRESSION,
                           alloc, free_fn);
}

inline int GzipUncompressHelper(Bytef *dest,
                                 uLongf *dest_length,
                                 const uint8_t *source,
                                 uLong source_length)
{
    return UncompressHelper(GZIP, dest, dest_length, reinterpret_cast<const Bytef *>(source),
                             source_length);
}

}  // namespace zlib_internal

#endif  // GOSSLENS_ADAPTERS_ANGLE_COMPRESSION_UTILS_PORTABLE_H_
