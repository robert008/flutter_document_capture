#ifndef QUALITY_ASSESSOR_HPP
#define QUALITY_ASSESSOR_HPP

#include <opencv2/opencv.hpp>
#include <vector>
#include <deque>

struct TextRegion {
    bool found;
    cv::Rect bounds;           // Bounding box of text region
    std::vector<cv::Point2f> corners;  // 4 corners (TL, TR, BR, BL)
    float confidence;          // 0-1, based on text density
    float area;                // Area of this region

    TextRegion() : found(false), confidence(0), area(0) {}
};

struct TextRegionsResult {
    bool found;
    std::vector<TextRegion> regions;  // All detected regions
    cv::Rect overallBounds;           // Bounding box of all regions combined
    std::vector<cv::Point2f> overallCorners;  // 4 corners of overall bounds
    int regionCount;
    float totalArea;                  // Sum of all region areas
    float coverageRatio;              // Total area / frame area

    TextRegionsResult() : found(false), regionCount(0), totalArea(0), coverageRatio(0) {}
};

struct QualityScore {
    float blur_score;         // 0-1, higher is sharper
    float brightness_score;   // 0-1, 0.5 is optimal
    float stability_score;    // 0-1, higher is more stable
    float corner_confidence;  // 0-1, from detection
    TextRegion text_region;   // Detected text region (legacy, single)
    TextRegionsResult text_regions;  // All detected text regions

    QualityScore()
        : blur_score(0), brightness_score(0),
          stability_score(0), corner_confidence(0) {}

    float overall() const {
        return blur_score * 0.3f +
               brightness_score * 0.2f +
               stability_score * 0.3f +
               corner_confidence * 0.2f;
    }

    bool isCaptureReady() const {
        return corner_confidence > 0.8f &&
               blur_score > 0.6f &&
               brightness_score > 0.5f &&
               stability_score > 0.9f;
    }
};

class QualityAssessor {
public:
    QualityAssessor();
    ~QualityAssessor();

    // Original method with document corners
    QualityScore assess(const cv::Mat& frame, const std::vector<cv::Point2f>& corners, float cornerConfidence);

    // Lightweight method using text region detection
    QualityScore assessWithTextRegion(const cv::Mat& frame);

    // Detect text region using morphology (fast, ~5-10ms)
    TextRegion detectTextRegion(const cv::Mat& frame);

    // Detect multiple text regions with overall bounds
    TextRegionsResult detectTextRegions(const cv::Mat& frame);

    void reset();

    // Quality assessment methods (public for direct use)
    float detectBlur(const cv::Mat& gray);
    float detectBlurInRegion(const cv::Mat& gray, const cv::Rect& region);
    float checkBrightness(const cv::Mat& gray);
    float checkBrightnessInRegion(const cv::Mat& gray, const cv::Rect& region);

private:
    float checkStability(const std::vector<cv::Point2f>& corners);

    std::deque<std::vector<cv::Point2f>> corner_history_;
    static const size_t MAX_HISTORY = 5;
};

#endif // QUALITY_ASSESSOR_HPP
