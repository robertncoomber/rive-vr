// Minimal OpenXR loader for Android. Finds the active runtime the way the
// Khronos loader does (runtime broker, then /<partition>/etc/openxr), loads it
// directly and resolves exactly the functions this app calls. No API layers.
// Replaces libopenxr_loader, which drags in jsoncpp and libc++ iostreams.
#pragma once

#include <jni.h>

#ifndef XR_USE_PLATFORM_ANDROID
#define XR_USE_PLATFORM_ANDROID
#endif
#define XR_NO_PROTOTYPES
#include <openxr/openxr.h>
#include <openxr/openxr_platform.h>

// Callable before an instance exists.
#define XR_GLOBAL_FUNCTIONS(X)                                                 \
    X(xrEnumerateInstanceExtensionProperties)                                  \
    X(xrCreateInstance)

// Resolved by xrLoaderLoadInstanceFunctions once the instance is created.
#define XR_INSTANCE_FUNCTIONS(X)                                               \
    X(xrAcquireSwapchainImage)                                                 \
    X(xrAttachSessionActionSets)                                               \
    X(xrBeginFrame)                                                            \
    X(xrBeginSession)                                                          \
    X(xrCreateAction)                                                          \
    X(xrCreateActionSet)                                                       \
    X(xrCreateActionSpace)                                                     \
    X(xrCreateReferenceSpace)                                                  \
    X(xrCreateSession)                                                         \
    X(xrCreateSwapchain)                                                       \
    X(xrDestroyInstance)                                                       \
    X(xrDestroySession)                                                        \
    X(xrDestroySpace)                                                          \
    X(xrDestroySwapchain)                                                      \
    X(xrEndFrame)                                                              \
    X(xrEndSession)                                                            \
    X(xrEnumerateSwapchainFormats)                                             \
    X(xrEnumerateSwapchainImages)                                              \
    X(xrEnumerateViewConfigurationViews)                                       \
    X(xrGetActionStateFloat)                                                   \
    X(xrGetActionStateBoolean)                                                 \
    X(xrApplyHapticFeedback)                                                   \
    X(xrGetInstanceProperties)                                                 \
    X(xrGetSystem)                                                             \
    X(xrGetSystemProperties)                                                   \
    X(xrLocateSpace)                                                           \
    X(xrLocateViews)                                                           \
    X(xrPollEvent)                                                             \
    X(xrReleaseSwapchainImage)                                                 \
    X(xrStringToPath)                                                          \
    X(xrSuggestInteractionProfileBindings)                                     \
    X(xrSyncActions)                                                           \
    X(xrWaitFrame)                                                             \
    X(xrWaitSwapchainImage)

#define XR_DECLARE_FUNCTION(name) extern PFN_##name name;
XR_DECLARE_FUNCTION(xrGetInstanceProcAddr)
XR_GLOBAL_FUNCTIONS(XR_DECLARE_FUNCTION)
XR_INSTANCE_FUNCTIONS(XR_DECLARE_FUNCTION)
#undef XR_DECLARE_FUNCTION

// Loads the active runtime, forwards xrInitializeLoaderKHR to it and resolves
// xrGetInstanceProcAddr plus XR_GLOBAL_FUNCTIONS. `context` is the activity.
XrResult xrLoaderInitialize(JavaVM* vm, jobject context);

// Resolves XR_INSTANCE_FUNCTIONS for a freshly created instance.
XrResult xrLoaderLoadInstanceFunctions(XrInstance instance);
