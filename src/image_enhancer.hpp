#ifndef IMAGE_ENHANCER_HPP
#define IMAGE_ENHANCER_HPP

#include <opencv2/opencv.hpp>

struct EnhanceConfig {
    bool apply_clahe;           // Adaptive histogram equalization
    bool apply_brightness_adjust;
    bool apply_sharpening;
    float clahe_clip_limit;     // CLAHE clip limit (default: 2.0)
    int clahe_tile_size;        // CLAHE tile size (default: 8)
    float target_brightness;    // Target brightness 0-1 (default: 0.5)
    float sharpening_strength;  // Sharpening strength (default: 0.5)

    EnhanceConfig() {
        apply_clahe = true;
        apply_brightness_adjust = true;
        apply_sharpening = false;
        clahe_clip_limit = 2.0f;
        clahe_tile_size = 8;
        target_brightness = 0.5f;
        sharpening_strength = 0.5f;
    }
};

class ImageEnhancer {
public:
    ImageEnhancer();
    ~ImageEnhancer();

    // Main enhancement function
    cv::Mat enhance(const cv::Mat& input, const EnhanceConfig& config = EnhanceConfig());

    // Individual enhancement functions
    cv::Mat applyCLAHE(const cv::Mat& input, float clipLimit = 2.0f, int tileSize = 8);
    cv::Mat adjustBrightness(const cv::Mat& input, float targetBrightness = 0.5f);
    cv::Mat sharpen(const cv::Mat& input, float strength = 0.5f);

    // New enhancement functions for OCR
    cv::Mat whitenBackground(const cv::Mat& input, int threshold = 200);
    cv::Mat stretchContrast(const cv::Mat& input);
    cv::Mat adaptiveBinarize(const cv::Mat& input, int blockSize = 11, double C = 2);
    cv::Mat sauvolaBinarize(const cv::Mat& input, int windowSize = 15, double k = 0.2, double R = 128);

private:
    float calculateBrightness(const cv::Mat& input);
};

#endif // IMAGE_ENHANCER_HPP
