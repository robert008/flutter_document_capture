#include "image_enhancer.hpp"
#include <algorithm>

ImageEnhancer::ImageEnhancer() {}

ImageEnhancer::~ImageEnhancer() {}

cv::Mat ImageEnhancer::enhance(const cv::Mat& input, const EnhanceConfig& config) {
    if (input.empty()) {
        return input;
    }

    cv::Mat result = input.clone();

    // Apply CLAHE (contrast enhancement)
    if (config.apply_clahe) {
        result = applyCLAHE(result, config.clahe_clip_limit, config.clahe_tile_size);
    }

    // Adjust brightness
    if (config.apply_brightness_adjust) {
        result = adjustBrightness(result, config.target_brightness);
    }

    // Apply sharpening
    if (config.apply_sharpening) {
        result = sharpen(result, config.sharpening_strength);
    }

    return result;
}

cv::Mat ImageEnhancer::applyCLAHE(const cv::Mat& input, float clipLimit, int tileSize) {
    if (input.empty()) {
        return input;
    }

    cv::Mat result;

    if (input.channels() == 1) {
        // Grayscale image
        cv::Ptr<cv::CLAHE> clahe = cv::createCLAHE(clipLimit, cv::Size(tileSize, tileSize));
        clahe->apply(input, result);
    } else {
        // Color image - convert to LAB, apply CLAHE to L channel
        cv::Mat lab;
        cv::cvtColor(input, lab, cv::COLOR_BGR2Lab);

        std::vector<cv::Mat> channels;
        cv::split(lab, channels);

        // Apply CLAHE to L channel
        cv::Ptr<cv::CLAHE> clahe = cv::createCLAHE(clipLimit, cv::Size(tileSize, tileSize));
        clahe->apply(channels[0], channels[0]);

        cv::merge(channels, lab);
        cv::cvtColor(lab, result, cv::COLOR_Lab2BGR);
    }

    return result;
}

cv::Mat ImageEnhancer::adjustBrightness(const cv::Mat& input, float targetBrightness) {
    if (input.empty()) {
        return input;
    }

    float currentBrightness = calculateBrightness(input);

    // Calculate adjustment factor
    // targetBrightness is 0-1, where 0.5 is neutral
    float brightnessDiff = targetBrightness - currentBrightness;

    // Only adjust if difference is significant
    if (std::abs(brightnessDiff) < 0.05f) {
        return input.clone();
    }

    cv::Mat result;

    // Convert brightness difference to alpha/beta for convertTo
    // alpha: contrast (1.0 = no change)
    // beta: brightness (-127 to 127)
    float alpha = 1.0f;
    float beta = brightnessDiff * 100.0f;  // Scale to reasonable range

    // Clamp beta
    beta = std::max(-50.0f, std::min(50.0f, beta));

    input.convertTo(result, -1, alpha, beta);

    return result;
}

cv::Mat ImageEnhancer::sharpen(const cv::Mat& input, float strength) {
    if (input.empty() || strength <= 0) {
        return input.clone();
    }

    // Unsharp masking
    cv::Mat blurred;
    cv::GaussianBlur(input, blurred, cv::Size(0, 0), 3);

    cv::Mat result;
    // sharpened = original + strength * (original - blurred)
    cv::addWeighted(input, 1.0 + strength, blurred, -strength, 0, result);

    return result;
}

float ImageEnhancer::calculateBrightness(const cv::Mat& input) {
    if (input.empty()) {
        return 0.5f;
    }

    cv::Mat gray;
    if (input.channels() == 1) {
        gray = input;
    } else {
        cv::cvtColor(input, gray, cv::COLOR_BGR2GRAY);
    }

    cv::Scalar mean = cv::mean(gray);
    return static_cast<float>(mean[0]) / 255.0f;
}

cv::Mat ImageEnhancer::whitenBackground(const cv::Mat& input, int threshold) {
    if (input.empty()) {
        return input;
    }

    cv::Mat gray;
    if (input.channels() == 1) {
        gray = input.clone();
    } else {
        cv::cvtColor(input, gray, cv::COLOR_BGR2GRAY);
    }

    cv::Mat result = input.clone();

    // Find pixels above threshold (likely background)
    // and push them towards white
    if (input.channels() == 1) {
        for (int y = 0; y < gray.rows; y++) {
            for (int x = 0; x < gray.cols; x++) {
                uchar pixel = gray.at<uchar>(y, x);
                if (pixel > threshold) {
                    result.at<uchar>(y, x) = 255;
                }
            }
        }
    } else {
        for (int y = 0; y < gray.rows; y++) {
            for (int x = 0; x < gray.cols; x++) {
                uchar pixel = gray.at<uchar>(y, x);
                if (pixel > threshold) {
                    result.at<cv::Vec3b>(y, x) = cv::Vec3b(255, 255, 255);
                }
            }
        }
    }

    return result;
}

