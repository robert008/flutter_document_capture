#ifndef PERSPECTIVE_CORRECTOR_HPP
#define PERSPECTIVE_CORRECTOR_HPP

#include <opencv2/opencv.hpp>
#include <vector>

struct CorrectionResult {
    cv::Mat image;
    bool success;
    int width;
    int height;

    CorrectionResult() : success(false), width(0), height(0) {}
};

class PerspectiveCorrector {
public:
    PerspectiveCorrector();
    ~PerspectiveCorrector();

    CorrectionResult correct(
        const cv::Mat& image,
        const std::vector<cv::Point2f>& corners,
        cv::Size outputSize = cv::Size(0, 0)
    );

private:
    cv::Size calculateOutputSize(const std::vector<cv::Point2f>& corners);
    std::vector<cv::Point2f> orderCorners(const std::vector<cv::Point2f>& corners);
};

#endif // PERSPECTIVE_CORRECTOR_HPP
