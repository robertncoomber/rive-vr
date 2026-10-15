#include "xr_loader.hpp"

#include <openxr/openxr_loader_negotiation.h>

#include <android/log.h>
#include <dlfcn.h>
#include <climits>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>

#define TAG "RiveVR"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, TAG, __VA_ARGS__)

#define XR_DEFINE_FUNCTION(name) PFN_##name name = nullptr;
XR_DEFINE_FUNCTION(xrGetInstanceProcAddr)
XR_GLOBAL_FUNCTIONS(XR_DEFINE_FUNCTION)
XR_INSTANCE_FUNCTIONS(XR_DEFINE_FUNCTION)
#undef XR_DEFINE_FUNCTION

namespace
{
// The broker path uses the Android ABI name; manifest file names use the
// loader's XR_ARCH_ABI (Quest ships active_runtime.aarch64.json).
#if defined(__aarch64__)
constexpr char kAbi[] = "arm64-v8a";
constexpr char kArchAbi[] = "aarch64";
#elif defined(__arm__)
constexpr char kAbi[] = "armeabi-v7l";
constexpr char kArchAbi[] = "armv7a-vfp";
#elif defined(__x86_64__)
constexpr char kAbi[] = "x86_64";
constexpr char kArchAbi[] = "x86_64";
#else
constexpr char kAbi[] = "x86";
constexpr char kArchAbi[] = "i686";
#endif

struct Runtime
{
    void* library = nullptr;
    // A broker may rename the two entry points the loader dlsyms.
    std::string negotiateSymbol = "xrNegotiateLoaderRuntimeInterface";
    std::string initSymbol = "xrInitializeLoaderKHR";
};

bool clearException(JNIEnv* env)
{
    if (env->ExceptionCheck())
    {
        env->ExceptionClear();
        return true;
    }
    return false;
}

std::string toString(JNIEnv* env, jstring str)
{
    if (str == nullptr)
    {
        return {};
    }
    const char* chars = env->GetStringUTFChars(str, nullptr);
    std::string result = chars ? chars : "";
    env->ReleaseStringUTFChars(str, chars);
    return result;
}

// Minimal android.database.Cursor wrapper; local refs are freed by the caller's
// PushLocalFrame/PopLocalFrame.
struct Cursor
{
    JNIEnv* env;
    jobject cursor;
    jmethodID moveToNext;
    jmethodID getColumnIndex;
    jmethodID getString;
    jmethodID getInt;
    jmethodID close;

