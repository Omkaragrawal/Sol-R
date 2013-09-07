/* 
* Copyright (C) 2011-2012 Cyrille Favreau <cyrille_favreau@hotmail.com>
*
* This library is free software; you can redistribute it and/or
* modify it under the terms of the GNU Library General Public
* License as published by the Free Software Foundation; either
* version 2 of the License, or (at your option) any later version.
*
* This library is distributed in the hope that it will be useful,
* but WITHOUT ANY WARRANTY; without even the implied warranty of
* MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
* Library General Public License for more details.
*
* You should have received a copy of the GNU General Public License
* along with this program.  If not, see <http://www.gnu.org/licenses/>. 
*/

/*
* Author: Cyrille Favreau <cyrille_favreau@hotmail.com>
*
*/

#pragma OPENCL EXTENSION cl_khr_fp64 : enable

// Globals
// Defines
// #define PHOTON_ENERGY
#define GRADIANT_BACKGROUND
#define EXTENDED_GEOMETRY      // Includes spheres, cylinders, etc

// Typedefs
typedef int4          PrimitiveXYIdBuffer;
typedef float4        PostProcessingBuffer;
typedef unsigned char BitmapBuffer;
typedef float         RandomBuffer;
typedef int           Lamp;

// Constants
#define MAX_GPU_COUNT     32
#define MAX_STREAM_COUNT  32
#define NB_MAX_ITERATIONS 20

__constant const int NB_MAX_BOXES      = 4096;
__constant const int NB_MAX_PRIMITIVES = 1000000;
__constant const int NB_MAX_LAMPS      = 10;
__constant const int NB_MAX_MATERIALS  = 1030; // Last 30 materials are reserved
__constant const int NB_MAX_TEXTURES   = 1000;
__constant const int NB_MAX_FRAMES     = 1000;
__constant const int NB_MAX_LIGHTINFORMATIONS = 500;

__constant const int MATERIAL_NONE = -1;
__constant const int TEXTURE_NONE = -1;
__constant const int TEXTURE_MANDELBROT = -2;
__constant const int TEXTURE_JULIA = -3;
__constant const int gColorDepth = 3;

// Globals
__constant const int PI=3.14159265358979323846f;
__constant const int EPSILON=1.f;

// Kinect
__constant const int gKinectVideoWidth  = 640;
__constant const int gKinectVideoHeight = 480;
__constant const int gKinectVideo       = 4;
__constant const int gKinectVideoSize   = gKinectVideoWidth*gKinectVideoHeight*gKinectVideo;

__constant const int gKinectDepthWidth  = 320;
__constant const int gKinectDepthHeight = 240;
__constant const int gKinectDepth       = 2;
__constant const int gKinectDepthSize   = gKinectDepthWidth*gKinectDepthHeight*gKinectDepth;

// 3D vision type
enum VisionType
{
   vtStandard = 0,
   vtAnaglyph = 1,
   vt3DVision = 2,
   vtFishEye  = 3
};

enum OutputType
{
   otOpenGL = 0,
   otDelphi = 1,
   otJPEG   = 2
};

// Scene information
typedef struct
{
   int    width;
   int    height;
   int    graphicsLevel;    // 1: lambert, 2: Specular, 3: Shadows
   int    nbRayIterations;
   float  transparentColor;
   float  viewDistance;
   float  shadowIntensity;
   float  width3DVision;
   float4  backgroundColor;
   int    renderingType;   // Anaglyth, 3DVision, Fish Eye, etc.
   int    renderBoxes;
   int    pathTracingIteration;
   int    maxPathTracingIterations;
   int4    misc; // x : OpenGL=0, Delphi=1, JPEG=2, y: timer, z: fog (0: disabled, 1: enabled), w: 1: Isometric 3D, 2: Antializing
} SceneInfo;

typedef struct
{
   float3 origin;
   float3 direction;
   float3 inv_direction;
   int4   signs;
} Ray;

typedef struct
{
   int   attribute; // x: object ID
   float3 location;
   float4 color;
} LightInformation;

// Enums
enum PrimitiveType 
{
   ptSphere      = 0,
   ptCylinder    = 1,
   ptTriangle    = 2,
   ptCheckboard  = 3,
   ptCamera      = 4,
   ptXYPlane     = 5,
   ptYZPlane     = 6,
   ptXZPlane     = 7,
   ptMagicCarpet = 8,
   ptEnvironment = 9,
   ptEllipsoid   = 10
};

// TODO! Data structure is too big!!!
typedef struct
{
   float4 innerIllumination; // x: inner illumination, y: diffusion strength
   float4 color;             // w: noise
   float4 specular;          // x: value, y: power, w: coef
   float reflection;     
   float refraction;
   float transparency;
   int4   attributes;        // x: fastTransparency, y: procedural, z: wireframe, w: wireframeWidth
   int4   textureMapping;    // x: width, y:height, z: Texture ID, w: color depth
   int   textureOffset;     // x: offset in the texture buffer
} Material;

typedef struct
{
   float3 parameters[2];
   int   nbPrimitives;
   int   startIndex;
   int2   type; // Alignment issues
} BoundingBox;

typedef struct
{
   float3 p0;
   float3 p1;
   float3 p2;
   float3 n0;
   float3 n1;
   float3 n2;
   float3 size;
   int   type;
   int   index;
   int   materialId;
   float3 vt0;
   float3 vt1;
   float3 vt2;
} Primitive;

typedef struct
{
   BitmapBuffer* buffer;
   int   offset;
   int3  size;
} TextureInformation;

// Post processing effect
enum PostProcessingType 
{
   ppe_none,
   ppe_depthOfField,
   ppe_ambientOcclusion,
   ppe_enlightment
};

typedef struct
{
   int   type;
   float param1; // pointOfFocus;
   float param2; // strength;
   int   param3; // iterations;
} PostProcessingInfo;

// ________________________________________________________________________________
float vectorLength( float4 vector )
{
   return sqrt( vector.x*vector.x + vector.y*vector.y + vector.z*vector.z );
}

// ________________________________________________________________________________
inline void normalizeVector( float4* v )
{
   (*v) /= vectorLength(*v);
}

// ________________________________________________________________________________
void saturateVector( float4* v )
{
   v->x = (v->x<0.f) ? 0.f : v->x;
   v->y = (v->y<0.f) ? 0.f : v->y; 
   v->z = (v->z<0.f) ? 0.f : v->z;
   v->w = (v->w<0.f) ? 0.f : v->w;

   v->x = (v->x>1.f) ? 1.f : v->x;
   v->y = (v->y>1.f) ? 1.f : v->y; 
   v->z = (v->z>1.f) ? 1.f : v->z;
   v->w = (v->w>1.f) ? 1.f : v->w;
}

// ________________________________________________________________________________
float3 crossProduct( const float3* b, const float3* c )
{
   float3 a;
   a.x = b->y*c->z - b->z*c->y;
   a.y = b->z*c->x - b->x*c->z;
   a.z = b->x*c->y - b->y*c->x;
   return a;
}

/*
________________________________________________________________________________
incident  : le vecteur normal inverse a la direction d'incidence de la source 
lumineuse
normal    : la normale a l'interface orientee dans le materiau ou se propage le 
rayon incident
reflected : le vecteur normal reflechi
________________________________________________________________________________
*/
#define vectorReflection( __r, __i, __n ) \
   __r = __i-2.f*dot(__i,__n)*__n;

/*
________________________________________________________________________________
incident: le vecteur norm? inverse ? la direction d?incidence de la source 
lumineuse
n1      : index of refraction of original medium
n2      : index of refraction of new medium
________________________________________________________________________________
*/
void vectorRefraction( 
   float3*      refracted, 
   const float3 incident, 
   const float  n1, 
   const float3 normal, 
   const float  n2 )
{
   (*refracted) = incident;
   if(n1!=n2 && n2!=0.f) 
   {
      float r = n1/n2;
      float cosI = dot( incident, normal );
      float cosT2 = 1.f - r*r*(1.f - cosI*cosI);
      (*refracted) = r*incident + (r*cosI-sqrt( fabs(cosT2) ))*normal;
   }
}

/*
________________________________________________________________________________
__v : Vector to rotate
__c : Center of rotations
__a : Angles
________________________________________________________________________________
*/
#define vectorRotation( __v, __c, __a ) \
{ \
   float3 __r = __v; \
   /* X axis */ \
   __r.y = __v.y*half_cos(angles.x) - __v.z*half_sin(__a.x); \
   __r.z = __v.y*half_sin(angles.x) + __v.z*half_cos(__a.x); \
   __v = __r; \
   __r = __v; \
   /* Y axis */ \
   __r.z = __v.z*half_cos(__a.y) - __v.x*half_sin(__a.y); \
   __r.x = __v.z*half_sin(__a.y) + __v.x*half_cos(__a.y); \
   __v = __r; \
}

/*
________________________________________________________________________________

Compute ray attributes
________________________________________________________________________________
*/
void computeRayAttributes(Ray* ray)
{
   ray->inv_direction.x = 1.f/ray->direction.x;
   ray->inv_direction.y = 1.f/ray->direction.y;
   ray->inv_direction.z = 1.f/ray->direction.z;
   ray->signs.x = (ray->inv_direction.x < 0);
   ray->signs.y = (ray->inv_direction.y < 0);
   ray->signs.z = (ray->inv_direction.z < 0);
}

/*
________________________________________________________________________________

Convert float4 into OpenGL RGB color
________________________________________________________________________________
*/
void makeColor(
   const SceneInfo* sceneInfo,
   const float4*    color,
   __global BitmapBuffer*    bitmap,
   int              index)
{
   int mdc_index = index*gColorDepth; 
   color->x = (color->x>1.f) ? 1.f : color->x;
   color->y = (color->y>1.f) ? 1.f : color->y; 
   color->z = (color->z>1.f) ? 1.f : color->z;
   color->x = (color->x<0.f) ? 0.f : color->x;
   color->y = (color->y<0.f) ? 0.f : color->y; 
   color->z = (color->z<0.f) ? 0.f : color->z;

   switch( sceneInfo->misc.x )
   {
   case otOpenGL: 
      {
         // OpenGL
         bitmap[mdc_index  ] = (BitmapBuffer)(color->x*255.f); // Red
         bitmap[mdc_index+1] = (BitmapBuffer)(color->y*255.f); // Green
         bitmap[mdc_index+2] = (BitmapBuffer)(color->z*255.f); // Blue
         break;
      }
   case otDelphi: 
      {
         // Delphi
         bitmap[mdc_index  ] = (BitmapBuffer)(color->z*255.f); // Blue
         bitmap[mdc_index+1] = (BitmapBuffer)(color->y*255.f); // Green
         bitmap[mdc_index+2] = (BitmapBuffer)(color->x*255.f); // Red
         break;
      }
   case otJPEG: 
      {
         mdc_index = (sceneInfo->width*sceneInfo->height-index)*gColorDepth; 
         // JPEG
         bitmap[mdc_index+2] = (BitmapBuffer)(color->z*255.f); // Blue
         bitmap[mdc_index+1] = (BitmapBuffer)(color->y*255.f); // Green
         bitmap[mdc_index  ] = (BitmapBuffer)(color->x*255.f); // Red
         break;
      }
   }
}

