/*
 * fly_mvkshim.c — a Vulkan feature interposer for MoltenVK.
 *
 * This file is part of Wyn.
 *
 * Wyn is free software: you can redistribute it and/or modify it under the terms
 * of the GNU General Public License as published by the Free Software Foundation,
 * either version 3 of the License, or (at your option) any later version.
 *
 * Wyn is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY;
 * without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
 * See the GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License along with Wyn.
 * If not, see https://www.gnu.org/licenses/.
 *
 *
 * WHAT THIS IS FOR
 *
 * id Tech titles (Wolfenstein: Youngblood, DOOM 2016) ask Vulkan for
 * `shaderCullDistance` and `depthBounds`. Metal has no equivalent of either, so
 * MoltenVK correctly reports them absent and fails `vkCreateDevice` with
 * VK_ERROR_FEATURE_NOT_PRESENT. The game then prints "Startup failure: error
 * while initializing the graphics driver" and exits.
 *
 * This library sits in front of MoltenVK as `libMoltenVK.dylib`, with the real
 * one beside it as `libMoltenVK.real.dylib`. It reports those features present
 * to the application, then strips them from the device-create request before
 * forwarding. The game believes it got them and Metal is never asked for what it
 * cannot do. Dropping cull distance is not free — two fragment pipelines fail to
 * compile in each title — but neither stops play.
 *
 * Written from scratch for Wyn, against the published Vulkan specification. It
 * replaces an Aug 2026 binary that was recovered without source (135,200 bytes,
 * md5 e8e03ea1b3976f1db16580f5dc3e0bcd), so that what Wyn ships is source Wyn
 * owns. Log lines and environment variable names are kept identical to that
 * binary's so Documentation/vulkan-titles.md stays accurate.
 *
 *   FLY_MVKSHIM_REAL   path to the real library. Default: libMoltenVK.real.dylib
 *                      resolved beside this one.
 *   FLY_MVKSHIM_FORCE  comma/space separated feature names to force.
 *                      Default: shaderCullDistance,depthBounds
 *   FLY_MVKSHIM_QUIET  any non-empty value silences the log.
 *
 * The Vulkan types below are declared here rather than included, so the build
 * needs no SDK and no vendored headers. VkPhysicalDeviceFeatures has been ABI
 * frozen since Vulkan 1.0 — 55 VkBool32 fields in a fixed order — which is what
 * makes indexing it by position safe.
 */

#include <dlfcn.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* ---- Minimal Vulkan surface, matching the spec's ABI ---- */

typedef uint32_t VkBool32;
typedef uint32_t VkFlags;
typedef int32_t VkResult;
typedef void *VkInstance;
typedef void *VkPhysicalDevice;
typedef void *VkDevice;
typedef void (*PFN_vkVoidFunction)(void);

#define VK_SUCCESS 0
#define VK_TRUE 1
#define VK_FALSE 0
#define VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2 1000059000

/* The 55 VkBool32 fields of VkPhysicalDeviceFeatures, in spec order. The struct
 * is all VkBool32, so a VkBool32* over it indexes fields by position — that is
 * how a name in FLY_MVKSHIM_FORCE reaches a field. */
