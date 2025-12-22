#import "DocumentCapturePlugin.h"

// Document capture FFI functions (from ffi_bridge.cpp)
extern void* capture_engine_create(void);
extern void capture_engine_destroy(void* engine);
extern void capture_engine_reset(void* engine);
extern char* analyze_frame(void* engine, const uint8_t* image_data, int width, int height, int format);
extern void* enhance_image(void* engine, const uint8_t* image_data, int width, int height, int format,
                           const float* corners, int apply_perspective, int apply_deskew, int apply_enhance,
                           int apply_sharpening, float sharpening_strength, int enhance_mode,
                           int output_width, int output_height);
extern void* enhance_image_with_guide_frame(void* engine, const uint8_t* image_data, int width, int height, int format,
                           float guide_left, float guide_top, float guide_right, float guide_bottom,
                           int apply_sharpening, float sharpening_strength, int enhance_mode);
extern int get_enhancement_success(void* result);
extern uint8_t* get_enhancement_image_data(void* result);
extern int get_enhancement_width(void* result);
extern int get_enhancement_height(void* result);
extern int get_enhancement_channels(void* result);
extern int get_enhancement_stride(void* result);
extern const char* get_enhancement_error(void* result);
extern void free_enhancement_result(void* result);
extern void free_string(char* str);
extern const char* get_version(void);

@implementation DocumentCapturePlugin

+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar>*)registrar {
    NSLog(@"DocumentCapturePlugin registered with Flutter");
}

// This method is called when the class is loaded into memory.
// It prevents the linker from stripping C++ symbols as dead code.
+ (void)load {
    NSLog(@"DocumentCapturePlugin: +load method called");

    // Force link by calling get_version (which is always safe)
    volatile const char* version = get_version();
    NSLog(@"DocumentCapturePlugin: Version check completed: %s", version);

    // The condition below will never be true (version is always non-NULL),
    // but it forces the linker to keep all these symbols.
    if (version == NULL) {
        // Force link capture engine symbols
        void* engine = capture_engine_create();
        capture_engine_reset(engine);
        capture_engine_destroy(engine);

        // Force link analyze_frame
        analyze_frame(NULL, NULL, 0, 0, 0);
        free_string(NULL);

        // Force link enhance_image and result accessors
        void* result = enhance_image(NULL, NULL, 0, 0, 0, NULL, 0, 0, 0, 0, 0.0f, 0, 0, 0);
        enhance_image_with_guide_frame(NULL, NULL, 0, 0, 0, 0.0f, 0.0f, 0.0f, 0.0f, 0, 0.0f, 0);
        get_enhancement_success(result);
        get_enhancement_image_data(result);
        get_enhancement_width(result);
        get_enhancement_height(result);
        get_enhancement_channels(result);
        get_enhancement_stride(result);
        get_enhancement_error(result);
        free_enhancement_result(result);
    }

    NSLog(@"DocumentCapturePlugin: All symbols retained");
}

@end