/*
________________________________________________________________________________

Mandelbrot Set
________________________________________________________________________________
*/
void juliaSet( 
   __global const Primitive* primitive,
   __global const Material*  materials,
   const SceneInfo* sceneInfo, 
   const float x, 
   const float y, 
   float4* color )
{
   __global const Material* material = &materials[primitive->materialId];
   float W = (float)material->textureMapping.x;
   float H = (float)material->textureMapping.y;

   //pick some values for the constant c, this determines the shape of the Julia Set
   float cRe = -0.7f + 0.4f*sin(sceneInfo->misc.y/1500.f);
   float cIm = 0.27015f + 0.4f*cos(sceneInfo->misc.y/2000.f);

   //calculate the initial real and imaginary part of z, based on the pixel location and zoom and position values
   float newRe = 1.5f * (x - W / 2.f) / (0.5f * W);
   float newIm = (y - H / 2.f) / (0.5f * H);
   //i will represent the number of iterations
   int n;
   //start the iteration process
   float  maxIterations = 40.f+sceneInfo->pathTracingIteration;
   for(n = 0; n<maxIterations; n++)
   {
      //remember value of previous iteration
      float oldRe = newRe;
      float oldIm = newIm;
      //the actual iteration, the real and imaginary part are calculated
      newRe = oldRe * oldRe - oldIm * oldIm + cRe;
      newIm = 2.f * oldRe * oldIm + cIm;
      //if the point is outside the circle with radius 2: stop
      if((newRe * newRe + newIm * newIm) > 4.f) break;
   }
   //use color model conversion to get rainbow palette, make brightness black if maxIterations reached
   //color.x += newRe/4.f;
   //color.z += newIm/4.f;
   color->x = 1.f-color->x*(n/maxIterations);
   color->y = 1.f-color->y*(n/maxIterations);
   color->z = 1.f-color->z*(n/maxIterations);
   color->w = 1.f-(n/maxIterations);
}

/*
________________________________________________________________________________

Mandelbrot Set
________________________________________________________________________________
*/
void mandelbrotSet( 
   __global const Primitive* primitive,
   __global const Material*  materials,
   const SceneInfo* sceneInfo, 
   const float x, 
   const float y, 
   float4* color )
{
   __global const Material* material = &materials[primitive->materialId];
   float W = (float)material->textureMapping.x;
   float H = (float)material->textureMapping.y;

   float  MinRe		= -2.f;
   float  MaxRe		=	1.f;
   float  MinIm		= -1.2f;
   float  MaxIm		=	MinIm + (MaxRe - MinRe) * H/W;
   float  Re_factor	=	(MaxRe - MinRe) / (W - 1.f);
   double Im_factor	=	(MaxIm - MinIm) / (H - 1.f);
   float  maxIterations = NB_MAX_ITERATIONS+sceneInfo->pathTracingIteration;

   float c_im = MaxIm - y*Im_factor;
   float c_re = MinRe + x*Re_factor;
   float Z_re = c_re;
   float Z_im = c_im;
   bool isInside = true;
   unsigned n;
   for( n = 0; isInside && n < maxIterations; ++n ) 
   {
      float Z_re2 = Z_re*Z_re;
      float Z_im2 = Z_im*Z_im;
      if ( Z_re2+Z_im2>4.f ) 
      {
         isInside = false;
      }
      Z_im = 2.f*Z_re*Z_im+c_im;
      Z_re = Z_re2 - Z_im2+c_re;
   }

   color->x = 1.f-color->x*(n/maxIterations);
   color->y = 1.f-color->y*(n/maxIterations);
   color->z = 1.f-color->z*(n/maxIterations);
   color->w = 1.f-(n/maxIterations);
}

/*
________________________________________________________________________________

Sphere texture Mapping
________________________________________________________________________________
*/
float4 sphereUVMapping( 
   __global const Primitive* primitive,
   __global const Material*  materials,
   __global const BitmapBuffer* textures,
   const float3 intersection)
{
   __global const Material* material = &materials[primitive->materialId];
   float4 result = material->color;

   float3 d = normalize(primitive->p0-intersection);
   int u = primitive->size.x * (0.5f - atan2(d.z, d.x) / 2*PI);
   int v = primitive->size.y * (0.5f - 2.f*(asin(d.y) / 2*PI));

   if( material->textureMapping.x != 0 ) u = u%material->textureMapping.x;
   if( material->textureMapping.y != 0 ) v = v%material->textureMapping.y;
   if( u>=0 && u<material->textureMapping.x && v>=0 && v<material->textureMapping.y )
   {
      int index = material->textureOffset + (v*material->textureMapping.x+u)*material->textureMapping.w;
      BitmapBuffer r = textures[index  ];
      BitmapBuffer g = textures[index+1];
      BitmapBuffer b = textures[index+2];
      result.x = r/256.f;
      result.y = g/256.f;
      result.z = b/256.f;
   }
   return result; 
}

/*
________________________________________________________________________________

Cube texture mapping
________________________________________________________________________________
*/
float4 cubeMapping( 
   const SceneInfo*    sceneInfo,
   __global const Primitive*    primitive, 
   __global const Material*     materials,
   __global const BitmapBuffer* textures,
   const float3        intersection)
{
   __global const Material* material = &materials[primitive->materialId];
   float4 result = material->color;

   int u = ((primitive->type == ptCheckboard) || (primitive->type == ptXZPlane) || (primitive->type == ptXYPlane))  ? 
      (intersection.x-primitive->p0.x+primitive->size.x):
   (intersection.z-primitive->p0.z+primitive->size.z);

   int v = ((primitive->type == ptCheckboard) || (primitive->type == ptXZPlane)) ? 
      (intersection.z+primitive->p0.z+primitive->size.z) :
   (intersection.y-primitive->p0.y+primitive->size.y);

   if( material->textureMapping.x != 0 ) u = u%material->textureMapping.x;
   if( material->textureMapping.y != 0 ) v = v%material->textureMapping.y;

   if( u>=0 && u<material->textureMapping.x && v>=0 && v<material->textureMapping.x )
   {
      switch( material->textureMapping.z )
      {
      case TEXTURE_MANDELBROT: mandelbrotSet( primitive, materials, sceneInfo, u, v, &result ); break;
      case TEXTURE_JULIA: juliaSet( primitive, materials, sceneInfo, u, v, &result ); break;
      default:
         {
            int index = material->textureOffset + (v*material->textureMapping.x+u)*material->textureMapping.w;
            BitmapBuffer r = textures[index];
            BitmapBuffer g = textures[index+1];
            BitmapBuffer b = textures[index+2];
            result.x = r/256.f;
            result.y = g/256.f;
            result.z = b/256.f;
         }
         break;
      }
   }

   return result;
}

/*
________________________________________________________________________________

Triangle texture Mapping
________________________________________________________________________________
*/
float4 triangleUVMapping( 
   const SceneInfo* sceneInfo,
   __global const Primitive* primitive,
   __global const Material*        materials,
   __global const BitmapBuffer*    textures,
   const float3    intersection,
   const float3    areas)
{
   __global const Material* material = &materials[primitive->materialId];
   float4 result = material->color;

   float3 T = (primitive->vt0*areas.x+primitive->vt1*areas.y+primitive->vt2*areas.z)/(areas.x+areas.y+areas.z);
   int u = T.x*material->textureMapping.x;
   int v = T.y*material->textureMapping.y;

   u = u%material->textureMapping.x;
   v = v%material->textureMapping.y;
   if( u>=0 && u<material->textureMapping.x && v>=0 && v<material->textureMapping.y )
   {
      switch( material->textureMapping.z )
      {
      case TEXTURE_MANDELBROT: mandelbrotSet( primitive, materials, sceneInfo, u, v, &result ); break;
      case TEXTURE_JULIA: juliaSet( primitive, materials, sceneInfo, u, v, &result ); break;
      default:
         {
            int index = material->textureOffset + (v*material->textureMapping.x+u)*material->textureMapping.w;
            BitmapBuffer r = textures[index  ];
            BitmapBuffer g = textures[index+1];
            BitmapBuffer b = textures[index+2];
            result.x = r/256.f;
            result.y = g/256.f;
            result.z = b/256.f;
         }
      }
   }
   return result; 
}

/*
________________________________________________________________________________

Box intersection
________________________________________________________________________________
*/
bool boxIntersection( 
   __global const BoundingBox* box, 
   const Ray*         ray,
   const float        t0,
   const float        t1)
{
   float tmin, tmax, tymin, tymax, tzmin, tzmax;

   tmin = (box->parameters[ray->signs.x].x - ray->origin.x) * ray->inv_direction.x;
   tmax = (box->parameters[1-ray->signs.x].x - ray->origin.x) * ray->inv_direction.x;
   tymin = (box->parameters[ray->signs.y].y - ray->origin.y) * ray->inv_direction.y;
   tymax = (box->parameters[1-ray->signs.y].y - ray->origin.y) * ray->inv_direction.y;

   if ( (tmin > tymax) || (tymin > tmax) ) 
      return false;

   if (tymin > tmin) tmin = tymin;
   if (tymax < tmax) tmax = tymax;
   tzmin = (box->parameters[ray->signs.z].z - ray->origin.z) * ray->inv_direction.z;
   tzmax = (box->parameters[1-ray->signs.z].z - ray->origin.z) * ray->inv_direction.z;

   if ( (tmin > tzmax) || (tzmin > tmax) ) 
      return false;

   if (tzmin > tmin) tmin = tzmin;
   if (tzmax < tmax) tmax = tzmax;
   return ( (tmin < t1) && (tmax > t0) );
}

#ifdef EXTENDED_GEOMETRY
/*
________________________________________________________________________________

Ellipsoid intersection
________________________________________________________________________________
*/
bool ellipsoidIntersection(
   const SceneInfo* sceneInfo,
   __global const Primitive* ellipsoid,
   __global const Material*  materials, 
   const Ray* ray, 
   float3* intersection,
   float3* normal,
   float* shadowIntensity,
   bool* back) 
{
   // Shadow intensity
   (*shadowIntensity) = 1.f;

   // solve the equation sphere-ray to find the intersections
   float3 O_C = ray->origin-ellipsoid->p0;
   float3 dir = normalize(ray->direction);

   float a = 
      ((dir.x*dir.x)/(ellipsoid->size.x*ellipsoid->size.x))
      + ((dir.y*dir.y)/(ellipsoid->size.y*ellipsoid->size.y))
      + ((dir.z*dir.z)/(ellipsoid->size.z*ellipsoid->size.z));
   float b = 
      ((2.f*O_C.x*dir.x)/(ellipsoid->size.x*ellipsoid->size.x))
      + ((2.f*O_C.y*dir.y)/(ellipsoid->size.y*ellipsoid->size.y))
      + ((2.f*O_C.z*dir.z)/(ellipsoid->size.z*ellipsoid->size.z));
   float c = 
      ((O_C.x*O_C.x)/(ellipsoid->size.x*ellipsoid->size.x))
      + ((O_C.y*O_C.y)/(ellipsoid->size.y*ellipsoid->size.y))
      + ((O_C.z*O_C.z)/(ellipsoid->size.z*ellipsoid->size.z))
      - 1.f;

   float d = ((b*b)-(4.f*a*c));
   if ( d<0.f || a==0.f || b==0.f || c==0.f ) 
   { 
      return false;
   }
   d = sqrt(d); 

   float t1 = (-b+d)/(2.f*a);
   float t2 = (-b-d)/(2.f*a);

   if( t1<=EPSILON && t2<=EPSILON ) return false; // both intersections are behind the ray origin
   (*back) = (t1<=EPSILON || t2<=EPSILON); // If only one intersection (t>0) then we are inside the sphere and the intersection is at the back of the sphere

   float t=0.f;
   if( t1<=EPSILON ) 
      t = t2;
   else 
      if( t2<=EPSILON )
         t = t1;
      else
         t=(t1<t2) ? t1 : t2;

   if( t<EPSILON ) return false; // Too close to intersection
   (*intersection) = ray->origin + t*dir;

   (*normal) = (*intersection)-ellipsoid->p0;
   normal->x = 2.f*normal->x/(ellipsoid->size.x*ellipsoid->size.x);
   normal->y = 2.f*normal->y/(ellipsoid->size.y*ellipsoid->size.y);
   normal->z = 2.f*normal->z/(ellipsoid->size.z*ellipsoid->size.z);

   (*normal) *= (*back) ? -1.f : 1.f;
   (*normal) = normalize(*normal);
   return true;
}

