/* POC (local): implicit Vulkan layer that turns draw/dispatch commands into no-ops.
 * Goal: a game server with no GPU (software Vulkan) does not pay for pixels nobody sees.
 * Independent of the game binary (no addresses), same source for Linux and Windows.
 * Enabled by MPF_VKNULL=1 (any other value or unset: the layer is inert, a real GPU is used as usual).
 * MPF_VKNULL_MODE: "draw" (default) = draws + dispatches ; "all" = also clears/copies/blits/resolves. */
#include <vulkan/vulkan.h>
#include <vulkan/vk_layer.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <stdint.h>
#include <pthread.h>
#include <sys/mman.h>
#include <unistd.h>

#ifdef _WIN32
#define EXPORT __declspec(dllexport)
#else
#define EXPORT __attribute__((visibility("default")))
#endif

static PFN_vkGetInstanceProcAddr g_nextGipa;
static PFN_vkGetDeviceProcAddr g_nextGdpa;
static int g_on = -1, g_all = 0;
static unsigned long long g_calls;

static void init_env(void)
{
    if (g_on >= 0) return;
    const char* v = getenv("MPF_VKNULL");
    g_on = (v && v[0] == '1') ? 1 : 0;
    const char* m = getenv("MPF_VKNULL_MODE");
    g_all = (m && !strcmp(m, "all")) ? 1 : 0;
    if (g_on) fprintf(stderr, "[mpf-vknull] active (mode=%s)\n", g_all ? "all" : "draw");
}

/* one function serves every void-returning command: the caller cleans the stack/regs (cdecl / SysV / Win64) */
static void VKAPI_CALL noop_cmd(void) { g_calls++; }

static const char* const k_draw[] = {
    "vkCmdDraw", "vkCmdDrawIndexed", "vkCmdDrawIndirect", "vkCmdDrawIndexedIndirect",
    "vkCmdDrawIndirectCount", "vkCmdDrawIndexedIndirectCount", "vkCmdDrawIndirectCountKHR",
    "vkCmdDrawIndexedIndirectCountKHR", "vkCmdDrawMultiEXT", "vkCmdDrawMultiIndexedEXT",
    "vkCmdDrawMeshTasksEXT", "vkCmdDrawMeshTasksIndirectEXT",
    "vkCmdDispatch", "vkCmdDispatchIndirect", "vkCmdDispatchBase", "vkCmdDispatchBaseKHR", 0 };
static const char* const k_all[] = {
    "vkCmdClearColorImage", "vkCmdClearDepthStencilImage", "vkCmdClearAttachments",
    "vkCmdBlitImage", "vkCmdBlitImage2", "vkCmdResolveImage", "vkCmdResolveImage2",
    "vkCmdCopyImage", "vkCmdCopyImage2",
    /* mode "memory": the uploads that fill the (software) GPU memory: nobody reads it on a server */
    "vkCmdCopyBufferToImage", "vkCmdCopyBufferToImage2", "vkCmdCopyBuffer", "vkCmdCopyBuffer2", "vkCmdCopyImageToBuffer",
    "vkCmdCopyImageToBuffer2", "vkCmdUpdateBuffer", "vkCmdFillBuffer",
    /* the render passes themselves (their load/clear/resolve work is the remaining software-GPU cost): all of them or none */
    "vkCmdBeginRenderPass", "vkCmdBeginRenderPass2", "vkCmdBeginRenderPass2KHR", "vkCmdEndRenderPass", "vkCmdEndRenderPass2",
    "vkCmdEndRenderPass2KHR", "vkCmdNextSubpass", "vkCmdNextSubpass2", "vkCmdNextSubpass2KHR", "vkCmdBeginRendering",
    "vkCmdBeginRenderingKHR", "vkCmdEndRendering", "vkCmdEndRenderingKHR", "vkCmdExecuteCommands", 0 };

static int in_list(const char* const* l, const char* n)
{
    for (; *l; ++l) if (!strcmp(*l, n)) return 1;
    return 0;
}


/* MPF_VKNULL_TRIM=1 (RAM): nothing is ever drawn, so what the game wrote into mapped GPU memory is never read by anyone. Every TRIM_EVERY
 * submits the pages of the big mapped ranges are given back to the system (they read as zeros afterwards). Off by default. */