cv::Mat ImageEnhancer::stretchContrast(const cv::Mat& input) {
    if (input.empty()) {
        return input;
    }

    cv::Mat result;

    if (input.channels() == 1) {
        cv::normalize(input, result, 0, 255, cv::NORM_MINMAX);
    } else {
        // Convert to LAB, stretch L channel, convert back
        cv::Mat lab;
        cv::cvtColor(input, lab, cv::COLOR_BGR2Lab);

        std::vector<cv::Mat> channels;
        cv::split(lab, channels);

        cv::normalize(channels[0], channels[0], 0, 255, cv::NORM_MINMAX);

        cv::merge(channels, lab);
        cv::cvtColor(lab, result, cv::COLOR_Lab2BGR);
    }

    return result;
}

cv::Mat ImageEnhancer::adaptiveBinarize(const cv::Mat& input, int blockSize, double C) {
    if (input.empty()) {
        return input;
    }

    cv::Mat gray;
    if (input.channels() == 1) {
        gray = input;
    } else {
        cv::cvtColor(input, gray, cv::COLOR_BGR2GRAY);
    }

    // Ensure blockSize is odd
    if (blockSize % 2 == 0) {
        blockSize++;
    }

    cv::Mat binary;
    cv::adaptiveThreshold(gray, binary, 255,
        cv::ADAPTIVE_THRESH_GAUSSIAN_C, cv::THRESH_BINARY,
        blockSize, C);

    // Convert back to BGR for consistency
    cv::Mat result;
    cv::cvtColor(binary, result, cv::COLOR_GRAY2BGR);

    return result;
}

cv::Mat ImageEnhancer::sauvolaBinarize(const cv::Mat& input, int windowSize, double k, double R) {
    if (input.empty()) {
        return input;
    }

    cv::Mat gray;
    if (input.channels() == 1) {
        gray = input;
    } else {
        cv::cvtColor(input, gray, cv::COLOR_BGR2GRAY);
    }

    // Ensure windowSize is odd
    if (windowSize % 2 == 0) {
        windowSize++;
    }

    int halfWindow = windowSize / 2;

    // Convert to float for calculations
    cv::Mat floatGray;
    gray.convertTo(floatGray, CV_64F);

    // Calculate local mean using integral image
    cv::Mat integralSum, integralSqSum;
    cv::integral(floatGray, integralSum, integralSqSum, CV_64F);

    cv::Mat binary = cv::Mat::zeros(gray.size(), CV_8U);

    for (int y = 0; y < gray.rows; y++) {
        for (int x = 0; x < gray.cols; x++) {
            // Define window boundaries
            int x1 = std::max(0, x - halfWindow);
            int y1 = std::max(0, y - halfWindow);
            int x2 = std::min(gray.cols - 1, x + halfWindow);
            int y2 = std::min(gray.rows - 1, y + halfWindow);

            int area = (x2 - x1 + 1) * (y2 - y1 + 1);

            // Calculate sum using integral image
            double sum = integralSum.at<double>(y2 + 1, x2 + 1)
                       - integralSum.at<double>(y1, x2 + 1)
                       - integralSum.at<double>(y2 + 1, x1)
                       + integralSum.at<double>(y1, x1);

            double sqSum = integralSqSum.at<double>(y2 + 1, x2 + 1)
                         - integralSqSum.at<double>(y1, x2 + 1)
                         - integralSqSum.at<double>(y2 + 1, x1)
                         + integralSqSum.at<double>(y1, x1);

            double mean = sum / area;
            double variance = (sqSum / area) - (mean * mean);
            double stddev = std::sqrt(std::max(0.0, variance));

            // Sauvola threshold formula
            double threshold = mean * (1.0 + k * (stddev / R - 1.0));

            // Apply threshold
            if (gray.at<uchar>(y, x) > threshold) {
                binary.at<uchar>(y, x) = 255;
            }
        }
    }

    // Convert back to BGR for consistency
    cv::Mat result;
    cv::cvtColor(binary, result, cv::COLOR_GRAY2BGR);

    return result;
}
