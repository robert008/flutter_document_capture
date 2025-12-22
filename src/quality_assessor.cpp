#include "quality_assessor.hpp"
#include <algorithm>
#include <cmath>

QualityAssessor::QualityAssessor() {}

QualityAssessor::~QualityAssessor() {}

void QualityAssessor::reset() {
    corner_history_.clear();
}

TextRegion QualityAssessor::detectTextRegion(const cv::Mat& frame) {
    TextRegion result;

    if (frame.empty()) {
        return result;
    }

    // Convert to grayscale
    cv::Mat gray;
    if (frame.channels() == 3) {
        cv::cvtColor(frame, gray, cv::COLOR_BGR2GRAY);
    } else if (frame.channels() == 4) {
        cv::cvtColor(frame, gray, cv::COLOR_BGRA2GRAY);
    } else {
        gray = frame.clone();
    }

    // Adaptive threshold (handles varying lighting)
    cv::Mat binary;
    cv::adaptiveThreshold(gray, binary, 255,
                          cv::ADAPTIVE_THRESH_GAUSSIAN_C,
                          cv::THRESH_BINARY_INV, 11, 2);

    // Morphological operations to connect text regions
    // Horizontal kernel to connect characters in a line
    cv::Mat kernelH = cv::getStructuringElement(cv::MORPH_RECT, cv::Size(25, 3));
    cv::Mat dilatedH;
    cv::dilate(binary, dilatedH, kernelH);

    // Vertical kernel to connect lines
    cv::Mat kernelV = cv::getStructuringElement(cv::MORPH_RECT, cv::Size(5, 15));
    cv::Mat dilated;
    cv::dilate(dilatedH, dilated, kernelV);

    // Find contours
    std::vector<std::vector<cv::Point>> contours;
    cv::findContours(dilated, contours, cv::RETR_EXTERNAL, cv::CHAIN_APPROX_SIMPLE);

    if (contours.empty()) {
        return result;
    }

    // Find the largest contour (main text region)
    double maxArea = 0;
    int maxIdx = -1;
    for (size_t i = 0; i < contours.size(); i++) {
        double area = cv::contourArea(contours[i]);
        if (area > maxArea) {
            maxArea = area;
            maxIdx = static_cast<int>(i);
        }
    }

    if (maxIdx < 0) {
        return result;
    }

    // Get bounding rect with padding
    cv::Rect bounds = cv::boundingRect(contours[maxIdx]);

    // Add 5% padding
    int padX = static_cast<int>(bounds.width * 0.05);
    int padY = static_cast<int>(bounds.height * 0.05);

    bounds.x = std::max(0, bounds.x - padX);
    bounds.y = std::max(0, bounds.y - padY);
    bounds.width = std::min(frame.cols - bounds.x, bounds.width + 2 * padX);
    bounds.height = std::min(frame.rows - bounds.y, bounds.height + 2 * padY);

    // Calculate confidence based on area ratio and aspect ratio
    double frameArea = frame.cols * frame.rows;
    double areaRatio = maxArea / frameArea;

    // Text region should be between 10% and 90% of frame
    float areaConfidence = 0.0f;
    if (areaRatio >= 0.10 && areaRatio <= 0.90) {
        areaConfidence = 1.0f;
    } else if (areaRatio >= 0.05 && areaRatio < 0.10) {
        areaConfidence = static_cast<float>((areaRatio - 0.05) / 0.05);
    } else if (areaRatio > 0.90 && areaRatio <= 0.95) {
        areaConfidence = static_cast<float>((0.95 - areaRatio) / 0.05);
    }

    result.found = true;
    result.bounds = bounds;
    result.confidence = areaConfidence;

    // Set 4 corners (TL, TR, BR, BL)
    result.corners = {
        cv::Point2f(static_cast<float>(bounds.x), static_cast<float>(bounds.y)),
        cv::Point2f(static_cast<float>(bounds.x + bounds.width), static_cast<float>(bounds.y)),
        cv::Point2f(static_cast<float>(bounds.x + bounds.width), static_cast<float>(bounds.y + bounds.height)),
        cv::Point2f(static_cast<float>(bounds.x), static_cast<float>(bounds.y + bounds.height))
    };

    return result;
}

