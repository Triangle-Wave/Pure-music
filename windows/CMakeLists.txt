# Project-level configuration.
cmake_minimum_required(VERSION 3.14)
project(pure_music LANGUAGES CXX)

# The name of the executable created for the application. Change this to change
# the on-disk name of your application.
set(BINARY_NAME "pure_music")

# Explicitly opt in to modern CMake behaviors to avoid warnings with recent
# versions of CMake.
cmake_policy(VERSION 3.14...3.25)

# Define build configuration option.
get_property(IS_MULTICONFIG GLOBAL PROPERTY GENERATOR_IS_MULTI_CONFIG)
if(IS_MULTICONFIG)
  set(CMAKE_CONFIGURATION_TYPES "Debug;Profile;Release"
    CACHE STRING "" FORCE)
else()
  if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
    set(CMAKE_BUILD_TYPE "Debug" CACHE
      STRING "Flutter build mode" FORCE)
    set_property(CACHE CMAKE_BUILD_TYPE PROPERTY STRINGS
      "Debug" "Profile" "Release")
  endif()
endif()
# Define settings for the Profile build mode.
set(CMAKE_EXE_LINKER_FLAGS_PROFILE "${CMAKE_EXE_LINKER_FLAGS_RELEASE}")
set(CMAKE_SHARED_LINKER_FLAGS_PROFILE "${CMAKE_SHARED_LINKER_FLAGS_RELEASE}")
set(CMAKE_C_FLAGS_PROFILE "${CMAKE_C_FLAGS_RELEASE}")
set(CMAKE_CXX_FLAGS_PROFILE "${CMAKE_CXX_FLAGS_RELEASE}")

# Use Unicode for all projects.
add_definitions(-DUNICODE -D_UNICODE)

# MSVC 并行编译，缩短 C++/插件编译时间。
if(MSVC)
  add_compile_options(/MP)
endif()

# Compilation settings that should be applied to most targets.
#
# Be cautious about adding new options here, as plugins use this function by
# default. In most cases, you should add new options to specific targets instead
# of modifying this function.
function(APPLY_STANDARD_SETTINGS TARGET)
  target_compile_features(${TARGET} PUBLIC cxx_std_17)
  target_compile_options(${TARGET} PRIVATE /W4 /WX /wd"4100" /utf-8)
  target_compile_options(${TARGET} PRIVATE /EHsc)
  target_compile_definitions(${TARGET} PRIVATE "_HAS_EXCEPTIONS=0")
  target_compile_definitions(${TARGET} PRIVATE "$<$<CONFIG:Debug>:_DEBUG>")
endfunction()

# Flutter library and tool build rules.
set(FLUTTER_MANAGED_DIR "${CMAKE_CURRENT_SOURCE_DIR}/flutter")
add_subdirectory(${FLUTTER_MANAGED_DIR})

# Application build; see runner/CMakeLists.txt.
add_subdirectory("runner")


# Generated plugin build rules, which manage building the plugins and adding
# them to the application.
include(flutter/generated_plugins.cmake)


# === Installation ===
# Support files are copied into place next to the executable, so that it can
# run in place. This is done instead of making a separate bundle (as on Linux)
# so that building and running from within Visual Studio will work.
set(BUILD_BUNDLE_DIR "$<TARGET_FILE_DIR:${BINARY_NAME}>")
# Make the "install" step default, as it's required to run.
set(CMAKE_VS_INCLUDE_INSTALL_TO_DEFAULT_BUILD 1)
if(CMAKE_INSTALL_PREFIX_INITIALIZED_TO_DEFAULT)
  set(CMAKE_INSTALL_PREFIX "${BUILD_BUNDLE_DIR}" CACHE PATH "..." FORCE)
endif()

set(INSTALL_BUNDLE_DATA_DIR "${CMAKE_INSTALL_PREFIX}/data")
set(INSTALL_BUNDLE_LIB_DIR "${CMAKE_INSTALL_PREFIX}")

install(TARGETS ${BINARY_NAME} RUNTIME DESTINATION "${CMAKE_INSTALL_PREFIX}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_ICU_DATA_FILE}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
  COMPONENT Runtime)

if(PLUGIN_BUNDLED_LIBRARIES)
  install(FILES "${PLUGIN_BUNDLED_LIBRARIES}"
    DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime)
endif()

