// rive-vr host: a minimal OpenXR app on Quest where Rive draws every pixel.
// It loads a .riv and records an artboard through Rive's deferred session (the
// path scripted GPU Canvas work requires), then replays it into an OpenXR
// swapchain image. The host itself issues no draw calls.
//
// Two modes, picked by the file:
//  - Stereo: an artboard named "Main" bound to the XR ViewModel. The host
//    writes both eye poses and FOVs into the ViewModel each frame and submits
//    a projection layer over one double-wide swapchain (left | right).
//  - Quad: anything else (the G3 gate file) is shown on a world-locked quad.

#include <android/log.h>
#include <android_native_app_glue.h>
#include <jni.h>
#include <sys/system_properties.h>

#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES3/gl32.h>
#include <GLES2/gl2ext.h>

#define XR_USE_PLATFORM_ANDROID
#define XR_USE_GRAPHICS_API_OPENGL_ES
#include <openxr/openxr.h>
#include <openxr/openxr_platform.h>

#include "rive/animation/state_machine_instance.hpp"
#include "rive/artboard.hpp"
#include "rive/file.hpp"
#include "rive/lua/rive_lua_libs.hpp"
#include "rive/lua/scripting_vm.hpp"
#include "rive/renderer/cmd/deferred_host.hpp"
#include "rive/renderer/cmd/deferred_session.hpp"
#include "rive/renderer/gl/render_context_gl_impl.hpp"
#include "rive/renderer/gl/render_target_gl.hpp"
#include "rive/renderer/rive_renderer.hpp"
#include "rive/viewmodel/runtime/viewmodel_instance_runtime.hpp"
#include "rive/viewmodel/runtime/viewmodel_runtime.hpp"

#include <chrono>
#include <pthread.h>
#include <unistd.h>
#include <cstdio>
#include <cstring>
#include <memory>
#include <string>
#include <vector>

#define TAG "RiveVR"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, TAG, __VA_ARGS__)

