/* Vulkan probe for scripts/smoke-runtime.sh: the path Vulkan-native titles
 * (id Tech) take — vulkan-1.dll -> winevulkan -> MoltenVK — with no D3D layer
 * in between. Declares the handful of Vulkan types it needs so it builds with
 * a bare mingw-w64 (no Vulkan SDK). */
#include <windows.h>
#include <stdio.h>
#include <stdint.h>

typedef struct VkApplicationInfo {
    int sType; const void *pNext; const char *pApplicationName; uint32_t applicationVersion;
    const char *pEngineName; uint32_t engineVersion; uint32_t apiVersion;
} VkApplicationInfo;
typedef struct VkInstanceCreateInfo {
    int sType; const void *pNext; uint32_t flags; const VkApplicationInfo *pApplicationInfo;
    uint32_t enabledLayerCount; const char *const *ppEnabledLayerNames;
    uint32_t enabledExtensionCount; const char *const *ppEnabledExtensionNames;
} VkInstanceCreateInfo;
/* VkPhysicalDeviceProperties begins with these fields; the rest is padding here. */
typedef struct VkPhysicalDevicePropertiesHead {
    uint32_t apiVersion, driverVersion, vendorID, deviceID; int deviceType; char deviceName[256];
    unsigned char rest[4096];
} VkPhysicalDevicePropertiesHead;

typedef int (WINAPI *PFN_vkCreateInstance)(const VkInstanceCreateInfo *, const void *, void **);
typedef int (WINAPI *PFN_vkEnumeratePhysicalDevices)(void *, uint32_t *, void **);
typedef void (WINAPI *PFN_vkGetPhysicalDeviceProperties)(void *, VkPhysicalDevicePropertiesHead *);

int main(void)
{
    HMODULE vk = LoadLibraryA("vulkan-1.dll");
    if (!vk) { printf("vulkan-1.dll: not loaded (%lu)\n", GetLastError()); return 1; }
    PFN_vkCreateInstance create = (PFN_vkCreateInstance)GetProcAddress(vk, "vkCreateInstance");
    PFN_vkEnumeratePhysicalDevices enumerate =
        (PFN_vkEnumeratePhysicalDevices)GetProcAddress(vk, "vkEnumeratePhysicalDevices");
    PFN_vkGetPhysicalDeviceProperties props =
        (PFN_vkGetPhysicalDeviceProperties)GetProcAddress(vk, "vkGetPhysicalDeviceProperties");

    VkApplicationInfo app = {0 /* VK_STRUCTURE_TYPE_APPLICATION_INFO */, NULL, "WynProbe", 1, NULL, 0,
                             (1u << 22) | (1u << 12) /* 1.1 */};
    VkInstanceCreateInfo info = {1 /* VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO */, NULL, 0, &app, 0, NULL, 0, NULL};
    void *instance = NULL;
    int r = create(&info, NULL, &instance);
    printf("vkCreateInstance: %d\n", r);
    if (r != 0) return 1;

    uint32_t count = 0;
    enumerate(instance, &count, NULL);
    void *devices[8] = {0};
    if (count > 8) count = 8;
    enumerate(instance, &count, devices);
    for (uint32_t i = 0; i < count; i++) {
        VkPhysicalDevicePropertiesHead p;
        props(devices[i], &p);
        printf("vulkan device %u: %s (api %u.%u)\n", i, p.deviceName, p.apiVersion >> 22, (p.apiVersion >> 12) & 0x3ff);
    }
    fflush(stdout);
    return count ? 0 : 1;
}