/*
________________________________________________________________________________

Sphere intersection
________________________________________________________________________________
*/
bool sphereIntersection(
   const SceneInfo* sceneInfo,
   __global const Primitive* sphere, 
   __global const Material*  materials, 
   const Ray* ray, 
   float3*    intersection,
   float3*    normal,
   float*     shadowIntensity,
   bool*      back
   ) 
{
   // solve the equation sphere-ray to find the intersections
   float3 O_C = ray->origin-sphere->p0;
   float3 dir = normalize(ray->direction); 

   float a = 2.f*dot(dir,dir);
   float b = 2.f*dot(O_C,dir);
   float c = dot(O_C,O_C) - (sphere->size.x*sphere->size.x);
   float d = b*b-2.f*a*c;

   if( d<=0.f || a == 0.f) return false;
   float r = sqrt(d);
   float t1 = (-b-r)/a;
   float t2 = (-b+r)/a;

   if( t1<=EPSILON && t2<=EPSILON ) return false; // both intersections are behind the ray origin
   (*back) = (t1<=EPSILON || t2<=EPSILON); // If only one intersection (t>0) then we are inside the sphere and the intersection is at the back of the sphere

   float t=0.f;
   if( t1<=EPSILON ) 
      t = t2;
   else 
      if( t2<=EPSILON )
         t = t1;
      else
         t=(t1<t2) ? t1 : t2;

   if( t<EPSILON ) return false; // Too close to intersection
   (*intersection) = ray->origin+t*dir;

   // TO REMOVE - For Charts only
   //if( intersection.y < sphere->p0.y ) return false;

   if( materials[sphere->materialId].attributes.y == 0) 
   {
      // Compute normal vector
      (*normal) = (*intersection)-sphere->p0;
   }
   else
   {
      // Procedural texture
      float3 newCenter;
      newCenter.x = sphere->p0.x + 0.008f*sphere->size.x*cos(sceneInfo->misc.y + intersection->x );
      newCenter.y = sphere->p0.y + 0.008f*sphere->size.y*sin(sceneInfo->misc.y + intersection->y );
      newCenter.z = sphere->p0.z + 0.008f*sphere->size.z*sin(cos(sceneInfo->misc.y + intersection->z ));
      (*normal) = (*intersection) - newCenter;
   }
   (*normal) *= (back) ? -1.f : 1.f;
   (*normal) = normalize(*normal);

   // Shadow management
   r = dot(dir,*normal);
   (*shadowIntensity) = (materials[sphere->materialId].transparency != 0.f) ? (1.f-fabs(r)) : 1.f;

#if EXTENDED_FEATURES
   // Power textures
   if (materials[sphere->materialId].textureInfo.y != TEXTURE_NONE && materials[sphere->materialId].transparency != 0 ) 
   {
      float3 color = sphereUVMapping(sphere, materials, textures, intersection, timer );
      return ((color.x+color.y+color.z) >= sceneInfo->transparentColor.x ); 
   }
#endif // 0

   return true;
}

/*
________________________________________________________________________________

Cylinder (*intersection)
________________________________________________________________________________
*/
bool cylinderIntersection( 
   const SceneInfo* sceneInfo,
   __global const Primitive* cylinder,
   __global const Material*  materials, 
   const Ray* ray,
   float3*    intersection,
   float3*    normal,
   float*     shadowIntensity,
   bool*      back) 
{
   back = false;
   float3 O_C = ray->origin-cylinder->p0;
   float3 dir = ray->direction;
   float3 n1 = cylinder->n1;
   float3 n   = crossProduct(&dir, &n1);

   float ln = length(n);

   // Parallel? (?)
   if((ln<EPSILON)&&(ln>-EPSILON))
      return false;

   n = normalize(n);

   float d = fabs(dot(O_C,n));
   if (d>cylinder->size.y) return false;

   float3 O = crossProduct(&O_C,&n1);
   float t = -dot(O, n)/ln;
   O = normalize(crossProduct(&n,&n1));
   float s=fabs( sqrt(cylinder->size.x*cylinder->size.x-d*d) / dot( dir,O ) );

   float in=t-s;
   float out=t+s;

   if (in<-EPSILON)
   {
      if(out<-EPSILON)
         return false;
      else 
      {
         t=out;
         (*back) = true;
      }
   }
   else
   {
      if(out<-EPSILON)
      {
         t=in;
      }
      else
      {
         if(in<out)
            t=in;
         else
         {
            t=out;
            (*back) = true;
         }

         if( t<0.f ) return false;

         // Calculate intersection point
         (*intersection) = ray->origin+t*dir;

         float3 HB1 = (*intersection)-cylinder->p0;
         float3 HB2 = (*intersection)-cylinder->p1;

         float scale1 = dot(HB1,cylinder->n1);
         float scale2 = dot(HB2,cylinder->n1);

         // Cylinder length
         if( scale1 < EPSILON || scale2 > EPSILON ) return false;

         if( materials[cylinder->materialId].attributes.y == 1) 
         {
            // Procedural texture
            float3 newCenter;
            newCenter.x = cylinder->p0.x + 0.01f*cylinder->size.x*cos(sceneInfo->misc.y/100.f+intersection->x);
            newCenter.y = cylinder->p0.y + 0.01f*cylinder->size.y*sin(sceneInfo->misc.y/100.f+intersection->y);
            newCenter.z = cylinder->p0.z + 0.01f*cylinder->size.z*sin(cos(sceneInfo->misc.y/100.f+intersection->z));
            HB1 = (*intersection) - newCenter;
         }

         (*normal) = normalize(HB1-cylinder->n1*scale1);

         // Shadow management
         dir = normalize(dir);
         float r = dot(dir,(*normal));
         (*shadowIntensity) = (materials[cylinder->materialId].transparency != 0.f) ? (1.f-fabs(r)) : 1.f;
         return true;
      }
   }
   return false;
}

/*
________________________________________________________________________________

Checkboard (*intersection)
________________________________________________________________________________
*/
bool planeIntersection( 
   const SceneInfo*    sceneInfo,
   __global const Primitive*    primitive,
   __global const Material*     materials,
   __global const BitmapBuffer* textures,
   const Ray*          ray, 
   float3*             intersection,
   float3*             normal,
   float*              shadowIntensity,
   bool                reverse)
{ 
   bool collision = false;

   float reverted = reverse ? -1.f : 1.f;
   switch( primitive->type ) 
   {
   case ptMagicCarpet:
   case ptCheckboard:
      {
         (*intersection).y = primitive->p0.y;
         float y = ray->origin.y-primitive->p0.y;
         if( reverted*ray->direction.y<0.f && reverted*ray->origin.y>reverted*primitive->p0.y) 
         {
            (*normal).x =  0.f;
            (*normal).y =  1.f;
            (*normal).z =  0.f;
            (*intersection).x = ray->origin.x+y*ray->direction.x/-ray->direction.y;
            (*intersection).z = ray->origin.z+y*ray->direction.z/-ray->direction.y;
            collision = 
               fabs((*intersection).x - primitive->p0.x) < primitive->size.x &&
               fabs((*intersection).z - primitive->p0.z) < primitive->size.z;
         }
         break;
      }
   case ptXZPlane:
      {
         float y = ray->origin.y-primitive->p0.y;
         if( reverted*ray->direction.y<0.f && reverted*ray->origin.y>reverted*primitive->p0.y) 
         {
            (*normal).x =  0.f;
            (*normal).y =  1.f;
            (*normal).z =  0.f;
            (*intersection).x = ray->origin.x+y*ray->direction.x/-ray->direction.y;
            (*intersection).y = primitive->p0.y;
            (*intersection).z = ray->origin.z+y*ray->direction.z/-ray->direction.y;
            collision = 
               fabs((*intersection).x - primitive->p0.x) < primitive->size.x &&
               fabs((*intersection).z - primitive->p0.z) < primitive->size.z;
         }
         if( !collision && reverted*ray->direction.y>0.f && reverted*ray->origin.y<reverted*primitive->p0.y) 
         {
            (*normal).x =  0.f;
            (*normal).y = -1.f;
            (*normal).z =  0.f;
            (*intersection).x = ray->origin.x+y*ray->direction.x/-ray->direction.y;
            (*intersection).y = primitive->p0.y;
            (*intersection).z = ray->origin.z+y*ray->direction.z/-ray->direction.y;
            collision = 
               fabs((*intersection).x - primitive->p0.x) < primitive->size.x &&
               fabs((*intersection).z - primitive->p0.z) < primitive->size.z;
         }
         break;
      }
   case ptYZPlane:
      {
         float x = ray->origin.x-primitive->p0.x;
         if( reverted*ray->direction.x<0.f && reverted*ray->origin.x>reverted*primitive->p0.x ) 
         {
            (*normal).x =  1.f;
            (*normal).y =  0.f;
            (*normal).z =  0.f;
            (*intersection).x = primitive->p0.x;
            (*intersection).y = ray->origin.y+x*ray->direction.y/-ray->direction.x;
            (*intersection).z = ray->origin.z+x*ray->direction.z/-ray->direction.x;
            collision = 
               fabs((*intersection).y - primitive->p0.y) < primitive->size.y &&
               fabs((*intersection).z - primitive->p0.z) < primitive->size.z;
         }
         if( !collision && reverted*ray->direction.x>0.f && reverted*ray->origin.x<reverted*primitive->p0.x ) 
         {
            (*normal).x = -1.f;
            (*normal).y =  0.f;
            (*normal).z =  0.f;
            (*intersection).x = primitive->p0.x;
            (*intersection).y = ray->origin.y+x*ray->direction.y/-ray->direction.x;
            (*intersection).z = ray->origin.z+x*ray->direction.z/-ray->direction.x;
            collision = 
               fabs((*intersection).y - primitive->p0.y) < primitive->size.y &&
               fabs((*intersection).z - primitive->p0.z) < primitive->size.z;
         }
         break;
      }
   case ptXYPlane:
      {
         float z = ray->origin.z-primitive->p0.z;
         if( reverted*ray->direction.z<0.f && reverted*ray->origin.z>reverted*primitive->p0.z) 
         {
            (*normal).x =  0.f;
            (*normal).y =  0.f;
            (*normal).z =  1.f;
            (*intersection).z = primitive->p0.z;
            (*intersection).x = ray->origin.x+z*ray->direction.x/-ray->direction.z;
            (*intersection).y = ray->origin.y+z*ray->direction.y/-ray->direction.z;
            collision = 
               fabs((*intersection).x - primitive->p0.x) < primitive->size.x &&
               fabs((*intersection).y - primitive->p0.y) < primitive->size.y;
         }
         if( !collision && reverted*ray->direction.z>0.f && reverted*ray->origin.z<reverted*primitive->p0.z )
         {
            (*normal).x =  0.f;
            (*normal).y =  0.f;
            (*normal).z = -1.f;
            (*intersection).z = primitive->p0.z;
            (*intersection).x = ray->origin.x+z*ray->direction.x/-ray->direction.z;
            (*intersection).y = ray->origin.y+z*ray->direction.y/-ray->direction.z;
            collision = 
               fabs((*intersection).x - primitive->p0.x) < primitive->size.x &&
               fabs((*intersection).y - primitive->p0.y) < primitive->size.y;
         }
         break;
      }
   case ptCamera:
      {
         if( reverted*ray->direction.z<0.f && reverted*ray->origin.z>reverted*primitive->p0.z )
         {
            (*normal).x =  0.f;
            (*normal).y =  0.f;
            (*normal).z =  1.f;
            (*intersection).z = primitive->p0.z;
            float z = ray->origin.z-primitive->p0.z;
            (*intersection).x = ray->origin.x+z*ray->direction.x/-ray->direction.z;
            (*intersection).y = ray->origin.y+z*ray->direction.y/-ray->direction.z;
            collision =
               fabs((*intersection).x - primitive->p0.x) < primitive->size.x &&
               fabs((*intersection).y - primitive->p0.y) < primitive->size.y;
         }
         break;
      }
   }

   if( collision ) 
   {
      // Shadow intensity
      (*shadowIntensity) = 1.f;

      float4 color = materials[primitive->materialId].color;
      if( primitive->type == ptCamera || materials[primitive->materialId].textureMapping.z != TEXTURE_NONE )
      {
         color = cubeMapping(sceneInfo, primitive, materials, textures, *intersection );
         (*shadowIntensity) = color.w;
      }

      if( (color.x+color.y+color.z)/3.f >= sceneInfo->transparentColor ) 
      {
         collision = false;
      }
   }
   return collision;
}
#endif // EXTENDED_GEOMETRY

