// ======================================================================== //
// Copyright 2009-2017 Intel Corporation                                    //
//                                                                          //
// Licensed under the Apache License, Version 2.0 (the "License");          //
// you may not use this file except in compliance with the License.         //
// You may obtain a copy of the License at                                  //
//                                                                          //
//     http://www.apache.org/licenses/LICENSE-2.0                           //
//                                                                          //
// Unless required by applicable law or agreed to in writing, software      //
// distributed under the License is distributed on an "AS IS" BASIS,        //
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. //
// See the License for the specific language governing permissions and      //
// limitations under the License.                                           //
// ======================================================================== //

#include "../common/tutorial/tutorial_device.isph"

const uniform int numPhi = 5;
const uniform int numTheta = 2*numPhi;

void renderTileStandardStream(uniform int taskIndex,
                              uniform int* uniform pixels,
                              const uniform unsigned int width,
                              const uniform unsigned int height,
                              const uniform float time,
                              const uniform ISPCCamera& camera,
                              const uniform int numTilesX,
                              const uniform int numTilesY);

// ======================================================================== //
//                         User defined instancing                          //
// ======================================================================== //

struct Instance
{
  ALIGNED_STRUCT
  uniform unsigned int geometry;
  RTCScene object;
  uniform int userID;
  AffineSpace3f local2world;
  AffineSpace3f world2local;
  LinearSpace3f normal2world;
  Vec3f lower;
  Vec3f upper;
};

unmasked void instanceBoundsFunc(const uniform Instance* uniform instance, uniform size_t item, uniform RTCBounds* uniform bounds_o)
{
  uniform Vec3f l = instance->lower;
  uniform Vec3f u = instance->upper;
  uniform Vec3f p000 = xfmPoint(instance->local2world,make_Vec3f(l.x,l.y,l.z));
  uniform Vec3f p001 = xfmPoint(instance->local2world,make_Vec3f(l.x,l.y,u.z));
  uniform Vec3f p010 = xfmPoint(instance->local2world,make_Vec3f(l.x,u.y,l.z));
  uniform Vec3f p011 = xfmPoint(instance->local2world,make_Vec3f(l.x,u.y,u.z));
  uniform Vec3f p100 = xfmPoint(instance->local2world,make_Vec3f(u.x,l.y,l.z));
  uniform Vec3f p101 = xfmPoint(instance->local2world,make_Vec3f(u.x,l.y,u.z));
  uniform Vec3f p110 = xfmPoint(instance->local2world,make_Vec3f(u.x,u.y,l.z));
  uniform Vec3f p111 = xfmPoint(instance->local2world,make_Vec3f(u.x,u.y,u.z));
  uniform Vec3f lower = min(min(min(p000,p001),min(p010,p011)),min(min(p100,p101),min(p110,p111)));
  uniform Vec3f upper = max(max(max(p000,p001),max(p010,p011)),max(max(p100,p101),max(p110,p111)));
  bounds_o->lower_x = lower.x;
  bounds_o->lower_y = lower.y;
  bounds_o->lower_z = lower.z;
  bounds_o->upper_x = upper.x;
  bounds_o->upper_y = upper.y;
  bounds_o->upper_z = upper.z;
}

void instanceIntersectFunc(const uniform Instance* uniform instance, varying RTCRay& ray, uniform size_t item)
{
  const Vec3f ray_org = ray.org;
  const Vec3f ray_dir = ray.dir;
  const int geomID = ray.geomID;
  ray.org = xfmPoint (instance->world2local,ray_org);
  ray.dir = xfmVector(instance->world2local,ray_dir);
  ray.geomID = RTC_INVALID_GEOMETRY_ID;
  rtcIntersect(instance->object,ray);
  ray.org = ray_org;
  ray.dir = ray_dir;
  if (ray.geomID == RTC_INVALID_GEOMETRY_ID) ray.geomID = geomID;
  else {
    ray.instID = instance->userID;
    ray.Ng = xfmVector(instance->normal2world,ray.Ng);
  }
}

void instanceOccludedFunc(const uniform Instance* uniform instance, varying RTCRay& ray, uniform size_t item)
{
  const Vec3f ray_org = ray.org;
  const Vec3f ray_dir = ray.dir;
  ray.org = xfmPoint (instance->world2local,ray_org);
  ray.dir = xfmVector(instance->world2local,ray_dir);
  rtcOccluded(instance->object,ray);
  ray.org = ray_org;
  ray.dir = ray_dir;
}

