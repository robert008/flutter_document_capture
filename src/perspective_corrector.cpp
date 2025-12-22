#include "perspective_corrector.hpp"
#include <algorithm>
#include <cmath>

PerspectiveCorrector::PerspectiveCorrector() {}

PerspectiveCorrector::~PerspectiveCorrector() {}

CorrectionResult PerspectiveCorrector::correct(
    const cv::Mat& image,
    const std::vector<cv::Point2f>& corners,
    cv::Size outputSize
) {
    CorrectionResult result;

    if (image.empty() || corners.size() != 4) {
        return result;
    }

    // Order corners: TL, TR, BR, BL
    std::vector<cv::Point2f> ordered = orderCorners(corners);

    // Calculate output size if not specified
    if (outputSize.width == 0 || outputSize.height == 0) {
        outputSize = calculateOutputSize(ordered);
    }

    // Destination corners
    std::vector<cv::Point2f> dst = {
        cv::Point2f(0, 0),
        cv::Point2f(static_cast<float>(outputSize.width - 1), 0),
        cv::Point2f(static_cast<float>(outputSize.width - 1), static_cast<float>(outputSize.height - 1)),
        cv::Point2f(0, static_cast<float>(outputSize.height - 1))
    };

    // Calculate perspective transform matrix
    cv::Mat M = cv::getPerspectiveTransform(ordered, dst);

    // Apply transformation
    cv::warpPerspective(image, result.image, M, outputSize);

    result.success = true;
    result.width = outputSize.width;
    result.height = outputSize.height;

    return result;
}

cv::Size PerspectiveCorrector::calculateOutputSize(const std::vector<cv::Point2f>& corners) {
    // corners should be ordered: TL, TR, BR, BL

    // Calculate width (average of top and bottom edges)
    float topWidth = cv::norm(corners[1] - corners[0]);
    float bottomWidth = cv::norm(corners[2] - corners[3]);
    float width = (topWidth + bottomWidth) / 2.0f;

    // Calculate height (average of left and right edges)
    float leftHeight = cv::norm(corners[3] - corners[0]);
    float rightHeight = cv::norm(corners[2] - corners[1]);
    float height = (leftHeight + rightHeight) / 2.0f;

    // Ensure minimum size
    width = std::max(width, 100.0f);
    height = std::max(height, 100.0f);

    return cv::Size(static_cast<int>(width), static_cast<int>(height));
}

std::vector<cv::Point2f> PerspectiveCorrector::orderCorners(const std::vector<cv::Point2f>& corners) {
    if (corners.size() != 4) {
        return corners;
    }

    // Calculate center
    cv::Point2f center(0, 0);
    for (const auto& pt : corners) {
        center += pt;
    }
    center *= 0.25f;

    // Classify corners by position relative to center
    std::vector<cv::Point2f> ordered(4);
    std::vector<bool> assigned(4, false);

    for (size_t i = 0; i < corners.size(); i++) {
        const auto& pt = corners[i];
        int idx = -1;

        if (pt.x < center.x && pt.y < center.y) {
            idx = 0;  // Top-left
        } else if (pt.x >= center.x && pt.y < center.y) {
            idx = 1;  // Top-right
        } else if (pt.x >= center.x && pt.y >= center.y) {
            idx = 2;  // Bottom-right
        } else {
            idx = 3;  // Bottom-left
        }

        if (!assigned[idx]) {
            ordered[idx] = pt;
            assigned[idx] = true;
        }
    }

    // Fallback: if classification failed, use original order
    bool allAssigned = true;
    for (bool a : assigned) {
        if (!a) allAssigned = false;
    }

    if (!allAssigned) {
        return corners;
    }

    return ordered;
}