/*
________________________________________________________________________________

Triangle intersection
________________________________________________________________________________
*/
bool triangleIntersection( 
   const SceneInfo* sceneInfo,
   __global const Primitive* triangle, 
   __global const Material*  materials,
   const Ray*       ray,
   float3*          intersection,
   float3*          normal,
   float3*          areas,
   float*           shadowIntensity,
   bool*            back )
{
   (*back) = false;
   // Reject rays using the barycentric coordinates of
   // the intersection point with respect to T.
   float3 E01=triangle->p1-triangle->p0;
   float3 E03=triangle->p2-triangle->p0;
   float3 P = crossProduct(&ray->direction,&E03);
   float det = dot(E01,P);

   if (fabs(det) < EPSILON) return false;

   float3 T = ray->origin-triangle->p0;
   float a = dot(T,P)/det;
   if (a < 0.f || a > 1.f) return false;

   float3 Q = crossProduct(&T,&E01);
   float b = dot(ray->direction,Q)/det;
   if (b < 0.f || b > 1.f) return false;

   // Reject rays using the barycentric coordinates of
   // the intersection point with respect to T'.
   if ((a+b) > 1.f) 
   {
      float3 E23 = triangle->p0-triangle->p1;
      float3 E21 = triangle->p1-triangle->p1;
      float3 P_ = crossProduct(&ray->direction,&E21);
      float det_ = dot(E23,P_);
      if(fabs(det_) < EPSILON) return false;
      float3 T_ = ray->origin-triangle->p2;
      float a_ = dot(T_,P_)/det_;
      if (a_ < 0.f) return false;
      float3 Q_ = crossProduct(&T_,&E23);
      float b_ = dot(ray->direction,Q_)/det_;
      if (b_ < 0.f) return false;
   }

   // Compute the ray parameter of the intersection
   // point.
   float t = dot(E03,Q)/det;
   if (t < 0) return false;

   // Intersection
   (*intersection) = ray->origin + t*ray->direction;

   // Normal
   (*normal) = triangle->n0;
   float3 v0 = triangle->p0 - (*intersection);
   float3 v1 = triangle->p1 - (*intersection);
   float3 v2 = triangle->p2 - (*intersection);
   areas->x = 0.5f*length(crossProduct( &v1,&v2 ));
   areas->y = 0.5f*length(crossProduct( &v0,&v2 ));
   areas->z = 0.5f*length(crossProduct( &v0,&v1 ));
   (*normal) = normalize((triangle->n0*areas->x + triangle->n1*areas->y + triangle->n2*areas->z)/(areas->x+areas->y+areas->z));

   float3 dir = normalize(ray->direction);
   float r = dot(dir,(*normal));

   if( r>0.f )
   {
      (*normal) *= -1.f;
   }

   // Shadow management
   (*shadowIntensity) = 1.f;
   return true;
}

/*
________________________________________________________________________________

(*intersection) Shader
________________________________________________________________________________
*/
float4 intersectionShader( 
   const SceneInfo* sceneInfo,
   __global const Primitive* primitive, 
   __global const Material*  materials,
   __global const BitmapBuffer* textures,
   const float3     intersection,
   const float3*    areas)
{
   float4 colorAtIntersection = materials[primitive->materialId].color;
   colorAtIntersection.w = 0.f; // w attribute is used to dtermine light intensity of the material

#ifdef EXTENDED_GEOMETRY
   switch( primitive->type ) 
   {
   case ptCylinder:
      {
         if(materials[primitive->materialId].textureMapping.z != TEXTURE_NONE)
         {
            colorAtIntersection = sphereUVMapping(primitive, materials, textures, intersection );
         }
         break;
      }
   case ptEnvironment:
   case ptSphere:
   case ptEllipsoid:
      {
         if(materials[primitive->materialId].textureMapping.z != TEXTURE_NONE)
         {
            colorAtIntersection = sphereUVMapping( primitive, materials, textures, intersection );
         }
         break;
      }
   case ptCheckboard :
      {
         if( materials[primitive->materialId].textureMapping.z != TEXTURE_NONE ) 
         {
            colorAtIntersection = cubeMapping( sceneInfo, primitive, materials, textures, intersection );
         }
         else 
         {
            int x = sceneInfo->viewDistance + ((intersection.x - primitive->p0.x)/primitive->size.x);
            int z = sceneInfo->viewDistance + ((intersection.z - primitive->p0.z)/primitive->size.x);
            if(x%2==0) 
            {
               if (z%2==0) 
               {
                  colorAtIntersection.x = 1.f-colorAtIntersection.x;
                  colorAtIntersection.y = 1.f-colorAtIntersection.y;
                  colorAtIntersection.z = 1.f-colorAtIntersection.z;
               }
            }
            else 
            {
               if (z%2!=0) 
               {
                  colorAtIntersection.x = 1.f-colorAtIntersection.x;
                  colorAtIntersection.y = 1.f-colorAtIntersection.y;
                  colorAtIntersection.z = 1.f-colorAtIntersection.z;
               }
            }
         }
         break;
      }
   case ptXYPlane:
   case ptYZPlane:
   case ptXZPlane:
   case ptCamera:
      {
         if( materials[primitive->materialId].textureMapping.z != TEXTURE_NONE ) 
         {
            colorAtIntersection = cubeMapping( sceneInfo, primitive, materials, textures, intersection );
         }
         break;
      }
   case ptTriangle:
      {
         if( materials[primitive->materialId].textureMapping.z != TEXTURE_NONE ) 
         {
            colorAtIntersection = triangleUVMapping( sceneInfo, primitive, materials, textures, intersection, *areas );
         }
         break;
      }
   }
#else
   if( materials[primitive->materialId].textureMapping.z != TEXTURE_NONE ) 
   {
      colorAtIntersection = triangleUVMapping( sceneInfo, primitive, materials, textures, intersection, *areas );
   }
#endif // EXTENDED_GEOMETRY
   return colorAtIntersection;
}

/*
________________________________________________________________________________

Shadows computation
We do not consider the object from which the ray is launched...
This object cannot shadow itself !

We now have to find the (*intersection) between the considered object and the ray 
which origin is the considered 3D float4 and which direction is defined by the 
light source center.
.
. * Lamp                     Ray = Origin -> Light Source Center
.  \
.   \##
.   #### object
.    ##
.      \
.       \  Origin
.--------O-------
.
@return 1.f when pixel is in the shades

________________________________________________________________________________
*/
float processShadows(
   const SceneInfo* sceneInfo,
   __global const BoundingBox*  boudingBoxes, 
   const int nbActiveBoxes,
   __global const Primitive*    primitives,
   __global const Material*     materials,
   __global const BitmapBuffer* textures,
   const int     nbPrimitives, 
   const float3 lampCenter, 
   const float3 origin, 
   const int    objectId,
   const int    iteration,
   float4*       color)
{
   float result = 0.f;
   int cptBoxes = 0;
   color->x = 0.f;
   color->y = 0.f;
   color->z = 0.f;
   int it=-1;
   Ray r;
   r.origin    = origin;
   r.direction = lampCenter-origin;
   computeRayAttributes( &r );

   while( result<sceneInfo->shadowIntensity && cptBoxes<nbActiveBoxes )
   {
      __global const BoundingBox* box = &boudingBoxes[cptBoxes];
      if( boxIntersection(box, &r, 0.f, sceneInfo->viewDistance))
      {
         int cptPrimitives = 0;
         while( result<sceneInfo->shadowIntensity && cptPrimitives<box->nbPrimitives)
         {
            float3 intersection = {0.f,0.f,0.f};
            float3 normal       = {0.f,0.f,0.f};
            float3 areas        = {0.f,0.f,0.f};
            float  shadowIntensity = 0.f;

            __global const Primitive* primitive = &(primitives[box->startIndex+cptPrimitives]);
            if( primitive->index!=objectId && materials[primitive->materialId].attributes.x==0)
            {

               bool back;
#ifdef EXTENDED_GEOMETRY
               bool hit = false;
               switch(primitive->type)
               {
               case ptSphere   : hit=sphereIntersection   ( sceneInfo, primitive, materials, &r, &intersection, &normal, &shadowIntensity, &back ); break;
               case ptCylinder : hit=cylinderIntersection ( sceneInfo, primitive, materials, &r, &intersection, &normal, &shadowIntensity, &back ); break;
               case ptCamera   : hit=false; break;
               case ptTriangle : hit=triangleIntersection ( sceneInfo, primitive, materials, &r, &intersection, &normal, &areas, &shadowIntensity, &back ); break;
               case ptEllipsoid: hit=ellipsoidIntersection( sceneInfo, primitive, materials, &r, &intersection, &normal, &shadowIntensity, &back ); break;
               default         : hit=planeIntersection    ( sceneInfo, primitive, materials, textures, &r, &intersection, &normal, &shadowIntensity, false ); break;
               }
               if( hit )
#else
               if( triangleIntersection( sceneInfo, primitive, materials, &r, &intersection, &normal, &areas, &shadowIntensity, &back ))
#endif

               {
                  float3 O_I = intersection-r.origin;
                  float3 O_L = r.direction;
                  float l = length(O_I);
                  if( l>EPSILON && l<length(O_L) )
                  {
                     float ratio = shadowIntensity*sceneInfo->shadowIntensity;
                     if( materials[primitive->materialId].transparency != 0.f )
                     {
                        O_L=normalize(O_L);
                        float a=fabs(dot(O_L,normal));
                        float r = (materials[primitive->materialId].transparency == 0.f ) ? 1.f : (1.f-0.8f*materials[primitive->materialId].transparency);
                        ratio *= r*a;
                        // Shadow color
                        color->x  += ratio*(0.3f-0.3f*materials[primitive->materialId].color.x);
                        color->y  += ratio*(0.3f-0.3f*materials[primitive->materialId].color.y);
                        color->z  += ratio*(0.3f-0.3f*materials[primitive->materialId].color.z);
                     }
                     result += ratio;
                  }
                  it++;
               }
            }
            cptPrimitives++;
         }
      }
      cptBoxes++;
   }
   result = (result>sceneInfo->shadowIntensity) ? sceneInfo->shadowIntensity : result;
   result = (result<0.f) ? 0.f : result;
   return result;
}

