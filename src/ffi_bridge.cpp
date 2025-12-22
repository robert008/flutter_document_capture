#include <cstdlib>
#include <cstring>
#include <cstdio>
#include <cstdarg>
#include <string>

#include "capture_engine.hpp"

#ifdef __ANDROID__
#include <android/log.h>
#define LOG_TAG "DocumentCapture"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)
#else
#define LOGI(...) do {} while(0)
#define LOGE(...) do {} while(0)
#endif

// FFI export macro
#if defined(_WIN32)
#define FFI_EXPORT __declspec(dllexport)
#else
#define FFI_EXPORT __attribute__((visibility("default")))
#endif

extern "C" {

// Create capture engine instance
FFI_EXPORT
void* capture_engine_create() {
    LOGI("Creating CaptureEngine");
    return new CaptureEngine();
}

// Destroy capture engine instance
FFI_EXPORT
void capture_engine_destroy(void* engine) {
    if (engine) {
        LOGI("Destroying CaptureEngine");
        delete static_cast<CaptureEngine*>(engine);
    }
}

// Reset engine state (clear stability history)
FFI_EXPORT
void capture_engine_reset(void* engine) {
    if (engine) {
        static_cast<CaptureEngine*>(engine)->reset();
    }
}

// Helper to append formatted string
static void append_fmt(std::string& s, const char* fmt, ...) {
    char buf[256];
    va_list args;
    va_start(args, fmt);
    vsnprintf(buf, sizeof(buf), fmt, args);
    va_end(args);
    s += buf;
}

// Analyze a single frame (Stage 1: real-time)
// Returns JSON string with analysis results
FFI_EXPORT
char* analyze_frame(
    void* engine,
    const uint8_t* image_data,
    int width,
    int height,
    int format,  // 0: BGRA, 1: BGR, 2: RGB
    int rotation, // 0: none, 90: clockwise, 180, 270: counter-clockwise
    int crop_x,   // Crop region after rotation (0 for no crop)
    int crop_y,
    int crop_w,
    int crop_h
) {
    if (!engine || !image_data) {
        return strdup("{\"error\":\"Invalid parameters\"}");
    }

    CaptureEngine* eng = static_cast<CaptureEngine*>(engine);
    FrameAnalysisResult result = eng->analyzeFrame(image_data, width, height, format, rotation,
                                                    crop_x, crop_y, crop_w, crop_h);

    // Build JSON response using std::string (avoids ABI issues with ostringstream)
    std::string json;
    json.reserve(2048);

    json += "{";
    json += result.document_found ? "\"document_found\":true," : "\"document_found\":false,";
    json += result.table_found ? "\"table_found\":true," : "\"table_found\":false,";
    append_fmt(json, "\"debug_corner_conf\":%.4f,", result.corner_confidence);
    json += result.text_region_found ? "\"text_region_found\":true," : "\"text_region_found\":false,";

    json += "\"corners\":[";
    for (int i = 0; i < 8; i++) {
        append_fmt(json, "%.2f", result.corners[i]);
        if (i < 7) json += ",";
    }
    json += "],";

    append_fmt(json, "\"corner_confidence\":%.4f,", result.corner_confidence);
    append_fmt(json, "\"blur_score\":%.4f,", result.blur_score);
    append_fmt(json, "\"brightness_score\":%.4f,", result.brightness_score);
    append_fmt(json, "\"stability_score\":%.4f,", result.stability_score);
    append_fmt(json, "\"overall_score\":%.4f,", result.overall_score);
    json += result.capture_ready ? "\"capture_ready\":true," : "\"capture_ready\":false,";

    // Table/Trapezoid data
    json += result.is_trapezoid ? "\"is_trapezoid\":true," : "\"is_trapezoid\":false,";
    append_fmt(json, "\"skew_ratio\":%.4f,", result.skew_ratio);
    append_fmt(json, "\"top_width\":%.2f,", result.top_width);
    append_fmt(json, "\"bottom_width\":%.2f,", result.bottom_width);
    append_fmt(json, "\"left_height\":%.2f,", result.left_height);
    append_fmt(json, "\"right_height\":%.2f,", result.right_height);
    append_fmt(json, "\"vertical_skew\":%.4f,", result.vertical_skew);
    append_fmt(json, "\"horizontal_skew\":%.4f,", result.horizontal_skew);

    // Multiple text regions data
    append_fmt(json, "\"text_region_count\":%d,", result.text_region_count);
    append_fmt(json, "\"coverage_ratio\":%.4f,", result.coverage_ratio);

    json += "\"overall_bounds\":[";
    for (int i = 0; i < 4; i++) {
        append_fmt(json, "%.2f", result.overall_bounds[i]);
        if (i < 3) json += ",";
    }
    json += "],";

    json += "\"text_regions\":[";
    for (int i = 0; i < result.text_region_count; i++) {
        json += "[";
        for (int j = 0; j < 4; j++) {
            append_fmt(json, "%.2f", result.text_regions_bounds[i * 4 + j]);
            if (j < 3) json += ",";
        }
        json += "]";
        if (i < result.text_region_count - 1) json += ",";
    }
    json += "]";
    json += "}";

    return strdup(json.c_str());
}

// Enhance captured image (Stage 2: post-capture)
// Returns pointer to EnhancementResult struct
FFI_EXPORT
void* enhance_image(
    void* engine,
    const uint8_t* image_data,
    int width,
    int height,
    int format,
    const float* corners,  // 8 floats: x0,y0,x1,y1,x2,y2,x3,y3
    int apply_perspective,
    int apply_deskew,
    int apply_enhance,
    int apply_sharpening,
    float sharpening_strength,  // 0.0 - 1.0+
    int enhance_mode,      // 0=none, 1=whiten_bg, 2=contrast_stretch, 3=adaptive_binarize, 4=sauvola
    int output_width,
    int output_height
) {
    EnhancementResult* result = new EnhancementResult();

    if (!engine || !image_data) {
        strncpy(result->error_message, "Invalid parameters", sizeof(result->error_message) - 1);
        return result;
    }

    CaptureEngine* eng = static_cast<CaptureEngine*>(engine);

    EnhancementOptions options;
    options.apply_perspective_correction = (apply_perspective != 0);
    options.apply_crop = (apply_perspective == 0);  // Auto crop when no perspective
    options.apply_deskew = (apply_deskew != 0);
    options.apply_auto_enhance = (apply_enhance != 0);
    options.apply_sharpening = (apply_sharpening != 0);
    options.sharpening_strength = sharpening_strength;
    options.enhance_mode = static_cast<EnhanceMode>(enhance_mode);
    options.output_width = output_width;
    options.output_height = output_height;

    *result = eng->enhanceImage(image_data, width, height, format, corners, options);

    return result;
}

// Enhance with guide frame (new API - auto-calculate virtual trapezoid)
FFI_EXPORT
void* enhance_image_with_guide_frame(
    void* engine,
    const uint8_t* image_data,
    int width,
    int height,
    int format,
    float guide_left,
    float guide_top,
    float guide_right,
    float guide_bottom,
    int apply_sharpening,
    float sharpening_strength,
    int enhance_mode,
    int rotation  // 0: none, 90: clockwise, 180, 270: counter-clockwise
) {
    EnhancementResult* result = new EnhancementResult();

    if (!engine || !image_data) {
        strncpy(result->error_message, "Invalid parameters", sizeof(result->error_message) - 1);
        return result;
    }

    CaptureEngine* eng = static_cast<CaptureEngine*>(engine);

    EnhancementOptions options;
    options.apply_perspective_correction = false;  // Will be set by enhanceImageWithGuideFrame
    options.apply_crop = false;  // Will be set by enhanceImageWithGuideFrame
    options.apply_deskew = false;
    options.apply_auto_enhance = false;
    options.apply_sharpening = (apply_sharpening != 0);
    options.sharpening_strength = sharpening_strength;
    options.enhance_mode = static_cast<EnhanceMode>(enhance_mode);
    options.output_width = 0;
    options.output_height = 0;

    *result = eng->enhanceImageWithGuideFrame(
        image_data, width, height, format,
        guide_left, guide_top, guide_right, guide_bottom,
        options,
        rotation
    );

    return result;
}

// Get enhancement result data
FFI_EXPORT
int get_enhancement_success(void* result) {
    if (!result) return 0;
    return static_cast<EnhancementResult*>(result)->success ? 1 : 0;
}

FFI_EXPORT
uint8_t* get_enhancement_image_data(void* result) {
    if (!result) return nullptr;
    return static_cast<EnhancementResult*>(result)->image_data;
}

FFI_EXPORT
int get_enhancement_width(void* result) {
    if (!result) return 0;
    return static_cast<EnhancementResult*>(result)->width;
}

FFI_EXPORT
int get_enhancement_height(void* result) {
    if (!result) return 0;
    return static_cast<EnhancementResult*>(result)->height;
}

FFI_EXPORT
int get_enhancement_channels(void* result) {
    if (!result) return 0;
    return static_cast<EnhancementResult*>(result)->channels;
}

FFI_EXPORT
int get_enhancement_stride(void* result) {
    if (!result) return 0;
    return static_cast<EnhancementResult*>(result)->stride;
}

FFI_EXPORT
const char* get_enhancement_error(void* result) {
    if (!result) return "Invalid result pointer";
    return static_cast<EnhancementResult*>(result)->error_message;
}

// Free enhancement result
FFI_EXPORT
void free_enhancement_result(void* result) {
    if (result) {
        EnhancementResult* r = static_cast<EnhancementResult*>(result);
        if (r->image_data) {
            delete[] r->image_data;
            r->image_data = nullptr;
        }
        delete r;
    }
}

// Free string allocated by analyze_frame
FFI_EXPORT
void free_string(char* str) {
    if (str) {
        free(str);
    }
}

// Get library version
FFI_EXPORT
const char* get_version() {
    return "0.1.0";
}

}  // extern "C"