static const char *const kFeatureNames[] = {
    "robustBufferAccess",                       /*  1 */
    "fullDrawIndexUint32",                      /*  2 */
    "imageCubeArray",                           /*  3 */
    "independentBlend",                         /*  4 */
    "geometryShader",                           /*  5 */
    "tessellationShader",                       /*  6 */
    "sampleRateShading",                        /*  7 */
    "dualSrcBlend",                             /*  8 */
    "logicOp",                                  /*  9 */
    "multiDrawIndirect",                        /* 10 */
    "drawIndirectFirstInstance",                /* 11 */
    "depthClamp",                               /* 12 */
    "depthBiasClamp",                           /* 13 */
    "fillModeNonSolid",                         /* 14 */
    "depthBounds",                              /* 15 <- id Tech asks for this */
    "wideLines",                                /* 16 */
    "largePoints",                              /* 17 */
    "alphaToOne",                               /* 18 */
    "multiViewport",                            /* 19 */
    "samplerAnisotropy",                        /* 20 */
    "textureCompressionETC2",                   /* 21 */
    "textureCompressionASTC_LDR",               /* 22 */
    "textureCompressionBC",                     /* 23 */
    "occlusionQueryPrecise",                    /* 24 */
    "pipelineStatisticsQuery",                  /* 25 */
    "vertexPipelineStoresAndAtomics",           /* 26 */
    "fragmentStoresAndAtomics",                 /* 27 */
    "shaderTessellationAndGeometryPointSize",   /* 28 */
    "shaderImageGatherExtended",                /* 29 */
    "shaderStorageImageExtendedFormats",        /* 30 */
    "shaderStorageImageMultisample",            /* 31 */
    "shaderStorageImageReadWithoutFormat",      /* 32 */
    "shaderStorageImageWriteWithoutFormat",     /* 33 */
    "shaderUniformBufferArrayDynamicIndexing",  /* 34 */
    "shaderSampledImageArrayDynamicIndexing",   /* 35 */
    "shaderStorageBufferArrayDynamicIndexing",  /* 36 */
    "shaderStorageImageArrayDynamicIndexing",   /* 37 */
    "shaderClipDistance",                       /* 38 */
    "shaderCullDistance",                       /* 39 <- and this */
    "shaderFloat64",                            /* 40 */
    "shaderInt64",                              /* 41 */
    "shaderInt16",                              /* 42 */
    "shaderResourceResidency",                  /* 43 */
    "shaderResourceMinLod",                     /* 44 */
    "sparseBinding",                            /* 45 */
    "sparseResidencyBuffer",                    /* 46 */
    "sparseResidencyImage2D",                   /* 47 */
    "sparseResidencyImage3D",                   /* 48 */
    "sparseResidency2Samples",                  /* 49 */
    "sparseResidency4Samples",                  /* 50 */
    "sparseResidency8Samples",                  /* 51 */
    "sparseResidency16Samples",                 /* 52 */
    "sparseResidencyAliased",                   /* 53 */
    "variableMultisampleRate",                  /* 54 */
    "inheritedQueries",                         /* 55 */
};

#define FEATURE_COUNT ((int)(sizeof(kFeatureNames) / sizeof(kFeatureNames[0])))

typedef struct {
    VkBool32 values[FEATURE_COUNT];
} VkPhysicalDeviceFeatures;

/* Only the header is needed to walk a pNext chain. */
typedef struct VkBaseOutStructure {
    int32_t sType;
    struct VkBaseOutStructure *pNext;
} VkBaseOutStructure;

typedef struct {
    int32_t sType;
    void *pNext;
    VkPhysicalDeviceFeatures features;
} VkPhysicalDeviceFeatures2;

typedef struct {
    int32_t sType;
    const void *pNext;
    VkFlags flags;
    uint32_t queueCreateInfoCount;
    const void *pQueueCreateInfos;
    uint32_t enabledLayerCount;
    const char *const *ppEnabledLayerNames;
    uint32_t enabledExtensionCount;
    const char *const *ppEnabledExtensionNames;
    const VkPhysicalDeviceFeatures *pEnabledFeatures;
} VkDeviceCreateInfo;

typedef void (*PFN_vkGetPhysicalDeviceFeatures)(VkPhysicalDevice, VkPhysicalDeviceFeatures *);
typedef void (*PFN_vkGetPhysicalDeviceFeatures2)(VkPhysicalDevice, VkPhysicalDeviceFeatures2 *);
typedef VkResult (*PFN_vkCreateDevice)(VkPhysicalDevice, const VkDeviceCreateInfo *,
                                       const void *, VkDevice *);
typedef PFN_vkVoidFunction (*PFN_vkGetInstanceProcAddr)(VkInstance, const char *);
typedef PFN_vkVoidFunction (*PFN_vkGetDeviceProcAddr)(VkDevice, const char *);
typedef PFN_vkVoidFunction (*PFN_vkGetPhysicalDeviceProcAddr)(VkInstance, const char *);
typedef VkResult (*PFN_vkNegotiateLoaderICDInterfaceVersion)(uint32_t *);

/* ---- State, resolved once ---- */

static void *g_real;
static bool g_quiet;
static bool g_forced[FEATURE_COUNT];

