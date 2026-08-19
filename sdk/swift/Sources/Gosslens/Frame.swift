import CGosslens

/// Pixel layout of a camera frame as delivered by the platform.
/// Raw values mirror the frozen C enum.
public enum PixelFormat: UInt32 {
    case nv12 = 0
    case nv21 = 1
    case i420 = 2
    case bgra8 = 3
    case rgba8 = 4
}

public enum ColorStandard: UInt32 {
    case bt601 = 0
    case bt709 = 1
    case bt2020 = 2
}

public enum ColorRange: UInt32 {
    case video = 0
    case full = 1
}

/// Platform thermal pressure, fed by the SDK from the OS thermal API.
public enum Thermal: UInt32 {
    case nominal = 0
    case fair = 1
    case serious = 2
    case critical = 3
}

/// How the pipeline is currently degraded. Levels only trade effect
/// quality; capture and preview never stop.
public enum DegradeLevel: UInt32 {
    case full = 0
    case reducedMlCadence = 1
    case segmentationOff = 2
    case beautySimplified = 3
    case passthrough = 4
}

/// Describes one camera frame. rotationDegrees is the clockwise turn to
/// apply for upright display, a multiple of 90; mirrored flips
/// horizontally, for front cameras.
public struct FrameDesc {
    public var width: UInt32
    public var height: UInt32
    public var pixelFormat: PixelFormat
    public var colorStandard: ColorStandard
    public var colorRange: ColorRange
    public var rotationDegrees: UInt32
    public var mirrored: Bool
    public var timestampUs: Int64

    public init(width: UInt32, height: UInt32, pixelFormat: PixelFormat, colorStandard: ColorStandard = .bt709, colorRange: ColorRange = .video, rotationDegrees: UInt32 = 0, mirrored: Bool = false, timestampUs: Int64 = 0) {
        self.width = width
        self.height = height
        self.pixelFormat = pixelFormat
        self.colorStandard = colorStandard
        self.colorRange = colorRange
        self.rotationDegrees = rotationDegrees
        self.mirrored = mirrored
        self.timestampUs = timestampUs
    }

    var raw: goss_frame_desc {
        var flags = (rotationDegrees / 90) << GOSS_FRAME_ROTATION_SHIFT
        if mirrored { flags |= GOSS_FRAME_FLAG_MIRROR }
        return goss_frame_desc(
            width: width, height: height,
            pixel_format: pixelFormat.rawValue, color_standard: colorStandard.rawValue, color_range: colorRange.rawValue,
            flags: flags, timestamp_us: timestampUs
        )
    }
}