unmasked void instanceIntersectFuncN(const uniform int* uniform valid,
                                     void* uniform ptr,
                                     const uniform RTCIntersectContext* uniform context,
                                     RTCRayN* uniform rays,
                                     uniform size_t N,
                                     uniform size_t item)
{
  /* avoid crashing when debug visualizations are used */
  if (context == NULL)
    return;

  const uniform Instance* uniform instance = (const uniform Instance* uniform) ptr;

  /* iterate over all rays in ray packet */
  for (uniform unsigned int ui=0; ui<N; ui+=programCount)
  {
    /* calculate varying loop and execution mask */
    unsigned int vi = ui+programIndex;
    if (vi>=N) continue;

    /* ignore inactive rays */
    if (valid[vi] != -1) continue;

    /* create transformed ray */
    RTCRay ray;
    const Vec3f ray_org = make_Vec3f(RTCRayN_org_x(rays,N,ui),RTCRayN_org_y(rays,N,ui),RTCRayN_org_z(rays,N,ui));
    const Vec3f ray_dir = make_Vec3f(RTCRayN_dir_x(rays,N,ui),RTCRayN_dir_y(rays,N,ui),RTCRayN_dir_z(rays,N,ui));
    ray.org = xfmPoint (instance->world2local,ray_org);
    ray.dir = xfmVector(instance->world2local,ray_dir);
    bool mask = __mask; unmasked {
      ray.tnear = mask ? RTCRayN_tnear(rays,N,ui) : (float)(pos_inf);
      ray.tfar  = mask ? RTCRayN_tfar(rays,N,ui ) : (float)(neg_inf);
    }
    ray.time  = RTCRayN_time(rays,N,ui);
    ray.mask  = RTCRayN_mask(rays,N,ui);
    ray.geomID = RTC_INVALID_GEOMETRY_ID;

    /* trace ray through object */
    rtcIntersectVM(instance->object,context,&ray,1,sizeof(RTCRay));
    if (ray.geomID == RTC_INVALID_GEOMETRY_ID) continue;

    /* update hit */
    RTCRayN_u(rays,N,ui) = ray.u;
    RTCRayN_v(rays,N,ui) = ray.v;
    RTCRayN_tfar(rays,N,ui) = ray.tfar;
    RTCRayN_instID(rays,N,ui) = instance->userID;
    RTCRayN_geomID(rays,N,ui) = ray.geomID;
    RTCRayN_primID(rays,N,ui) = ray.primID;
    Vec3f Ng = xfmVector(instance->normal2world,ray.Ng);
    RTCRayN_Ng_x(rays,N,ui) = Ng.x;
    RTCRayN_Ng_y(rays,N,ui) = Ng.y;
    RTCRayN_Ng_z(rays,N,ui) = Ng.z;
  }
}

unmasked void instanceOccludedFuncN(const uniform int* uniform valid,
                                    void* uniform ptr,
                                    const uniform RTCIntersectContext* uniform context,
                                    RTCRayN* uniform rays,
                                    uniform size_t N,
                                    uniform size_t item)
{
  /* avoid crashing when debug visualizations are used */
  if (context == NULL)
    return;

  const uniform Instance* uniform instance = (const uniform Instance* uniform) ptr;

  /* iterate over all rays in ray packet */
  for (uniform unsigned int ui=0; ui<N; ui+=programCount)
  {
    /* calculate varying loop and execution mask */
    unsigned int vi = ui+programIndex;
    if (vi>=N) continue;

    /* ignore inactive rays */
    if (valid[vi] != -1) continue;

    /* create transformed ray */
    RTCRay ray;
    const Vec3f ray_org = make_Vec3f(RTCRayN_org_x(rays,N,ui),RTCRayN_org_y(rays,N,ui),RTCRayN_org_z(rays,N,ui));
    const Vec3f ray_dir = make_Vec3f(RTCRayN_dir_x(rays,N,ui),RTCRayN_dir_y(rays,N,ui),RTCRayN_dir_z(rays,N,ui));
    ray.org = xfmPoint (instance->world2local,ray_org);
    ray.dir = xfmVector(instance->world2local,ray_dir);
    bool mask = __mask; unmasked {
      ray.tnear = mask ? RTCRayN_tnear(rays,N,ui) : (float)(pos_inf);
      ray.tfar  = mask ? RTCRayN_tfar(rays,N,ui)  : (float)(neg_inf);
    }
    ray.time  = RTCRayN_time(rays,N,ui);
    ray.mask  = RTCRayN_mask(rays,N,ui);
    ray.geomID = RTC_INVALID_GEOMETRY_ID;

    /* trace ray through object */
    rtcOccludedVM(instance->object,context,&ray,1,sizeof(RTCRay));
    if (ray.geomID == RTC_INVALID_GEOMETRY_ID) continue;

    /* update hit */
    RTCRayN_geomID(rays,N,ui) = ray.geomID;
  }
}

uniform Instance* uniform createInstance (RTCScene scene, RTCScene object, uniform int userID, const uniform Vec3f& lower, const uniform Vec3f& upper)
{
  uniform Instance* uniform instance = uniform new uniform Instance;
  instance->object = object;
  instance->userID = userID;
  instance->lower = lower;
  instance->upper = upper;
  instance->local2world.l.vx = make_Vec3f(1,0,0);
  instance->local2world.l.vy = make_Vec3f(0,1,0);
  instance->local2world.l.vz = make_Vec3f(0,0,1);
  instance->local2world.p    = make_Vec3f(0,0,0);
  instance->geometry = rtcNewUserGeometry(scene,1);
  rtcSetUserData(scene,instance->geometry,instance);
  rtcSetBoundsFunction(scene,instance->geometry,(RTCBoundsFunc)&instanceBoundsFunc);
  if (g_mode == MODE_NORMAL) {
    rtcSetIntersectFunction(scene,instance->geometry,(RTCIntersectFuncVarying)&instanceIntersectFunc);
    rtcSetOccludedFunction (scene,instance->geometry,(RTCOccludedFuncVarying )&instanceOccludedFunc);
  } else {
    rtcSetIntersectFunctionN(scene,instance->geometry,&instanceIntersectFuncN);
    rtcSetOccludedFunctionN (scene,instance->geometry,&instanceOccludedFuncN);
  }
  return instance;
}

void updateInstance (RTCScene scene, uniform Instance* uniform instance)
{
  instance->world2local = rcp(instance->local2world);
  instance->normal2world = transposed(rcp(instance->local2world.l));
  rtcUpdate(scene,instance->geometry);
}