static PFN_vkGetPhysicalDeviceFeatures g_getFeatures;
static PFN_vkGetPhysicalDeviceFeatures2 g_getFeatures2;
static PFN_vkGetPhysicalDeviceFeatures2 g_getFeatures2KHR;
static PFN_vkCreateDevice g_createDevice;
static PFN_vkGetInstanceProcAddr g_getInstanceProcAddr;
static PFN_vkGetDeviceProcAddr g_getDeviceProcAddr;
static PFN_vkGetPhysicalDeviceProcAddr g_getPhysicalDeviceProcAddr;
static PFN_vkNegotiateLoaderICDInterfaceVersion g_negotiate;

static void shim_log(const char *fmt, ...) {
    if (g_quiet) return;
    va_list ap;
    va_start(ap, fmt);
    fprintf(stderr, "fly-mvkshim: ");
    vfprintf(stderr, fmt, ap);
    fprintf(stderr, "\n");
    va_end(ap);
    fflush(stderr);
}

static const char *result_name(VkResult r) {
    switch (r) {
    case VK_SUCCESS: return "VK_SUCCESS";
    case -1: return "VK_ERROR_OUT_OF_HOST_MEMORY";
    case -2: return "VK_ERROR_OUT_OF_DEVICE_MEMORY";
    case -3: return "VK_ERROR_INITIALIZATION_FAILED";
    case -7: return "VK_ERROR_EXTENSION_NOT_PRESENT";
    case -8: return "VK_ERROR_FEATURE_NOT_PRESENT";
    case -9: return "VK_ERROR_INCOMPATIBLE_DRIVER";
    case -11: return "VK_ERROR_DEVICE_LOST";
    default: return "VkResult";
    }
}

static int feature_index(const char *name, size_t len) {
    for (int i = 0; i < FEATURE_COUNT; i++) {
        if (strlen(kFeatureNames[i]) == len && strncmp(kFeatureNames[i], name, len) == 0) {
            return i;
        }
    }
    return -1;
}

/* Resolve the real library beside this one, so a drop-in needs no configuration:
 * winevulkan dlopens <tree>/Wine/lib/libMoltenVK.dylib and the stock copy is
 * kept next to it as libMoltenVK.real.dylib. */
static char *default_real_path(void) {
    Dl_info info;
    if (dladdr((void *)(uintptr_t)&default_real_path, &info) == 0 || info.dli_fname == NULL) {
        return strdup("libMoltenVK.real.dylib");
    }
    const char *slash = strrchr(info.dli_fname, '/');
    if (slash == NULL) return strdup("libMoltenVK.real.dylib");

    size_t dir = (size_t)(slash - info.dli_fname) + 1;
    static const char leaf[] = "libMoltenVK.real.dylib";
    char *path = malloc(dir + sizeof(leaf));
    if (path == NULL) return NULL;
    memcpy(path, info.dli_fname, dir);
    memcpy(path + dir, leaf, sizeof(leaf));
    return path;
}

static void parse_forced(const char *spec) {
    const char *p = spec;
    while (*p != '\0') {
        while (*p == ',' || *p == ' ' || *p == '\t') p++;
        const char *start = p;
        while (*p != '\0' && *p != ',' && *p != ' ' && *p != '\t') p++;
        if (p == start) continue;

        int index = feature_index(start, (size_t)(p - start));
        if (index < 0) {
            shim_log("ignoring unknown feature '%.*s'", (int)(p - start), start);
            continue;
        }
        g_forced[index] = true;
        shim_log("forcing %s (%dth flag)", kFeatureNames[index], index + 1);
    }
}

