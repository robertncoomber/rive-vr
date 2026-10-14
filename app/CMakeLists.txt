cmake_minimum_required(VERSION 3.22)
project(rivevr CXX C)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

set(ROOT ${CMAKE_CURRENT_SOURCE_DIR}/..)
set(RIVE ${ROOT}/third_party/rive-runtime)
set(RIVE_OUT ${RIVE}/renderer/out/android_arm64_release)
set(OPENXR ${ROOT}/third_party/openxr/aar/prefab/modules)
file(GLOB LUAU_VM_INCLUDE ${RIVE}/renderer/dependencies/*luau*/VM/include)

# Must match the defines rive-runtime was built with, or class layouts differ.
set(RIVE_DEFINES
    RIVE_ANDROID ORE_BACKEND_GL RIVE_ORE RIVE_CANVAS
    WITH_RIVE_TEXT WITH_RIVE_LAYOUT WITH_RIVE_SCRIPTING WITH_RIVE_SCRIPTING_LUAU
    RIVE_DECODERS YOGA_EXPORT= _RIVE_INTERNAL_)

add_library(native_app_glue STATIC
    ${ANDROID_NDK}/sources/android/native_app_glue/android_native_app_glue.c)
target_include_directories(native_app_glue PUBLIC
    ${ANDROID_NDK}/sources/android/native_app_glue)

add_library(openxr_loader SHARED IMPORTED)
set_target_properties(openxr_loader PROPERTIES
    IMPORTED_LOCATION ${OPENXR}/openxr_loader/libs/android.arm64-v8a/libopenxr_loader.so)

add_library(main SHARED ${ROOT}/src/main.cpp ${ROOT}/src/net.cpp)
target_compile_definitions(main PRIVATE ${RIVE_DEFINES})
target_compile_options(main PRIVATE -flto -fno-exceptions -fno-rtti
    -include ${RIVE}/scripting/rive_luau.hpp)
target_include_directories(main PRIVATE
    ${OPENXR}/headers/include
    ${RIVE}/include
    ${RIVE}/renderer/include
    ${RIVE}/decoders/include
    ${RIVE}/scripting
    ${LUAU_VM_INCLUDE})

target_link_options(main PRIVATE -flto -u ANativeActivity_onCreate)
target_link_libraries(main PRIVATE
    native_app_glue
    openxr_loader
    ${RIVE_OUT}/librive_pls_renderer.a
    ${RIVE_OUT}/librive.a
    ${RIVE_OUT}/librive_decoders.a
    ${RIVE_OUT}/librive_harfbuzz.a
    ${RIVE_OUT}/librive_sheenbidi.a
    ${RIVE_OUT}/librive_yoga.a
    ${RIVE_OUT}/libluau_vm.a
    ${RIVE_OUT}/liblibpng.a
    ${RIVE_OUT}/liblibjpeg.a
    ${RIVE_OUT}/liblibwebp.a
    ${RIVE_OUT}/libzlib.a
    android log EGL GLESv3)
