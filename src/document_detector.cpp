#include "document_detector.hpp"
#include <algorithm>
#include <cmath>

DocumentDetector::DocumentDetector() {}

DocumentDetector::~DocumentDetector() {}

void DocumentDetector::setCannyThreshold(int low, int high) {
    canny_low_ = low;
    canny_high_ = high;
}

void DocumentDetector::setMinAreaRatio(float ratio) {
    min_area_ratio_ = ratio;
}

DetectionResult DocumentDetector::detect(const cv::Mat& frame) {
    DetectionResult result;

    if (frame.empty()) {
        return result;
    }

    // Resize for faster processing
    cv::Mat resized;
    float scale = 1.0f;
    const int TARGET_WIDTH = 480;

    if (frame.cols > TARGET_WIDTH) {
        scale = static_cast<float>(TARGET_WIDTH) / frame.cols;
        cv::resize(frame, resized, cv::Size(), scale, scale);
    } else {
        resized = frame.clone();
    }

    // Preprocess
    cv::Mat edges = preprocess(resized);

    // Find contours
    std::vector<std::vector<cv::Point>> contours = findContours(edges);

    // Find largest quadrilateral
    std::vector<cv::Point2f> quad = findLargestQuadrilateral(contours, resized.size());

    if (quad.size() == 4) {
        // Scale corners back to original size
        for (auto& pt : quad) {
            pt.x /= scale;
            pt.y /= scale;
        }

        // Order corners: TL, TR, BR, BL
        result.corners = orderCorners(quad);
        result.found = true;
        result.confidence = calculateConfidence(result.corners, frame.size());
    }

    return result;
}

cv::Mat DocumentDetector::preprocess(const cv::Mat& input) {
    cv::Mat gray, blurred, edges;

    // Convert to grayscale
    if (input.channels() == 3) {
        cv::cvtColor(input, gray, cv::COLOR_BGR2GRAY);
    } else if (input.channels() == 4) {
        cv::cvtColor(input, gray, cv::COLOR_BGRA2GRAY);
    } else {
        gray = input.clone();
    }

    // Apply CLAHE (Contrast Limited Adaptive Histogram Equalization)
    // This helps detect edges on low-contrast backgrounds
    cv::Ptr<cv::CLAHE> clahe = cv::createCLAHE(2.0, cv::Size(8, 8));
    clahe->apply(gray, gray);

    // Gaussian blur
    cv::GaussianBlur(gray, blurred, cv::Size(5, 5), 0);

    // Canny edge detection
    cv::Canny(blurred, edges, canny_low_, canny_high_);

    // Dilate to connect edges
    cv::Mat kernel = cv::getStructuringElement(cv::MORPH_RECT, cv::Size(3, 3));
    cv::dilate(edges, edges, kernel);

    // Close operation to fill small gaps
    cv::Mat closeKernel = cv::getStructuringElement(cv::MORPH_RECT, cv::Size(5, 5));
    cv::morphologyEx(edges, edges, cv::MORPH_CLOSE, closeKernel);

    return edges;
}

std::vector<std::vector<cv::Point>> DocumentDetector::findContours(const cv::Mat& edges) {
    std::vector<std::vector<cv::Point>> contours;
    cv::findContours(edges, contours, cv::RETR_EXTERNAL, cv::CHAIN_APPROX_SIMPLE);

    // Sort by area (descending)
    std::sort(contours.begin(), contours.end(),
        [](const std::vector<cv::Point>& a, const std::vector<cv::Point>& b) {
            return cv::contourArea(a) > cv::contourArea(b);
        });

    return contours;
}

std::vector<cv::Point2f> DocumentDetector::findLargestQuadrilateral(
    const std::vector<std::vector<cv::Point>>& contours,
    const cv::Size& imageSize
) {
    float minArea = imageSize.width * imageSize.height * min_area_ratio_;

    for (const auto& contour : contours) {
        double area = cv::contourArea(contour);
        if (area < minArea) {
            continue;
        }

        // Try different epsilon values for approximation
        double perimeter = cv::arcLength(contour, true);

        for (double epsFactor = 0.02; epsFactor <= 0.1; epsFactor += 0.02) {
            std::vector<cv::Point> approx;
            double epsilon = epsFactor * perimeter;
            cv::approxPolyDP(contour, approx, epsilon, true);

            // Check if quadrilateral (allow 4 points)
            if (approx.size() == 4 && cv::isContourConvex(approx)) {
                std::vector<cv::Point2f> quad;
                for (const auto& pt : approx) {
                    quad.push_back(cv::Point2f(static_cast<float>(pt.x), static_cast<float>(pt.y)));
                }
                return quad;
            }
        }

        // If no 4-point approximation found, try to get 4 corners from bounding rect
        // This helps when document edges are not perfectly detected
        if (contour.size() >= 4) {
            cv::RotatedRect rotRect = cv::minAreaRect(contour);
            cv::Point2f vertices[4];
            rotRect.points(vertices);

            // Check if the rotated rect covers a significant portion of the contour
            double rectArea = rotRect.size.width * rotRect.size.height;
            double contourArea = cv::contourArea(contour);

            if (contourArea / rectArea > 0.7) {  // Contour fills at least 70% of rect
                std::vector<cv::Point2f> quad(vertices, vertices + 4);
                return quad;
            }
        }
    }

    return std::vector<cv::Point2f>();
}

std::vector<cv::Point2f> DocumentDetector::orderCorners(const std::vector<cv::Point2f>& corners) {
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
    for (const auto& pt : corners) {
        if (pt.x < center.x && pt.y < center.y) {
            ordered[0] = pt;  // Top-left
        } else if (pt.x >= center.x && pt.y < center.y) {
            ordered[1] = pt;  // Top-right
        } else if (pt.x >= center.x && pt.y >= center.y) {
            ordered[2] = pt;  // Bottom-right
        } else {
            ordered[3] = pt;  // Bottom-left
        }
    }

    return ordered;
}

float DocumentDetector::calculateConfidence(const std::vector<cv::Point2f>& corners, const cv::Size& imageSize) {
    if (corners.size() != 4) {
        return 0.0f;
    }

    // Calculate quadrilateral area
    float area = static_cast<float>(cv::contourArea(corners));
    float imageArea = static_cast<float>(imageSize.width * imageSize.height);

    // Area ratio factor (prefer documents that fill 20-80% of frame)
    float areaRatio = area / imageArea;
    float areaScore = 0.0f;
    if (areaRatio >= 0.2f && areaRatio <= 0.8f) {
        areaScore = 1.0f - std::abs(areaRatio - 0.5f);
    } else if (areaRatio > 0.1f) {
        areaScore = 0.5f;
    }

    // Check if corners are well-distributed (not too close together)
    float minDist = std::numeric_limits<float>::max();
    for (int i = 0; i < 4; i++) {
        for (int j = i + 1; j < 4; j++) {
            float dist = cv::norm(corners[i] - corners[j]);
            minDist = std::min(minDist, dist);
        }
    }
    float minExpectedDist = std::sqrt(imageArea) * 0.1f;
    float distScore = std::min(1.0f, minDist / minExpectedDist);

    // Combined confidence
    return areaScore * 0.6f + distScore * 0.4f;
}