/*
________________________________________________________________________________

Primitive shader
________________________________________________________________________________
*/
float4 primitiveShader(
   const SceneInfo*   sceneInfo,
   const PostProcessingInfo*   postProcessingInfo,
   __global const BoundingBox* boundingBoxes, 
   const int nbActiveBoxes, 
   __global const Primitive* primitives, 
   const int nbActivePrimitives,
   __global const LightInformation* lightInformation, 
   const int lightInformationSize, 
   const int nbActiveLamps,
   __global const Material* materials, 
   __global const BitmapBuffer* textures,
   __global const RandomBuffer* randoms,
   const float3 origin,
   const float3 normal, 
   const int    objectId, 
   const float3 intersection,
   const float3 areas,
   const int    iteration,
   float4*       refractionFromColor,
   float*        shadowIntensity,
   float4*       totalBlinn)
{
   __global const Primitive* primitive = &(primitives[objectId]);
   float4 color = materials[primitive->materialId].color;
   float4 lampsColor = { 0.f, 0.f, 0.f, 0.f };

   // Lamp Impact
   (*shadowIntensity) = 0.f;

   if( materials[primitive->materialId].innerIllumination.x != 0.f || materials[primitive->materialId].attributes.z == 2 )
   {
      // Wireframe returns constant color
      return color; 
   }

   if( materials[primitive->materialId].attributes.z == 1 )
   {
      // Sky box returns color with constant lightning
      return intersectionShader( 
         sceneInfo, primitive, materials, textures, 
         intersection, &areas );
   }

   if( sceneInfo->graphicsLevel>0 )
   {
      color *= materials[primitive->materialId].innerIllumination.x;
      int activeLamps = nbActiveLamps;
      for( int cpt=0; cpt<activeLamps; ++cpt ) 
      {
         //int cptLamp = (sceneInfo->pathTracingIteration>NB_MAX_ITERATIONS && sceneInfo->pathTracingIteration%2==0) ? (sceneInfo->pathTracingIteration%lightInformationSize) : cpt;
         int cptLamp = (sceneInfo->pathTracingIteration>NB_MAX_ITERATIONS) ? (sceneInfo->pathTracingIteration%lightInformationSize) : cpt;
         if(lightInformation[cptLamp].attribute != primitive->index)
         {
            float3 center;
            // randomize lamp center
            center.x = lightInformation[cptLamp].location.x;
            center.y = lightInformation[cptLamp].location.y;
            center.z = lightInformation[cptLamp].location.z;

            //if( lightInformation[cptLamp].attribute.x != -1 )
            {
               Primitive lamp = primitives[lightInformation[cptLamp].attribute];

               //if( sceneInfo->pathTracingIteration>NB_MAX_ITERATIONS /*&& sceneInfo->pathTracingIteration%2!=0*/ )
               {
                  int t = 3*sceneInfo->pathTracingIteration + (int)(10.f*sceneInfo->misc.y)%100;
                  center.x += materials[lamp.materialId].innerIllumination.y*randoms[t  ]*sceneInfo->pathTracingIteration/(float)(sceneInfo->maxPathTracingIterations);
                  center.y += materials[lamp.materialId].innerIllumination.y*randoms[t+1]*sceneInfo->pathTracingIteration/(float)(sceneInfo->maxPathTracingIterations);
                  center.z += materials[lamp.materialId].innerIllumination.y*randoms[t+2]*sceneInfo->pathTracingIteration/(float)(sceneInfo->maxPathTracingIterations);
               }
            }

            float4 shadowColor = {0.f,0.f,0.f,0.f};
            if( sceneInfo->graphicsLevel>3 && materials[primitive->materialId].innerIllumination.x == 0.f ) 
            {
               (*shadowIntensity) = processShadows(
                  sceneInfo, boundingBoxes, nbActiveBoxes,
                  primitives, materials, textures, 
                  nbActivePrimitives, center, 
                  intersection, lightInformation[cptLamp].attribute, 
                  iteration, &shadowColor );
            }

            if( sceneInfo->graphicsLevel>0 )
            {
               float3 lightRay = center - intersection;
               lightRay = normalize(lightRay);
               // --------------------------------------------------------------------------------
               // Lambert
               // --------------------------------------------------------------------------------
               float lambert = (postProcessingInfo->type==ppe_ambientOcclusion) ? 0.6f : dot(normal,lightRay);
               // Transparent materials are lighted on both sides but the amount of light received by the "dark side" 
               // depends on the transparency rate.
               lambert *= (lambert<0.f) ? -materials[primitive->materialId].transparency : lambert;
               lambert *= lightInformation[cptLamp].color.w;
               lambert *= (1.f-(*shadowIntensity));

               // Lighted object, not in the shades

               lampsColor.x += lambert*lightInformation[cptLamp].color.x*lightInformation[cptLamp].color.w - shadowColor.x;
               lampsColor.y += lambert*lightInformation[cptLamp].color.y*lightInformation[cptLamp].color.w - shadowColor.y;
               lampsColor.z += lambert*lightInformation[cptLamp].color.z*lightInformation[cptLamp].color.w - shadowColor.z;

               if( sceneInfo->graphicsLevel>1 && (*shadowIntensity)<sceneInfo->shadowIntensity )
               {
                  // --------------------------------------------------------------------------------
                  // Blinn - Phong
                  // --------------------------------------------------------------------------------
                  float3 viewRay = normalize(intersection - origin);
                  float3 blinnDir = lightRay - viewRay;
                  float temp = sqrt(dot(blinnDir,blinnDir));
                  if (temp != 0.f ) 
                  {
                     // Specular reflection
                     blinnDir = (1.f / temp) * blinnDir;

                     float blinnTerm = dot(blinnDir,normal);
                     blinnTerm = ( blinnTerm < 0.f) ? 0.f : blinnTerm;

                     blinnTerm = materials[primitive->materialId].specular.x * pow(blinnTerm,materials[primitive->materialId].specular.y);

                     totalBlinn->x += lightInformation[cptLamp].color.x * lightInformation[cptLamp].color.w * blinnTerm;
                     totalBlinn->y += lightInformation[cptLamp].color.y * lightInformation[cptLamp].color.w * blinnTerm;
                     totalBlinn->z += lightInformation[cptLamp].color.z * lightInformation[cptLamp].color.w * blinnTerm;
                  }
               }
            }
         }

         // Final color
         float4 intersectionColor = 
            intersectionShader( sceneInfo, primitive, materials, textures, intersection, &areas );

         // Light impact on material
         color += intersectionColor*lampsColor;

         // Saturate color
         saturateVector(&color);

         (*refractionFromColor) = intersectionColor; // Refraction depending on color;
         saturateVector( totalBlinn );
      }
   }
   return color;
}

/*
________________________________________________________________________________

Intersections with primitives
________________________________________________________________________________
*/
inline bool intersectionWithPrimitives(
   const SceneInfo* sceneInfo,
   __global const BoundingBox* boundingBoxes, 
   const int nbActiveBoxes,
   __global const Primitive* primitives, 
   const int nbActivePrimitives,
   __global const Material* materials, 
   __global const BitmapBuffer* textures,
   const Ray* ray, 
   const int iteration,
   int*    closestPrimitive, 
   float3* closestIntersection,
   float3* closestNormal,
   float3* closestAreas,
   float4* colorBox,
   bool*   back,
   const int currentMaterialId)
{
   bool intersections = false; 
   float minDistance  = sceneInfo->viewDistance;

   Ray r;
   r.origin    = ray->origin;
   r.direction = ray->direction-ray->origin;
   computeRayAttributes( &r );

   float3 intersection = {0.f,0.f,0.f};
   float3 normal       = {0.f,0.f,0.f};
   bool i = false;
   float shadowIntensity = 0.f;

   for( int cptBoxes = 0; cptBoxes<nbActiveBoxes; ++cptBoxes )
   {
      __global const BoundingBox* box = &boundingBoxes[cptBoxes];
      if( boxIntersection(box, &r, 0.f, sceneInfo->viewDistance) )
      {
         // Intersection with Box
         if( sceneInfo->renderBoxes != 0 ) 
         {
            (*colorBox) += materials[cptBoxes%NB_MAX_MATERIALS].color/20.f;
         }

         // Intersection with primitive within boxes
         for( int cptPrimitives = 0; cptPrimitives<box->nbPrimitives; ++cptPrimitives )
         { 
            __global const Primitive* primitive = &(primitives[box->startIndex+cptPrimitives]);
            __global const Material* material = &materials[primitive->materialId];
            if( material->attributes.x==0 || (material->attributes.x==1 && currentMaterialId != primitive->materialId)) // !!!! TEST SHALL BE REMOVED TO INCREASE TRANSPARENCY QUALITY !!!
            {
               float3 areas = {0.f,0.f,0.f};
#ifdef EXTENDED_GEOMETRY
               i = false;
               switch( primitive->type )
               {
               case ptEnvironment :
               case ptSphere      : i = sphereIntersection  ( sceneInfo, primitive, materials, &r, &intersection, &normal, &shadowIntensity, back ); break;
               case ptCylinder    : i = cylinderIntersection( sceneInfo, primitive, materials, &r, &intersection, &normal, &shadowIntensity, back ); break;
               case ptEllipsoid   : i = ellipsoidIntersection( sceneInfo, primitive, materials, &r, &intersection, &normal, &shadowIntensity, back ); break;
               case ptTriangle    : back = false; i = triangleIntersection( sceneInfo, primitive, materials, &r, &intersection, &normal, &areas, &shadowIntensity, back ); break;
               default: 
                  {
                     back = false;
                     i = planeIntersection   ( sceneInfo, primitive, materials, textures, &r, &intersection, &normal, &shadowIntensity, false); 
                     break;
                  }
               }
#else
               back = false;
               i = triangleIntersection( sceneInfo, primitive, materials, &r, &intersection, &normal, &areas, &shadowIntensity, back ); 
#endif // EXTENDED_GEOMETRY

               float distance = length(intersection-r.origin);
               if( i && distance>EPSILON && distance<minDistance ) 
               {
                  // Only keep intersection with the closest object
                  minDistance            = distance;
                  (*closestPrimitive)    = box->startIndex+cptPrimitives;
                  (*closestIntersection) = intersection;
                  (*closestNormal)       = normal;
                  (*closestAreas)        = areas;
                  intersections          = true;
               }
            }
         }
      }
   }
   return intersections;
}

