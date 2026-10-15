cmake_minimum_required(VERSION 3.22)
project(rivevr CXX C)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

set(ROOT ${CMAKE_CURRENT_SOURCE_DIR}/..)
set(RIVE ${ROOT}/third_party/rive-runtime)
set(RIVE_OUT ${RIVE}/renderer/out/android_arm64_size CACHE PATH "Prebuilt runtime")
set(OPT_LEVEL Oz CACHE STRING "Optimization level for our code and LTO")
set(OPENXR ${ROOT}/third_party/openxr/aar/prefab/modules)
file(GLOB LUAU_VM_INCLUDE ${RIVE}/renderer/dependencies/*luau*/VM/include)

# Must match the defines rive-runtime was built with, or class layouts differ.
set(RIVE_DEFINES
    RIVE_ANDROID ORE_BACKEND_GL RIVE_ORE RIVE_CANVAS
    WITH_RIVE_SCRIPTING WITH_RIVE_SCRIPTING_LUAU _RIVE_INTERNAL_)

# Nothing we compile throws (Luau uses longjmp), so unwind tables are dead weight.
set(NO_UNWIND -fno-unwind-tables -fno-asynchronous-unwind-tables -fno-stack-protector)

add_library(native_app_glue STATIC
    ${ANDROID_NDK}/sources/android/native_app_glue/android_native_app_glue.c)
target_include_directories(native_app_glue PUBLIC
    ${ANDROID_NDK}/sources/android/native_app_glue)
target_compile_options(native_app_glue PRIVATE -${OPT_LEVEL} ${NO_UNWIND})

add_library(main SHARED
    ${ROOT}/src/main.cpp ${ROOT}/src/net.cpp ${ROOT}/src/xr_loader.cpp)
target_compile_definitions(main PRIVATE ${RIVE_DEFINES})
target_compile_options(main PRIVATE -${OPT_LEVEL} -flto -fno-exceptions -fno-rtti ${NO_UNWIND}
    -include ${RIVE}/scripting/rive_luau.hpp)
target_include_directories(main PRIVATE
    ${OPENXR}/headers/include
    ${RIVE}/include
    ${RIVE}/renderer/include
    ${RIVE}/decoders/include
    ${RIVE}/scripting
    ${LUAU_VM_INCLUDE})

target_link_options(main PRIVATE -${OPT_LEVEL} -flto -u ANativeActivity_onCreate
    -Wl,--gc-sections -Wl,--icf=safe -Wl,--pack-dyn-relocs=android+relr
    -Wl,--version-script=${CMAKE_CURRENT_SOURCE_DIR}/exports.map)
set_property(TARGET main APPEND PROPERTY LINK_DEPENDS ${CMAKE_CURRENT_SOURCE_DIR}/exports.map)
target_link_libraries(main PRIVATE
    native_app_glue
    ${RIVE_OUT}/librive_pls_renderer.a
    ${RIVE_OUT}/librive.a
    ${RIVE_OUT}/libluau_vm.a
    android log dl EGL GLESv3)
