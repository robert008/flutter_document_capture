#ifndef CAPTURE_ENGINE_HPP
#define CAPTURE_ENGINE_HPP

#include <opencv2/opencv.hpp>
#include <vector>
#include <memory>

#include "document_detector.hpp"
#include "perspective_corrector.hpp"
#include "quality_assessor.hpp"
#include "image_enhancer.hpp"

struct FrameAnalysisResult {
    bool document_found;
    bool table_found;        // True if table detected (clear rectangular border)
    bool text_region_found;  // True if text region detected (fallback when no document)
    float corners[8];  // x0,y0,x1,y1,x2,y2,x3,y3 (TL,TR,BR,BL)
    float corner_confidence;
    float blur_score;
    float brightness_score;
    float stability_score;
    float overall_score;
    bool capture_ready;

    // Table/Trapezoid detection
    bool is_trapezoid;       // True if shape is trapezoid (needs perspective correction)
    float skew_ratio;        // Overall skew ratio (max of vertical and horizontal)
    float top_width;         // Width of top edge
    float bottom_width;      // Width of bottom edge
    float left_height;       // Height of left edge
    float right_height;      // Height of right edge
    float vertical_skew;     // Vertical skew: |top-bottom|/avg
    float horizontal_skew;   // Horizontal skew: |left-right|/avg

    // Multiple text regions data
    int text_region_count;
    float text_regions_bounds[32];  // Up to 8 regions, each with x,y,w,h
    float overall_bounds[4];        // x,y,w,h of all regions combined
    float coverage_ratio;           // Total text area / frame area

    FrameAnalysisResult() {
        document_found = false;
        table_found = false;
        text_region_found = false;
        memset(corners, 0, sizeof(corners));
        corner_confidence = 0;
        blur_score = 0;
        brightness_score = 0;
        stability_score = 0;
        overall_score = 0;
        capture_ready = false;
        is_trapezoid = false;
        skew_ratio = 0;
        top_width = 0;
        bottom_width = 0;
        left_height = 0;
        right_height = 0;
        vertical_skew = 0;
        horizontal_skew = 0;
        text_region_count = 0;
        memset(text_regions_bounds, 0, sizeof(text_regions_bounds));
        memset(overall_bounds, 0, sizeof(overall_bounds));
        coverage_ratio = 0;
    }
};

// Enhancement mode for OCR optimization
enum EnhanceMode {
    ENHANCE_NONE = 0,
    ENHANCE_WHITEN_BG = 1,        // Background whitening
    ENHANCE_CONTRAST_STRETCH = 2,  // Contrast stretching
    ENHANCE_ADAPTIVE_BINARIZE = 3, // Adaptive binarization
    ENHANCE_SAUVOLA = 4            // Sauvola binarization
};

struct EnhancementOptions {
    bool apply_crop;                    // Simple rectangular crop
    bool apply_perspective_correction;  // Perspective transform (for trapezoid -> rectangle)
    bool apply_deskew;
    bool apply_auto_enhance;            // CLAHE + brightness
    bool apply_sharpening;              // Sharpening (independent)
    float sharpening_strength;          // Sharpening strength 0.0 - 1.0+
    EnhanceMode enhance_mode;           // OCR enhancement mode
    int output_width;   // 0 = auto
    int output_height;  // 0 = auto

    EnhancementOptions() {
        apply_crop = false;
        apply_perspective_correction = true;
        apply_deskew = false;
        apply_auto_enhance = false;
        apply_sharpening = false;
        sharpening_strength = 0.5f;
        enhance_mode = ENHANCE_NONE;
        output_width = 0;
        output_height = 0;
    }
};

struct EnhancementResult {
    uint8_t* image_data;
    int width;
    int height;
    int channels;
    int stride;
    bool success;
    char error_message[256];

    EnhancementResult() {
        image_data = nullptr;
        width = 0;
        height = 0;
        channels = 0;
        stride = 0;
        success = false;
        error_message[0] = '\0';
    }
};

class CaptureEngine {
public:
    CaptureEngine();
    ~CaptureEngine();

    // Stage 1: Real-time frame analysis
    FrameAnalysisResult analyzeFrame(
        const uint8_t* image_data,
        int width,
        int height,
        int format,  // 0: BGRA, 1: BGR, 2: RGB
        int rotation = 0,  // 0: none, 90: clockwise, 180, 270: counter-clockwise
        int crop_x = 0,    // Crop region after rotation (0,0,0,0 for no crop)
        int crop_y = 0,
        int crop_w = 0,
        int crop_h = 0
    );

    // Stage 2: Post-capture enhancement (legacy - corners provided by caller)
    EnhancementResult enhanceImage(
        const uint8_t* image_data,
        int width,
        int height,
        int format,
        const float* corners,  // 8 floats
        const EnhancementOptions& options
    );

    // Stage 2: Post-capture enhancement (new - auto-calculate virtual trapezoid)
    // Uses last analysis result to calculate perspective correction
    EnhancementResult enhanceImageWithGuideFrame(
        const uint8_t* image_data,
        int width,
        int height,
        int format,
        float guide_left,
        float guide_top,
        float guide_right,
        float guide_bottom,
        const EnhancementOptions& options,
        int rotation = 0  // 0: none, 90: clockwise, 180, 270: counter-clockwise
    );

    // Get last analysis result
    const FrameAnalysisResult& getLastAnalysis() const { return last_analysis_; }

    // Free enhancement result memory
    void freeEnhancementResult(EnhancementResult* result);

    // Reset state (e.g., stability history)
    void reset();

private:
    cv::Mat bufferToMat(const uint8_t* data, int width, int height, int format);

    // Calculate virtual trapezoid corners from guide frame using last analysis
    void calculateVirtualTrapezoid(
        float guide_left, float guide_top, float guide_right, float guide_bottom,
        float* out_corners  // 8 floats output
    );

    std::unique_ptr<DocumentDetector> detector_;
    std::unique_ptr<PerspectiveCorrector> corrector_;
    std::unique_ptr<QualityAssessor> assessor_;
    std::unique_ptr<ImageEnhancer> enhancer_;

    FrameAnalysisResult last_analysis_;  // Store last analysis for enhance
};

#endif // CAPTURE_ENGINE_HPP