    bool next()
    {
        bool ok = env->CallBooleanMethod(cursor, moveToNext);
        return !clearException(env) && ok;
    }
    int column(const char* name)
    {
        jint index = env->CallIntMethod(cursor,
                                        getColumnIndex,
                                        env->NewStringUTF(name));
        return clearException(env) ? -1 : index;
    }
    std::string string(const char* name)
    {
        int index = column(name);
        if (index < 0)
        {
            return {};
        }
        auto value = (jstring)env->CallObjectMethod(cursor, getString, index);
        return clearException(env) ? std::string() : toString(env, value);
    }
    int integer(const char* name)
    {
        int index = column(name);
        if (index < 0)
        {
            return 0;
        }
        jint value = env->CallIntMethod(cursor, getInt, index);
        return clearException(env) ? 0 : value;
    }
    void finish()
    {
        env->CallVoidMethod(cursor, close);
        clearException(env);
    }
};

// ContentResolver.query(uri, columns, null, null, null). False when the
// provider is missing, throws, or returns no rows.
bool query(JNIEnv* env,
           jobject resolver,
           const std::string& uri,
           std::initializer_list<const char*> columns,
           Cursor& out)
{
    jclass uriClass = env->FindClass("android/net/Uri");
    jmethodID parse =
        env->GetStaticMethodID(uriClass,
                               "parse",
                               "(Ljava/lang/String;)Landroid/net/Uri;");
    jobject uriObject =
        env->CallStaticObjectMethod(uriClass,
                                    parse,
                                    env->NewStringUTF(uri.c_str()));
    if (clearException(env) || uriObject == nullptr)
    {
        return false;
    }

    jobjectArray projection =
        env->NewObjectArray((jsize)columns.size(),
                            env->FindClass("java/lang/String"),
                            nullptr);
    jsize i = 0;
    for (const char* column : columns)
    {
        env->SetObjectArrayElement(projection, i++, env->NewStringUTF(column));
    }

    jmethodID queryMethod = env->GetMethodID(
        env->GetObjectClass(resolver),
        "query",
        "(Landroid/net/Uri;[Ljava/lang/String;Ljava/lang/String;"
        "[Ljava/lang/String;Ljava/lang/String;)Landroid/database/Cursor;");
    jobject cursor = env->CallObjectMethod(resolver,
                                           queryMethod,
                                           uriObject,
                                           projection,
                                           nullptr,
                                           nullptr,
                                           nullptr);
    if (clearException(env) || cursor == nullptr)
    {
        LOGI("OpenXR broker: no answer from %s", uri.c_str());
        return false;
    }

    jclass cursorClass = env->FindClass("android/database/Cursor");
    out = {env,
           cursor,
           env->GetMethodID(cursorClass, "moveToNext", "()Z"),
           env->GetMethodID(cursorClass,
                            "getColumnIndex",
                            "(Ljava/lang/String;)I"),
           env->GetMethodID(cursorClass, "getString", "(I)Ljava/lang/String;"),
           env->GetMethodID(cursorClass, "getInt", "(I)I"),
           env->GetMethodID(cursorClass, "close", "()V")};
    jint count =
        env->CallIntMethod(cursor, env->GetMethodID(cursorClass, "getCount", "()I"));
    if (clearException(env) || count < 1)
    {
        out.finish();
        return false;
    }
    return true;
}

// Mirrors getActiveRuntimeVirtualManifest in the Khronos loader's
// android_utilities.cpp: installable broker first, then the system broker.
bool findBrokerRuntime(JNIEnv* env, jobject context, Runtime& out)
{
    jobject resolver = env->CallObjectMethod(
        context,
        env->GetMethodID(env->GetObjectClass(context),
                         "getContentResolver",
                         "()Landroid/content/ContentResolver;"));
    if (clearException(env) || resolver == nullptr)
    {
        return false;
    }

    for (const char* authority : {"org.khronos.openxr.runtime_broker",
                                  "org.khronos.openxr.system_runtime_broker"})
    {
        std::string base = std::string("content://") + authority + "/openxr/" +
                           std::to_string(XR_VERSION_MAJOR(XR_CURRENT_API_VERSION)) +
                           "/abi/" + kAbi + "/runtimes/";
        Cursor runtimes;
        if (!query(env,
                   resolver,
                   base + "active",
                   {"package_name", "native_lib_dir", "so_filename", "has_functions"},
                   runtimes))
        {
            continue;
        }
        while (runtimes.next())
        {
            std::string package = runtimes.string("package_name");
            std::string path = runtimes.string("native_lib_dir") + "/" +
                               runtimes.string("so_filename");
            bool hasFunctions = runtimes.integer("has_functions") == 1;
            void* library = dlopen(path.c_str(), RTLD_NOW | RTLD_LOCAL);
            if (library == nullptr)
            {
                LOGI("OpenXR broker: can't open %s", path.c_str());
                continue;
            }

            Runtime runtime;
            runtime.library = library;
            if (hasFunctions)
            {
                Cursor functions;
                if (!query(env,
                           resolver,
                           base + package + "/functions",
                           {"function_name", "symbol_name"},
                           functions))
                {
                    dlclose(library);
                    continue;
                }
                while (functions.next())
                {
                    std::string name = functions.string("function_name");
                    std::string symbol = functions.string("symbol_name");
                    if (name == "xrNegotiateLoaderRuntimeInterface")
                    {
                        runtime.negotiateSymbol = symbol;
                    }
                    else if (name == "xrInitializeLoaderKHR")
                    {
                        runtime.initSymbol = symbol;
                    }
                }
                functions.finish();
            }
            runtimes.finish();
            LOGI("OpenXR runtime %s from %s", path.c_str(), authority);
            out = runtime;
            return true;
        }
        runtimes.finish();
    }
    return false;
}

// Pulls the "library_path" string out of a runtime manifest. The manifest is a
// small, flat JSON file, so a key search is enough.
std::string manifestLibraryPath(const std::string& json)
{
    size_t key = json.find("\"library_path\"");
    if (key == std::string::npos)
    {
        return {};
    }
    size_t open = json.find('"', json.find(':', key));
    if (open == std::string::npos)
    {
        return {};
    }
    std::string value;
    for (size_t i = open + 1; i < json.size() && json[i] != '"'; ++i)
    {
        if (json[i] == '\\' && i + 1 < json.size())
        {
            ++i;
        }
        value += json[i];
    }
    return value;
}

// Mirrors PlatformGetGlobalRuntimeFileName: /<partition>/etc/openxr/<major>/.
bool findManifestRuntime(Runtime& out)
{
    for (const char* partition : {"/product", "/odm", "/oem", "/vendor", "/system"})
    {
        std::string dir = std::string(partition) + "/etc/openxr/" +
                          std::to_string(XR_VERSION_MAJOR(XR_CURRENT_API_VERSION)) +
                          "/";
        for (std::string name : {std::string("active_runtime.") + kArchAbi + ".json",
                                 std::string("active_runtime.json")})
        {
            std::string manifest = dir + name;
            FILE* file = fopen(manifest.c_str(), "rb");
            if (file == nullptr)
            {
                continue;
            }
            std::string json;
            char buffer[1024];
            size_t read;
            while ((read = fread(buffer, 1, sizeof(buffer), file)) > 0)
            {
                json.append(buffer, read);
            }
            fclose(file);

            std::string path = manifestLibraryPath(json);
            // A bare file name goes through the library search path; a
            // relative path is relative to the (resolved) manifest.
            if (path.find('/') != std::string::npos && path[0] != '/')
            {
                char resolved[PATH_MAX];
                std::string real =
                    realpath(manifest.c_str(), resolved) ? resolved : manifest;
                path = real.substr(0, real.rfind('/') + 1) + path;
            }
            void* library =
                path.empty() ? nullptr : dlopen(path.c_str(), RTLD_NOW | RTLD_LOCAL);
            if (library == nullptr)
            {
                LOGE("OpenXR manifest %s: can't open '%s'",
                     manifest.c_str(),
                     path.c_str());
                return false;
            }
            LOGI("OpenXR runtime %s from %s", path.c_str(), manifest.c_str());
            out.library = library;
            return true;
        }
    }
    return false;
}

// Mirrors RuntimeInterface::LoadRuntime.
XrResult negotiate(const Runtime& runtime, const XrLoaderInitInfoAndroidKHR& init)
{
    auto header = (const XrLoaderInitInfoBaseHeaderKHR*)&init;
    auto exportedInit = (PFN_xrInitializeLoaderKHR)dlsym(runtime.library,
                                                         runtime.initSymbol.c_str());
    if (exportedInit != nullptr)
    {
        XrResult result = exportedInit(header);
        if (XR_FAILED(result))
        {
            return result;
        }
    }

    auto negotiateFn = (PFN_xrNegotiateLoaderRuntimeInterface)dlsym(
        runtime.library,
        runtime.negotiateSymbol.c_str());
    if (negotiateFn == nullptr)
    {
        LOGE("OpenXR runtime has no %s", runtime.negotiateSymbol.c_str());
        return XR_ERROR_RUNTIME_UNAVAILABLE;
    }
    XrNegotiateLoaderInfo loaderInfo{};
    loaderInfo.structType = XR_LOADER_INTERFACE_STRUCT_LOADER_INFO;
    loaderInfo.structVersion = XR_LOADER_INFO_STRUCT_VERSION;
    loaderInfo.structSize = sizeof(XrNegotiateLoaderInfo);
    loaderInfo.minInterfaceVersion = 1;
    loaderInfo.maxInterfaceVersion = XR_CURRENT_LOADER_RUNTIME_VERSION;
    loaderInfo.minApiVersion = XR_MAKE_VERSION(1, 0, 0);
    loaderInfo.maxApiVersion = XR_MAKE_VERSION(1, 0x3ff, 0xfff);
    XrNegotiateRuntimeRequest request{};
    request.structType = XR_LOADER_INTERFACE_STRUCT_RUNTIME_REQUEST;
    request.structVersion = XR_RUNTIME_INFO_STRUCT_VERSION;
    request.structSize = sizeof(XrNegotiateRuntimeRequest);
    XrResult result = negotiateFn(&loaderInfo, &request);
    if (XR_FAILED(result) || request.getInstanceProcAddr == nullptr ||
        request.runtimeInterfaceVersion < 1 ||
        request.runtimeInterfaceVersion > XR_CURRENT_LOADER_RUNTIME_VERSION)
    {
        LOGE("OpenXR runtime negotiation failed: %d", (int)result);
        return XR_FAILED(result) ? result : XR_ERROR_RUNTIME_FAILURE;
    }
    xrGetInstanceProcAddr = request.getInstanceProcAddr;

    if (exportedInit == nullptr)
    {
        PFN_xrInitializeLoaderKHR queriedInit = nullptr;
        if (XR_SUCCEEDED(xrGetInstanceProcAddr(XR_NULL_HANDLE,
                                               "xrInitializeLoaderKHR",
                                               (PFN_xrVoidFunction*)&queriedInit)) &&
            queriedInit != nullptr)
        {
            result = queriedInit(header);
            if (XR_FAILED(result))
            {
                return result;
            }
        }
    }
    return XR_SUCCESS;
}

XrResult resolve(XrInstance instance, const char* name, PFN_xrVoidFunction* out)
{
    XrResult result = xrGetInstanceProcAddr(instance, name, out);
    if (XR_SUCCEEDED(result) && *out == nullptr)
    {
        result = XR_ERROR_FUNCTION_UNSUPPORTED;
    }
    if (XR_FAILED(result))
    {
        LOGE("OpenXR runtime is missing %s: %d", name, (int)result);
    }
    return result;
}
} // namespace