#define TRIM_EVERY 30
#define MAXMAP 8192
static struct { VkDeviceMemory m; char* p; size_t n; } g_map[MAXMAP];
static pthread_mutex_t g_mu = PTHREAD_MUTEX_INITIALIZER;
static int g_trim = -1;
static unsigned long long g_submits, g_trimmed;
static PFN_vkMapMemory r_map; static PFN_vkUnmapMemory r_unmap; static PFN_vkFreeMemory r_free; static PFN_vkQueueSubmit r_submit;

static VKAPI_ATTR VkResult VKAPI_CALL T_Map(VkDevice d, VkDeviceMemory m, VkDeviceSize off, VkDeviceSize sz, VkMemoryMapFlags f, void** pp)
{
    VkResult r = r_map(d, m, off, sz, f, pp);
    if (r == VK_SUCCESS && sz != VK_WHOLE_SIZE && sz >= (1u << 20)) {
        pthread_mutex_lock(&g_mu);
        for (int i = 0; i < MAXMAP; i++) if (!g_map[i].m) { g_map[i].m = m; g_map[i].p = (char*)*pp; g_map[i].n = (size_t)sz; break; }
        pthread_mutex_unlock(&g_mu);
    }
    return r;
}
static void forget(VkDeviceMemory m)
{
    pthread_mutex_lock(&g_mu);
    for (int i = 0; i < MAXMAP; i++) if (g_map[i].m == m) g_map[i].m = 0;
    pthread_mutex_unlock(&g_mu);
}
static VKAPI_ATTR void VKAPI_CALL T_Unmap(VkDevice d, VkDeviceMemory m) { forget(m); r_unmap(d, m); }
static VKAPI_ATTR void VKAPI_CALL T_Free(VkDevice d, VkDeviceMemory m, const VkAllocationCallbacks* al) { forget(m); r_free(d, m, al); }
static VKAPI_ATTR VkResult VKAPI_CALL T_Submit(VkQueue q, uint32_t n, const VkSubmitInfo* si, VkFence f)
{
    VkResult r = r_submit(q, n, si, f);
    if (++g_submits % TRIM_EVERY == 0) {
        long pg = sysconf(_SC_PAGESIZE);
        pthread_mutex_lock(&g_mu);
        for (int i = 0; i < MAXMAP; i++) if (g_map[i].m) {
            uintptr_t a = ((uintptr_t)g_map[i].p + pg - 1) & ~(uintptr_t)(pg - 1), b = ((uintptr_t)g_map[i].p + g_map[i].n) & ~(uintptr_t)(pg - 1);
            if (b > a && madvise((void*)a, b - a, MADV_DONTNEED) == 0) g_trimmed += b - a;
        }
        pthread_mutex_unlock(&g_mu);
    }
    return r;
}

static VKAPI_ATTR PFN_vkVoidFunction VKAPI_CALL L_GetDeviceProcAddr(VkDevice d, const char* n)
{
    init_env();
    if (g_on && (in_list(k_draw, n) || (g_all && in_list(k_all, n)))) return (PFN_vkVoidFunction)noop_cmd;
    if (g_trim < 0) { const char* t = getenv("MPF_VKNULL_TRIM"); g_trim = (g_on && t && t[0] == '1') ? 1 : 0; }
    if (g_trim && g_nextGdpa) {
        if (!strcmp(n, "vkMapMemory"))   { if (!r_map)    r_map    = (PFN_vkMapMemory)g_nextGdpa(d, n);    if (r_map)    return (PFN_vkVoidFunction)T_Map; }
        if (!strcmp(n, "vkUnmapMemory")) { if (!r_unmap)  r_unmap  = (PFN_vkUnmapMemory)g_nextGdpa(d, n);  if (r_unmap)  return (PFN_vkVoidFunction)T_Unmap; }
        if (!strcmp(n, "vkFreeMemory"))  { if (!r_free)   r_free   = (PFN_vkFreeMemory)g_nextGdpa(d, n);   if (r_free)   return (PFN_vkVoidFunction)T_Free; }
        if (!strcmp(n, "vkQueueSubmit")) { if (!r_submit) r_submit = (PFN_vkQueueSubmit)g_nextGdpa(d, n); if (r_submit) return (PFN_vkVoidFunction)T_Submit; }
    }
    return g_nextGdpa ? g_nextGdpa(d, n) : 0;
}