__attribute__((constructor)) static void shim_init(void) {
    const char *quiet = getenv("FLY_MVKSHIM_QUIET");
    g_quiet = (quiet != NULL && *quiet != '\0');

    const char *spec = getenv("FLY_MVKSHIM_FORCE");
    parse_forced(spec != NULL && *spec != '\0' ? spec : "shaderCullDistance,depthBounds");

    const char *env = getenv("FLY_MVKSHIM_REAL");
    char *owned = (env != NULL && *env != '\0') ? strdup(env) : default_real_path();
    if (owned == NULL) return;

    g_real = dlopen(owned, RTLD_NOW | RTLD_LOCAL);
    if (g_real == NULL) {
        /* Not silenced by FLY_MVKSHIM_QUIET: without the real library nothing
         * can work, and a silent failure here looks like a graphics bug. */
        fprintf(stderr, "fly-mvkshim: FATAL: cannot load real MoltenVK at %s: %s\n",
                owned, dlerror());
        fflush(stderr);
        free(owned);
        return;
    }

    g_getFeatures = (PFN_vkGetPhysicalDeviceFeatures)dlsym(g_real, "vkGetPhysicalDeviceFeatures");
    g_getFeatures2 = (PFN_vkGetPhysicalDeviceFeatures2)dlsym(g_real, "vkGetPhysicalDeviceFeatures2");
    g_getFeatures2KHR = (PFN_vkGetPhysicalDeviceFeatures2)dlsym(g_real, "vkGetPhysicalDeviceFeatures2KHR");
    g_createDevice = (PFN_vkCreateDevice)dlsym(g_real, "vkCreateDevice");
    g_getInstanceProcAddr = (PFN_vkGetInstanceProcAddr)dlsym(g_real, "vkGetInstanceProcAddr");
    g_getDeviceProcAddr = (PFN_vkGetDeviceProcAddr)dlsym(g_real, "vkGetDeviceProcAddr");
    g_getPhysicalDeviceProcAddr =
        (PFN_vkGetPhysicalDeviceProcAddr)dlsym(g_real, "vk_icdGetPhysicalDeviceProcAddr");
    g_negotiate = (PFN_vkNegotiateLoaderICDInterfaceVersion)dlsym(
        g_real, "vk_icdNegotiateLoaderICDInterfaceVersion");

    if (g_getInstanceProcAddr == NULL || g_createDevice == NULL || g_getFeatures == NULL) {
        fprintf(stderr, "fly-mvkshim: FATAL: real MoltenVK at %s is missing core entry points\n",
                owned);
        fflush(stderr);
        free(owned);
        return;
    }

    shim_log("active; real library %s", owned);
    free(owned);
}

/* ---- Reporting features as present ---- */

static void force_reported(VkPhysicalDeviceFeatures *features) {
    if (features == NULL) return;
    for (int i = 0; i < FEATURE_COUNT; i++) {
        if (g_forced[i] && features->values[i] != VK_TRUE) {
            features->values[i] = VK_TRUE;
            shim_log("reporting %s=VK_TRUE to the app", kFeatureNames[i]);
        }
    }
}

void vkGetPhysicalDeviceFeatures(VkPhysicalDevice device, VkPhysicalDeviceFeatures *features) {
    if (g_getFeatures == NULL) return;
    g_getFeatures(device, features);
    force_reported(features);
}

static void features2_common(PFN_vkGetPhysicalDeviceFeatures2 real, VkPhysicalDevice device,
                             VkPhysicalDeviceFeatures2 *features) {
    if (real == NULL) return;
    real(device, features);
    if (features != NULL) force_reported(&features->features);
}

void vkGetPhysicalDeviceFeatures2(VkPhysicalDevice device, VkPhysicalDeviceFeatures2 *features) {
    features2_common(g_getFeatures2, device, features);
}

void vkGetPhysicalDeviceFeatures2KHR(VkPhysicalDevice device, VkPhysicalDeviceFeatures2 *features) {
    features2_common(g_getFeatures2KHR != NULL ? g_getFeatures2KHR : g_getFeatures2, device,
                     features);
}

/* ---- Stripping them from the device-create request ---- */

