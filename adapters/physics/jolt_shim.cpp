// The rigid-body world for lens content, behind a C surface: create a
// world, add boxes and spheres, step at a fixed rate, read poses back.
// No Jolt type escapes; exceptions cannot cross (Jolt builds without).

#include <Jolt/Jolt.h>

#include <Jolt/Core/Factory.h>
#include <Jolt/Core/JobSystemSingleThreaded.h>
#include <Jolt/Core/TempAllocator.h>
#include <Jolt/Physics/Body/BodyCreationSettings.h>
#include <Jolt/Physics/Body/BodyInterface.h>
#include <Jolt/Physics/Collision/Shape/BoxShape.h>
#include <Jolt/Physics/Collision/Shape/SphereShape.h>
#include <Jolt/Physics/Constraints/DistanceConstraint.h>
#include <Jolt/Physics/Body/BodyLock.h>
#include <Jolt/Physics/PhysicsSettings.h>
#include <Jolt/Physics/PhysicsSystem.h>
#include <Jolt/RegisterTypes.h>

#include <cstdint>
#include <cstring>

namespace {

// Two layers: static scenery and moving bodies.
constexpr JPH::ObjectLayer layer_static = 0;
constexpr JPH::ObjectLayer layer_moving = 1;
constexpr JPH::BroadPhaseLayer bp_static(0);
constexpr JPH::BroadPhaseLayer bp_moving(1);

class BpLayers final : public JPH::BroadPhaseLayerInterface {
 public:
  JPH::uint GetNumBroadPhaseLayers() const override { return 2; }
  JPH::BroadPhaseLayer GetBroadPhaseLayer(JPH::ObjectLayer layer) const override {
    return layer == layer_static ? bp_static : bp_moving;
  }
};

class ObjectVsBp final : public JPH::ObjectVsBroadPhaseLayerFilter {
 public:
  bool ShouldCollide(JPH::ObjectLayer layer, JPH::BroadPhaseLayer bp) const override {
    return layer == layer_moving || bp == bp_moving;
  }
};

class ObjectPairs final : public JPH::ObjectLayerPairFilter {
 public:
  bool ShouldCollide(JPH::ObjectLayer a, JPH::ObjectLayer b) const override {
    return a == layer_moving || b == layer_moving;
  }
};

struct World {
  JPH::TempAllocatorImpl temp{4 * 1024 * 1024};
  JPH::JobSystemSingleThreaded jobs{JPH::cMaxPhysicsJobs};
  BpLayers bp_layers;
  ObjectVsBp object_vs_bp;
  ObjectPairs object_pairs;
  JPH::PhysicsSystem system;
  double accumulator = 0.0;
};

int world_count = 0;

}  // namespace

extern "C" void* goss_physics_world_create(float gravity_y) {
  if (world_count == 0) {
    JPH::RegisterDefaultAllocator();
    JPH::Factory::sInstance = new JPH::Factory();
    JPH::RegisterTypes();
  }
  world_count += 1;
  auto* world = new World();
  world->system.Init(1024, 0, 1024, 1024, world->bp_layers, world->object_vs_bp, world->object_pairs);
  world->system.SetGravity(JPH::Vec3(0.0f, gravity_y, 0.0f));
  return world;
}

extern "C" void goss_physics_world_destroy(void* handle) {
  auto* world = static_cast<World*>(handle);
  if (world == nullptr) return;
  delete world;
  world_count -= 1;
  if (world_count == 0) {
    JPH::UnregisterTypes();
    delete JPH::Factory::sInstance;
    JPH::Factory::sInstance = nullptr;
  }
}