# Copy the native assets provided by the build.dart from all packages.
set(NATIVE_ASSETS_DIR "${PROJECT_BUILD_DIR}native_assets/windows/")
install(DIRECTORY "${NATIVE_ASSETS_DIR}"
   DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
   COMPONENT Runtime)

# Fully re-copy the assets directory on each build to avoid having stale files
# from a previous install.
set(FLUTTER_ASSET_DIR_NAME "flutter_assets")
option(PURE_MUSIC_CLEAN_ASSETS_ON_INSTALL "Delete flutter_assets before install" OFF)
if(PURE_MUSIC_CLEAN_ASSETS_ON_INSTALL)
  install(CODE "
    file(REMOVE_RECURSE \"${INSTALL_BUNDLE_DATA_DIR}/${FLUTTER_ASSET_DIR_NAME}\")
    " COMPONENT Runtime)
endif()
install(DIRECTORY "${PROJECT_BUILD_DIR}/${FLUTTER_ASSET_DIR_NAME}"
  DESTINATION "${INSTALL_BUNDLE_DATA_DIR}" COMPONENT Runtime)

# Install the AOT library on non-Debug builds only.
install(FILES "${AOT_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  CONFIGURATIONS Profile;Release
  COMPONENT Runtime)

# Install BASS audio library & plugins (required at runtime)
file(GLOB BASS_PLUGINS CONFIGURE_DEPENDS "${CMAKE_SOURCE_DIR}/../BASS/*.dll")
install(FILES ${BASS_PLUGINS}
    DESTINATION "${INSTALL_BUNDLE_LIB_DIR}/dll/BASS"
    COMPONENT Runtime)

# Install desktop_lyric (required at runtime)
install(DIRECTORY "${CMAKE_SOURCE_DIR}/../desktop_lyric/"
    DESTINATION "${INSTALL_BUNDLE_LIB_DIR}/desktop_lyric"
    COMPONENT Runtime)

# Install BASS_FFMPEG plugin and its FFmpeg shared libraries (TAK native decoding).
# The bundle is prepared by tool/ffmpeg/fetch_ffmpeg.ps1 (official plugin release)
# and optionally tool/ffmpeg/build_minimal_ffmpeg.sh (trimmed FFmpeg shared build).
# DLLs live next to bass.dll so the Windows loader resolves their imports in place.
set(BASS_FFMPEG_BUNDLE_DIR "${CMAKE_SOURCE_DIR}/../tool/ffmpeg/runtime")
set(BASS_FFMPEG_RUNTIME_DLLS
    bass_ffmpeg.dll
    avcodec-62.dll
    avformat-62.dll
    avutil-60.dll
    swresample-6.dll)
set(BASS_FFMPEG_MISSING "")
set(BASS_FFMPEG_RUNTIME_PATHS "")
foreach(FFMPEG_DLL IN LISTS BASS_FFMPEG_RUNTIME_DLLS)
  set(FFMPEG_DLL_PATH "${BASS_FFMPEG_BUNDLE_DIR}/${FFMPEG_DLL}")
  if(NOT EXISTS "${FFMPEG_DLL_PATH}")
    list(APPEND BASS_FFMPEG_MISSING "${FFMPEG_DLL}")
  else()
    list(APPEND BASS_FFMPEG_RUNTIME_PATHS "${FFMPEG_DLL_PATH}")
  endif()
endforeach()
if(BASS_FFMPEG_MISSING)
  message(FATAL_ERROR
    "BASS_FFMPEG runtime is incomplete in ${BASS_FFMPEG_BUNDLE_DIR}: ${BASS_FFMPEG_MISSING}. "
    "Run tool/ffmpeg/fetch_ffmpeg.ps1 (bundled) or tool/ffmpeg/build_minimal_ffmpeg.sh (trimmed) before building.")
endif()
install(FILES ${BASS_FFMPEG_RUNTIME_PATHS}
    DESTINATION "${INSTALL_BUNDLE_LIB_DIR}/dll/BASS"
    COMPONENT Runtime)
foreach(FFMPEG_DOC LICENSE README-ffmpeg.txt THIRD-PARTY-NOTICES.txt)
  if(EXISTS "${BASS_FFMPEG_BUNDLE_DIR}/${FFMPEG_DOC}")
    install(FILES "${BASS_FFMPEG_BUNDLE_DIR}/${FFMPEG_DOC}"
        DESTINATION "${INSTALL_BUNDLE_LIB_DIR}/ffmpeg"
        COMPONENT Runtime)
  endif()
endforeach()
