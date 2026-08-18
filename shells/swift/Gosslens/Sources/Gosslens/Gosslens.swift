import CGosslens

/// ABI bootstrap and pure math - callable before any handle exists.
public enum Gosslens {
    /// Any-thread. Must be the first call this shell makes; compare the
    /// high 16 bits against the header's own GOSS_ABI_MAJOR before
    /// creating anything.
    public static func abiVersion() -> UInt32 {
        goss_abi_version()
    }

    /// Any-thread, pure. The YCbCr to RGB conversion for a standard and
    /// range as one column-major homogeneous matrix.
    public static func yuvToRgb(standard: UInt32, range: UInt32) throws -> [Float] {
        var matrix = [Float](repeating: 0, count: 16)
        try matrix.withUnsafeMutableBufferPointer { buffer in
            try checked(goss_color_yuv_to_rgb(standard, range, buffer.baseAddress))
        }
        return matrix
    }
}