TextRegionsResult QualityAssessor::detectTextRegions(const cv::Mat& frame) {
    TextRegionsResult result;

    if (frame.empty()) {
        return result;
    }

    // Convert to grayscale
    cv::Mat gray;
    if (frame.channels() == 3) {
        cv::cvtColor(frame, gray, cv::COLOR_BGR2GRAY);
    } else if (frame.channels() == 4) {
        cv::cvtColor(frame, gray, cv::COLOR_BGRA2GRAY);
    } else {
        gray = frame.clone();
    }

    // Adaptive threshold
    cv::Mat binary;
    cv::adaptiveThreshold(gray, binary, 255,
                          cv::ADAPTIVE_THRESH_GAUSSIAN_C,
                          cv::THRESH_BINARY_INV, 11, 2);

    // Morphological operations to connect text
    cv::Mat kernelH = cv::getStructuringElement(cv::MORPH_RECT, cv::Size(15, 3));
    cv::Mat dilatedH;
    cv::dilate(binary, dilatedH, kernelH);

    cv::Mat kernelV = cv::getStructuringElement(cv::MORPH_RECT, cv::Size(3, 8));
    cv::Mat dilated;
    cv::dilate(dilatedH, dilated, kernelV);

    // Find all contours
    std::vector<std::vector<cv::Point>> contours;
    cv::findContours(dilated, contours, cv::RETR_EXTERNAL, cv::CHAIN_APPROX_SIMPLE);

    if (contours.empty()) {
        return result;
    }

    // Filter and collect valid regions
    double frameArea = frame.cols * frame.rows;
    double minArea = frameArea * 0.005;  // Min 0.5% of frame
    double maxArea = frameArea * 0.95;   // Max 95% of frame

    int minX = frame.cols, minY = frame.rows;
    int maxX = 0, maxY = 0;
    float totalArea = 0;

    for (const auto& contour : contours) {
        double area = cv::contourArea(contour);
        if (area < minArea || area > maxArea) continue;

        cv::Rect bounds = cv::boundingRect(contour);

        // Skip very thin regions (likely noise)
        if (bounds.width < 20 || bounds.height < 10) continue;

        TextRegion region;
        region.found = true;
        region.bounds = bounds;
        region.area = static_cast<float>(area);
        region.confidence = static_cast<float>(std::min(area / (frameArea * 0.5), 1.0));

        // Set corners
        region.corners = {
            cv::Point2f(static_cast<float>(bounds.x), static_cast<float>(bounds.y)),
            cv::Point2f(static_cast<float>(bounds.x + bounds.width), static_cast<float>(bounds.y)),
            cv::Point2f(static_cast<float>(bounds.x + bounds.width), static_cast<float>(bounds.y + bounds.height)),
            cv::Point2f(static_cast<float>(bounds.x), static_cast<float>(bounds.y + bounds.height))
        };

        result.regions.push_back(region);
        totalArea += region.area;

        // Update overall bounds
        minX = std::min(minX, bounds.x);
        minY = std::min(minY, bounds.y);
        maxX = std::max(maxX, bounds.x + bounds.width);
        maxY = std::max(maxY, bounds.y + bounds.height);
    }

    if (result.regions.empty()) {
        return result;
    }

    // Sort by area (largest first)
    std::sort(result.regions.begin(), result.regions.end(),
              [](const TextRegion& a, const TextRegion& b) {
                  return a.area > b.area;
              });

    // Set overall bounds with padding
    int padX = static_cast<int>((maxX - minX) * 0.02);
    int padY = static_cast<int>((maxY - minY) * 0.02);

    minX = std::max(0, minX - padX);
    minY = std::max(0, minY - padY);
    maxX = std::min(frame.cols, maxX + padX);
    maxY = std::min(frame.rows, maxY + padY);

    result.found = true;
    result.regionCount = static_cast<int>(result.regions.size());
    result.totalArea = totalArea;
    result.coverageRatio = totalArea / static_cast<float>(frameArea);
    result.overallBounds = cv::Rect(minX, minY, maxX - minX, maxY - minY);
    result.overallCorners = {
        cv::Point2f(static_cast<float>(minX), static_cast<float>(minY)),
        cv::Point2f(static_cast<float>(maxX), static_cast<float>(minY)),
        cv::Point2f(static_cast<float>(maxX), static_cast<float>(maxY)),
        cv::Point2f(static_cast<float>(minX), static_cast<float>(maxY))
    };

    return result;
}