VkResult vkCreateDevice(VkPhysicalDevice physicalDevice, const VkDeviceCreateInfo *pCreateInfo,
                        const void *pAllocator, VkDevice *pDevice) {
    if (g_createDevice == NULL) return -3; /* VK_ERROR_INITIALIZATION_FAILED */
    if (pCreateInfo == NULL) return g_createDevice(physicalDevice, pCreateInfo, pAllocator, pDevice);

    VkDeviceCreateInfo info = *pCreateInfo;
    VkPhysicalDeviceFeatures scrubbed;
    bool dropped = false;

    /* pEnabledFeatures: point at our own copy, so the caller's struct is
     * untouched. This is the path id Tech takes. */
    if (pCreateInfo->pEnabledFeatures != NULL) {
        scrubbed = *pCreateInfo->pEnabledFeatures;
        for (int i = 0; i < FEATURE_COUNT; i++) {
            if (g_forced[i] && scrubbed.values[i] != VK_FALSE) {
                scrubbed.values[i] = VK_FALSE;
                dropped = true;
            }
        }
        info.pEnabledFeatures = &scrubbed;
    }

    /* A VkPhysicalDeviceFeatures2 in the pNext chain is the other way to ask.
     * The chain can hold extension structs of sizes we do not know, so it cannot
     * be deep-copied; clear the bits in place and restore them before returning,
     * leaving the caller's memory as it was found. */
    VkPhysicalDeviceFeatures2 *chained = NULL;
    VkPhysicalDeviceFeatures saved;
    for (VkBaseOutStructure *node = (VkBaseOutStructure *)(void *)pCreateInfo->pNext;
         node != NULL; node = node->pNext) {
        if (node->sType != VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2) continue;

        chained = (VkPhysicalDeviceFeatures2 *)(void *)node;
        saved = chained->features;
        for (int i = 0; i < FEATURE_COUNT; i++) {
            if (g_forced[i] && chained->features.values[i] != VK_FALSE) {
                chained->features.values[i] = VK_FALSE;
                dropped = true;
            }
        }
        break;
    }

    VkResult result = g_createDevice(physicalDevice, &info, pAllocator, pDevice);

    if (chained != NULL) chained->features = saved;
    if (dropped) {
        shim_log("vkCreateDevice: dropped forced features from the request -> %s",
                 result_name(result));
    }
    return result;
}

/* ---- Entry point dispatch ---- */

PFN_vkVoidFunction vkGetInstanceProcAddr(VkInstance instance, const char *pName);
PFN_vkVoidFunction vkGetDeviceProcAddr(VkDevice device, const char *pName);

static PFN_vkVoidFunction shim_override(const char *name) {
    if (name == NULL) return NULL;
    if (strcmp(name, "vkGetPhysicalDeviceFeatures") == 0)
        return (PFN_vkVoidFunction)vkGetPhysicalDeviceFeatures;
    if (strcmp(name, "vkGetPhysicalDeviceFeatures2") == 0)
        return (PFN_vkVoidFunction)vkGetPhysicalDeviceFeatures2;
    if (strcmp(name, "vkGetPhysicalDeviceFeatures2KHR") == 0)
        return (PFN_vkVoidFunction)vkGetPhysicalDeviceFeatures2KHR;
    if (strcmp(name, "vkCreateDevice") == 0) return (PFN_vkVoidFunction)vkCreateDevice;
    if (strcmp(name, "vkGetInstanceProcAddr") == 0)
        return (PFN_vkVoidFunction)vkGetInstanceProcAddr;
    if (strcmp(name, "vkGetDeviceProcAddr") == 0)
        return (PFN_vkVoidFunction)vkGetDeviceProcAddr;
    return NULL;
}

PFN_vkVoidFunction vkGetInstanceProcAddr(VkInstance instance, const char *pName) {
    PFN_vkVoidFunction ours = shim_override(pName);
    if (ours != NULL) return ours;
    if (g_getInstanceProcAddr == NULL) return NULL;
    return g_getInstanceProcAddr(instance, pName);
}

PFN_vkVoidFunction vkGetDeviceProcAddr(VkDevice device, const char *pName) {
    /* A device-level vkGetDeviceProcAddr must not hand back our instance-level
     * overrides; only the two feature queries and vkCreateDevice are ours, and
     * none of them are device-level functions. */
    if (g_getDeviceProcAddr == NULL) return NULL;
    return g_getDeviceProcAddr(device, pName);
}

PFN_vkVoidFunction vk_icdGetInstanceProcAddr(VkInstance instance, const char *pName) {
    return vkGetInstanceProcAddr(instance, pName);
}

PFN_vkVoidFunction vk_icdGetPhysicalDeviceProcAddr(VkInstance instance, const char *pName) {
    PFN_vkVoidFunction ours = shim_override(pName);
    if (ours != NULL) return ours;
    if (g_getPhysicalDeviceProcAddr == NULL) return NULL;
    return g_getPhysicalDeviceProcAddr(instance, pName);
}

VkResult vk_icdNegotiateLoaderICDInterfaceVersion(uint32_t *pVersion) {
    if (g_negotiate == NULL) return -3; /* VK_ERROR_INITIALIZATION_FAILED */
    return g_negotiate(pVersion);
}
