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
#include <Jolt/Physics/SoftBody/SoftBodyCreationSettings.h>
#include <Jolt/Physics/SoftBody/SoftBodySharedSettings.h>
#include <Jolt/Physics/SoftBody/SoftBodyMotionProperties.h>
#include <Jolt/Physics/Hair/Hair.h>
#include <Jolt/Physics/Hair/HairSettings.h>
#include <Jolt/Physics/Hair/HairShaders.h>
#include <Jolt/Physics/Hair/RegisterHair.h>
#include <Jolt/Compute/CPU/ComputeSystemCPU.h>
#include <Jolt/Shaders/HairWrapper.h>
#include <Jolt/Physics/PhysicsSettings.h>
#include <Jolt/Physics/PhysicsSystem.h>
#include <Jolt/RegisterTypes.h>

#include <cstdint>
#include <cstring>
#include <vector>

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

struct HairInstance {
  JPH::Ref<JPH::HairSettings> settings;
  JPH::Hair* hair = nullptr;
};

struct World {
  JPH::TempAllocatorImpl temp{4 * 1024 * 1024};
  JPH::JobSystemSingleThreaded jobs{JPH::cMaxPhysicsJobs};
  BpLayers bp_layers;
  ObjectVsBp object_vs_bp;
  ObjectPairs object_pairs;
  JPH::PhysicsSystem system;
  double accumulator = 0.0;
  // Lazily created on the first hair; shared across a world's hairs.
  JPH::Ref<JPH::ComputeSystemCPU> compute;
  JPH::Ref<JPH::ComputeQueue> queue;
  JPH::HairShaders hair_shaders;
  bool hair_ready = false;
  std::vector<HairInstance> hairs;
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

// Adds a cols x rows cloth grid spanning width x height metres at
// (px,py,pz), top row pinned. Returns the soft body id, or UINT32_MAX.
// Vertices are row-major (cols*rows) so the reader returns mesh order.
extern "C" uint32_t goss_physics_add_cloth(void* handle, uint32_t cols, uint32_t rows, float width, float height, float px, float py, float pz) {
  auto* world = static_cast<World*>(handle);
  if (world == nullptr || cols < 2 || rows < 2) return UINT32_MAX;
  JPH::Ref<JPH::SoftBodySharedSettings> shared = new JPH::SoftBodySharedSettings();
  for (uint32_t y = 0; y < rows; y++) {
    for (uint32_t x = 0; x < cols; x++) {
      const float fx = width * ((float)x / (cols - 1) - 0.5f);
      const float fy = height * (float)y / (rows - 1);
      const float inv_mass = (y == rows - 1) ? 0.0f : 1.0f;
      shared->mVertices.push_back(JPH::SoftBodySharedSettings::Vertex(JPH::Float3(fx, fy, 0), JPH::Float3(0, 0, 0), inv_mass));
    }
  }
  for (uint32_t y = 0; y < rows - 1; y++) {
    for (uint32_t x = 0; x < cols - 1; x++) {
      const JPH::uint32 a = y * cols + x, b = y * cols + x + 1, c = (y + 1) * cols + x, d = (y + 1) * cols + x + 1;
      shared->AddFace(JPH::SoftBodySharedSettings::Face(a, c, b));
      shared->AddFace(JPH::SoftBodySharedSettings::Face(b, c, d));
    }
  }
  JPH::SoftBodySharedSettings::VertexAttributes attr(1.0e-4f, 1.0e-4f, 1.0e-4f);
  shared->CreateConstraints(&attr, 1);
  shared->Optimize();
  JPH::SoftBodyCreationSettings settings(shared, JPH::RVec3(px, py, pz), JPH::Quat::sIdentity(), layer_moving);
  const JPH::BodyID id = world->system.GetBodyInterface().CreateAndAddSoftBody(settings, JPH::EActivation::Activate);
  return id.IsInvalid() ? UINT32_MAX : id.GetIndexAndSequenceNumber();
}

// Reads the cloth's deformed world-space vertices into out (three
// floats per vertex, up to max_vertices). Returns the count.
extern "C" uint32_t goss_physics_cloth_read(void* handle, uint32_t body, float* out, uint32_t max_vertices) {
  auto* world = static_cast<World*>(handle);
  if (world == nullptr || out == nullptr) return 0;
  const JPH::BodyID id(body);
  JPH::BodyLockRead lock(world->system.GetBodyLockInterface(), id);
  if (!lock.Succeeded()) return 0;
  const JPH::Body& b = lock.GetBody();
  if (!b.IsSoftBody()) return 0;
  const JPH::SoftBodyMotionProperties* mp = static_cast<const JPH::SoftBodyMotionProperties*>(b.GetMotionProperties());
  const JPH::RVec3 com = b.GetCenterOfMassPosition();
  const auto& verts = mp->GetVertices();
  const uint32_t count = (uint32_t)verts.size() < max_vertices ? (uint32_t)verts.size() : max_vertices;
  for (uint32_t i = 0; i < count; i++) {
    const JPH::RVec3 p = com + verts[i].mPosition;
    out[i * 3 + 0] = (float)p.GetX();
    out[i * 3 + 1] = (float)p.GetY();
    out[i * 3 + 2] = (float)p.GetZ();
  }
  return count;
}

namespace { bool g_hair_registered = false; }

// Adds a hanging clump of `strand_count` strands, each `verts` vertices
// long and `length` metres, rooted near the origin. Returns a hair id
// (index) for this world, or UINT32_MAX. Simulated on the CPU compute
// backend, deterministic.
extern "C" uint32_t goss_physics_add_hair(void* handle, uint32_t strand_count, uint32_t verts, float length) {
  auto* world = static_cast<World*>(handle);
  if (world == nullptr || strand_count < 1 || verts < 2) return UINT32_MAX;
  if (!g_hair_registered) { JPH::RegisterHair(); g_hair_registered = true; }
  if (!world->hair_ready) {
    world->compute = JPH::StaticCast<JPH::ComputeSystemCPU>(JPH::CreateComputeSystemCPU().Get());
    if (world->compute == nullptr) return UINT32_MAX;
    JPH::HairRegisterShaders(world->compute);
    world->queue = world->compute->CreateComputeQueue().Get();
    world->hair_shaders.Init(world->compute);
    world->hair_ready = true;
  }
  JPH::Array<JPH::HairSettings::SVertex> sverts;
  JPH::Array<JPH::HairSettings::SStrand> sstrands;
  for (uint32_t s = 0; s < strand_count; s++) {
    const float sx = -0.1f + 0.2f * (float)s / (strand_count > 1 ? strand_count - 1 : 1);
    const uint32_t start = (uint32_t)sverts.size();
    for (uint32_t i = 0; i < verts; i++) {
      JPH::HairSettings::SVertex v;
      v.mPosition = JPH::Float3(sx, 0.5f - length * (float)i / (verts - 1), 0.0f);
      v.mInvMass = (i == 0) ? 0.0f : 1.0f;  // root pinned
      sverts.push_back(v);
    }
    sstrands.push_back(JPH::HairSettings::SStrand(start, start + verts, 0));
  }
  JPH::Ref<JPH::HairSettings> settings = new JPH::HairSettings;
  JPH::HairSettings::Material m;
  m.mEnableLRA = false;
  m.mBendCompliance = 1e-8f;
  m.mStretchCompliance = 1e-10f;
  settings->mMaterials.push_back(m);
  settings->mSimulationBoundsPadding = JPH::Vec3::sReplicate(1.0f);
  settings->InitRenderAndSimulationStrands(sverts, sstrands);
  float max_dist_sq = 0.0f;
  settings->Init(max_dist_sq);
  settings->InitCompute(world->compute);
  JPH::Hair* hair = new JPH::Hair(settings, JPH::RVec3::sZero(), JPH::Quat::sIdentity(), layer_moving);
  hair->Init(world->compute);
  hair->Update(0.0f, JPH::Mat44::sIdentity(), nullptr, world->system, world->hair_shaders, world->compute, world->queue);
  hair->ReadBackGPUState(world->queue);
  const uint32_t id = (uint32_t)world->hairs.size();
  world->hairs.push_back({ settings, hair });
  return id;
}

// Moves the hair with the head (a translation extracted from the 4x4
// column-major head transform) and steps it; the free tips swing.
extern "C" void goss_physics_hair_update(void* handle, uint32_t hair_id, const float* head_transform, float dt_seconds) {
  auto* world = static_cast<World*>(handle);
  if (world == nullptr || hair_id >= world->hairs.size() || dt_seconds <= 0) return;
  JPH::Hair* hair = world->hairs[hair_id].hair;
  if (head_transform != nullptr) {
    hair->SetPosition(JPH::RVec3(head_transform[12], head_transform[13], head_transform[14]));
  }
  hair->Update(dt_seconds, JPH::Mat44::sIdentity(), nullptr, world->system, world->hair_shaders, world->compute, world->queue);
  hair->ReadBackGPUState(world->queue);
}

// Reads simulated strand vertex positions (three floats each) into out.
extern "C" uint32_t goss_physics_hair_read(void* handle, uint32_t hair_id, float* out, uint32_t max_vertices) {
  auto* world = static_cast<World*>(handle);
  if (world == nullptr || out == nullptr || hair_id >= world->hairs.size()) return 0;
  const JPH::Hair* hair = world->hairs[hair_id].hair;
  const JPH::Float3* positions = hair->GetPositions();
  if (positions == nullptr) return 0;
  const uint32_t count = world->hairs[hair_id].settings->GetNumVerticesPadded() < max_vertices ? world->hairs[hair_id].settings->GetNumVerticesPadded() : max_vertices;
  for (uint32_t i = 0; i < count; i++) {
    out[i * 3 + 0] = positions[i].x;
    out[i * 3 + 1] = positions[i].y;
    out[i * 3 + 2] = positions[i].z;
  }
  return count;
}