// ======================================================================== //
//                     User defined sphere geometry                         //
// ======================================================================== //

struct Sphere
{
  ALIGNED_STRUCT
  Vec3f p;                      //!< position of the sphere
  float r;                      //!< radius of the sphere
  unsigned int geomID;
};

unmasked void sphereBoundsFunc(const uniform Sphere* uniform spheres, uniform size_t item, uniform RTCBounds* uniform bounds_o)
{
  const uniform Sphere& sphere = spheres[item];
  bounds_o->lower_x = sphere.p.x-sphere.r;
  bounds_o->lower_y = sphere.p.y-sphere.r;
  bounds_o->lower_z = sphere.p.z-sphere.r;
  bounds_o->upper_x = sphere.p.x+sphere.r;
  bounds_o->upper_y = sphere.p.y+sphere.r;
  bounds_o->upper_z = sphere.p.z+sphere.r;
}

void sphereIntersectFunc(const uniform Sphere* uniform spheres, varying RTCRay& ray, uniform size_t item)
{
  const uniform Sphere& sphere = spheres[item];
  const Vec3f v = ray.org-sphere.p;
  const float A = dot(ray.dir,ray.dir);
  const float B = 2.0f*dot(v,ray.dir);
  const float C = dot(v,v) - sqr(sphere.r);
  const float D = B*B - 4.0f*A*C;
  if (D < 0.0f) return;
  const float Q = sqrt(D);
  const float rcpA = rcp(A);
  const float t0 = 0.5f*rcpA*(-B-Q);
  const float t1 = 0.5f*rcpA*(-B+Q);
  if ((ray.tnear < t0) & (t0 < ray.tfar)) {
    ray.u = 0.0f;
    ray.v = 0.0f;
    ray.tfar = t0;
    ray.geomID = sphere.geomID;
    ray.primID = (unsigned int) item;
    ray.Ng = ray.org+t0*ray.dir-sphere.p;
  }
  if ((ray.tnear < t1) & (t1 < ray.tfar)) {
    ray.u = 0.0f;
    ray.v = 0.0f;
    ray.tfar = t1;
    ray.geomID = sphere.geomID;
    ray.primID = (unsigned int) item;
    ray.Ng = ray.org+t1*ray.dir-sphere.p;
  }
}

void sphereOccludedFunc(const uniform Sphere* uniform spheres, varying RTCRay& ray, uniform size_t item)
{
  const uniform Sphere& sphere = spheres[item];
  const Vec3f v = ray.org-sphere.p;
  const float A = dot(ray.dir,ray.dir);
  const float B = 2.0f*dot(v,ray.dir);
  const float C = dot(v,v) - sqr(sphere.r);
  const float D = B*B - 4.0f*A*C;
  if (D < 0.0f) return;
  const float Q = sqrt(D);
  const float rcpA = rcp(A);
  const float t0 = 0.5f*rcpA*(-B-Q);
  const float t1 = 0.5f*rcpA*(-B+Q);
  if ((ray.tnear < t0) & (t0 < ray.tfar)) {
    ray.geomID = 0;
  }
  if ((ray.tnear < t1) & (t1 < ray.tfar)) {
    ray.geomID = 0;
  }
}

unmasked void sphereIntersectFuncN(const uniform int* uniform valid,
                                   void* uniform ptr,
                                   const uniform RTCIntersectContext* uniform context,
                                   RTCRayN* uniform rays,
                                   uniform size_t N,
                                   uniform size_t item)
{
  const uniform Sphere* uniform spheres = (const uniform Sphere* uniform) ptr;

  /* iterate over all rays in ray packet */
  for (uniform unsigned int ui=0; ui<N; ui+=programCount)
  {
    /* calculate varying loop and execution mask */
    unsigned int vi = ui+programIndex;
    if (vi>=N) continue;

    /* ignore inactive rays */
    if (valid[vi] != -1) continue;

    const Vec3f ray_org = make_Vec3f(RTCRayN_org_x(rays,N,ui),RTCRayN_org_y(rays,N,ui),RTCRayN_org_z(rays,N,ui));
    const Vec3f ray_dir = make_Vec3f(RTCRayN_dir_x(rays,N,ui),RTCRayN_dir_y(rays,N,ui),RTCRayN_dir_z(rays,N,ui));
    float& ray_tnear = RTCRayN_tnear(rays,N,ui);
    float& ray_tfar = RTCRayN_tfar(rays,N,ui);

    const uniform Sphere& sphere = spheres[item];
    const Vec3f v = ray_org-sphere.p;
    const float A = dot(ray_dir,ray_dir);
    const float B = 2.0f*dot(v,ray_dir);
    const float C = dot(v,v) - sqr(sphere.r);
    const float D = B*B - 4.0f*A*C;
    if (D < 0.0f) continue;
    const float Q = sqrt(D);
    const float rcpA = rcp(A);
    const float t0 = 0.5f*rcpA*(-B-Q);
    const float t1 = 0.5f*rcpA*(-B+Q);

    if ((ray_tnear < t0) & (t0 < ray_tfar))
    {
      RTCRayN_u(rays,N,ui) = 0.0f;
      RTCRayN_v(rays,N,ui) = 0.0f;
      RTCRayN_tfar(rays,N,ui) = t0;
      RTCRayN_geomID(rays,N,ui) = sphere.geomID;
      RTCRayN_primID(rays,N,ui) = (unsigned int)item;
      const Vec3f Ng = ray_org+t0*ray_dir-sphere.p;
      RTCRayN_Ng_x(rays,N,ui) = Ng.x;
      RTCRayN_Ng_y(rays,N,ui) = Ng.y;
      RTCRayN_Ng_z(rays,N,ui) = Ng.z;
    }
    if ((ray_tnear < t1) & (t1 < ray_tfar))
    {
      RTCRayN_u(rays,N,ui) = 0.0f;
      RTCRayN_v(rays,N,ui) = 0.0f;
      RTCRayN_tfar(rays,N,ui) = t1;
      RTCRayN_geomID(rays,N,ui) = sphere.geomID;
      RTCRayN_primID(rays,N,ui) = (unsigned int)item;
      const Vec3f Ng = ray_org+t1*ray_dir-sphere.p;
      RTCRayN_Ng_x(rays,N,ui) = Ng.x;
      RTCRayN_Ng_y(rays,N,ui) = Ng.y;
      RTCRayN_Ng_z(rays,N,ui) = Ng.z;
    }
  }
}

