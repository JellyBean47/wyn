/*
 * fly_mvkshim_probe.c — reproduce id Tech's Vulkan wall, with and without the shim.
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
 * Usage: fly_mvkshim_probe <path to libMoltenVK.dylib or the shim>
 *
 * Does exactly what Youngblood and DOOM do at startup: create an instance, take
 * the first physical device, ask whether `shaderCullDistance` and `depthBounds`
 * are supported, then request them in vkCreateDevice. Against stock MoltenVK
 * this prints VK_ERROR_FEATURE_NOT_PRESENT — the game's "Startup failure: error
 * while initializing the graphics driver". Against the shim it prints
 * VK_SUCCESS. That difference is the whole claim, so it is worth being able to
 * re-run rather than remember.
 *
 * Exit status: 0 if a device was created, 1 if not, 2 on a setup failure. So
 * the stock run is *expected* to exit 1.
 */

#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

typedef uint32_t VkBool32;
typedef uint32_t VkFlags;
typedef int32_t VkResult;
typedef void *VkInstance;
typedef void *VkPhysicalDevice;
typedef void *VkDevice;
typedef void (*PFN_vkVoidFunction)(void);

#define VK_SUCCESS 0
#define VK_TRUE 1
#define VK_API_VERSION_1_0 (1u << 22)

#define DEPTH_BOUNDS_INDEX 14        /* 15th field */
#define SHADER_CULL_DISTANCE_INDEX 38 /* 39th field */
#define FEATURE_COUNT 55

typedef struct {
    VkBool32 values[FEATURE_COUNT];
} VkPhysicalDeviceFeatures;

typedef struct {
    int32_t sType;
    const void *pNext;
    const char *pApplicationName;
    uint32_t applicationVersion;
    const char *pEngineName;
    uint32_t engineVersion;
    uint32_t apiVersion;
} VkApplicationInfo;

typedef struct {
    int32_t sType;
    const void *pNext;
    VkFlags flags;
    const VkApplicationInfo *pApplicationInfo;
    uint32_t enabledLayerCount;
    const char *const *ppEnabledLayerNames;
    uint32_t enabledExtensionCount;
    const char *const *ppEnabledExtensionNames;
} VkInstanceCreateInfo;

typedef struct {
    int32_t sType;
    const void *pNext;
    VkFlags flags;
    uint32_t queueFamilyIndex;
    uint32_t queueCount;
    const float *pQueuePriorities;
} VkDeviceQueueCreateInfo;

typedef struct {
    int32_t sType;
    const void *pNext;
    VkFlags flags;
    uint32_t queueCreateInfoCount;
    const VkDeviceQueueCreateInfo *pQueueCreateInfos;
    uint32_t enabledLayerCount;
    const char *const *ppEnabledLayerNames;
    uint32_t enabledExtensionCount;
    const char *const *ppEnabledExtensionNames;
    const VkPhysicalDeviceFeatures *pEnabledFeatures;
} VkDeviceCreateInfo;

typedef PFN_vkVoidFunction (*PFN_GIPA)(VkInstance, const char *);
typedef VkResult (*PFN_CreateInstance)(const VkInstanceCreateInfo *, const void *, VkInstance *);
typedef VkResult (*PFN_EnumPhys)(VkInstance, uint32_t *, VkPhysicalDevice *);
typedef void (*PFN_GetFeatures)(VkPhysicalDevice, VkPhysicalDeviceFeatures *);
typedef VkResult (*PFN_CreateDevice)(VkPhysicalDevice, const VkDeviceCreateInfo *, const void *,
                                     VkDevice *);

