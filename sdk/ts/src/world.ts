/// The WebXR world backend: reads the viewer pose, projection, detected
/// planes, and tracked anchors off each XR frame and feeds them into
/// the session. The page owns the XR session; this source only reads.

import type { GossSession, GossWorldPlane, GossWorldAnchorInput } from "./index";

// WebXR's types live outside the DOM lib; the narrow slice this source
// reads is declared here so no type package enters the build.
interface XRRigidTransformLike {
  matrix: Float32Array;
}

interface XRViewLike {
  projectionMatrix: Float32Array;
}

interface XRViewerPoseLike {
  transform: XRRigidTransformLike;
  views: XRViewLike[];
  emulatedPosition?: boolean;
}

interface XRPlaneLike {
  planeSpace: unknown;
}

interface XRAnchorLike {
  anchorSpace: unknown;
}

interface XRPoseLike {
  transform: XRRigidTransformLike;
}

export interface GossXRFrameLike {
  getViewerPose(referenceSpace: unknown): XRViewerPoseLike | null;
  getPose(space: unknown, referenceSpace: unknown): XRPoseLike | null;
  detectedPlanes?: Set<XRPlaneLike>;
  trackedAnchors?: Set<XRAnchorLike>;
}

export class GossWebXRWorldSource {
  private planeIds = new Map<XRPlaneLike, number>();
  private anchorIds = new Map<XRAnchorLike, number>();
  private nextId = 1;

  constructor(private readonly session: GossSession) {}

  /// Call once per XR animation frame with the frame and the reference
  /// space the page renders against.
  onFrame(frame: GossXRFrameLike, referenceSpace: unknown, timestampUs: number): void {
    const viewer = frame.getViewerPose(referenceSpace);
    if (!viewer || viewer.views.length === 0) {
      this.session.submitWorld({
        trackingState: 1,
        worldFromCamera: identity16,
        projection: identity16,
        timestampUs,
      });
      return;
    }

    const planes: GossWorldPlane[] = [];
    if (frame.detectedPlanes) {
      for (const plane of frame.detectedPlanes) {
        const pose = frame.getPose(plane.planeSpace, referenceSpace);
        if (!pose) continue;
        planes.push({
          id: this.idFor(this.planeIds, plane),
          pose: pose.transform.matrix,
          extentX: 0,
          extentZ: 0,
          classification: 0,
        });
      }
    }
    const anchors: GossWorldAnchorInput[] = [];
    if (frame.trackedAnchors) {
      for (const anchor of frame.trackedAnchors) {
        const pose = frame.getPose(anchor.anchorSpace, referenceSpace);
        if (!pose) continue;
        anchors.push({ id: this.idFor(this.anchorIds, anchor), pose: pose.transform.matrix });
      }
    }

    this.session.submitWorld(
      {
        trackingState: viewer.emulatedPosition ? 3 : 2,
        worldFromCamera: viewer.transform.matrix,
        projection: viewer.views[0].projectionMatrix,
        timestampUs,
      },
      planes,
      anchors,
    );
  }

  private idFor<K>(map: Map<K, number>, key: K): number {
    const existing = map.get(key);
    if (existing !== undefined) return existing;
    const id = this.nextId;
    this.nextId += 1;
    map.set(key, id);
    return id;
  }
}

const identity16 = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1];