XrResult xrLoaderInitialize(JavaVM* vm, jobject context)
{
    JNIEnv* env = nullptr;
    if (vm->GetEnv((void**)&env, JNI_VERSION_1_6) != JNI_OK &&
        vm->AttachCurrentThread(&env, nullptr) != JNI_OK)
    {
        return XR_ERROR_INITIALIZATION_FAILED;
    }

    Runtime runtime;
    env->PushLocalFrame(64);
    bool found = findBrokerRuntime(env, context, runtime);
    env->PopLocalFrame(nullptr);
    if (!found && !findManifestRuntime(runtime))
    {
        LOGE("No OpenXR runtime found");
        return XR_ERROR_RUNTIME_UNAVAILABLE;
    }

    XrLoaderInitInfoAndroidKHR init{XR_TYPE_LOADER_INIT_INFO_ANDROID_KHR};
    init.applicationVM = vm;
    init.applicationContext = context;
    XrResult result = negotiate(runtime, init);
    if (XR_FAILED(result))
    {
        return result;
    }

#define XR_RESOLVE_GLOBAL(name)                                                \
    if (XR_FAILED(result = resolve(XR_NULL_HANDLE,                             \
                                   #name,                                      \
                                   (PFN_xrVoidFunction*)&name)))               \
    {                                                                          \
        return result;                                                         \
    }
    XR_GLOBAL_FUNCTIONS(XR_RESOLVE_GLOBAL)
#undef XR_RESOLVE_GLOBAL
    return XR_SUCCESS;
}

XrResult xrLoaderLoadInstanceFunctions(XrInstance instance)
{
    XrResult result;
#define XR_RESOLVE_INSTANCE(name)                                              \
    if (XR_FAILED(result = resolve(instance,                                   \
                                   #name,                                      \
                                   (PFN_xrVoidFunction*)&name)))               \
    {                                                                          \
        return result;                                                         \
    }
    XR_INSTANCE_FUNCTIONS(XR_RESOLVE_INSTANCE)
#undef XR_RESOLVE_INSTANCE
    return XR_SUCCESS;
}
