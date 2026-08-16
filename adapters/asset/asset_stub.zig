//! Off-thread asset loading on targets without real OS threads
//! (wasm32-freestanding): every entry refuses immediately rather than
//! pretending to load. Directory-based lens activation - the only path
//! that could ever reach an asset loader - already refuses with the
//! same CK_UNSUPPORTED there before this would ever be reached.

const std = @import("std");
const image = @import("image");

pub const CreateError = error{Unsupported};

pub const Loader = struct {
    pub fn start(gpa: std.mem.Allocator, path: []const u8) CreateError!*Loader {
        _ = gpa;
        _ = path;
        return error.Unsupported;
    }

    pub fn take(loader: *Loader) ?image.Image {
        _ = loader;
        return null;
    }

    pub fn hasFailed(loader: *const Loader) bool {
        _ = loader;
        return true;
    }

    pub fn deinit(loader: *Loader) void {
        _ = loader;
    }
};