unmasked void sphereOccludedFuncN(const uniform int* uniform valid,
                                  void* uniform ptr,
                                  const uniform RTCIntersectContext* uniform context,
                                  RTCRayN* uniform rays,
                                  uniform size_t N,
                                  uniform size_t item)
{
  const uniform Sphere* uniform spheres = (const uniform Sphere* uniform) ptr;

  /* iterate over all rays in ray packet */
  for (uniform unsigned int ui=0; ui<N; ui+=programCount)
  {
    /* calculate varying loop and execution mask */
    unsigned int vi = ui+programIndex;
    if (vi>=N) continue;

    /* ignore inactive rays */
    if (valid[vi] != -1) continue;

    const Vec3f ray_org = make_Vec3f(RTCRayN_org_x(rays,N,ui),RTCRayN_org_y(rays,N,ui),RTCRayN_org_z(rays,N,ui));
    const Vec3f ray_dir = make_Vec3f(RTCRayN_dir_x(rays,N,ui),RTCRayN_dir_y(rays,N,ui),RTCRayN_dir_z(rays,N,ui));
    float& ray_tnear = RTCRayN_tnear(rays,N,ui);
    float& ray_tfar = RTCRayN_tfar(rays,N,ui);

    const uniform Sphere& sphere = spheres[item];
    const Vec3f v = ray_org-sphere.p;
    const float A = dot(ray_dir,ray_dir);
    const float B = 2.0f*dot(v,ray_dir);
    const float C = dot(v,v) - sqr(sphere.r);
    const float D = B*B - 4.0f*A*C;
    if (D < 0.0f) continue;
    const float Q = sqrt(D);
    const float rcpA = rcp(A);
    const float t0 = 0.5f*rcpA*(-B-Q);
    const float t1 = 0.5f*rcpA*(-B+Q);
    if ((ray_tnear < t0) & (t0 < ray_tfar)) {
      RTCRayN_geomID(rays,N,ui) = 0;
    }
    if ((ray_tnear < t1) & (t1 < ray_tfar)) {
      RTCRayN_geomID(rays,N,ui) = 0;
    }
  }
}

uniform Sphere* uniform createAnalyticalSphere (RTCScene scene, const uniform Vec3f& p, uniform float r)
{
  uniform unsigned int geomID = rtcNewUserGeometry(scene,1);
  uniform Sphere* uniform sphere = uniform new uniform Sphere;
  sphere->p = p;
  sphere->r = r;
  sphere->geomID = geomID;
  rtcSetUserData(scene,geomID,sphere);
  rtcSetBoundsFunction(scene,geomID,(RTCBoundsFunc)&sphereBoundsFunc);
  if (g_mode == MODE_NORMAL) {
    rtcSetIntersectFunction(scene,geomID,(RTCIntersectFuncVarying)&sphereIntersectFunc);
    rtcSetOccludedFunction (scene,geomID,(RTCOccludedFuncVarying )&sphereOccludedFunc);
  } else {
    rtcSetIntersectFunctionN(scene,geomID,&sphereIntersectFuncN);
    rtcSetOccludedFunctionN (scene,geomID,&sphereOccludedFuncN);
  }
  return sphere;
}

uniform Sphere* uniform createAnalyticalSpheres (RTCScene scene, uniform size_t N)
{
  uniform unsigned int geomID = rtcNewUserGeometry(scene,N);
  uniform Sphere* uniform spheres = uniform new uniform Sphere[N];
  for (uniform size_t i=0; i<N; i++) spheres[i].geomID = geomID;
  rtcSetUserData(scene,geomID,spheres);
  rtcSetBoundsFunction(scene,geomID,(RTCBoundsFunc)&sphereBoundsFunc);
  if (g_mode == MODE_NORMAL) {
    rtcSetIntersectFunction(scene,geomID,(RTCIntersectFuncVarying)&sphereIntersectFunc);
    rtcSetOccludedFunction (scene,geomID,(RTCOccludedFuncVarying )&sphereOccludedFunc);
  } else {
    rtcSetIntersectFunctionN(scene,geomID,sphereIntersectFuncN);
    rtcSetOccludedFunctionN (scene,geomID,sphereOccludedFuncN);
  }
  return spheres;
}

// ======================================================================== //
//                      Triangular sphere geometry                          //
// ======================================================================== //

