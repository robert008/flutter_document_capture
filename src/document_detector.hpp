#ifndef DOCUMENT_DETECTOR_HPP
#define DOCUMENT_DETECTOR_HPP

#include <opencv2/opencv.hpp>
#include <vector>

struct DetectionResult {
    bool found;
    std::vector<cv::Point2f> corners;  // TL, TR, BR, BL
    float confidence;

    DetectionResult() : found(false), confidence(0.0f) {}
};

class DocumentDetector {
public:
    DocumentDetector();
    ~DocumentDetector();

    DetectionResult detect(const cv::Mat& frame);

    // Configuration
    void setCannyThreshold(int low, int high);
    void setMinAreaRatio(float ratio);

private:
    cv::Mat preprocess(const cv::Mat& input);
    std::vector<std::vector<cv::Point>> findContours(const cv::Mat& edges);
    std::vector<cv::Point2f> findLargestQuadrilateral(
        const std::vector<std::vector<cv::Point>>& contours,
        const cv::Size& imageSize
    );
    std::vector<cv::Point2f> orderCorners(const std::vector<cv::Point2f>& corners);
    float calculateConfidence(const std::vector<cv::Point2f>& corners, const cv::Size& imageSize);

    // Parameters - adjusted for better sensitivity
    int canny_low_ = 30;      // Lower threshold for better edge detection
    int canny_high_ = 100;    // Lower high threshold
    float min_area_ratio_ = 0.05f;  // Allow smaller documents (5% of image)
};

#endif // DOCUMENT_DETECTOR_HPP