QualityScore QualityAssessor::assessWithTextRegion(const cv::Mat& frame) {
    QualityScore score;

    if (frame.empty()) {
        return score;
    }

    // Convert to grayscale
    cv::Mat gray;
    if (frame.channels() == 3) {
        cv::cvtColor(frame, gray, cv::COLOR_BGR2GRAY);
    } else if (frame.channels() == 4) {
        cv::cvtColor(frame, gray, cv::COLOR_BGRA2GRAY);
    } else {
        gray = frame;
    }

    // Detect text region
    TextRegion textRegion = detectTextRegion(frame);
    score.text_region = textRegion;

    if (textRegion.found) {
        // Assess quality within text region
        score.blur_score = detectBlurInRegion(gray, textRegion.bounds);
        score.brightness_score = checkBrightnessInRegion(gray, textRegion.bounds);
        score.corner_confidence = textRegion.confidence;

        // Track stability using text region corners
        if (textRegion.corners.size() == 4) {
            score.stability_score = checkStability(textRegion.corners);
        }
    } else {
        // Fallback to full frame assessment
        score.blur_score = detectBlur(gray);
        score.brightness_score = checkBrightness(gray);
    }

    return score;
}

QualityScore QualityAssessor::assess(
    const cv::Mat& frame,
    const std::vector<cv::Point2f>& corners,
    float cornerConfidence
) {
    QualityScore score;
    score.corner_confidence = cornerConfidence;

    if (frame.empty()) {
        return score;
    }

    // Convert to grayscale
    cv::Mat gray;
    if (frame.channels() == 3) {
        cv::cvtColor(frame, gray, cv::COLOR_BGR2GRAY);
    } else if (frame.channels() == 4) {
        cv::cvtColor(frame, gray, cv::COLOR_BGRA2GRAY);
    } else {
        gray = frame;
    }

    // Assess quality metrics
    score.blur_score = detectBlur(gray);
    score.brightness_score = checkBrightness(gray);

    if (!corners.empty() && corners.size() == 4) {
        score.stability_score = checkStability(corners);
    }

    return score;
}

float QualityAssessor::detectBlur(const cv::Mat& gray) {
    // Laplacian variance method
    cv::Mat laplacian;
    cv::Laplacian(gray, laplacian, CV_64F);

    cv::Scalar mean, stddev;
    cv::meanStdDev(laplacian, mean, stddev);

    double variance = stddev.val[0] * stddev.val[0];

    // Normalize: variance < 100 is blurry, > 500 is sharp
    // Map to 0-1 range
    float score = static_cast<float>(std::min(variance / 500.0, 1.0));

    return score;
}

float QualityAssessor::checkBrightness(const cv::Mat& gray) {
    cv::Scalar meanVal = cv::mean(gray);
    double brightness = meanVal.val[0] / 255.0;

    // Optimal brightness is around 0.4-0.6
    // Calculate distance from optimal (0.5)
    float distance = static_cast<float>(std::abs(brightness - 0.5));

    // Convert to score: closer to 0.5 = higher score
    float score = 1.0f - (distance * 2.0f);

    return std::max(0.0f, score);
}

float QualityAssessor::detectBlurInRegion(const cv::Mat& gray, const cv::Rect& region) {
    // Validate region bounds
    cv::Rect safeRegion = region & cv::Rect(0, 0, gray.cols, gray.rows);
    if (safeRegion.width < 10 || safeRegion.height < 10) {
        return detectBlur(gray);
    }

    cv::Mat roi = gray(safeRegion);
    return detectBlur(roi);
}

float QualityAssessor::checkBrightnessInRegion(const cv::Mat& gray, const cv::Rect& region) {
    // Validate region bounds
    cv::Rect safeRegion = region & cv::Rect(0, 0, gray.cols, gray.rows);
    if (safeRegion.width < 10 || safeRegion.height < 10) {
        return checkBrightness(gray);
    }

    cv::Mat roi = gray(safeRegion);
    return checkBrightness(roi);
}

float QualityAssessor::checkStability(const std::vector<cv::Point2f>& corners) {
    if (corners.size() != 4) {
        return 0.0f;
    }

    // Not enough history yet
    if (corner_history_.size() < 3) {
        corner_history_.push_back(corners);
        return 0.0f;
    }

    // Calculate average displacement from previous frames
    float totalDisplacement = 0.0f;
    int comparisons = 0;

    for (const auto& prevCorners : corner_history_) {
        if (prevCorners.size() != 4) continue;

        for (int i = 0; i < 4; i++) {
            totalDisplacement += cv::norm(corners[i] - prevCorners[i]);
        }
        comparisons += 4;
    }

    float avgDisplacement = (comparisons > 0) ? totalDisplacement / comparisons : 0.0f;

    // Update history
    corner_history_.push_back(corners);
    if (corner_history_.size() > MAX_HISTORY) {
        corner_history_.pop_front();
    }

    // Score: displacement < 5 pixels is stable
    // Map to 0-1: 0 pixels = 1.0, 20+ pixels = 0.0
    float score = std::max(0.0f, 1.0f - (avgDisplacement / 20.0f));

    return score;
}