uniform unsigned int createTriangulatedSphere (RTCScene scene, const uniform Vec3f& p, uniform float r)
{
  /* create triangle mesh */
  uniform unsigned int mesh = rtcNewTriangleMesh (scene, RTC_GEOMETRY_STATIC, 2*numTheta*(numPhi-1), numTheta*(numPhi+1));

  /* map triangle and vertex buffers */
  uniform Vertex* uniform vertices = (uniform Vertex* uniform) rtcMapBuffer(scene,mesh,RTC_VERTEX_BUFFER);
  uniform Triangle* uniform triangles = (uniform Triangle* uniform) rtcMapBuffer(scene,mesh,RTC_INDEX_BUFFER);

  /* create sphere */
  uniform int tri = 0;
  const uniform float rcpNumTheta = rcp((uniform float)numTheta);
  const uniform float rcpNumPhi   = rcp((uniform float)numPhi);
  for (uniform int phi=0; phi<=numPhi; phi++)
  {
    for (uniform int theta=0; theta<numTheta; theta++)
    {
      const uniform float phif   = phi*pi*rcpNumPhi;
      const uniform float thetaf = theta*2.0f*pi*rcpNumTheta;

      uniform Vertex& v = vertices[phi*numTheta+theta];
      v.x = p.x + r*sin(phif)*sin(thetaf);
      v.y = p.y + r*cos(phif);
      v.z = p.z + r*sin(phif)*cos(thetaf);
    }
    if (phi == 0) continue;

    for (uniform int theta=1; theta<=numTheta; theta++)
    {
      uniform int p00 = (phi-1)*numTheta+theta-1;
      uniform int p01 = (phi-1)*numTheta+theta%numTheta;
      uniform int p10 = phi*numTheta+theta-1;
      uniform int p11 = phi*numTheta+theta%numTheta;

      if (phi > 1) {
        triangles[tri].v0 = p10;
        triangles[tri].v1 = p00;
        triangles[tri].v2 = p01;
        tri++;
      }

      if (phi < numPhi) {
        triangles[tri].v0 = p11;
        triangles[tri].v1 = p10;
        triangles[tri].v2 = p01;
        tri++;
      }
    }
  }
  rtcUnmapBuffer(scene,mesh,RTC_VERTEX_BUFFER);
  rtcUnmapBuffer(scene,mesh,RTC_INDEX_BUFFER);
  return mesh;
}

/* creates a ground plane */
uniform unsigned int createGroundPlane (RTCScene scene)
{
  /* create a triangulated plane with 2 triangles and 4 vertices */
  uniform unsigned int mesh = rtcNewTriangleMesh (scene, RTC_GEOMETRY_STATIC, 2, 4);

  /* set vertices */
  uniform Vertex* uniform vertices = (uniform Vertex* uniform) rtcMapBuffer(scene,mesh,RTC_VERTEX_BUFFER);
  vertices[0].x = -10; vertices[0].y = -2; vertices[0].z = -10;
  vertices[1].x = -10; vertices[1].y = -2; vertices[1].z = +10;
  vertices[2].x = +10; vertices[2].y = -2; vertices[2].z = -10;
  vertices[3].x = +10; vertices[3].y = -2; vertices[3].z = +10;
  rtcUnmapBuffer(scene,mesh,RTC_VERTEX_BUFFER);

  /* set triangles */
  uniform Triangle* uniform triangles = (uniform Triangle* uniform) rtcMapBuffer(scene,mesh,RTC_INDEX_BUFFER);
  triangles[0].v0 = 0; triangles[0].v1 = 2; triangles[0].v2 = 1;
  triangles[1].v0 = 1; triangles[1].v1 = 2; triangles[1].v2 = 3;
  rtcUnmapBuffer(scene,mesh,RTC_INDEX_BUFFER);

  return mesh;
}

/* scene data */
RTCDevice g_device = NULL;
RTCScene g_scene  = NULL;
RTCScene g_scene0 = NULL;
RTCScene g_scene1 = NULL;
RTCScene g_scene2 = NULL;

uniform Instance* uniform g_instance[4] = { NULL, NULL, NULL, NULL };

uniform Vec3f colors[5][4];