/*
________________________________________________________________________________

Calculate the reflected vector                   

^ Normal to object surface (N)  
Reflection (O_R)  |                              
\ |  Eye (O_E)                    
\| /                             
----------------O--------------- Object surface 
closestIntersection                      

============================================================================== 
colours                                                                                    
------------------------------------------------------------------------------ 
We now have to know the colour of this (*intersection)                                        
Color_from_object will compute the amount of light received by the
(*intersection) float4 and  will also compute the shadows. 
The resulted color is stored in result.                     
The first parameter is the closest object to the (*intersection) (following 
the ray). It can  be considered as a light source if its inner light rate 
is > 0.                            
________________________________________________________________________________
*/
inline float4 launchRay( 
   __global const BoundingBox* boundingBoxes, 
   const int nbActiveBoxes,
   __global const Primitive* primitives, 
   const int nbActivePrimitives,
   __global const LightInformation* lightInformation, 
   const int lightInformationSize, 
   const int nbActiveLamps,
   __global const Material*  materials, 
   __global const BitmapBuffer* textures,
   __global const RandomBuffer* randoms,
   const Ray*       ray, 
   const SceneInfo* sceneInfo,
   const PostProcessingInfo* postProcessingInfo,
   float3*          intersection,
   float*           depthOfField,
   __global PrimitiveXYIdBuffer* primitiveXYId)
{
   float4 intersectionColor   = {0.f,0.f,0.f,0.f};

   float3 closestIntersection = {0.f,0.f,0.f};
   float3 firstIntersection   = {0.f,0.f,0.f};
   float3 normal              = {0.f,0.f,0.f};
   int    closestPrimitive  = 0;
   bool   carryon           = true;
   Ray    rayOrigin         = (*ray);
   float  initialRefraction = 1.f;
   int    iteration         = 0;
   primitiveXYId->x = -1;
   primitiveXYId->z = 0;
   int currentMaterialId=-2;

   // TODO
   float  colorContributions[NB_MAX_ITERATIONS];
   float4 colors[NB_MAX_ITERATIONS];
   for( int i=0; i<NB_MAX_ITERATIONS; ++i )
   {
      colorContributions[i] = 0.f;
      colors[i].x = 0.f;
      colors[i].y = 0.f;
      colors[i].z = 0.f;
      colors[i].w = 0.f;
   }

   float4 recursiveBlinn = { 0.f, 0.f, 0.f, 0.f };

   // Variable declarations
   float  shadowIntensity = 0.f;
   float4 refractionFromColor;
   float3 reflectedTarget;
   float4 colorBox = {0.f,0.f,0.f,0.f};
   bool   back = false;

#ifdef PHOTON_ENERGY
   // Photon energy
   float photonDistance = sceneInfo->viewDistance.x;
   float previousTransparency = 1.f;
#endif // PHOTON_ENERGY

   // Reflected rays
   int reflectedRays=-1;
   Ray reflectedRay;
   float reflectedRatio;

   float4 rBlinn = {0.f,0.f,0.f,0.f};
   int currentMaxIteration = ( sceneInfo->graphicsLevel<3 ) ? 1 : sceneInfo->nbRayIterations+sceneInfo->pathTracingIteration;
   currentMaxIteration = (currentMaxIteration>NB_MAX_ITERATIONS) ? NB_MAX_ITERATIONS : currentMaxIteration;
#ifdef PHOTON_ENERGY
   while( iteration<currentMaxIteration && carryon && photonDistance>0.f ) 
#else
   while( iteration<currentMaxIteration && carryon ) 
#endif // PHOTON_ENERGY
   {
      float3 areas = {0.f,0.f,0.f};
      // If no intersection with lamps detected. Now compute intersection with Primitives
      if( carryon ) 
      {
         carryon = intersectionWithPrimitives(
            sceneInfo,
            boundingBoxes, nbActiveBoxes,
            primitives, nbActivePrimitives,
            materials, textures,
            &rayOrigin,
            iteration,  
            &closestPrimitive, &closestIntersection, 
            &normal, &areas, &colorBox, &back, currentMaterialId);
      }

      if( carryon ) 
      {
         currentMaterialId = primitives[closestPrimitive].materialId;

         if ( iteration==0 )
         {
            colors[iteration].x = 0.f;
            colors[iteration].y = 0.f;
            colors[iteration].z = 0.f;
            colors[iteration].w = 0.f;
            colorContributions[iteration]=1.f;

            firstIntersection = closestIntersection;

            // Primitive ID for current pixel
            primitiveXYId->x = primitives[closestPrimitive].index;

         }

#ifdef PHOTON_ENERGY
         // Photon
         photonDistance -= length(closestIntersection-rayOrigin.origin) * (5.f-previousTransparency);
         previousTransparency = back ? 1.f : materials[primitives[closestPrimitive].materialId].transparency;
#endif // PHOTON_ENERGY

         // Get object color
         colors[iteration] =
            primitiveShader( 
            sceneInfo, postProcessingInfo,
            boundingBoxes, nbActiveBoxes, 
            primitives, nbActivePrimitives, 
            lightInformation, lightInformationSize, nbActiveLamps,
            materials, textures, 
            randoms, rayOrigin.origin, normal, 
            closestPrimitive, closestIntersection, areas, 
            iteration, &refractionFromColor, &shadowIntensity, &rBlinn );

         // Primitive illumination
         float colorLight=colors[iteration].x+colors[iteration].y+colors[iteration].z;
         //TODO primitiveXYId->z += (materials[currentMaterialId].innerIllumination*255.f);
         primitiveXYId->z += (colorLight>sceneInfo->transparentColor) ? 16 : 0;

         // ----------
         // Refraction
         // ----------

         if( materials[primitives[closestPrimitive].materialId].transparency != 0.f ) 
         {
            // Replace the normal using the intersection color
            // r,g,b become x,y,z... What the fuck!!
            if( materials[primitives[closestPrimitive].materialId].textureMapping.z != TEXTURE_NONE) 
            {
               normal.x *= (colors[iteration].x-0.5f);
               normal.y *= (colors[iteration].y-0.5f);
               normal.z *= (colors[iteration].z-0.5f);
            }

            // Back of the object? If so, reset refraction to 1.f (air)
            float refraction = back ? 1.f : materials[primitives[closestPrimitive].materialId].refraction;

            // Actual refraction
            float3 O_E = normalize(rayOrigin.origin - closestIntersection);
            vectorRefraction( &rayOrigin.direction, O_E, refraction, normal, initialRefraction );
            reflectedTarget = closestIntersection - rayOrigin.direction;

            colorContributions[iteration] = materials[primitives[closestPrimitive].materialId].transparency;

            // Prepare next ray
            initialRefraction = refraction;

            if( reflectedRays==-1 && materials[primitives[closestPrimitive].materialId].reflection != 0.f )
            {
               vectorReflection( reflectedRay.direction, O_E, normal );
               float3 rt = closestIntersection - reflectedRay.direction;

               reflectedRay.origin    = closestIntersection + rt*0.00001f;
               reflectedRay.direction = rt;
               reflectedRatio = materials[primitives[closestPrimitive].materialId].reflection;
               reflectedRays=iteration;
            }
         }
         else
         {
            // ----------
            // Reflection
            // ----------
            if( materials[primitives[closestPrimitive].materialId].reflection != 0.f ) 
            {
               float3 O_E = rayOrigin.origin - closestIntersection;
               vectorReflection( rayOrigin.direction, O_E, normal );
               reflectedTarget = closestIntersection - rayOrigin.direction;
               colorContributions[iteration] = materials[primitives[closestPrimitive].materialId].reflection;
            }
            else 
            {
               colorContributions[iteration] = 1.f;
               carryon = false;
            }         
         }

         // Contribute to final color
         recursiveBlinn += rBlinn;

         rayOrigin.origin    = closestIntersection + reflectedTarget*0.00001f; 
         rayOrigin.direction = reflectedTarget;

         // Noise management
         if( sceneInfo->pathTracingIteration != 0 && materials[primitives[closestPrimitive].materialId].color.w != 0.f)
         {
            // Randomize view
            float ratio = materials[primitives[closestPrimitive].materialId].color.w;
            ratio *= (materials[primitives[closestPrimitive].materialId].transparency==0.f) ? 1000.f : 1.f;
            int rindex = 3*sceneInfo->misc.y + sceneInfo->pathTracingIteration;
            rindex = rindex%(sceneInfo->width*sceneInfo->height);
            rayOrigin.direction.x += randoms[rindex  ]*ratio;
            rayOrigin.direction.y += randoms[rindex+1]*ratio;
            rayOrigin.direction.z += randoms[rindex+2]*ratio;
         }
      }
      else
      {
#ifdef GRADIANT_BACKGROUND
         // Background
         float3 normal = {0.f, 1.f, 0.f };
         float3 dir = normalize(rayOrigin.direction-rayOrigin.origin);
         float angle = 0.5f*fabs(dot( normal, dir));
         angle = (angle>1.f) ? 1.f: angle;
         colors[iteration] = (1.f-angle)*sceneInfo->backgroundColor;
#else
         colors[iteration] = sceneInfo->backgroundColor;
#endif // GRADIANT_BACKGROUND
         colorContributions[iteration] = 1.f;
      }
      iteration++;
   }

   if( sceneInfo->graphicsLevel>=3 && reflectedRays != -1 ) // TODO: Draft mode should only test "sceneInfo->pathTracingIteration==iteration"
   {
      float3 areas = {0.f,0.f,0.f};
      // TODO: Dodgy implementation		
      if( intersectionWithPrimitives(
         sceneInfo,
         boundingBoxes, nbActiveBoxes,
         primitives, nbActivePrimitives,
         materials, textures,
         &reflectedRay,
         reflectedRays,  
         &closestPrimitive, &closestIntersection, 
         &normal, &areas, &colorBox, &back, currentMaterialId) )
      {
         float4 color = primitiveShader( 
            sceneInfo, postProcessingInfo,
            boundingBoxes, nbActiveBoxes, 
            primitives, nbActivePrimitives, 
            lightInformation, lightInformationSize, nbActiveLamps, 
            materials, textures, randoms, 
            reflectedRay.origin, normal, closestPrimitive, 
            closestIntersection, areas, 
            reflectedRays, 
            &refractionFromColor, &shadowIntensity, &rBlinn );

         colors[reflectedRays] += color*reflectedRatio;
      }
   }

   for( int i=iteration-2; i>=0; --i)
   {
      colors[i] = colors[i]*(1.f-colorContributions[i]) + colors[i+1]*colorContributions[i];
   }
   intersectionColor = colors[0];
   intersectionColor += recursiveBlinn;

   (*intersection) = closestIntersection;

   Primitive primitive=primitives[closestPrimitive];
   float len = length(firstIntersection - ray->origin);
   if( materials[primitive.materialId].attributes.z == 0 ) // Wireframe
   {
#ifdef PHOTON_ENERGY
      // --------------------------------------------------
      // Photon energy
      // --------------------------------------------------
      intersectionColor *= ( photonDistance>0.f) ? (photonDistance/sceneInfo->viewDistance.x) : 0.f;
#endif // PHOTON_ENERGY

      // --------------------------------------------------
      // Fog
      // --------------------------------------------------
      //intersectionColor += randoms[((int)len + sceneInfo->misc.y)%100];

      // --------------------------------------------------
      // Background color
      // --------------------------------------------------
      float D1 = sceneInfo->viewDistance*0.95f;
      if( sceneInfo->misc.z==1 && len>D1)
      {
         float D2 = sceneInfo->viewDistance*0.05f;
         float a = len - D1;
         float b = 1.f-(a/D2);
         intersectionColor = intersectionColor*b + sceneInfo->backgroundColor*(1.f-b);
      }
   }
   (*depthOfField) = (len-(*depthOfField))/sceneInfo->viewDistance;

   // Primitive information
   primitiveXYId->y = iteration;

   // Depth of field
   intersectionColor -= colorBox;
   saturateVector( &intersectionColor );
   return intersectionColor;
}