static VKAPI_ATTR VkResult VKAPI_CALL L_CreateDevice(VkPhysicalDevice pd, const VkDeviceCreateInfo* ci,
                                                     const VkAllocationCallbacks* al, VkDevice* out)
{
    VkLayerDeviceCreateInfo* lci = (VkLayerDeviceCreateInfo*)ci->pNext;
    while (lci && !(lci->sType == VK_STRUCTURE_TYPE_LOADER_DEVICE_CREATE_INFO && lci->function == VK_LAYER_LINK_INFO))
        lci = (VkLayerDeviceCreateInfo*)lci->pNext;
    if (!lci) return VK_ERROR_INITIALIZATION_FAILED;
    PFN_vkGetInstanceProcAddr gipa = lci->u.pLayerInfo->pfnNextGetInstanceProcAddr;
    PFN_vkGetDeviceProcAddr gdpa = lci->u.pLayerInfo->pfnNextGetDeviceProcAddr;
    lci->u.pLayerInfo = lci->u.pLayerInfo->pNext;
    PFN_vkCreateDevice next = (PFN_vkCreateDevice)gipa(VK_NULL_HANDLE, "vkCreateDevice");
    VkResult r = next(pd, ci, al, out);
    if (r == VK_SUCCESS) g_nextGdpa = gdpa;
    return r;
}

static VKAPI_ATTR VkResult VKAPI_CALL L_CreateInstance(const VkInstanceCreateInfo* ci,
                                                       const VkAllocationCallbacks* al, VkInstance* out)
{
    VkLayerInstanceCreateInfo* lci = (VkLayerInstanceCreateInfo*)ci->pNext;
    while (lci && !(lci->sType == VK_STRUCTURE_TYPE_LOADER_INSTANCE_CREATE_INFO && lci->function == VK_LAYER_LINK_INFO))
        lci = (VkLayerInstanceCreateInfo*)lci->pNext;
    if (!lci) return VK_ERROR_INITIALIZATION_FAILED;
    PFN_vkGetInstanceProcAddr gipa = lci->u.pLayerInfo->pfnNextGetInstanceProcAddr;
    lci->u.pLayerInfo = lci->u.pLayerInfo->pNext;
    PFN_vkCreateInstance next = (PFN_vkCreateInstance)gipa(VK_NULL_HANDLE, "vkCreateInstance");
    VkResult r = next(ci, al, out);
    if (r == VK_SUCCESS) g_nextGipa = gipa;
    return r;
}

static VKAPI_ATTR PFN_vkVoidFunction VKAPI_CALL L_GetInstanceProcAddr(VkInstance i, const char* n)
{
    if (!strcmp(n, "vkGetInstanceProcAddr")) return (PFN_vkVoidFunction)L_GetInstanceProcAddr;
    if (!strcmp(n, "vkCreateInstance")) return (PFN_vkVoidFunction)L_CreateInstance;
    if (!strcmp(n, "vkCreateDevice")) return (PFN_vkVoidFunction)L_CreateDevice;
    if (!strcmp(n, "vkGetDeviceProcAddr")) return (PFN_vkVoidFunction)L_GetDeviceProcAddr;
    return g_nextGipa ? g_nextGipa(i, n) : 0;
}

EXPORT VKAPI_ATTR VkResult VKAPI_CALL vkNegotiateLoaderLayerInterfaceVersion(VkNegotiateLayerInterface* p)
{
    if (p->loaderLayerInterfaceVersion >= 2) {
        p->pfnGetInstanceProcAddr = L_GetInstanceProcAddr;
        p->pfnGetDeviceProcAddr = L_GetDeviceProcAddr;
        p->pfnGetPhysicalDeviceProcAddr = 0;
    }
    if (p->loaderLayerInterfaceVersion > 2) p->loaderLayerInterfaceVersion = 2;
    return VK_SUCCESS;
}