/* called by the C++ code for initialization */
export void device_init (uniform int8* uniform cfg)
{
  /* create new Embree device */
  g_device = rtcNewDevice(cfg);
  error_handler(NULL,rtcDeviceGetError(g_device));

  /* set error handler */
  rtcDeviceSetErrorFunction2(g_device,error_handler,NULL);

  uniform RTCAlgorithmFlags aflags;
  if (g_mode == MODE_NORMAL) aflags = RTC_INTERSECT_UNIFORM | RTC_INTERSECT_VARYING;
  else                       aflags = RTC_INTERSECT_UNIFORM | RTC_INTERSECT_STREAM;

  /* create scene */
  g_scene = rtcDeviceNewScene(g_device, RTC_SCENE_DYNAMIC,aflags);

  /* create scene with 4 analytical spheres */
  g_scene0 = rtcDeviceNewScene(g_device, RTC_SCENE_STATIC,aflags);
  uniform Sphere* uniform spheres = createAnalyticalSpheres(g_scene0,4);
  spheres[0].p = make_Vec3f( 0, 0,+1); spheres[0].r = 0.5f;
  spheres[1].p = make_Vec3f(+1, 0, 0); spheres[1].r = 0.5f;
  spheres[2].p = make_Vec3f( 0, 0,-1); spheres[2].r = 0.5f;
  spheres[3].p = make_Vec3f(-1, 0, 0); spheres[3].r = 0.5f;
  rtcCommit(g_scene0);

  /* create scene with 4 triangulated spheres */
  g_scene1 = rtcDeviceNewScene(g_device, RTC_SCENE_STATIC,aflags);
  createTriangulatedSphere(g_scene1,make_Vec3f( 0, 0,+1),0.5f);
  createTriangulatedSphere(g_scene1,make_Vec3f(+1, 0, 0),0.5f);
  createTriangulatedSphere(g_scene1,make_Vec3f( 0, 0,-1),0.5f);
  createTriangulatedSphere(g_scene1,make_Vec3f(-1, 0, 0),0.5f);
  rtcCommit(g_scene1);

  /* create scene with 2 triangulated and 2 analytical spheres */
  g_scene2 = rtcDeviceNewScene(g_device, RTC_SCENE_STATIC,aflags);
  createTriangulatedSphere(g_scene2,make_Vec3f( 0, 0,+1),0.5f);
  createAnalyticalSphere  (g_scene2,make_Vec3f(+1, 0, 0),0.5f);
  createTriangulatedSphere(g_scene2,make_Vec3f( 0, 0,-1),0.5f);
  createAnalyticalSphere  (g_scene2,make_Vec3f(-1, 0, 0),0.5f);
  rtcCommit(g_scene2);

  /* instantiate geometry */
  createGroundPlane(g_scene);
  g_instance[0] = createInstance(g_scene,g_scene0,0,make_Vec3f(-2,-2,-2),make_Vec3f(+2,+2,+2));
  g_instance[1] = createInstance(g_scene,g_scene1,1,make_Vec3f(-2,-2,-2),make_Vec3f(+2,+2,+2));
  g_instance[2] = createInstance(g_scene,g_scene2,2,make_Vec3f(-2,-2,-2),make_Vec3f(+2,+2,+2));
  g_instance[3] = createInstance(g_scene,g_scene2,3,make_Vec3f(-2,-2,-2),make_Vec3f(+2,+2,+2));
  rtcCommit(g_scene);

  /* set all colors */
  colors[0][0] = make_Vec3f(0.25f, 0.00f, 0.00f);
  colors[0][1] = make_Vec3f(0.50f, 0.00f, 0.00f);
  colors[0][2] = make_Vec3f(0.75f, 0.00f, 0.00f);
  colors[0][3] = make_Vec3f(1.00f, 0.00f, 0.00f);

  colors[1][0] = make_Vec3f(0.00f, 0.25f, 0.00f);
  colors[1][1] = make_Vec3f(0.00f, 0.50f, 0.00f);
  colors[1][2] = make_Vec3f(0.00f, 0.75f, 0.00f);
  colors[1][3] = make_Vec3f(0.00f, 1.00f, 0.00f);

  colors[2][0] = make_Vec3f(0.00f, 0.00f, 0.25f);
  colors[2][1] = make_Vec3f(0.00f, 0.00f, 0.50f);
  colors[2][2] = make_Vec3f(0.00f, 0.00f, 0.75f);
  colors[2][3] = make_Vec3f(0.00f, 0.00f, 1.00f);

  colors[3][0] = make_Vec3f(0.25f, 0.25f, 0.00f);
  colors[3][1] = make_Vec3f(0.50f, 0.50f, 0.00f);
  colors[3][2] = make_Vec3f(0.75f, 0.75f, 0.00f);
  colors[3][3] = make_Vec3f(1.00f, 1.00f, 0.00f);

  colors[4][0] = make_Vec3f(1.0f, 1.0f, 1.0f);
  colors[4][1] = make_Vec3f(1.0f, 1.0f, 1.0f);
  colors[4][2] = make_Vec3f(1.0f, 1.0f, 1.0f);
  colors[4][3] = make_Vec3f(1.0f, 1.0f, 1.0f);

  /* set start render mode */
  if (g_mode == MODE_NORMAL) renderTile = renderTileStandard;
  else                       renderTile = renderTileStandardStream;
  key_pressed_handler = device_key_pressed_default;
}

/* task that renders a single screen tile */
Vec3f renderPixelStandard(float x, float y, const uniform ISPCCamera& camera)
{
  /* initialize ray */
  RTCRay ray;
  ray.org = make_Vec3f(camera.xfm.p);
  ray.dir = make_Vec3f(normalize(x*camera.xfm.l.vx + y*camera.xfm.l.vy + camera.xfm.l.vz));
  ray.tnear = 0.0f;
  ray.tfar = (float)(inf);
  ray.geomID = RTC_INVALID_GEOMETRY_ID;
  ray.primID = RTC_INVALID_GEOMETRY_ID;
  ray.instID = 4; // set default instance ID
  ray.mask = -1;
  ray.time = 0;

  /* intersect ray with scene */
  rtcIntersect(g_scene,ray);

  /* shade pixels */
  Vec3f color = make_Vec3f(0.0f);
  if (ray.geomID != RTC_INVALID_GEOMETRY_ID)
  {
    /* calculate shading normal */
    Vec3f Ns = normalize(ray.Ng);

    /* calculate diffuse color of geometries */
    Vec3f diffuse = make_Vec3f(0.0f);
    if (ray.instID == 0) diffuse = colors[ray.instID][ray.primID];
    else                 diffuse = colors[ray.instID][ray.geomID];
    color = color + diffuse*0.5;

    /* initialize shadow ray */
    Vec3f lightDir = normalize(make_Vec3f(-1,-1,-1));
    RTCRay shadow;
    shadow.org = ray.org + ray.tfar*ray.dir;
    shadow.dir = neg(lightDir);
    shadow.tnear = 0.001f;
    shadow.tfar = (float)(inf);
    shadow.geomID = 1;
    shadow.primID = 0;
    shadow.mask = -1;
    shadow.time = 0;

    /* trace shadow ray */
    rtcOccluded(g_scene,shadow);

    /* add light contribution */
    if (shadow.geomID)
      color = color + diffuse*clamp(-dot(lightDir,Ns),0.0f,1.0f);
  }
  return color;
}

