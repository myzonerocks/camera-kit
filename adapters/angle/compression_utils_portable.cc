#include "compression_utils_portable.h"

namespace zlib_internal {

namespace {

int WindowBitsForType(WrapperType type)
{
    switch (type)
    {
        case GZIP:
            return MAX_WBITS + 16;
        case ZRAW:
            return -MAX_WBITS;
        case ZLIB:
        default:
            return MAX_WBITS;
    }
}

}  // namespace

uLong GzipExpectedCompressedSize(uLong uncompressed_size)
{
    // compressBound() covers zlib/raw deflate framing; gzip adds a fixed
    // 10-byte header and 8-byte trailer on top of that.
    return compressBound(uncompressed_size) + 18;
}

uint32_t GetGzipUncompressedSize(const uint8_t *compressed_data, size_t compressed_size)
{
    // RFC 1952 ISIZE: the last 4 bytes of a gzip stream hold the
    // uncompressed size modulo 2^32, little-endian.
    if (compressed_size < 4)
    {
        return 0;
    }
    const uint8_t *tail = compressed_data + compressed_size - 4;
    return static_cast<uint32_t>(tail[0]) | (static_cast<uint32_t>(tail[1]) << 8) |
           (static_cast<uint32_t>(tail[2]) << 16) | (static_cast<uint32_t>(tail[3]) << 24);
}

int CompressHelper(WrapperType type,
                    Bytef *dest,
                    uLongf *dest_length,
                    const Bytef *source,
                    uLong source_length,
                    int compression_level,
                    alloc_func alloc,
                    free_func free_fn)
{
    z_stream stream;
    stream.zalloc = alloc;
    stream.zfree  = free_fn;
    stream.opaque = Z_NULL;

    int result = deflateInit2(&stream, compression_level, Z_DEFLATED, WindowBitsForType(type), 8,
                               Z_DEFAULT_STRATEGY);
    if (result != Z_OK)
    {
        return result;
    }

    stream.next_in   = const_cast<Bytef *>(source);
    stream.avail_in  = static_cast<uInt>(source_length);
    stream.next_out  = dest;
    stream.avail_out = static_cast<uInt>(*dest_length);

    result        = deflate(&stream, Z_FINISH);
    *dest_length  = stream.total_out;
    deflateEnd(&stream);

    return result == Z_STREAM_END ? Z_OK : (result == Z_OK ? Z_BUF_ERROR : result);
}

int UncompressHelper(WrapperType type,
                      Bytef *dest,
                      uLongf *dest_length,
                      const Bytef *source,
                      uLong source_length)
{
    z_stream stream;
    stream.zalloc = Z_NULL;
    stream.zfree  = Z_NULL;
    stream.opaque = Z_NULL;

    int result = inflateInit2(&stream, WindowBitsForType(type));
    if (result != Z_OK)
    {
        return result;
    }

    stream.next_in   = const_cast<Bytef *>(source);
    stream.avail_in  = static_cast<uInt>(source_length);
    stream.next_out  = dest;
    stream.avail_out = static_cast<uInt>(*dest_length);

    result        = inflate(&stream, Z_FINISH);
    *dest_length  = stream.total_out;
    inflateEnd(&stream);

    return result == Z_STREAM_END ? Z_OK : (result == Z_OK ? Z_BUF_ERROR : result);
}

}  // namespace zlib_internal