#define XR_CHECK(call)                                                         \
    do                                                                         \
    {                                                                          \
        XrResult _r = (call);                                                  \
        if (XR_FAILED(_r))                                                     \
        {                                                                      \
            LOGE("%s failed: %d (%s:%d)", #call, (int)_r, __FILE__, __LINE__); \
            return false;                                                      \
        }                                                                      \
    } while (0)

namespace
{
constexpr uint32_t kQuadPixels = 1024;
constexpr float kQuadMeters = 0.8f;
constexpr float kQuadDistance = 1.2f;

const char* kEyeProps[2] = {"eyeL", "eyeR"};
const char* kHandSuffix[2] = {"L", "R"};
const char* kHandPaths[2] = {"/user/hand/left", "/user/hand/right"};
const char* kControllerPoseKeys[7] = {"px", "py", "pz", "qx", "qy", "qz", "qw"};
const char* kPoseKeys[11] =
    {"px", "py", "pz", "qx", "qy", "qz", "qw", "fovL", "fovR", "fovU", "fovD"};

float sysPropFloat(const char* name, float fallback)
{
    char value[PROP_VALUE_MAX] = {};
    if (__system_property_get(name, value) <= 0)
    {
        return fallback;
    }
    return strtof(value, nullptr);
}

bool sysPropEnabled(const char* name, bool fallback)
{
    char value[PROP_VALUE_MAX] = {};
    if (__system_property_get(name, value) <= 0)
    {
        return fallback;
    }
    return value[0] == '1' || value[0] == 't';
}

// Opens Rive's real GL frame on the swapchain texture during replay.
class SwapchainSink : public rive::cmd::HostFrameSink
{
public:
    SwapchainSink(rive::gpu::RenderContext* rc,
                  uint64_t target,
                  uint32_t width,
                  uint32_t height) :
        rive::cmd::HostFrameSink(true, 0xff000000u, target),
        m_rc(rc),
        m_width(width),
        m_height(height)
    {
        m_acceptAnyScreenTarget = true;
    }

    rive::gpu::RenderContext* renderContext() override { return m_rc; }

    rive::Renderer* beginScreen(uint64_t, bool clear, uint32_t color) override
    {
        rive::gpu::RenderContext::FrameDescriptor fd;
        fd.renderTargetWidth = m_width;
        fd.renderTargetHeight = m_height;
        fd.loadAction = clear ? rive::gpu::LoadAction::clear
                              : rive::gpu::LoadAction::preserveRenderTarget;
        fd.clearColor = color;
        m_rc->beginFrame(fd);
        m_renderer = std::make_unique<rive::RiveRenderer>(m_rc);
        return m_renderer.get();
    }

private:
    rive::gpu::RenderContext* m_rc;
    uint32_t m_width;
    uint32_t m_height;
    std::unique_ptr<rive::RiveRenderer> m_renderer;
};

struct App
{
    android_app* android = nullptr;
    bool resumed = false;

    // EGL
    EGLDisplay display = EGL_NO_DISPLAY;
    EGLConfig config = nullptr;
    EGLContext context = EGL_NO_CONTEXT;
    EGLSurface pbuffer = EGL_NO_SURFACE;
    bool srgbWriteControl = false;

    // OpenXR
    XrInstance instance = XR_NULL_HANDLE;
    XrSystemId systemId = XR_NULL_SYSTEM_ID;
    XrSession session = XR_NULL_HANDLE;
    XrSpace localSpace = XR_NULL_HANDLE;
    XrSpace stageSpace = XR_NULL_HANDLE;

    // Controller input: one action set, grip/aim poses and trigger per hand.
    XrActionSet actionSet = XR_NULL_HANDLE;
    XrAction gripAction = XR_NULL_HANDLE;
    XrAction aimAction = XR_NULL_HANDLE;
    XrAction triggerAction = XR_NULL_HANDLE;
    XrPath handPaths[2] = {XR_NULL_PATH, XR_NULL_PATH};
    XrSpace gripSpaces[2] = {XR_NULL_HANDLE, XR_NULL_HANDLE};
    XrSpace aimSpaces[2] = {XR_NULL_HANDLE, XR_NULL_HANDLE};
    XrSwapchain swapchain = XR_NULL_HANDLE;
    uint32_t swapchainWidth = 0;
    uint32_t swapchainHeight = 0;
    uint32_t eyeWidth = 0;
    uint32_t eyeHeight = 0;
    XrView views[2] = {{XR_TYPE_VIEW}, {XR_TYPE_VIEW}};
    std::vector<XrSwapchainImageOpenGLESKHR> images;
    int64_t swapchainFormat = 0;
    XrSessionState state = XR_SESSION_STATE_UNKNOWN;
    bool sessionRunning = false;
    bool exitRequested = false;

    // Rive
    std::unique_ptr<rive::gpu::RenderContext> rc;
    std::unique_ptr<rive::cmd::DeferredSession> riveSession;
    rive::cmd::DeferredInlineHost host;
    uint64_t target = 0;
    rive::rcp<rive::gpu::TextureRenderTargetGL> renderTarget;
    rive::rcp<rive::ScriptingVM> scriptingVM;
    rive::rcp<rive::File> file;
    std::unique_ptr<rive::ArtboardInstance> artboard;
    std::unique_ptr<rive::StateMachineInstance> stateMachine;
    rive::rcp<rive::ViewModelInstanceRuntime> viewModel;
    bool stereo = false;
    rive::ViewModelInstanceNumberRuntime* eyeProps[2][11] = {};
    rive::ViewModelInstanceNumberRuntime* frameIndexProp = nullptr;
    rive::ViewModelInstanceNumberRuntime* seenFrameProp = nullptr;
    rive::ViewModelInstanceNumberRuntime* eyeWidthProp = nullptr;
    rive::ViewModelInstanceNumberRuntime* eyeHeightProp = nullptr;
    // [hand][0..6] grip pose, [hand][7..13] aim pose, [hand][14] trigger,
    // [hand][15] active (1 when the controller is tracked).
    rive::ViewModelInstanceNumberRuntime* handProps[2][16] = {};

    // G4: frames where the script drew with a stale frameIndex.
    uint64_t g4Frames = 0;
    uint64_t g4Stale = 0;

    // Timing
    XrTime lastDisplayTime = 0;
    uint64_t frameNumber = 0;
    uint32_t framesThisSecond = 0;
    double cpuMsThisSecond = 0;
    std::chrono::steady_clock::time_point secondStart =
        std::chrono::steady_clock::now();
};

bool initEGL(App& app)
{
    app.display = eglGetDisplay(EGL_DEFAULT_DISPLAY);
    if (!eglInitialize(app.display, nullptr, nullptr))
    {
        LOGE("eglInitialize failed");
        return false;
    }
    const EGLint configAttribs[] = {EGL_RED_SIZE,
                                    8,
                                    EGL_GREEN_SIZE,
                                    8,
                                    EGL_BLUE_SIZE,
                                    8,
                                    EGL_ALPHA_SIZE,
                                    8,
                                    EGL_DEPTH_SIZE,
                                    0,
                                    EGL_STENCIL_SIZE,
                                    0,
                                    EGL_RENDERABLE_TYPE,
                                    EGL_OPENGL_ES3_BIT_KHR,
                                    EGL_SURFACE_TYPE,
                                    EGL_PBUFFER_BIT,
                                    EGL_NONE};
    EGLint numConfigs = 0;
    if (!eglChooseConfig(app.display,
                         configAttribs,
                         &app.config,
                         1,
                         &numConfigs) ||
        numConfigs == 0)
    {
        LOGE("eglChooseConfig failed");
        return false;
    }
    const EGLint contextAttribs[] = {EGL_CONTEXT_MAJOR_VERSION_KHR,
                                     3,
                                     EGL_CONTEXT_MINOR_VERSION_KHR,
                                     2,
                                     EGL_NONE};
    app.context = eglCreateContext(app.display,
                                   app.config,
                                   EGL_NO_CONTEXT,
                                   contextAttribs);
    if (app.context == EGL_NO_CONTEXT)
    {
        LOGE("eglCreateContext failed: 0x%x", eglGetError());
        return false;
    }
    const EGLint pbufferAttribs[] = {EGL_WIDTH, 16, EGL_HEIGHT, 16, EGL_NONE};
    app.pbuffer =
        eglCreatePbufferSurface(app.display, app.config, pbufferAttribs);
    if (!eglMakeCurrent(app.display, app.pbuffer, app.pbuffer, app.context))
    {
        LOGE("eglMakeCurrent failed: 0x%x", eglGetError());
        return false;
    }
    const char* exts = (const char*)glGetString(GL_EXTENSIONS);
    app.srgbWriteControl =
        exts != nullptr && strstr(exts, "GL_EXT_sRGB_write_control") != nullptr;
    LOGI("GL_RENDERER=%s GL_VERSION=%s sRGB_write_control=%d",
         (const char*)glGetString(GL_RENDERER),
         (const char*)glGetString(GL_VERSION),
         app.srgbWriteControl ? 1 : 0);
    return true;
}

bool initInput(App& app)
{
    for (int hand = 0; hand < 2; ++hand)
    {
        XR_CHECK(
            xrStringToPath(app.instance, kHandPaths[hand], &app.handPaths[hand]));
    }

    XrActionSetCreateInfo setInfo{XR_TYPE_ACTION_SET_CREATE_INFO};
    strcpy(setInfo.actionSetName, "main");
    strcpy(setInfo.localizedActionSetName, "Main");
    XR_CHECK(xrCreateActionSet(app.instance, &setInfo, &app.actionSet));

    auto makeAction = [&](const char* name, XrActionType type, XrAction* out) {
        XrActionCreateInfo info{XR_TYPE_ACTION_CREATE_INFO};
        info.actionType = type;
        strcpy(info.actionName, name);
        strcpy(info.localizedActionName, name);
        info.countSubactionPaths = 2;
        info.subactionPaths = app.handPaths;
        return xrCreateAction(app.actionSet, &info, out);
    };
    XR_CHECK(makeAction("grip_pose", XR_ACTION_TYPE_POSE_INPUT, &app.gripAction));
    XR_CHECK(makeAction("aim_pose", XR_ACTION_TYPE_POSE_INPUT, &app.aimAction));
    XR_CHECK(
        makeAction("trigger", XR_ACTION_TYPE_FLOAT_INPUT, &app.triggerAction));

    auto path = [&](const char* str) {
        XrPath p = XR_NULL_PATH;
        xrStringToPath(app.instance, str, &p);
        return p;
    };
    const XrActionSuggestedBinding bindings[] = {
        {app.gripAction, path("/user/hand/left/input/grip/pose")},
        {app.gripAction, path("/user/hand/right/input/grip/pose")},
        {app.aimAction, path("/user/hand/left/input/aim/pose")},
        {app.aimAction, path("/user/hand/right/input/aim/pose")},
        {app.triggerAction, path("/user/hand/left/input/trigger/value")},
        {app.triggerAction, path("/user/hand/right/input/trigger/value")},
    };
    XrInteractionProfileSuggestedBinding suggested{
        XR_TYPE_INTERACTION_PROFILE_SUGGESTED_BINDING};
    suggested.interactionProfile =
        path("/interaction_profiles/oculus/touch_controller");
    suggested.countSuggestedBindings =
        sizeof(bindings) / sizeof(bindings[0]);
    suggested.suggestedBindings = bindings;
    XR_CHECK(xrSuggestInteractionProfileBindings(app.instance, &suggested));

    for (int hand = 0; hand < 2; ++hand)
    {
        XrActionSpaceCreateInfo spaceInfo{XR_TYPE_ACTION_SPACE_CREATE_INFO};
        spaceInfo.subactionPath = app.handPaths[hand];
        spaceInfo.poseInActionSpace.orientation.w = 1.0f;
        spaceInfo.action = app.gripAction;
        XR_CHECK(
            xrCreateActionSpace(app.session, &spaceInfo, &app.gripSpaces[hand]));
        spaceInfo.action = app.aimAction;
        XR_CHECK(
            xrCreateActionSpace(app.session, &spaceInfo, &app.aimSpaces[hand]));
    }

    XrSessionActionSetsAttachInfo attach{XR_TYPE_SESSION_ACTION_SETS_ATTACH_INFO};
    attach.countActionSets = 1;
    attach.actionSets = &app.actionSet;
    XR_CHECK(xrAttachSessionActionSets(app.session, &attach));
    return true;
}

bool initOpenXR(App& app)
{
    PFN_xrInitializeLoaderKHR initializeLoader = nullptr;
    XR_CHECK(
        xrGetInstanceProcAddr(XR_NULL_HANDLE,
                              "xrInitializeLoaderKHR",
                              (PFN_xrVoidFunction*)&initializeLoader));
    XrLoaderInitInfoAndroidKHR loaderInit{XR_TYPE_LOADER_INIT_INFO_ANDROID_KHR};
    loaderInit.applicationVM = app.android->activity->vm;
    loaderInit.applicationContext = app.android->activity->clazz;
    XR_CHECK(initializeLoader((const XrLoaderInitInfoBaseHeaderKHR*)&loaderInit));

    const char* extensions[] = {XR_KHR_ANDROID_CREATE_INSTANCE_EXTENSION_NAME,
                                XR_KHR_OPENGL_ES_ENABLE_EXTENSION_NAME};
    XrInstanceCreateInfoAndroidKHR androidInfo{
        XR_TYPE_INSTANCE_CREATE_INFO_ANDROID_KHR};
    androidInfo.applicationVM = app.android->activity->vm;
    androidInfo.applicationActivity = app.android->activity->clazz;

    XrInstanceCreateInfo createInfo{XR_TYPE_INSTANCE_CREATE_INFO};
    createInfo.next = &androidInfo;
    createInfo.enabledExtensionCount = 2;
    createInfo.enabledExtensionNames = extensions;
    strcpy(createInfo.applicationInfo.applicationName, "Rive VR");
    createInfo.applicationInfo.applicationVersion = 1;
    strcpy(createInfo.applicationInfo.engineName, "rive-vr");
    createInfo.applicationInfo.engineVersion = 1;
    createInfo.applicationInfo.apiVersion = XR_API_VERSION_1_0;
    XR_CHECK(xrCreateInstance(&createInfo, &app.instance));

    XrInstanceProperties props{XR_TYPE_INSTANCE_PROPERTIES};
    xrGetInstanceProperties(app.instance, &props);
    LOGI("OpenXR runtime: %s %u.%u.%u",
         props.runtimeName,
         XR_VERSION_MAJOR(props.runtimeVersion),
         XR_VERSION_MINOR(props.runtimeVersion),
         XR_VERSION_PATCH(props.runtimeVersion));

    XrSystemGetInfo systemInfo{XR_TYPE_SYSTEM_GET_INFO};
    systemInfo.formFactor = XR_FORM_FACTOR_HEAD_MOUNTED_DISPLAY;
    XR_CHECK(xrGetSystem(app.instance, &systemInfo, &app.systemId));

    XrSystemProperties systemProps{XR_TYPE_SYSTEM_PROPERTIES};
    xrGetSystemProperties(app.instance, app.systemId, &systemProps);
    LOGI("System: %s", systemProps.systemName);

    PFN_xrGetOpenGLESGraphicsRequirementsKHR getRequirements = nullptr;
    XR_CHECK(xrGetInstanceProcAddr(app.instance,
                                   "xrGetOpenGLESGraphicsRequirementsKHR",
                                   (PFN_xrVoidFunction*)&getRequirements));
    XrGraphicsRequirementsOpenGLESKHR requirements{
        XR_TYPE_GRAPHICS_REQUIREMENTS_OPENGL_ES_KHR};
    XR_CHECK(getRequirements(app.instance, app.systemId, &requirements));

    XrGraphicsBindingOpenGLESAndroidKHR binding{
        XR_TYPE_GRAPHICS_BINDING_OPENGL_ES_ANDROID_KHR};
    binding.display = app.display;
    binding.config = app.config;
    binding.context = app.context;

    XrSessionCreateInfo sessionInfo{XR_TYPE_SESSION_CREATE_INFO};
    sessionInfo.next = &binding;
    sessionInfo.systemId = app.systemId;
    XR_CHECK(xrCreateSession(app.instance, &sessionInfo, &app.session));

    XrReferenceSpaceCreateInfo spaceInfo{XR_TYPE_REFERENCE_SPACE_CREATE_INFO};
    spaceInfo.referenceSpaceType = XR_REFERENCE_SPACE_TYPE_LOCAL;
    spaceInfo.poseInReferenceSpace.orientation.w = 1.0f;
    XR_CHECK(xrCreateReferenceSpace(app.session, &spaceInfo, &app.localSpace));
    if (!initInput(app))
    {
        return false;
    }

    // Floor-level space for the stereo scene (y = 0 is the floor).
    spaceInfo.referenceSpaceType = XR_REFERENCE_SPACE_TYPE_STAGE;
    if (XR_FAILED(
            xrCreateReferenceSpace(app.session, &spaceInfo, &app.stageSpace)))
    {
        LOGE("No STAGE space; falling back to LOCAL");
        app.stageSpace = app.localSpace;
    }

    // Per-eye resolution: the runtime's recommendation times
    // debug.rivevr.scale (default 1.0), for the G5 fill-cost sweep.
    uint32_t viewCount = 0;
    xrEnumerateViewConfigurationViews(app.instance,
                                      app.systemId,
                                      XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO,
                                      0,
                                      &viewCount,
                                      nullptr);
    std::vector<XrViewConfigurationView> configViews(
        viewCount,
        {XR_TYPE_VIEW_CONFIGURATION_VIEW});
    XR_CHECK(xrEnumerateViewConfigurationViews(
        app.instance,
        app.systemId,
        XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO,
        viewCount,
        &viewCount,
        configViews.data()));
    const float scale = sysPropFloat("debug.rivevr.scale", 1.0f);
    app.eyeWidth =
        (uint32_t)(configViews[0].recommendedImageRectWidth * scale) & ~1u;
    app.eyeHeight =
        (uint32_t)(configViews[0].recommendedImageRectHeight * scale) & ~1u;
    LOGI("Eye: recommended %ux%u, scale %.2f -> %ux%u",
         configViews[0].recommendedImageRectWidth,
         configViews[0].recommendedImageRectHeight,
         scale,
         app.eyeWidth,
         app.eyeHeight);
    return true;
}

bool createSwapchain(App& app, uint32_t width, uint32_t height)
{
    // Swapchain format: sRGB by default (what the Quest compositor expects).
    // `adb shell setprop debug.rivevr.srgb 0` switches to plain RGBA8 for the
    // G2 colour A/B.
    const bool wantSrgb = sysPropEnabled("debug.rivevr.srgb", true);
    uint32_t formatCount = 0;
    xrEnumerateSwapchainFormats(app.session, 0, &formatCount, nullptr);
    std::vector<int64_t> formats(formatCount);
    xrEnumerateSwapchainFormats(app.session,
                                formatCount,
                                &formatCount,
                                formats.data());
    const int64_t preferred = wantSrgb ? GL_SRGB8_ALPHA8 : GL_RGBA8;
    app.swapchainFormat = formats.empty() ? GL_RGBA8 : formats[0];
    for (int64_t f : formats)
    {
        if (f == preferred)
        {
            app.swapchainFormat = f;
        }
    }
    LOGI("Swapchain format: 0x%llx (wanted %s)",
         (long long)app.swapchainFormat,
         wantSrgb ? "sRGB" : "RGBA8");

    XrSwapchainCreateInfo swapInfo{XR_TYPE_SWAPCHAIN_CREATE_INFO};
    swapInfo.usageFlags = XR_SWAPCHAIN_USAGE_COLOR_ATTACHMENT_BIT |
                          XR_SWAPCHAIN_USAGE_SAMPLED_BIT;
    swapInfo.format = app.swapchainFormat;
    swapInfo.sampleCount = 1;
    swapInfo.width = width;
    swapInfo.height = height;
    swapInfo.faceCount = 1;
    swapInfo.arraySize = 1;
    swapInfo.mipCount = 1;
    XR_CHECK(xrCreateSwapchain(app.session, &swapInfo, &app.swapchain));

    uint32_t imageCount = 0;
    xrEnumerateSwapchainImages(app.swapchain, 0, &imageCount, nullptr);
    app.images.resize(imageCount, {XR_TYPE_SWAPCHAIN_IMAGE_OPENGL_ES_KHR});
    XR_CHECK(xrEnumerateSwapchainImages(
        app.swapchain,
        imageCount,
        &imageCount,
        (XrSwapchainImageBaseHeader*)app.images.data()));
    app.swapchainWidth = width;
    app.swapchainHeight = height;
    app.renderTarget =
        rive::make_rcp<rive::gpu::TextureRenderTargetGL>(width, height);
    LOGI("Swapchain: %u images, %ux%u", imageCount, width, height);
    return true;
}

bool readFile(const std::string& path, std::vector<uint8_t>& out)
{
    FILE* f = fopen(path.c_str(), "rb");
    if (f == nullptr)
    {
        return false;
    }
    fseek(f, 0, SEEK_END);
    long size = ftell(f);
    fseek(f, 0, SEEK_SET);
    out.resize(size > 0 ? (size_t)size : 0);
    size_t read = out.empty() ? 0 : fread(out.data(), 1, out.size(), f);
    fclose(f);
    return read == out.size();
}

bool initRive(App& app)
{
    app.rc = rive::gpu::RenderContextGLImpl::MakeContext();
    if (!app.rc)
    {
        LOGE("RenderContextGLImpl::MakeContext failed");
        return false;
    }
    rive::ore::Context* ore = app.rc->ore();
    if (ore == nullptr)
    {
        LOGE("No Ore context: GPU Canvas unavailable");
        return false;
    }
    app.riveSession = std::make_unique<rive::cmd::DeferredSession>(
        rive::ore::ReplayCaps::from(*ore));
    app.riveSession->bindRenderContext(app.rc.get());
    app.target = app.riveSession->acquireScreenTarget();
    app.host.bindSession(app.riveSession.get(), app.target);

    const std::string path =
        std::string(app.android->activity->externalDataPath) + "/scene.riv";
    std::vector<uint8_t> bytes;
    if (!readFile(path, bytes))
    {
        LOGE("Could not read %s (push one with tools/push.sh)", path.c_str());
        return false;
    }
    // Our own scripting VM so scripts get a 5 s budget per call instead of the
    // runtime's default 200 ms (decoding a model at init needs more).
    app.scriptingVM = rive::make_rcp<rive::ScriptingVM>(
        std::make_unique<rive::CPPRuntimeScriptingContext>(app.riveSession.get(),
                                                           5000));
    rive::ImportResult result;
    app.file = rive::File::import(bytes,
                                  app.riveSession.get(),
                                  &result,
                                  (rive::FileAssetLoader*)nullptr,
                                  app.scriptingVM.get());
    if (!app.file)
    {
        LOGE("File::import failed: %d", (int)result);
        return false;
    }
    app.artboard = app.file->artboardNamed("Main");
    app.stereo = app.artboard != nullptr;
    if (!app.artboard)
    {
        app.artboard = app.file->artboardDefault();
    }
    if (!app.artboard)
    {
        LOGE("No default artboard");
        return false;
    }
    app.stateMachine = app.artboard->defaultStateMachine();
    if (!app.stateMachine && app.artboard->stateMachineCount() > 0)
    {
        app.stateMachine = app.artboard->stateMachineAt(0);
    }
    if (rive::ViewModelRuntime* vm =
            app.file->defaultArtboardViewModel(app.artboard.get()))
    {
        app.viewModel = vm->createDefaultInstance();
        if (app.viewModel)
        {
            app.artboard->bindViewModelInstance(app.viewModel->instance());
            if (app.stateMachine)
            {
                app.stateMachine->bindViewModelInstance(
                    app.viewModel->instance());
            }
        }
    }
    if (app.stereo)
    {
        if (!app.viewModel)
        {
            LOGE("Main artboard has no ViewModel bound; expected XR");
            return false;
        }
        for (int eye = 0; eye < 2; ++eye)
        {
            for (int k = 0; k < 11; ++k)
            {
                const std::string name =
                    std::string(kEyeProps[eye]) + "_" + kPoseKeys[k];
                app.eyeProps[eye][k] = app.viewModel->propertyNumber(name);
                if (app.eyeProps[eye][k] == nullptr)
                {
                    LOGE("XR ViewModel is missing %s", name.c_str());
                    return false;
                }
            }
        }
        app.frameIndexProp = app.viewModel->propertyNumber("frameIndex");
        app.seenFrameProp = app.viewModel->propertyNumber("seenFrame");
        app.eyeWidthProp = app.viewModel->propertyNumber("eyeWidth");
        app.eyeHeightProp = app.viewModel->propertyNumber("eyeHeight");
        for (int hand = 0; hand < 2; ++hand)
        {
            const std::string h = kHandSuffix[hand];
            for (int k = 0; k < 7; ++k)
            {
                app.handProps[hand][k] = app.viewModel->propertyNumber(
                    "grip" + h + "_" + kControllerPoseKeys[k]);
                app.handProps[hand][7 + k] = app.viewModel->propertyNumber(
                    "aim" + h + "_" + kControllerPoseKeys[k]);
            }
            app.handProps[hand][14] =
                app.viewModel->propertyNumber("trigger" + h);
            app.handProps[hand][15] =
                app.viewModel->propertyNumber("active" + h);
        }
        if (app.eyeWidthProp)
            app.eyeWidthProp->value((float)app.eyeWidth);
        if (app.eyeHeightProp)
            app.eyeHeightProp->value((float)app.eyeHeight);
        // The artboard is the double-wide eye image, pixel for pixel.
        app.artboard->width((float)(app.eyeWidth * 2));
        app.artboard->height((float)app.eyeHeight);
    }
    LOGI("Loaded %s (%zu bytes): %s mode, artboard %.0fx%.0f, state machine %s",
         path.c_str(),
         bytes.size(),
         app.stereo ? "stereo" : "quad",
         app.artboard->width(),
         app.artboard->height(),
         app.stateMachine ? "yes" : "no");
    return app.stereo ? createSwapchain(app, app.eyeWidth * 2, app.eyeHeight)
                      : createSwapchain(app, kQuadPixels, kQuadPixels);
}

void handleSessionState(App& app, const XrEventDataSessionStateChanged& e)
{
    app.state = e.state;
    LOGI("Session state -> %d", (int)e.state);
    switch (e.state)
    {
        case XR_SESSION_STATE_READY:
        {
            XrSessionBeginInfo begin{XR_TYPE_SESSION_BEGIN_INFO};
            begin.primaryViewConfigurationType =
                XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO;
            if (XR_SUCCEEDED(xrBeginSession(app.session, &begin)))
            {
                app.sessionRunning = true;
            }
            break;
        }
        case XR_SESSION_STATE_STOPPING:
            xrEndSession(app.session);
            app.sessionRunning = false;
            break;
        case XR_SESSION_STATE_EXITING:
        case XR_SESSION_STATE_LOSS_PENDING:
            app.exitRequested = true;
            break;
        default:
            break;
    }
}

void pollXrEvents(App& app)
{
    XrEventDataBuffer event{XR_TYPE_EVENT_DATA_BUFFER};
    while (xrPollEvent(app.instance, &event) == XR_SUCCESS)
    {
        if (event.type == XR_TYPE_EVENT_DATA_SESSION_STATE_CHANGED)
        {
            handleSessionState(
                app,
                *reinterpret_cast<XrEventDataSessionStateChanged*>(&event));
        }
        else if (event.type == XR_TYPE_EVENT_DATA_INSTANCE_LOSS_PENDING)
        {
            app.exitRequested = true;
        }
        event = {XR_TYPE_EVENT_DATA_BUFFER};
    }
}

// Locates both eyes at the predicted display time and writes them into the
// XR ViewModel before the state machine advances, so this frame's draw uses
// this frame's poses. Returns false when tracking has no valid pose.
void setProp(rive::ViewModelInstanceNumberRuntime* prop, float value)
{
    if (prop != nullptr)
    {
        prop->value(value);
    }
}

// Syncs controller input and writes grip/aim poses and trigger values into
// the XR ViewModel, located at the same display time and space as the eyes.
void writeControllers(App& app, XrTime displayTime)
{
    XrActiveActionSet active{app.actionSet, XR_NULL_PATH};
    XrActionsSyncInfo syncInfo{XR_TYPE_ACTIONS_SYNC_INFO};
    syncInfo.countActiveActionSets = 1;
    syncInfo.activeActionSets = &active;
    xrSyncActions(app.session, &syncInfo);

    for (int hand = 0; hand < 2; ++hand)
    {
        XrSpaceLocation grip{XR_TYPE_SPACE_LOCATION};
        XrSpaceLocation aim{XR_TYPE_SPACE_LOCATION};
        xrLocateSpace(app.gripSpaces[hand], app.stageSpace, displayTime, &grip);
        xrLocateSpace(app.aimSpaces[hand], app.stageSpace, displayTime, &aim);
        const XrSpaceLocationFlags required =
            XR_SPACE_LOCATION_POSITION_VALID_BIT |
            XR_SPACE_LOCATION_ORIENTATION_VALID_BIT;
        const bool tracked = (grip.locationFlags & required) == required &&
                             (aim.locationFlags & required) == required;
        setProp(app.handProps[hand][15], tracked ? 1.0f : 0.0f);
        if (!tracked)
        {
            continue;
        }
        const XrPosef* poses[2] = {&grip.pose, &aim.pose};
        for (int p = 0; p < 2; ++p)
        {
            const XrPosef& pose = *poses[p];
            const float values[7] = {pose.position.x,
                                     pose.position.y,
                                     pose.position.z,
                                     pose.orientation.x,
                                     pose.orientation.y,
                                     pose.orientation.z,
                                     pose.orientation.w};
            for (int k = 0; k < 7; ++k)
            {
                setProp(app.handProps[hand][p * 7 + k], values[k]);
            }
        }

        XrActionStateGetInfo getInfo{XR_TYPE_ACTION_STATE_GET_INFO};
        getInfo.action = app.triggerAction;
        getInfo.subactionPath = app.handPaths[hand];
        XrActionStateFloat trigger{XR_TYPE_ACTION_STATE_FLOAT};
        xrGetActionStateFloat(app.session, &getInfo, &trigger);
        setProp(app.handProps[hand][14],
                trigger.isActive ? trigger.currentState : 0.0f);
    }
}

bool writeEyePoses(App& app, XrTime displayTime)
{
    XrViewLocateInfo locateInfo{XR_TYPE_VIEW_LOCATE_INFO};
    locateInfo.viewConfigurationType = XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO;
    locateInfo.displayTime = displayTime;
    locateInfo.space = app.stageSpace;
    XrViewState viewState{XR_TYPE_VIEW_STATE};
    uint32_t count = 0;
    app.views[0] = {XR_TYPE_VIEW};
    app.views[1] = {XR_TYPE_VIEW};
    if (XR_FAILED(xrLocateViews(app.session,
                                &locateInfo,
                                &viewState,
                                2,
                                &count,
                                app.views)) ||
        (viewState.viewStateFlags & XR_VIEW_STATE_POSITION_VALID_BIT) == 0 ||
        (viewState.viewStateFlags & XR_VIEW_STATE_ORIENTATION_VALID_BIT) == 0)
    {
        return false;
    }
    for (int eye = 0; eye < 2; ++eye)
    {
        const XrView& v = app.views[eye];
        const float values[11] = {v.pose.position.x,
                                  v.pose.position.y,
                                  v.pose.position.z,
                                  v.pose.orientation.x,
                                  v.pose.orientation.y,
                                  v.pose.orientation.z,
                                  v.pose.orientation.w,
                                  v.fov.angleLeft,
                                  v.fov.angleRight,
                                  v.fov.angleUp,
                                  v.fov.angleDown};
        for (int k = 0; k < 11; ++k)
        {
            app.eyeProps[eye][k]->value(values[k]);
        }
    }
    if (app.frameIndexProp != nullptr)
    {
        // The frame number replayRive is about to use.
        app.frameIndexProp->value((float)(app.frameNumber + 1));
    }
    return true;
}

// Records this frame's artboard into the deferred session.
void recordRive(App& app, float dt)
{
    if (app.stateMachine)
    {
        app.stateMachine->advanceAndApply(dt);
    }
    else
    {
        app.artboard->advance(dt);
    }

    app.riveSession->beginTargetFrame(app.target);
    app.host.beginRecord(true, 0xff000000u);
    rive::Renderer* renderer = app.host.screenRenderer();
    renderer->save();
    renderer->align(app.stereo ? rive::Fit::fill : rive::Fit::contain,
                    rive::Alignment::center,
                    rive::AABB(0,
                               0,
                               (float)app.swapchainWidth,
                               (float)app.swapchainHeight),
                    app.artboard->bounds());
    app.artboard->draw(renderer);
    renderer->restore();
    app.riveSession->endTargetFrame(app.target);
}

// Replays the recorded frame into the swapchain texture. Returns false if
// Rive had nothing to draw.
bool replayRive(App& app, GLuint texture)
{
    app.renderTarget->setTargetTexture(texture);
    if (app.srgbWriteControl)
    {
        // Rive writes gamma-encoded values; stop GL encoding them a second
        // time when the swapchain is sRGB.
        glDisable(GL_FRAMEBUFFER_SRGB_EXT);
    }
    SwapchainSink sink(app.rc.get(),
                       app.target,
                       app.swapchainWidth,
                       app.swapchainHeight);
    const uint64_t frame = ++app.frameNumber;
    return app.host.replayInline(sink, [&] {
        rive::gpu::RenderContext::FlushResources flush;
        flush.renderTarget = app.renderTarget.get();
        flush.currentFrameNumber = frame;
        flush.safeFrameNumber = frame > 3 ? frame - 3 : 0;
        app.rc->flush(flush);
    });
}

void renderFrame(App& app)
{
    XrFrameWaitInfo waitInfo{XR_TYPE_FRAME_WAIT_INFO};
    XrFrameState frameState{XR_TYPE_FRAME_STATE};
    if (XR_FAILED(xrWaitFrame(app.session, &waitInfo, &frameState)))
    {
        return;
    }
    XrFrameBeginInfo beginInfo{XR_TYPE_FRAME_BEGIN_INFO};
    xrBeginFrame(app.session, &beginInfo);

    const auto cpuStart = std::chrono::steady_clock::now();
    XrCompositionLayerQuad quad{XR_TYPE_COMPOSITION_LAYER_QUAD};
    XrCompositionLayerProjection projection{
        XR_TYPE_COMPOSITION_LAYER_PROJECTION};
    XrCompositionLayerProjectionView projViews[2] = {
        {XR_TYPE_COMPOSITION_LAYER_PROJECTION_VIEW},
        {XR_TYPE_COMPOSITION_LAYER_PROJECTION_VIEW}};
    const XrCompositionLayerBaseHeader* layers[1] = {};
    uint32_t layerCount = 0;

    if (frameState.shouldRender)
    {
        float dt = 1.0f / 72.0f;
        if (app.lastDisplayTime != 0)
        {
            dt = (float)((frameState.predictedDisplayTime -
                          app.lastDisplayTime) *
                         1e-9);
        }
        app.lastDisplayTime = frameState.predictedDisplayTime;

        bool posesValid = true;
        if (app.stereo)
        {
            posesValid = writeEyePoses(app, frameState.predictedDisplayTime);
            writeControllers(app, frameState.predictedDisplayTime);
        }

        recordRive(app, dt);

        if (app.stereo && app.seenFrameProp != nullptr)
        {
            app.g4Frames++;
            if (app.seenFrameProp->value() != (float)app.frameNumber + 1)
            {
                app.g4Stale++;
            }
        }

        uint32_t index = 0;
        XrSwapchainImageAcquireInfo acquireInfo{
            XR_TYPE_SWAPCHAIN_IMAGE_ACQUIRE_INFO};
        xrAcquireSwapchainImage(app.swapchain, &acquireInfo, &index);
        XrSwapchainImageWaitInfo imageWait{XR_TYPE_SWAPCHAIN_IMAGE_WAIT_INFO};
        imageWait.timeout = XR_INFINITE_DURATION;
        xrWaitSwapchainImage(app.swapchain, &imageWait);

        if (!replayRive(app, app.images[index].image))
        {
            static bool warned = false;
            if (!warned)
            {
                LOGE("Rive recorded nothing this frame");
                warned = true;
            }
        }

        XrSwapchainImageReleaseInfo releaseInfo{
            XR_TYPE_SWAPCHAIN_IMAGE_RELEASE_INFO};
        xrReleaseSwapchainImage(app.swapchain, &releaseInfo);

        if (app.stereo)
        {
            if (posesValid)
            {
                // Submit exactly the poses the script drew with, so
                // timewarp corrects from the right place.
                for (int eye = 0; eye < 2; ++eye)
                {
                    projViews[eye].pose = app.views[eye].pose;
                    projViews[eye].fov = app.views[eye].fov;
                    projViews[eye].subImage.swapchain = app.swapchain;
                    projViews[eye].subImage.imageRect = {
                        {(int32_t)(eye * app.eyeWidth), 0},
                        {(int32_t)app.eyeWidth, (int32_t)app.eyeHeight}};
                }
                projection.space = app.stageSpace;
                projection.viewCount = 2;
                projection.views = projViews;
                layers[0] = (const XrCompositionLayerBaseHeader*)&projection;
                layerCount = 1;
            }
        }
        else
        {
        quad.space = app.localSpace;
        quad.eyeVisibility = XR_EYE_VISIBILITY_BOTH;
        quad.subImage.swapchain = app.swapchain;
        quad.subImage.imageRect = {{0, 0},
                                   {(int32_t)kQuadPixels,
                                    (int32_t)kQuadPixels}};
        quad.pose.orientation.w = 1.0f;
        quad.pose.position = {0.0f, 0.0f, -kQuadDistance};
        quad.size = {kQuadMeters, kQuadMeters};
        layers[0] = (const XrCompositionLayerBaseHeader*)&quad;
        layerCount = 1;
        }
    }

    XrFrameEndInfo endInfo{XR_TYPE_FRAME_END_INFO};
    endInfo.displayTime = frameState.predictedDisplayTime;
    endInfo.environmentBlendMode = XR_ENVIRONMENT_BLEND_MODE_OPAQUE;
    endInfo.layerCount = layerCount;
    endInfo.layers = layers;
    xrEndFrame(app.session, &endInfo);

    const auto now = std::chrono::steady_clock::now();
    app.cpuMsThisSecond +=
        std::chrono::duration<double, std::milli>(now - cpuStart).count();
    app.framesThisSecond++;
    const double elapsed =
        std::chrono::duration<double>(now - app.secondStart).count();
    if (elapsed >= 1.0)
    {
        auto handState = [&](int hand) {
            auto* active = app.handProps[hand][15];
            auto* trigger = app.handProps[hand][14];
            auto* y = app.handProps[hand][1];
            return std::string(active && active->value() > 0.5f ? "on" : "off") +
                   " y=" + std::to_string(y ? y->value() : 0.0f).substr(0, 4) +
                   " trig=" +
                   std::to_string(trigger ? trigger->value() : 0.0f).substr(0, 4);
        };
        LOGI("fps=%.1f rive cpu=%.2fms/frame g4 stale=%llu/%llu | L %s | R %s",
             app.framesThisSecond / elapsed,
             app.cpuMsThisSecond / app.framesThisSecond,
             (unsigned long long)app.g4Stale,
             (unsigned long long)app.g4Frames,
             handState(0).c_str(),
             handState(1).c_str());
        app.framesThisSecond = 0;
        app.cpuMsThisSecond = 0;
        app.secondStart = now;
    }
}

void handleAppCmd(android_app* android, int32_t cmd)
{
    App& app = *static_cast<App*>(android->userData);
    switch (cmd)
    {
        case APP_CMD_RESUME:
            app.resumed = true;
            break;
        case APP_CMD_PAUSE:
            app.resumed = false;
            break;
        case APP_CMD_DESTROY:
            app.exitRequested = true;
            break;
        default:
            break;
    }
}
} // namespace

// Luau print() and script errors go to stdout/stderr, which Android drops.
// Pipe both into logcat under the "RiveScript" tag.
void startStdioLogging()
{
    static int fds[2];
    setvbuf(stdout, nullptr, _IOLBF, 0);
    setvbuf(stderr, nullptr, _IONBF, 0);
    if (pipe(fds) != 0)
    {
        return;
    }
    dup2(fds[1], STDOUT_FILENO);
    dup2(fds[1], STDERR_FILENO);
    pthread_t thread;
    pthread_create(
        &thread,
        nullptr,
        [](void*) -> void* {
            char buf[1024];
            std::string line;
            ssize_t n;
            while ((n = read(fds[0], buf, sizeof(buf))) > 0)
            {
                for (ssize_t i = 0; i < n; ++i)
                {
                    if (buf[i] == '\n')
                    {
                        __android_log_write(ANDROID_LOG_INFO, "RiveScript", line.c_str());
                        line.clear();
                    }
                    else
                    {
                        line += buf[i];
                    }
                }
            }
            return nullptr;
        },
        nullptr);
    pthread_detach(thread);
}

void android_main(android_app* android)
{
    App app;
    app.android = android;
    android->userData = &app;
    android->onAppCmd = handleAppCmd;

    startStdioLogging();
    LOGI("rive-vr starting");
    if (!initEGL(app) || !initOpenXR(app) || !initRive(app))
    {
        LOGE("Init failed, exiting");
        ANativeActivity_finish(android->activity);
    }

    while (!android->destroyRequested)
    {
        const int timeout =
            (!app.resumed && !app.sessionRunning && !app.exitRequested) ? -1
                                                                        : 0;
        android_poll_source* source = nullptr;
        if (ALooper_pollOnce(timeout, nullptr, nullptr, (void**)&source) >= 0 &&
            source != nullptr)
        {
            source->process(android, source);
        }
        if (app.instance == XR_NULL_HANDLE || app.exitRequested)
        {
            continue;
        }
        pollXrEvents(app);
        if (app.sessionRunning && app.artboard)
        {
            renderFrame(app);
        }
    }

    app.stateMachine.reset();
    app.artboard.reset();
    app.file = nullptr;
    if (app.swapchain != XR_NULL_HANDLE)
        xrDestroySwapchain(app.swapchain);
    if (app.localSpace != XR_NULL_HANDLE)
        xrDestroySpace(app.localSpace);
    if (app.session != XR_NULL_HANDLE)
        xrDestroySession(app.session);
    if (app.instance != XR_NULL_HANDLE)
        xrDestroyInstance(app.instance);
}