/* renders a single screen tile */
void renderTileStandard(uniform int taskIndex,
                        uniform int* uniform pixels,
                        const uniform unsigned int width,
                        const uniform unsigned int height,
                        const uniform float time,
                        const uniform ISPCCamera& camera,
                        const uniform int numTilesX,
                        const uniform int numTilesY)
{
  const uniform unsigned int tileY = taskIndex / numTilesX;
  const uniform unsigned int tileX = taskIndex - tileY * numTilesX;
  const uniform unsigned int x0 = tileX * TILE_SIZE_X;
  const uniform unsigned int x1 = min(x0+TILE_SIZE_X,width);
  const uniform unsigned int y0 = tileY * TILE_SIZE_Y;
  const uniform unsigned int y1 = min(y0+TILE_SIZE_Y,height);

  foreach_tiled (y = y0 ... y1, x = x0 ... x1)
  {
    /* calculate pixel color */
    Vec3f color = renderPixelStandard((float)x,(float)y,camera);

    /* write color to framebuffer */
    unsigned int r = (unsigned int) (255.0f * clamp(color.x,0.0f,1.0f));
    unsigned int g = (unsigned int) (255.0f * clamp(color.y,0.0f,1.0f));
    unsigned int b = (unsigned int) (255.0f * clamp(color.z,0.0f,1.0f));
    pixels[y*width+x] = (b << 16) + (g << 8) + r;
  }
}

/* renders a single screen tile */
void renderTileStandardStream(uniform int taskIndex,
                              uniform int* uniform pixels,
                              const uniform unsigned int width,
                              const uniform unsigned int height,
                              const uniform float time,
                              const uniform ISPCCamera& camera,
                              const uniform int numTilesX,
                              const uniform int numTilesY)
{
  const uniform unsigned int tileY = taskIndex / numTilesX;
  const uniform unsigned int tileX = taskIndex - tileY * numTilesX;
  const uniform unsigned int x0 = tileX * TILE_SIZE_X;
  const uniform unsigned int x1 = min(x0+TILE_SIZE_X,width);
  const uniform unsigned int y0 = tileY * TILE_SIZE_Y;
  const uniform unsigned int y1 = min(y0+TILE_SIZE_Y,height);

  RTCRay primary_stream[TILE_SIZE_X*TILE_SIZE_Y];
  RTCRay shadow_stream[TILE_SIZE_X*TILE_SIZE_Y];
  Vec3f color_stream[TILE_SIZE_X*TILE_SIZE_Y];
  bool valid_stream[TILE_SIZE_X*TILE_SIZE_Y];

  /* select stream mode */
  uniform RTCIntersectFlags iflags = g_mode == MODE_STREAM_COHERENT ?  RTC_INTERSECT_COHERENT : RTC_INTERSECT_INCOHERENT;

  /* generate stream of primary rays */
  uniform int N = 0;
  foreach_tiled (y = y0 ... y1, x = x0 ... x1)
  {
    /* ISPC workaround for mask == 0 */
    if (all(__mask == 0)) continue;

    /* initialize variables */
    color_stream[N] = make_Vec3f(0.0f);
    bool mask = __mask; unmasked { valid_stream[N] = mask; }

    /* initialize ray */
    RTCRay& primary = primary_stream[N];
    primary.org = make_Vec3f(camera.xfm.p);
    primary.dir = make_Vec3f(normalize((float)x*camera.xfm.l.vx + (float)y*camera.xfm.l.vy + camera.xfm.l.vz));
    mask = __mask; unmasked { // invalidates inactive rays
      primary.tnear = mask ? 0.0f         : (float)(pos_inf);
      primary.tfar  = mask ? (float)(inf) : (float)(neg_inf);
    }
    primary.instID = 4; // set default instance ID
    primary.geomID = RTC_INVALID_GEOMETRY_ID;
    primary.primID = RTC_INVALID_GEOMETRY_ID;
    primary.mask = -1;
    primary.time = 0.0f;
    N++;
  }

  Vec3f lightDir = normalize(make_Vec3f(-1,-1,-1));

  /* trace rays */
  uniform RTCIntersectContext primary_context;
  primary_context.flags = iflags;
  primary_context.userRayExt = &primary_stream;
  rtcIntersectVM(g_scene,&primary_context,(varying RTCRay* uniform)&primary_stream,N,sizeof(RTCRay));

  /* terminate rays and update color */
  N = -1;
  foreach_tiled (y = y0 ... y1, x = x0 ... x1)
  {
    N++;
    /* ISPC workaround for mask == 0 */
    if (all(__mask == 0)) continue;

    /* invalidate shadow rays by default */
    RTCRay& shadow = shadow_stream[N];
    unmasked {
      shadow.tnear = (float)(pos_inf);
      shadow.tfar  = (float)(neg_inf);
    }

    /* ignore invalid rays */
    if (valid_stream[N] == false) continue;

    /* terminate rays that hit nothing */
    if (primary_stream[N].geomID == RTC_INVALID_GEOMETRY_ID) {
      valid_stream[N] = false;
      continue;
    }

    /* calculate diffuse color of geometries */
    RTCRay& primary = primary_stream[N];
    Vec3f diffuse = make_Vec3f(0.0f);
    if (primary.instID == 0) diffuse = colors[primary.instID][primary.primID];
    else                     diffuse = colors[primary.instID][primary.geomID];
    color_stream[N] = color_stream[N] + diffuse*0.5;

    /* initialize shadow ray */
    shadow.org = primary.org + primary.tfar*primary.dir;
    shadow.dir = neg(lightDir);
    bool mask = __mask; unmasked {
      shadow.tnear = mask ? 0.001f       : (float)(pos_inf);
      shadow.tfar  = mask ? (float)(inf) : (float)(neg_inf);
    }
    shadow.geomID = RTC_INVALID_GEOMETRY_ID;
    shadow.primID = RTC_INVALID_GEOMETRY_ID;
    shadow.mask = N*programCount + programIndex;
    shadow.time = 0;
  }
  N++;

  /* trace shadow rays */
  uniform RTCIntersectContext shadow_context;
  shadow_context.flags = iflags;
  shadow_context.userRayExt = &shadow_stream;
  rtcOccludedVM(g_scene,&shadow_context,(varying RTCRay* uniform)&shadow_stream,N,sizeof(RTCRay));

  /* add light contribution */
  N = -1;
  foreach_tiled (y = y0 ... y1, x = x0 ... x1)
  {
    N++;
    /* ISPC workaround for mask == 0 */
    if (all(__mask == 0)) continue;

    /* ignore invalid rays */
    if (valid_stream[N] == false) continue;

    /* add light contrinution */
    RTCRay& primary = primary_stream[N];
    Vec3f Ns = normalize(primary.Ng);
    Vec3f diffuse = make_Vec3f(0.0f);
    if (primary.instID == 0) diffuse = colors[primary.instID][primary.primID];
    else                     diffuse = colors[primary.instID][primary.geomID];
    RTCRay& shadow = shadow_stream[N];
    if (shadow.geomID) {
      color_stream[N] = color_stream[N] + diffuse*clamp(-dot(lightDir,Ns),0.0f,1.0f);
    }
  }
  N++;

  /* framebuffer writeback */
  N = 0;
  foreach_tiled (y = y0 ... y1, x = x0 ... x1)
  {
    /* ISPC workaround for mask == 0 */
    if (all(__mask == 0)) continue;

    /* write color to framebuffer */
    unsigned int r = (unsigned int) (255.0f * clamp(color_stream[N].x,0.0f,1.0f));
    unsigned int g = (unsigned int) (255.0f * clamp(color_stream[N].y,0.0f,1.0f));
    unsigned int b = (unsigned int) (255.0f * clamp(color_stream[N].z,0.0f,1.0f));
    pixels[y*width+x] = (b << 16) + (g << 8) + r;
    N++;
  }
}

