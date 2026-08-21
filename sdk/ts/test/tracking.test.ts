import { test, expect } from "bun:test";
import {
  parseFaceResult,
  parseHandResult,
  parsePoseResult,
  GOSS_FACE_LANDMARK_COUNT,
  GOSS_FACE_BLENDSHAPE_COUNT,
  GOSS_POSE_LANDMARK_COUNT,
  GOSS_HAND_LANDMARK_COUNT,
} from "../src/tracking";

// These pin the parsers to the frozen C result layouts (goss_face_result,
// goss_hand_result, goss_pose_result). A drift in an offset here would be a
// silent cross-language bug; the buffers are hand-laid to match the header.

test("parseFaceResult reads the frozen goss_face_result layout", () => {
  const size = 24 + (GOSS_FACE_LANDMARK_COUNT * 3 + GOSS_FACE_BLENDSHAPE_COUNT) * 4;
  const buffer = new ArrayBuffer(size);
  const view = new DataView(buffer);
  view.setBigUint64(0, 7n, true);
  view.setBigInt64(8, 123456n, true);
  view.setFloat32(16, 0.9, true);
  view.setUint32(20, GOSS_FACE_LANDMARK_COUNT, true);
  view.setFloat32(24, 1.5, true); // first landmark x
  view.setFloat32(24 + GOSS_FACE_LANDMARK_COUNT * 3 * 4, 0.25, true); // first blendshape

  const r = parseFaceResult(buffer, 0);
  expect(r.frameSerial).toBe(7n);
  expect(r.timestampUs).toBe(123456n);
  expect(r.presence).toBeCloseTo(0.9, 5);
  expect(r.landmarkCount).toBe(GOSS_FACE_LANDMARK_COUNT);
  expect(r.landmarks.length).toBe(GOSS_FACE_LANDMARK_COUNT * 3);
  expect(r.landmarks[0]).toBeCloseTo(1.5, 5);
  expect(r.blendshapes.length).toBe(GOSS_FACE_BLENDSHAPE_COUNT);
  expect(r.blendshapes[0]).toBeCloseTo(0.25, 5);
});

test("parseFaceResult honors a non-zero result pointer", () => {
  const offset = 64;
  const size = offset + 24 + (GOSS_FACE_LANDMARK_COUNT * 3 + GOSS_FACE_BLENDSHAPE_COUNT) * 4;
  const buffer = new ArrayBuffer(size);
  const view = new DataView(buffer, offset);
  view.setUint32(20, GOSS_FACE_LANDMARK_COUNT, true);
  view.setFloat32(24, 2.0, true);
  const r = parseFaceResult(buffer, offset);
  expect(r.landmarkCount).toBe(GOSS_FACE_LANDMARK_COUNT);
  expect(r.landmarks[0]).toBeCloseTo(2.0, 5);
});

test("parseHandResult reads a hand out of the frozen layout", () => {
  const stride = 16 + GOSS_HAND_LANDMARK_COUNT * 3 * 4;
  const buffer = new ArrayBuffer(24 + 2 * stride);
  const view = new DataView(buffer);
  view.setBigUint64(0, 3n, true);
  view.setUint32(16, 1, true); // one hand
  const base = 24;
  view.setFloat32(base, 0.8, true); // presence
  view.setFloat32(base + 4, 0.95, true); // handedness
  view.setUint32(base + 8, 2, true); // gesture
  view.setFloat32(base + 12, 0.7, true); // gesture score
  view.setFloat32(base + 16, 4.5, true); // first landmark x

  const r = parseHandResult(buffer, 0);
  expect(r.frameSerial).toBe(3n);
  expect(r.handCount).toBe(1);
  expect(r.hands.length).toBe(1);
  expect(r.hands[0].presence).toBeCloseTo(0.8, 5);
  expect(r.hands[0].handedness).toBeCloseTo(0.95, 5);
  expect(r.hands[0].gesture).toBe(2);
  expect(r.hands[0].gestureScore).toBeCloseTo(0.7, 5);
  expect(r.hands[0].landmarks.length).toBe(GOSS_HAND_LANDMARK_COUNT * 3);
  expect(r.hands[0].landmarks[0]).toBeCloseTo(4.5, 5);
});

test("parseHandResult returns no hands for a zero count", () => {
  const stride = 16 + GOSS_HAND_LANDMARK_COUNT * 3 * 4;
  const buffer = new ArrayBuffer(24 + 2 * stride);
  const r = parseHandResult(buffer, 0);
  expect(r.handCount).toBe(0);
  expect(r.hands.length).toBe(0);
});

test("parsePoseResult reads the frozen goss_pose_result layout", () => {
  const buffer = new ArrayBuffer(688);
  const view = new DataView(buffer);
  view.setFloat32(16, 0.99, true); // presence
  view.setUint32(20, GOSS_POSE_LANDMARK_COUNT, true);
  view.setFloat32(24, 3.0, true); // first landmark x
  view.setFloat32(24 + GOSS_POSE_LANDMARK_COUNT * 3 * 4, 0.5, true); // first visibility
  view.setFloat32(24 + GOSS_POSE_LANDMARK_COUNT * 4 * 4, 0.6, true); // first presence

  const r = parsePoseResult(buffer, 0);
  expect(r.presence).toBeCloseTo(0.99, 5);
  expect(r.landmarkCount).toBe(GOSS_POSE_LANDMARK_COUNT);
  expect(r.landmarks.length).toBe(GOSS_POSE_LANDMARK_COUNT * 3);
  expect(r.landmarks[0]).toBeCloseTo(3.0, 5);
  expect(r.visibilities.length).toBe(GOSS_POSE_LANDMARK_COUNT);
  expect(r.visibilities[0]).toBeCloseTo(0.5, 5);
  expect(r.presences.length).toBe(GOSS_POSE_LANDMARK_COUNT);
  expect(r.presences[0]).toBeCloseTo(0.6, 5);
});
