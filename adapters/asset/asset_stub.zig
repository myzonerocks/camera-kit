//! Off-thread asset loading on targets without real OS threads
//! (wasm32-freestanding): every entry refuses immediately rather than
//! pretending to load. Directory-based lens activation - the only path
//! that could ever reach an asset loader - already refuses with the
//! same GOSS_UNSUPPORTED there before this would ever be reached.

const std = @import("std");
const image = @import("image");
const gltf = @import("gltf");

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
/// A .glb model, refused for the same reason as ImageLoader above -
/// still needs the real Result shape (gltf.DecodedModel, the same stub
/// type the real asset.zig's own ModelLoader uses) even though take()
/// never actually returns one: callers that pattern-match a successful
/// take() (pollModelLoaders in core/abi/abi.zig) still type-check that
/// branch's body against Result's real fields.
pub const ModelLoader = StubLoader(gltf.DecodedModel);
