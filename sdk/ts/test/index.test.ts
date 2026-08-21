import { test, expect } from "bun:test";
import { pickEngineUrl, GOSS_SEGMENTATION_CHANNELS, GOSS_FACE_LANDMARK_COUNT } from "../src/index";

test("GOSS_SEGMENTATION_CHANNELS is the engine's frozen channel order", () => {
  expect([...GOSS_SEGMENTATION_CHANNELS]).toEqual([
    "person",
    "background",
    "hair",
    "body_skin",
    "face_skin",
    "clothes",
    "others",
  ]);
});

test("landmark count matches the frozen ABI", () => {
  expect(GOSS_FACE_LANDMARK_COUNT).toBe(478);
});

test("pickEngineUrl only chooses WebGPU with a real adapter", async () => {
  const nav = globalThis.navigator as unknown as { gpu?: unknown };
  const had = "gpu" in nav;
  const original = nav.gpu;
  try {
    nav.gpu = undefined; // no WebGPU at all
    expect(await pickEngineUrl("gpu.js", "gl.js")).toBe("gl.js");

    nav.gpu = { requestAdapter: async () => ({}) }; // a real adapter
    expect(await pickEngineUrl("gpu.js", "gl.js")).toBe("gpu.js");

    nav.gpu = { requestAdapter: async () => null }; // gpu present, no adapter
    expect(await pickEngineUrl("gpu.js", "gl.js")).toBe("gl.js");

    nav.gpu = {
      requestAdapter: async () => {
        throw new Error("adapter blew up");
      },
    };
    expect(await pickEngineUrl("gpu.js", "gl.js")).toBe("gl.js");
  } finally {
    if (had) nav.gpu = original;
    else delete nav.gpu;
  }
});