/* task that renders a single screen tile */
task void renderTileTask(uniform int* uniform pixels,
                         const uniform unsigned int width,
                         const uniform unsigned int height,
                         const uniform float time,
                         const uniform ISPCCamera& camera,
                         const uniform int numTilesX,
                         const uniform int numTilesY)
{
  renderTile(taskIndex,pixels,width,height,time,camera,numTilesX,numTilesY);
}

/* called by the C++ code to render */
export void device_render (uniform int* uniform pixels,
                           const uniform unsigned int width,
                           const uniform unsigned int height,
                           const uniform float time,
                           const uniform ISPCCamera& camera)
{
  uniform float t0 = 0.7f*time;
  uniform float t1 = 1.5f*time;

  /* rotate instances around themselves */
  uniform LinearSpace3f xfm;
  xfm.vx = make_Vec3f(cos(t1),0,sin(t1));
  xfm.vy = make_Vec3f(0,1,0);
  xfm.vz = make_Vec3f(-sin(t1),0,cos(t1));

  /* calculate transformations to move instances in circles */
  g_instance[0]->local2world = make_AffineSpace3f(xfm,2.2f*make_Vec3f(+cos(t0),0.0f,+sin(t0)));
  g_instance[1]->local2world = make_AffineSpace3f(xfm,2.2f*make_Vec3f(-cos(t0),0.0f,-sin(t0)));
  g_instance[2]->local2world = make_AffineSpace3f(xfm,2.2f*make_Vec3f(-sin(t0),0.0f,+cos(t0)));
  g_instance[3]->local2world = make_AffineSpace3f(xfm,2.2f*make_Vec3f(+sin(t0),0.0f,-cos(t0)));

  /* update scene */
  updateInstance(g_scene,g_instance[0]);
  updateInstance(g_scene,g_instance[1]);
  updateInstance(g_scene,g_instance[2]);
  updateInstance(g_scene,g_instance[3]);
  rtcCommit (g_scene);

  /* render all pixels */
  const uniform int numTilesX = (width +TILE_SIZE_X-1)/TILE_SIZE_X;
  const uniform int numTilesY = (height+TILE_SIZE_Y-1)/TILE_SIZE_Y;
  launch[numTilesX*numTilesY] renderTileTask(pixels,width,height,time,camera,numTilesX,numTilesY); sync;
}

/* called by the C++ code for cleanup */
export void device_cleanup ()
{
  rtcDeleteScene (g_scene); g_scene = NULL;
  rtcDeleteScene (g_scene0); g_scene0 = NULL;
  rtcDeleteScene (g_scene1); g_scene1 = NULL;
  rtcDeleteScene (g_scene2); g_scene2 = NULL;
  rtcDeleteDevice(g_device); g_device = NULL;
}
