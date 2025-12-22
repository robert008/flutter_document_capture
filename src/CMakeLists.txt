cmake_minimum_required(VERSION 3.10)
project(flutter_document_capture_library VERSION 0.1.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Source files
set(SOURCES
    ffi_bridge.cpp
    capture_engine.cpp
    document_detector.cpp
    perspective_corrector.cpp
    quality_assessor.cpp
    image_enhancer.cpp
)

# Header directories
set(INCLUDE_DIRS
    ${CMAKE_CURRENT_SOURCE_DIR}
)

# For Android NDK build
if(ANDROID)
    # Use local OpenCV headers and pre-built library (same as flutter_ocr_kit)
    set(OPENCV_INCLUDE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../android/src/main/cpp/include")
    set(OPENCV_LIB_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../android/src/main/jniLibs/${ANDROID_ABI}")

    message(STATUS "OpenCV include dir: ${OPENCV_INCLUDE_DIR}")
    message(STATUS "OpenCV lib dir: ${OPENCV_LIB_DIR}")

    # Import pre-built OpenCV shared library
    add_library(opencv_java4 SHARED IMPORTED)
    set_target_properties(opencv_java4 PROPERTIES
        IMPORTED_LOCATION "${OPENCV_LIB_DIR}/libopencv_java4.so"
    )

    add_library(flutter_document_capture SHARED ${SOURCES})

    target_include_directories(flutter_document_capture PRIVATE
        ${INCLUDE_DIRS}
        ${OPENCV_INCLUDE_DIR}
    )

    target_link_libraries(flutter_document_capture
        opencv_java4
        log
    )

    # Support Android 15 16k page size
    target_link_options(flutter_document_capture PRIVATE "-Wl,-z,max-page-size=16384")

    set_target_properties(flutter_document_capture PROPERTIES
        OUTPUT_NAME "flutter_document_capture"
    )
endif()

# For iOS build (static library, linked via podspec)
if(IOS)
    # Use local OpenCV headers (framework provided via podspec)
    set(OPENCV_INCLUDE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../ios/Frameworks/opencv2.framework/Headers")

    add_library(flutter_document_capture STATIC ${SOURCES})

    target_include_directories(flutter_document_capture PRIVATE
        ${INCLUDE_DIRS}
        ${OPENCV_INCLUDE_DIR}
    )

    # OpenCV framework will be linked via podspec vendored_frameworks
    set_target_properties(flutter_document_capture PROPERTIES
        OUTPUT_NAME "flutter_document_capture"
    )
endif()

# For desktop build (macOS/Linux - testing/development)
if(NOT ANDROID AND NOT IOS)
    find_package(OpenCV REQUIRED)

    message(STATUS "OpenCV found: ${OpenCV_VERSION}")
    message(STATUS "OpenCV include dirs: ${OpenCV_INCLUDE_DIRS}")

    add_library(flutter_document_capture SHARED ${SOURCES})

    target_include_directories(flutter_document_capture PRIVATE
        ${INCLUDE_DIRS}
        ${OpenCV_INCLUDE_DIRS}
    )

    target_link_libraries(flutter_document_capture
        ${OpenCV_LIBS}
    )

    set_target_properties(flutter_document_capture PROPERTIES
        OUTPUT_NAME "flutter_document_capture"
    )

    # Build test executable for desktop
    add_executable(test_capture
        test_main.cpp
        capture_engine.cpp
        document_detector.cpp
        perspective_corrector.cpp
        quality_assessor.cpp
        image_enhancer.cpp
    )

    target_include_directories(test_capture PRIVATE
        ${INCLUDE_DIRS}
        ${OpenCV_INCLUDE_DIRS}
    )

    target_link_libraries(test_capture
        ${OpenCV_LIBS}
    )
endif()

target_compile_definitions(flutter_document_capture PUBLIC DART_SHARED_LIB)