/*
________________________________________________________________________________

Standard renderer
________________________________________________________________________________
*/
__kernel void k_standardRenderer(
   const int2   occupancyParameters,
   int          device_split,
   int          stream_split,
   __global BoundingBox* boundingBoxes, 
   int nbActiveBoxes,
   __global Primitive* primitives, 
   int nbActivePrimitives,
   __global LightInformation* lightInformation, 
   int lightInformationSize, 
   int nbActiveLamps,
   __global Material*    materials,
   __global BitmapBuffer* textures,
   __global RandomBuffer* randoms,
   float3        origin,
   float3        direction,
   float3        angles,
   const SceneInfo          sceneInfo,
   const PostProcessingInfo postProcessingInfo,
   __global PostProcessingBuffer* postProcessingBuffer,
   __global PrimitiveXYIdBuffer*  primitiveXYIds)
{
   int x = get_global_id(0);
   int y = get_global_id(1);
   int index = y*sceneInfo.width+x;

   // Beware out of bounds error! \[^_^]/
   if( index>=sceneInfo.width*sceneInfo.height/occupancyParameters.x ) return;

   Ray ray;
   ray.origin = origin;
   ray.direction = direction;

   float3 rotationCenter = {0.f,0.f,0.f};
   if( sceneInfo.renderingType==vt3DVision)
   {
      rotationCenter = origin;
   }

   bool antialiasingActivated = (sceneInfo.misc.w == 2);

   if( sceneInfo.pathTracingIteration == 0 )
   {
      postProcessingBuffer[index].x = 0.f;
      postProcessingBuffer[index].y = 0.f;
      postProcessingBuffer[index].z = 0.f;
      postProcessingBuffer[index].w = 0.f;
   }
   else
   {
      // Randomize view for natural depth of field
      if( sceneInfo.pathTracingIteration >= NB_MAX_ITERATIONS )
      {
         int rindex = index + sceneInfo.pathTracingIteration;
         rindex = rindex%(sceneInfo.width*sceneInfo.height);
         ray.direction.x += randoms[rindex  ]*postProcessingBuffer[index].w*postProcessingInfo.param2*(float)(sceneInfo.pathTracingIteration)/(float)(sceneInfo.maxPathTracingIterations);
         ray.direction.y += randoms[rindex+1]*postProcessingBuffer[index].w*postProcessingInfo.param2*(float)(sceneInfo.pathTracingIteration)/(float)(sceneInfo.maxPathTracingIterations);
         ray.direction.z += randoms[rindex+2]*postProcessingBuffer[index].w*postProcessingInfo.param2*(float)(sceneInfo.pathTracingIteration)/(float)(sceneInfo.maxPathTracingIterations);
      }
   }

   float dof = postProcessingInfo.param1;
   float3 intersection;


   if( sceneInfo.misc.w == 1 ) // Isometric 3D
   {
      ray.direction.x = ray.origin.z*0.001f*(float)(x - (sceneInfo.width/2));
      ray.direction.y = -ray.origin.z*0.001f*(float)(device_split+stream_split+y - (sceneInfo.height/2));
      ray.origin.x = ray.direction.x;
      ray.origin.y = ray.direction.y;
   }
   else
   {
      float ratio=(float)sceneInfo.width/(float)sceneInfo.height;
      float2 step;
      step.x=ratio*6400.f/(float)sceneInfo.width;
      step.y=6400.f/(float)sceneInfo.height;
      ray.direction.x = ray.direction.x - step.x*(float)(x - (sceneInfo.width/2));
      ray.direction.y = ray.direction.y + step.y*(float)(device_split+stream_split+y - (sceneInfo.height/2));
   }

   vectorRotation( ray.origin, rotationCenter, angles );
   vectorRotation( ray.direction, rotationCenter, angles );

   // Antialisazing
   float2 AArotatedGrid[4] =
   {
      {  3.f,  5.f },
      {  5.f, -3.f },
      { -3.f, -5.f },
      { -5.f,  3.f }
   };

   if( sceneInfo.pathTracingIteration>primitiveXYIds[index].y && sceneInfo.pathTracingIteration>0 && sceneInfo.pathTracingIteration<=NB_MAX_ITERATIONS ) return;

   float4 color = {0.f,0.f,0.f,0.f};
   if( antialiasingActivated )
   {
      Ray r=ray;
      for( int I=0; I<4; ++I )
      {
         r.direction.x = ray.direction.x + AArotatedGrid[I].x;
         r.direction.y = ray.direction.y + AArotatedGrid[I].y;
         float4 c = launchRay(
            boundingBoxes, nbActiveBoxes,
            primitives, nbActivePrimitives,
            lightInformation, lightInformationSize, nbActiveLamps,
            materials, textures, 
            randoms,
            &r, 
            &sceneInfo, &postProcessingInfo,
            &intersection,
            &dof,
            &primitiveXYIds[index]);
         color += c;
      }
   }
   color += launchRay(
      boundingBoxes, nbActiveBoxes,
      primitives, nbActivePrimitives,
      lightInformation, lightInformationSize, nbActiveLamps,
      materials, textures, 
      randoms,
      &ray, 
      &sceneInfo, &postProcessingInfo,
      &intersection,
      &dof,
      &primitiveXYIds[index]);

   // Randomize light intensity
   int rindex = index;
   rindex = rindex%(sceneInfo.width*sceneInfo.height);
   color += sceneInfo.backgroundColor*randoms[rindex]*5.f;

   if( antialiasingActivated )
   {
      color /= 5.f;
   }

   if( sceneInfo.pathTracingIteration == 0 )
   {
      postProcessingBuffer[index].w = dof;
   }

   if( sceneInfo.pathTracingIteration<=NB_MAX_ITERATIONS )
   {
      postProcessingBuffer[index].x = color.x;
      postProcessingBuffer[index].y = color.y;
      postProcessingBuffer[index].z = color.z;
   }
   else
   {
      postProcessingBuffer[index].x += color.x;
      postProcessingBuffer[index].y += color.y;
      postProcessingBuffer[index].z += color.z;
   }
}

/*
________________________________________________________________________________

Anaglyph Renderer
________________________________________________________________________________
*/
__kernel void k_anaglyphRenderer(
   const int2   occupancyParameters,
   int          device_split,
   int          stream_split,
   __global BoundingBox* boundingBoxes, int nbActiveBoxes,
   __global Primitive* primitives, int nbActivePrimitives,
   __global LightInformation* lightInformation, int lightInformationSize, int nbActiveLamps,
   __global    Material*    materials,
   __global BitmapBuffer* textures,
   __global RandomBuffer* randoms,
   float3        origin,
   float3        direction,
   float3        angles,
   const SceneInfo     sceneInfo,
   const PostProcessingInfo postProcessingInfo,
   __global PostProcessingBuffer* postProcessingBuffer,
   __global PrimitiveXYIdBuffer*  primitiveXYIds)
{
   int x = get_global_id(0);
   int y = get_global_id(1);
   int index = y*sceneInfo.width+x;

   // Beware out of bounds error! \[^_^]/
   if( index>=sceneInfo.width*sceneInfo.height/occupancyParameters.x ) return;

   float focus = primitiveXYIds[sceneInfo.width*sceneInfo.height/2].x - origin.z;
   float eyeSeparation = sceneInfo.width3DVision*(focus/direction.z);

   float3 rotationCenter = {0.f,0.f,0.f};
   if( sceneInfo.renderingType==vt3DVision)
   {
      rotationCenter = origin;
   }

   if( sceneInfo.pathTracingIteration == 0 )
   {
      postProcessingBuffer[index].x = 0.f;
      postProcessingBuffer[index].y = 0.f;
      postProcessingBuffer[index].z = 0.f;
      postProcessingBuffer[index].w = 0.f;
   }

   float dof = postProcessingInfo.param1;
   float3 intersection;
   Ray eyeRay;

   float ratio=(float)sceneInfo.width/(float)sceneInfo.height;
   float2 step;
   step.x=4.f*ratio*6400.f/(float)sceneInfo.width;
   step.y=4.f*6400.f/(float)sceneInfo.height;

   // Left eye
   eyeRay.origin.x = origin.x + eyeSeparation;
   eyeRay.origin.y = origin.y;
   eyeRay.origin.z = origin.z;

   eyeRay.direction.x = direction.x - step.x*(float)(x - (sceneInfo.width/2));
   eyeRay.direction.y = direction.y + step.y*(float)(y - (sceneInfo.height/2));
   eyeRay.direction.z = direction.z;

   //vectorRotation( eyeRay.origin, rotationCenter, angles );
   vectorRotation( eyeRay.direction, rotationCenter, angles );

   float4 colorLeft = launchRay(
      boundingBoxes, nbActiveBoxes,
      primitives, nbActivePrimitives,
      lightInformation, lightInformationSize, nbActiveLamps,
      materials, textures, 
      randoms,
      &eyeRay, 
      &sceneInfo, &postProcessingInfo,
      &intersection,
      &dof,
      &primitiveXYIds[index]);

   // Right eye
   eyeRay.origin.x = origin.x - eyeSeparation;
   eyeRay.origin.y = origin.y;
   eyeRay.origin.z = origin.z;

   eyeRay.direction.x = direction.x - step.x*(float)(x - (sceneInfo.width/2));
   eyeRay.direction.y = direction.y + step.y*(float)(y - (sceneInfo.height/2));
   eyeRay.direction.z = direction.z;

   //vectorRotation( eyeRay.origin, rotationCenter, angles );
   vectorRotation( eyeRay.direction, rotationCenter, angles );

   float4 colorRight = launchRay(
      boundingBoxes, nbActiveBoxes,
      primitives, nbActivePrimitives,
      lightInformation, lightInformationSize, nbActiveLamps,
      materials, textures, 
      randoms,
      &eyeRay, 
      &sceneInfo, &postProcessingInfo,
      &intersection,
      &dof,
      &primitiveXYIds[index]);

   float r1 = colorLeft.x*0.299f + colorLeft.y*0.587f + colorLeft.z*0.114f;
   float b1 = 0.f;
   float g1 = 0.f;

   float r2 = 0.f;
   float g2 = colorRight.y;
   float b2 = colorRight.z;

   if( sceneInfo.pathTracingIteration == 0 ) postProcessingBuffer[index].w = dof;
   if( sceneInfo.pathTracingIteration<=NB_MAX_ITERATIONS )
   {
      postProcessingBuffer[index].x = r1+r2;
      postProcessingBuffer[index].y = g1+g2;
      postProcessingBuffer[index].z = b1+b2;
   }
   else
   {
      postProcessingBuffer[index].x += r1+r2;
      postProcessingBuffer[index].y += g1+g2;
      postProcessingBuffer[index].z += b1+b2;
   }
}

