//! Off-thread asset loading on targets without real OS threads
//! (wasm32-freestanding): every entry refuses immediately rather than
//! pretending to load. Directory-based lens activation - the only path
//! that could ever reach an asset loader - already refuses with the
//! same CK_UNSUPPORTED there before this would ever be reached.

const std = @import("std");
const image = @import("image");

pub const CreateError = error{Unsupported};

fn StubLoader(comptime Result: type) type {
    return struct {
        const Self = @This();

        pub fn start(gpa: std.mem.Allocator, path: []const u8) CreateError!*Self {
            _ = gpa;
            _ = path;
            return error.Unsupported;
        }

        pub fn take(loader: *Self) ?Result {
            _ = loader;
            return null;
        }

        pub fn hasFailed(loader: *const Self) bool {
            _ = loader;
            return true;
        }

        pub fn deinit(loader: *Self) void {
            _ = loader;
        }
    };
}

pub const ImageLoader = StubLoader(image.Image);
/// A .glb model, refused for the same reason as ImageLoader above - no
/// gltf dependency needed here at all, since every entry point returns
/// error.Unsupported before ever touching Result's actual shape.
pub const ModelLoader = StubLoader(struct {});