static const char *result_name(VkResult r) {
    switch (r) {
    case VK_SUCCESS: return "VK_SUCCESS";
    case -3: return "VK_ERROR_INITIALIZATION_FAILED";
    case -7: return "VK_ERROR_EXTENSION_NOT_PRESENT";
    case -8: return "VK_ERROR_FEATURE_NOT_PRESENT";
    case -9: return "VK_ERROR_INCOMPATIBLE_DRIVER";
    default: return "VkResult (other)";
    }
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: %s <libMoltenVK.dylib or shim>\n", argv[0]);
        return 2;
    }

    void *lib = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
    if (lib == NULL) {
        fprintf(stderr, "probe: cannot load %s: %s\n", argv[1], dlerror());
        return 2;
    }

    PFN_GIPA gipa = (PFN_GIPA)dlsym(lib, "vkGetInstanceProcAddr");
    if (gipa == NULL) {
        fprintf(stderr, "probe: no vkGetInstanceProcAddr in %s\n", argv[1]);
        return 2;
    }

    PFN_CreateInstance createInstance = (PFN_CreateInstance)gipa(NULL, "vkCreateInstance");
    if (createInstance == NULL) {
        fprintf(stderr, "probe: no vkCreateInstance\n");
        return 2;
    }

    VkApplicationInfo app = {0};
    app.sType = 0; /* VK_STRUCTURE_TYPE_APPLICATION_INFO */
    app.pApplicationName = "fly_mvkshim_probe";
    app.pEngineName = "fly_mvkshim_probe";
    app.apiVersion = VK_API_VERSION_1_0;

    VkInstanceCreateInfo ici = {0};
    ici.sType = 1; /* VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO */
    ici.pApplicationInfo = &app;

    VkInstance instance = NULL;
    VkResult r = createInstance(&ici, NULL, &instance);
    if (r != VK_SUCCESS) {
        fprintf(stderr, "probe: vkCreateInstance -> %s\n", result_name(r));
        return 2;
    }

    PFN_EnumPhys enumPhys = (PFN_EnumPhys)gipa(instance, "vkEnumeratePhysicalDevices");
    PFN_GetFeatures getFeatures =
        (PFN_GetFeatures)gipa(instance, "vkGetPhysicalDeviceFeatures");
    PFN_CreateDevice createDevice = (PFN_CreateDevice)gipa(instance, "vkCreateDevice");
    if (enumPhys == NULL || getFeatures == NULL || createDevice == NULL) {
        fprintf(stderr, "probe: missing instance entry points\n");
        return 2;
    }

    uint32_t count = 0;
    enumPhys(instance, &count, NULL);
    if (count == 0) {
        fprintf(stderr, "probe: no physical devices\n");
        return 2;
    }
    VkPhysicalDevice devices[8];
    if (count > 8) count = 8;
    enumPhys(instance, &count, devices);

    VkPhysicalDeviceFeatures reported;
    memset(&reported, 0, sizeof(reported));
    getFeatures(devices[0], &reported);

    printf("reported by vkGetPhysicalDeviceFeatures:\n");
    printf("  depthBounds         (15th) = %s\n",
           reported.values[DEPTH_BOUNDS_INDEX] == VK_TRUE ? "VK_TRUE" : "VK_FALSE");
    printf("  shaderCullDistance  (39th) = %s\n",
           reported.values[SHADER_CULL_DISTANCE_INDEX] == VK_TRUE ? "VK_TRUE" : "VK_FALSE");

    /* Ask for them, the way id Tech does. */
    VkPhysicalDeviceFeatures wanted;
    memset(&wanted, 0, sizeof(wanted));
    wanted.values[DEPTH_BOUNDS_INDEX] = VK_TRUE;
    wanted.values[SHADER_CULL_DISTANCE_INDEX] = VK_TRUE;

    float priority = 1.0f;
    VkDeviceQueueCreateInfo queue = {0};
    queue.sType = 2; /* VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO */
    queue.queueFamilyIndex = 0;
    queue.queueCount = 1;
    queue.pQueuePriorities = &priority;

    VkDeviceCreateInfo dci = {0};
    dci.sType = 3; /* VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO */
    dci.queueCreateInfoCount = 1;
    dci.pQueueCreateInfos = &queue;
    dci.pEnabledFeatures = &wanted;

    VkDevice device = NULL;
    r = createDevice(devices[0], &dci, NULL, &device);
    printf("vkCreateDevice requesting both -> %s\n", result_name(r));

    if (r != VK_SUCCESS) {
        printf("RESULT: no device. This is the game's 'Startup failure'.\n");
        return 1;
    }
    printf("RESULT: device created.\n");
    return 0;
}
