// Xcode's native SwiftPM integration expects a compiled object per
// target; a headers-only C target (the real gosslens.h symlink) needs
// one anyway, even though plain `swift build` handles it fine without.