// shape: 0 = box (params x/y/z half extents), 1 = sphere (params x =
// radius). motion: 0 static, 1 dynamic, 2 kinematic (the engine drives
// it; chained bodies follow). Returns the body id, or UINT32_MAX.
extern "C" uint32_t goss_physics_body_add(void* handle, uint32_t shape, float px, float py, float pz, float sx, float sy, float sz, uint32_t motion) {
  auto* world = static_cast<World*>(handle);
  if (world == nullptr) return UINT32_MAX;
  JPH::Ref<JPH::Shape> body_shape;
  if (shape == 0) {
    body_shape = new JPH::BoxShape(JPH::Vec3(sx, sy, sz));
  } else if (shape == 1) {
    body_shape = new JPH::SphereShape(sx);
  } else {
    return UINT32_MAX;
  }
  const JPH::EMotionType motion_type = motion == 1   ? JPH::EMotionType::Dynamic
                                       : motion == 2 ? JPH::EMotionType::Kinematic
                                                     : JPH::EMotionType::Static;
  const bool moving = motion != 0;
  JPH::BodyCreationSettings settings(body_shape, JPH::RVec3(px, py, pz), JPH::Quat::sIdentity(),
                                     motion_type, moving ? layer_moving : layer_static);
  const JPH::BodyID id = world->system.GetBodyInterface().CreateAndAddBody(
      settings, moving ? JPH::EActivation::Activate : JPH::EActivation::DontActivate);
  return id.IsInvalid() ? UINT32_MAX : id.GetIndexAndSequenceNumber();
}

// Links two bodies with a distance constraint between local attach
// points - the chain link for content hanging off an anchor body.
extern "C" int32_t goss_physics_constrain_distance(void* handle, uint32_t body_a, uint32_t body_b, float ax, float ay, float az, float bx, float by, float bz, float min_distance, float max_distance) {
  auto* world = static_cast<World*>(handle);
  if (world == nullptr) return -1;
  JPH::Body* a = nullptr;
  JPH::Body* b = nullptr;
  {
    JPH::BodyLockWrite lock_a(world->system.GetBodyLockInterface(), JPH::BodyID(body_a));
    if (!lock_a.Succeeded()) return -1;
    a = &lock_a.GetBody();
  }
  {
    JPH::BodyLockWrite lock_b(world->system.GetBodyLockInterface(), JPH::BodyID(body_b));
    if (!lock_b.Succeeded()) return -1;
    b = &lock_b.GetBody();
  }
  JPH::DistanceConstraintSettings settings;
  settings.mSpace = JPH::EConstraintSpace::LocalToBodyCOM;
  settings.mPoint1 = JPH::RVec3(ax, ay, az);
  settings.mPoint2 = JPH::RVec3(bx, by, bz);
  settings.mMinDistance = min_distance;
  settings.mMaxDistance = max_distance;
  world->system.AddConstraint(settings.Create(*a, *b));
  return 0;
}

// Moves a kinematic body toward a pose over dt - the anchor's per-frame
// drive; chained bodies swing after it.
extern "C" void goss_physics_body_move(void* handle, uint32_t body, float px, float py, float pz, float dt_seconds) {
  auto* world = static_cast<World*>(handle);
  if (world == nullptr || dt_seconds <= 0) return;
  world->system.GetBodyInterface().MoveKinematic(JPH::BodyID(body), JPH::RVec3(px, py, pz), JPH::Quat::sIdentity(), dt_seconds);
}

// Fixed 60 Hz substeps accumulated from dt, the determinism contract.
extern "C" void goss_physics_step(void* handle, float dt_seconds) {
  auto* world = static_cast<World*>(handle);
  if (world == nullptr) return;
  world->accumulator += dt_seconds;
  const double step = 1.0 / 60.0;
  while (world->accumulator >= step) {
    world->system.Update((float)step, 1, &world->temp, &world->jobs);
    world->accumulator -= step;
  }
}

// Writes the body's column-major world transform into out[16].
extern "C" int32_t goss_physics_body_pose(void* handle, uint32_t body, float* out) {
  auto* world = static_cast<World*>(handle);
  if (world == nullptr || out == nullptr) return -1;
  const JPH::BodyID id(body);
  if (id.IsInvalid()) return -1;
  const JPH::RMat44 transform = world->system.GetBodyInterface().GetWorldTransform(id);
  for (int column = 0; column < 4; column++) {
    const JPH::Vec4 v = transform.GetColumn4(column);
    out[column * 4 + 0] = v.GetX();
    out[column * 4 + 1] = v.GetY();
    out[column * 4 + 2] = v.GetZ();
    out[column * 4 + 3] = v.GetW();
  }
  return 0;
}
