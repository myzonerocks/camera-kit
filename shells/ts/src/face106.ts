// The face contour convention the beauty effects consume: one hundred and
// six points in a fixed order, jaw and brows and eyes and nose and mouth,
// each the tracked mesh vertex closest to it on the canonical face, plus
// five more for regions the face-makeup mesh needs a center point for but
// no single landmark covers (the mouth opening, each eyebrow, each
// cheek) - the same table core/tracking/face106.zig defines for the
// native shells, ported verbatim so a lens effect that reads it behaves
// identically regardless of which shell tracked the frame.

export const BASE_POINT_COUNT = 106;
export const POINT_COUNT = 111;

const MESH_INDEX = [
  139, 34, 34, 116, 123, 147, 147, 213, 192, 135, 135, 169, 170, 140, 140, 171, 152, 396, 369, 369, 395, 394, 364,
  364, 416, 433, 376, 376, 352, 345, 264, 264, 368, 71, 68, 104, 105, 66, 296, 334, 333, 298, 301, 168, 197, 5, 1,
  165, 167, 0, 393, 391, 113, 30, 158, 154, 153, 25, 381, 385, 260, 342, 255, 380, 63, 63, 52, 65, 295, 282, 293,
  293, 29, 144, 160, 259, 373, 387, 244, 464, 49, 279, 203, 423, 43, 96, 87, 14, 317, 325, 273, 335, 421, 200, 201,
  106, 43, 181, 16, 405, 273, 405, 17, 181, 160, 387,
] as const;

// Each hub point (106-110) as the centroid of these already-filled
// contour indices (0-105), not raw mediapipe landmarks.
const HUB_NEIGHBORS = [
  [97, 98, 99, 101, 102, 103], // 106: mouth-opening center
  [34, 35, 36, 65, 66], // 107: left eyebrow hub
  [39, 40, 41, 69, 70], // 108: right eyebrow hub
  [4, 5, 6, 7, 56, 57, 74, 80, 82], // 109: left cheek hub
  [25, 26, 27, 28, 62, 63, 76, 81, 83], // 110: right cheek hub
] as const;

/// Fills the effect engine's landmark layout from tracked mesh landmarks:
/// x then y per point, normalized by the frame size, in the same 0..1
/// image-space sense a tracked landmark's own x/y already use, the raw
/// 106 first and then the five derived hub points.
export function fill(landmarks: Float32Array, width: number, height: number): Float32Array {
  const out = new Float32Array(POINT_COUNT * 2);
  for (let at = 0; at < MESH_INDEX.length; at += 1) {
    const vertex = MESH_INDEX[at]!;
    out[at * 2] = landmarks[vertex * 3]! / width;
    out[at * 2 + 1] = landmarks[vertex * 3 + 1]! / height;
  }
  for (let at = 0; at < HUB_NEIGHBORS.length; at += 1) {
    const neighbors = HUB_NEIGHBORS[at]!;
    let sumX = 0;
    let sumY = 0;
    for (const n of neighbors) {
      sumX += out[n * 2]!;
      sumY += out[n * 2 + 1]!;
    }
    const hub = BASE_POINT_COUNT + at;
    out[hub * 2] = sumX / neighbors.length;
    out[hub * 2 + 1] = sumY / neighbors.length;
  }
  return out;
}
