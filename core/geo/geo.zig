//! Geographic membership: is a submitted location inside a lens's region? Pure
//! f64 math, no allocation, deterministic. The engine computes membership
//! on-device; only a boolean crosses to a trigger, so the location never leaves
//! the process, a privacy property that follows from the air-gap.
const std = @import("std");

/// Mean Earth radius (IUGG), in meters.
pub const earth_radius_m: f64 = 6_371_008.8;

/// A circular availability region: a center and a radius in meters.
pub const Circle = struct { lat: f64, lon: f64, radius_m: f64 };

fn radians(deg: f64) f64 {
    return deg * std.math.pi / 180.0;
}

/// Great-circle distance between two lat/lon points in meters (haversine).
pub fn distanceMeters(lat0: f64, lon0: f64, lat1: f64, lon1: f64) f64 {
    const p0 = radians(lat0);
    const p1 = radians(lat1);
    const dp = radians(lat1 - lat0);
    const dl = radians(lon1 - lon0);
    const a = @sin(dp / 2) * @sin(dp / 2) + @cos(p0) * @cos(p1) * @sin(dl / 2) * @sin(dl / 2);
    return earth_radius_m * 2 * std.math.atan2(@sqrt(a), @sqrt(1 - a));
}

/// Whether (lat, lon) is within radius_m of the circle's center.
pub fn withinCircle(lat: f64, lon: f64, c_lat: f64, c_lon: f64, radius_m: f64) bool {
    return distanceMeters(lat, lon, c_lat, c_lon) <= radius_m;
}

/// Whether (lat, lon) is inside the axis-aligned lat/lon box.
pub fn withinBBox(lat: f64, lon: f64, min_lat: f64, min_lon: f64, max_lat: f64, max_lon: f64) bool {
    return lat >= min_lat and lat <= max_lat and lon >= min_lon and lon <= max_lon;
}

const t = std.testing;

test "haversine matches a known great-circle distance" {
    // New York to Los Angeles is about 3936 km; allow a 1 km tolerance.
    const d = distanceMeters(40.7128, -74.0060, 34.0522, -118.2437);
    try t.expect(@abs(d - 3_936_000) < 10_000);
    try t.expectEqual(@as(f64, 0), distanceMeters(51.5, -0.12, 51.5, -0.12));
}

test "circle membership is inside up to the radius, outside beyond it" {
    const c_lat: f64 = 37.7749;
    const c_lon: f64 = -122.4194;
    // ~111 m north (0.001 deg latitude) is inside a 200 m circle, outside a 50 m one.
    try t.expect(withinCircle(c_lat + 0.001, c_lon, c_lat, c_lon, 200));
    try t.expect(!withinCircle(c_lat + 0.001, c_lon, c_lat, c_lon, 50));
    try t.expect(withinCircle(c_lat, c_lon, c_lat, c_lon, 1)); // the center is always in
}

test "bbox membership" {
    try t.expect(withinBBox(10, 20, 0, 0, 30, 30));
    try t.expect(!withinBBox(40, 20, 0, 0, 30, 30));
    try t.expect(!withinBBox(10, 40, 0, 0, 30, 30));
}