/*
________________________________________________________________________________

3D Vision Renderer
________________________________________________________________________________
*/
__kernel void k_3DVisionRenderer(
   const int2   occupancyParameters,
   int          device_split,
   int          stream_split,
   __global BoundingBox* boundingBoxes, int nbActiveBoxes,
   __global Primitive* primitives, int nbActivePrimitives,
   __global LightInformation* lightInformation, int lightInformationSize, int nbActiveLamps,
   __global    Material*    materials,
   __global BitmapBuffer* textures,
   __global RandomBuffer* randoms,
   float3        origin,
   float3        direction,
   float3        angles,
   const SceneInfo     sceneInfo,
   const PostProcessingInfo postProcessingInfo,
   __global PostProcessingBuffer* postProcessingBuffer,
   __global PrimitiveXYIdBuffer*  primitiveXYIds)
{
   int x = get_global_id(0);
   int y = get_global_id(1);
   int index = y*sceneInfo.width+x;

   // Beware out of bounds error! \[^_^]/
   if( index>=sceneInfo.width*sceneInfo.height/occupancyParameters.x ) return;

   float focus = primitiveXYIds[sceneInfo.width*sceneInfo.height/2].x - origin.z;
   float eyeSeparation = sceneInfo.width3DVision*(direction.z/focus);

   float3 rotationCenter = {0.f,0.f,0.f};
   if( sceneInfo.renderingType==vt3DVision)
   {
      rotationCenter = origin;
   }

   if( sceneInfo.pathTracingIteration == 0 )
   {
      postProcessingBuffer[index].x = 0.f;
      postProcessingBuffer[index].y = 0.f;
      postProcessingBuffer[index].z = 0.f;
      postProcessingBuffer[index].w = 0.f;
   }

   float dof = postProcessingInfo.param1;
   float3 intersection;
   int halfWidth  = sceneInfo.width/2;

   float ratio=(float)sceneInfo.width/(float)sceneInfo.height;
   float2 step;
   step.x=ratio*6400.f/(float)sceneInfo.width;
   step.y=6400.f/(float)sceneInfo.height;

   Ray eyeRay;
   if( x<halfWidth ) 
   {
      // Left eye
      eyeRay.origin.x = origin.x + eyeSeparation;
      eyeRay.origin.y = origin.y;
      eyeRay.origin.z = origin.z;

      eyeRay.direction.x = direction.x - step.x*(float)(x - (sceneInfo.width/2) + halfWidth/2 ) + sceneInfo.width3DVision;
      eyeRay.direction.y = direction.y + step.y*(float)(y - (sceneInfo.height/2));
      eyeRay.direction.z = direction.z;
   }
   else
   {
      // Right eye
      eyeRay.origin.x = origin.x - eyeSeparation;
      eyeRay.origin.y = origin.y;
      eyeRay.origin.z = origin.z;

      eyeRay.direction.x = direction.x - step.x*(float)(x - (sceneInfo.width/2) - halfWidth/2) - sceneInfo.width3DVision;
      eyeRay.direction.y = direction.y + step.y*(float)(y - (sceneInfo.height/2));
      eyeRay.direction.z = direction.z;
   }

   if(sqrt(eyeRay.direction.x*eyeRay.direction.x+eyeRay.direction.y*eyeRay.direction.y)>(halfWidth*6)) return;

   vectorRotation( eyeRay.origin,    rotationCenter, angles );
   vectorRotation( eyeRay.direction, rotationCenter, angles );

   float4 color = launchRay(
      boundingBoxes, nbActiveBoxes,
      primitives, nbActivePrimitives,
      lightInformation, lightInformationSize, nbActiveLamps,
      materials, textures, 
      randoms,
      &eyeRay, 
      &sceneInfo, &postProcessingInfo,
      &intersection,
      &dof,
      &primitiveXYIds[index]);

   // Randomize light intensity
   int rindex = index;
   rindex = rindex%(sceneInfo.width*sceneInfo.height);
   color += sceneInfo.backgroundColor*randoms[rindex]*5.f;

   // Contribute to final image
   if( sceneInfo.pathTracingIteration == 0 ) postProcessingBuffer[index].w = dof;
   if( sceneInfo.pathTracingIteration<=NB_MAX_ITERATIONS )
   {
      postProcessingBuffer[index].x = color.x;
      postProcessingBuffer[index].y = color.y;
      postProcessingBuffer[index].z = color.z;
   }
   else
   {
      postProcessingBuffer[index].x += color.x;
      postProcessingBuffer[index].y += color.y;
      postProcessingBuffer[index].z += color.z;
   }
}

/*
________________________________________________________________________________

3D Vision Renderer
________________________________________________________________________________
*/
__kernel void k_fishEyeRenderer(
   const int2   occupancyParameters,
   int          device_split,
   int          stream_split,
   __global BoundingBox* boundingBoxes, int nbActiveBoxes,
   __global Primitive* primitives, int nbActivePrimitives,
   __global LightInformation* lightInformation, int lightInformationSize, int nbActiveLamps,
   __global    Material*    materials,
   __global BitmapBuffer* textures,
   __global RandomBuffer* randoms,
   float3        origin,
   float3        direction,
   float3        angles,
   const SceneInfo     sceneInfo,
   const PostProcessingInfo postProcessingInfo,
   __global PostProcessingBuffer* postProcessingBuffer,
   __global PrimitiveXYIdBuffer*  primitiveXYIds)
{
}

/*
________________________________________________________________________________

Post Processing Effect: Default
________________________________________________________________________________
*/
__kernel void k_default(
   const int2                     occupancyParameters,
   SceneInfo                      sceneInfo,
   PostProcessingInfo             PostProcessingInfo,
   __global PostProcessingBuffer* postProcessingBuffer,
   __global BitmapBuffer*         bitmap) 
{
   int x = get_global_id(0);
   int y = get_global_id(1);
   int index = y*sceneInfo.width+x;

   // Beware out of bounds error! \[^_^]/
   if( index>=sceneInfo.width*sceneInfo.height/occupancyParameters.x ) return;

   float4 localColor = postProcessingBuffer[index];
   if(sceneInfo.pathTracingIteration>NB_MAX_ITERATIONS)
   {
      localColor /= (float)(sceneInfo.pathTracingIteration-NB_MAX_ITERATIONS+1);
   }
   makeColor( &sceneInfo, &localColor, bitmap, index ); 
}

/*
________________________________________________________________________________

Post Processing Effect: Depth of field
________________________________________________________________________________
*/
__kernel void k_depthOfField(
   const int2                     occupancyParameters,
   SceneInfo                      sceneInfo,
   PostProcessingInfo             postProcessingInfo,
   __global PostProcessingBuffer* postProcessingBuffer,
   __global RandomBuffer*         randoms,
   __global BitmapBuffer*         bitmap) 
{
   int x = get_global_id(0);
   int y = get_global_id(1);
   int index = y*sceneInfo.width+x;

   // Beware out of bounds error! \[^_^]/
   if( index>=sceneInfo.width*sceneInfo.height/occupancyParameters.x ) return;

   float  depth = postProcessingInfo.param2*postProcessingBuffer[index].w;
   int    wh = sceneInfo.width*sceneInfo.height;

   float4 localColor = {0.f,0.f,0.f,0.f};
   for( int i=0; i<postProcessingInfo.param3; ++i )
   {
      int ix = i%wh;
      int iy = (i+sceneInfo.width)%wh;
      int xx = x+depth*randoms[ix]*0.5f;
      int yy = y+depth*randoms[iy]*0.5f;
      if( xx>=0 && xx<sceneInfo.width && yy>=0 && yy<sceneInfo.height )
      {
         int localIndex = yy*sceneInfo.width+xx;
         if( localIndex>=0 && localIndex<wh )
         {
            localColor += postProcessingBuffer[localIndex];
         }
      }
      else
      {
         localColor += postProcessingBuffer[index];
      }
   }
   localColor /= postProcessingInfo.param3;

   if(sceneInfo.pathTracingIteration>NB_MAX_ITERATIONS)
      localColor /= (float)(sceneInfo.pathTracingIteration-NB_MAX_ITERATIONS+1);

   localColor.w = 1.f;

   makeColor( &sceneInfo, &localColor, bitmap, index ); 
}

/*
________________________________________________________________________________

Post Processing Effect: Ambiant Occlusion
________________________________________________________________________________
*/
__kernel void k_ambiantOcclusion(
   const int2                     occupancyParameters,
   SceneInfo                      sceneInfo,
   PostProcessingInfo             postProcessingInfo,
   __global PostProcessingBuffer* postProcessingBuffer,
   __global RandomBuffer*         randoms,
   __global BitmapBuffer*         bitmap) 
{
   int x = get_global_id(0);
   int y = get_global_id(1);
   int index = y*sceneInfo.width+x;

   // Beware out of bounds error! \[^_^]/
   if( index>=sceneInfo.width*sceneInfo.height/occupancyParameters.x ) return;

   float occ = 0.f;
   float4 localColor = postProcessingBuffer[index];
   float  depth = localColor.w;

   const int step = 16;
   for( int X=-step; X<step; X+=2 )
   {
      for( int Y=-step; Y<step; Y+=2 )
      {
         int xx = x+X;
         int yy = y+Y;
         if( xx>=0 && xx<sceneInfo.width && yy>=0 && yy<sceneInfo.height )
         {
            int localIndex = yy*sceneInfo.width+xx;
            if( postProcessingBuffer[localIndex].w>=depth)
            {
               occ += 1.f;
            }
         }
         else
            occ += 1.f;
      }
   }
   occ /= (float)(step*step);
   occ += 0.3f; // Ambient light
   localColor.x *= occ;
   localColor.y *= occ;
   localColor.z *= occ;

   if(sceneInfo.pathTracingIteration>NB_MAX_ITERATIONS)
   {
      localColor /= (float)(sceneInfo.pathTracingIteration-NB_MAX_ITERATIONS+1);
   }

   saturateVector( &localColor );
   localColor.w = 1.f;

   makeColor( &sceneInfo, &localColor, bitmap, index ); 
}

/*
________________________________________________________________________________

Post Processing Effect: Enlightment
________________________________________________________________________________
*/
__kernel void k_enlightment(
   const int2                     occupancyParameters,
   SceneInfo                      sceneInfo,
   PostProcessingInfo             postProcessingInfo,
   __global PrimitiveXYIdBuffer*  primitiveXYIds,
   __global PostProcessingBuffer* postProcessingBuffer,
   __global RandomBuffer*         randoms,
   __global BitmapBuffer*         bitmap) 
{
   int x = get_global_id(0);
   int y = get_global_id(1);
   int index = y*sceneInfo.width+x;

   // Beware out of bounds error! \[^_^]/
   if( index>=sceneInfo.width*sceneInfo.height/occupancyParameters.x ) return;

   int wh = sceneInfo.width*sceneInfo.height;

   int div = (sceneInfo.pathTracingIteration>NB_MAX_ITERATIONS) ? (sceneInfo.pathTracingIteration-NB_MAX_ITERATIONS+1) : 1;

   float4 localColor = {0.f,0.f,0.f,0.f};
   for( int i=0; i<postProcessingInfo.param3; ++i )
   {
      int ix = (i+sceneInfo.misc.y+sceneInfo.pathTracingIteration)%wh;
      int iy = (i+sceneInfo.misc.y+sceneInfo.width)%wh;
      int xx = x+randoms[ix]*postProcessingInfo.param2;
      int yy = y+randoms[iy]*postProcessingInfo.param2;
      localColor += postProcessingBuffer[index];
      if( xx>=0 && xx<sceneInfo.width && yy>=0 && yy<sceneInfo.height )
      {
         int localIndex = yy*sceneInfo.width+xx;
         localColor += ( localIndex>=0 && localIndex<wh ) ? div*primitiveXYIds[localIndex].z/255 : 0.f;
      }
   }
   localColor /= postProcessingInfo.param3;
   localColor /= div;
   localColor.w = 1.f;

   makeColor( &sceneInfo, &localColor, bitmap, index ); 
}

