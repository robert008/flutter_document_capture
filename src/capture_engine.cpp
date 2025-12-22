#include "capture_engine.hpp"
#include <cstring>

#ifdef __ANDROID__
#include <android/log.h>
#endif

CaptureEngine::CaptureEngine() {
    detector_ = std::make_unique<DocumentDetector>();
    corrector_ = std::make_unique<PerspectiveCorrector>();
    assessor_ = std::make_unique<QualityAssessor>();
    enhancer_ = std::make_unique<ImageEnhancer>();
}

CaptureEngine::~CaptureEngine() {}

void CaptureEngine::reset() {
    if (assessor_) {
        assessor_->reset();
    }
}

cv::Mat CaptureEngine::bufferToMat(const uint8_t* data, int width, int height, int format) {
    cv::Mat result;

    switch (format) {
        case 0:  // BGRA
            result = cv::Mat(height, width, CV_8UC4, const_cast<uint8_t*>(data)).clone();
            break;
        case 1:  // BGR
            result = cv::Mat(height, width, CV_8UC3, const_cast<uint8_t*>(data)).clone();
            break;
        case 2:  // RGB
            {
                cv::Mat rgb(height, width, CV_8UC3, const_cast<uint8_t*>(data));
                cv::cvtColor(rgb, result, cv::COLOR_RGB2BGR);
            }
            break;
        default:
            // Assume BGR
            result = cv::Mat(height, width, CV_8UC3, const_cast<uint8_t*>(data)).clone();
            break;
    }

    return result;
}

FrameAnalysisResult CaptureEngine::analyzeFrame(
    const uint8_t* image_data,
    int width,
    int height,
    int format,
    int rotation,
    int crop_x,
    int crop_y,
    int crop_w,
    int crop_h
) {
    FrameAnalysisResult result;

    if (!image_data || width <= 0 || height <= 0) {
        return result;
    }

    // Convert buffer to cv::Mat
    cv::Mat frame = bufferToMat(image_data, width, height, format);

    if (frame.empty()) {
        return result;
    }

    // Apply rotation if needed (SIMD optimized via OpenCV)
    if (rotation == 90) {
        cv::rotate(frame, frame, cv::ROTATE_90_CLOCKWISE);
    } else if (rotation == 180) {
        cv::rotate(frame, frame, cv::ROTATE_180);
    } else if (rotation == 270) {
        cv::rotate(frame, frame, cv::ROTATE_90_COUNTERCLOCKWISE);
    }

    // Apply crop after rotation if specified
    if (crop_w > 0 && crop_h > 0) {
        int x = std::max(0, crop_x);
        int y = std::max(0, crop_y);
        int w = std::min(crop_w, frame.cols - x);
        int h = std::min(crop_h, frame.rows - y);
        if (w > 0 && h > 0) {
            frame = frame(cv::Rect(x, y, w, h)).clone();
        }
    }

    // Detect document corners
    DetectionResult detection = detector_->detect(frame);

    result.document_found = detection.found;
    result.corner_confidence = detection.confidence;

    // Debug: log detection result
    #ifdef __ANDROID__
    __android_log_print(ANDROID_LOG_INFO, "CaptureEngine",
        "Detection: found=%d, corners=%zu, imageSize=%dx%d",
        detection.found, detection.corners.size(), frame.cols, frame.rows);
    #else
    // iOS/macOS: use printf for debug
    printf("[CaptureEngine] Detection: found=%d, corners=%zu, imageSize=%dx%d\n",
        detection.found, detection.corners.size(), frame.cols, frame.rows);
    #endif

    if (detection.found && detection.corners.size() == 4) {
        // Document found - treat as TABLE detection
        result.table_found = true;

        // Copy corners to result
        for (int i = 0; i < 4; i++) {
            result.corners[i * 2] = detection.corners[i].x;
            result.corners[i * 2 + 1] = detection.corners[i].y;
        }

        // Debug: log corner coordinates
        #ifdef __ANDROID__
        __android_log_print(ANDROID_LOG_INFO, "CaptureEngine",
            "Corners: TL(%.1f,%.1f) TR(%.1f,%.1f) BR(%.1f,%.1f) BL(%.1f,%.1f)",
            detection.corners[0].x, detection.corners[0].y,
            detection.corners[1].x, detection.corners[1].y,
            detection.corners[2].x, detection.corners[2].y,
            detection.corners[3].x, detection.corners[3].y);
        #endif

        // Calculate trapezoid metrics
        // TL=0, TR=1, BR=2, BL=3
        float topWidth = std::sqrt(
            std::pow(detection.corners[1].x - detection.corners[0].x, 2) +
            std::pow(detection.corners[1].y - detection.corners[0].y, 2)
        );
        float bottomWidth = std::sqrt(
            std::pow(detection.corners[2].x - detection.corners[3].x, 2) +
            std::pow(detection.corners[2].y - detection.corners[3].y, 2)
        );
        float leftHeight = std::sqrt(
            std::pow(detection.corners[3].x - detection.corners[0].x, 2) +
            std::pow(detection.corners[3].y - detection.corners[0].y, 2)
        );
        float rightHeight = std::sqrt(
            std::pow(detection.corners[2].x - detection.corners[1].x, 2) +
            std::pow(detection.corners[2].y - detection.corners[1].y, 2)
        );

        result.top_width = topWidth;
        result.bottom_width = bottomWidth;
        result.left_height = leftHeight;
        result.right_height = rightHeight;

        // Calculate vertical skew (front-back tilt)
        float avgWidth = (topWidth + bottomWidth) / 2.0f;
        result.vertical_skew = (avgWidth > 0) ? std::abs(topWidth - bottomWidth) / avgWidth : 0;

        // Calculate horizontal skew (left-right offset)
        float avgHeight = (leftHeight + rightHeight) / 2.0f;
        result.horizontal_skew = (avgHeight > 0) ? std::abs(leftHeight - rightHeight) / avgHeight : 0;

        // Overall skew is max of vertical and horizontal
        result.skew_ratio = std::max(result.vertical_skew, result.horizontal_skew);

        // Is trapezoid if either skew > 5%
        result.is_trapezoid = result.skew_ratio > 0.05f;

        // Assess quality using table corners
        QualityScore quality = assessor_->assess(frame, detection.corners, detection.confidence);

        result.blur_score = quality.blur_score;
        result.brightness_score = quality.brightness_score;
        result.stability_score = quality.stability_score;
        result.overall_score = quality.overall();

        // Capture ready: need stability AND good quality
        result.capture_ready = quality.blur_score > 0.6f &&
                               quality.brightness_score > 0.5f &&
                               quality.stability_score > 0.8f;
    } else {
        // Document not found - use text regions detection as fallback
        TextRegionsResult textRegions = assessor_->detectTextRegions(frame);

        if (textRegions.found) {
            result.text_region_found = true;
            result.text_region_count = std::min(textRegions.regionCount, 8);
            result.coverage_ratio = textRegions.coverageRatio;

            // Copy overall bounds
            result.overall_bounds[0] = static_cast<float>(textRegions.overallBounds.x);
            result.overall_bounds[1] = static_cast<float>(textRegions.overallBounds.y);
            result.overall_bounds[2] = static_cast<float>(textRegions.overallBounds.width);
            result.overall_bounds[3] = static_cast<float>(textRegions.overallBounds.height);

            // Copy overall corners for stability tracking
            if (textRegions.overallCorners.size() == 4) {
                for (int i = 0; i < 4; i++) {
                    result.corners[i * 2] = textRegions.overallCorners[i].x;
                    result.corners[i * 2 + 1] = textRegions.overallCorners[i].y;
                }
            }

            // Copy individual region bounds (up to 8)
            for (int i = 0; i < result.text_region_count; i++) {
                const auto& region = textRegions.regions[i];
                result.text_regions_bounds[i * 4 + 0] = static_cast<float>(region.bounds.x);
                result.text_regions_bounds[i * 4 + 1] = static_cast<float>(region.bounds.y);
                result.text_regions_bounds[i * 4 + 2] = static_cast<float>(region.bounds.width);
                result.text_regions_bounds[i * 4 + 3] = static_cast<float>(region.bounds.height);
            }

            // Assess quality within overall bounds
            cv::Mat gray;
            if (frame.channels() == 3) {
                cv::cvtColor(frame, gray, cv::COLOR_BGR2GRAY);
            } else if (frame.channels() == 4) {
                cv::cvtColor(frame, gray, cv::COLOR_BGRA2GRAY);
            } else {
                gray = frame;
            }

            result.blur_score = assessor_->detectBlurInRegion(gray, textRegions.overallBounds);
            result.brightness_score = assessor_->checkBrightnessInRegion(gray, textRegions.overallBounds);

            // Track stability using overall corners
            if (textRegions.overallCorners.size() == 4) {
                QualityScore tempScore = assessor_->assess(frame, textRegions.overallCorners, textRegions.coverageRatio);
                result.stability_score = tempScore.stability_score;
            }

            result.corner_confidence = textRegions.coverageRatio;
            result.overall_score = result.blur_score * 0.4f + result.brightness_score * 0.2f +
                                   result.stability_score * 0.2f + result.corner_confidence * 0.2f;
        } else {
            // No text regions found, assess full frame
            cv::Mat gray;
            if (frame.channels() == 3) {
                cv::cvtColor(frame, gray, cv::COLOR_BGR2GRAY);
            } else {
                gray = frame;
            }
            result.blur_score = assessor_->detectBlur(gray);
            result.brightness_score = assessor_->checkBrightness(gray);
        }

        // Capture ready based on quality
        result.capture_ready = result.blur_score > 0.6f &&
                               result.brightness_score > 0.5f &&
                               result.stability_score > 0.9f;
    }

    // Store result for use in enhanceImageWithGuideFrame
    last_analysis_ = result;

    return result;
}

EnhancementResult CaptureEngine::enhanceImage(
    const uint8_t* image_data,
    int width,
    int height,
    int format,
    const float* corners,
    const EnhancementOptions& options
) {
    EnhancementResult result;

    if (!image_data || width <= 0 || height <= 0) {
        strncpy(result.error_message, "Invalid image data", sizeof(result.error_message) - 1);
        return result;
    }

    if (!corners) {
        strncpy(result.error_message, "Corners not provided", sizeof(result.error_message) - 1);
        return result;
    }

    // Convert buffer to cv::Mat
    cv::Mat frame = bufferToMat(image_data, width, height, format);

    if (frame.empty()) {
        strncpy(result.error_message, "Failed to create image from buffer", sizeof(result.error_message) - 1);
        return result;
    }

    cv::Mat processed = frame;

    // Apply simple rectangular crop
    if (options.apply_crop && !options.apply_perspective_correction) {
        // Get bounding box from corners
        float minX = std::min({corners[0], corners[2], corners[4], corners[6]});
        float maxX = std::max({corners[0], corners[2], corners[4], corners[6]});
        float minY = std::min({corners[1], corners[3], corners[5], corners[7]});
        float maxY = std::max({corners[1], corners[3], corners[5], corners[7]});

        // Clamp to image bounds
        int x = std::max(0, static_cast<int>(minX));
        int y = std::max(0, static_cast<int>(minY));
        int w = std::min(frame.cols - x, static_cast<int>(maxX - minX));
        int h = std::min(frame.rows - y, static_cast<int>(maxY - minY));

        if (w > 0 && h > 0) {
            cv::Rect roi(x, y, w, h);
            processed = frame(roi).clone();
        }
    }

    // Apply perspective correction
    if (options.apply_perspective_correction) {
        std::vector<cv::Point2f> cornerPoints = {
            cv::Point2f(corners[0], corners[1]),  // TL
            cv::Point2f(corners[2], corners[3]),  // TR
            cv::Point2f(corners[4], corners[5]),  // BR
            cv::Point2f(corners[6], corners[7])   // BL
        };

        cv::Size outputSize(options.output_width, options.output_height);
        CorrectionResult correction = corrector_->correct(processed, cornerPoints, outputSize);

        if (correction.success) {
            processed = correction.image;
        } else {
            strncpy(result.error_message, "Perspective correction failed", sizeof(result.error_message) - 1);
            return result;
        }
    }

    // Convert to BGR if needed (ensure 3 channels)
    if (processed.channels() == 4) {
        cv::cvtColor(processed, processed, cv::COLOR_BGRA2BGR);
    }

    // Apply auto enhancement (CLAHE + brightness)
    if (options.apply_auto_enhance && enhancer_) {
        EnhanceConfig enhanceConfig;
        enhanceConfig.apply_clahe = true;
        enhanceConfig.apply_brightness_adjust = true;
        enhanceConfig.apply_sharpening = false;
        enhanceConfig.clahe_clip_limit = 2.0f;
        enhanceConfig.clahe_tile_size = 8;
        enhanceConfig.target_brightness = 0.5f;

        processed = enhancer_->enhance(processed, enhanceConfig);
    }

    // Apply sharpening (independent of auto enhance)
    if (options.apply_sharpening && enhancer_) {
        processed = enhancer_->sharpen(processed, options.sharpening_strength);
    }

    // Apply OCR enhancement mode
    if (enhancer_) {
        switch (options.enhance_mode) {
            case ENHANCE_WHITEN_BG:
                processed = enhancer_->whitenBackground(processed, 200);
                break;
            case ENHANCE_CONTRAST_STRETCH:
                processed = enhancer_->stretchContrast(processed);
                break;
            case ENHANCE_ADAPTIVE_BINARIZE:
                processed = enhancer_->adaptiveBinarize(processed, 11, 2);
                break;
            case ENHANCE_SAUVOLA:
                processed = enhancer_->sauvolaBinarize(processed, 15, 0.2, 128);
                break;
            case ENHANCE_NONE:
            default:
                break;
        }
    }

    // Allocate output buffer
    result.width = processed.cols;
    result.height = processed.rows;
    result.channels = processed.channels();
    result.stride = static_cast<int>(processed.step);

    size_t dataSize = processed.total() * processed.elemSize();
    result.image_data = new uint8_t[dataSize];
    memcpy(result.image_data, processed.data, dataSize);

    result.success = true;
    return result;
}

void CaptureEngine::freeEnhancementResult(EnhancementResult* result) {
    if (result && result->image_data) {
        delete[] result->image_data;
        result->image_data = nullptr;
    }
}

void CaptureEngine::calculateVirtualTrapezoid(
    float guide_left, float guide_top, float guide_right, float guide_bottom,
    float* out_corners
) {
    float guide_width = guide_right - guide_left;
    float guide_height = guide_bottom - guide_top;

    // Default to rectangular guide frame
    float tl_x = guide_left, tl_y = guide_top;
    float tr_x = guide_right, tr_y = guide_top;
    float br_x = guide_right, br_y = guide_bottom;
    float bl_x = guide_left, bl_y = guide_bottom;

    // Only apply skew if we have a valid table detection with trapezoid
    if (last_analysis_.table_found && last_analysis_.is_trapezoid) {
        // Apply vertical skew (front-back tilt): adjust left/right of top/bottom edges
        if (last_analysis_.vertical_skew > 0.01f) {
            float topW = last_analysis_.top_width;
            float bottomW = last_analysis_.bottom_width;
            float avgW = (topW + bottomW) / 2.0f;

            if (avgW > 0) {
                float skewDiff = (bottomW - topW) / avgW;
                float h_adjustment = guide_width * std::abs(skewDiff) / 2.0f;

                if (bottomW > topW) {
                    // Bottom wider: shrink top edges
                    tl_x += h_adjustment;
                    tr_x -= h_adjustment;
                } else {
                    // Top wider: shrink bottom edges
                    bl_x += h_adjustment;
                    br_x -= h_adjustment;
                }
            }
        }

        // Apply horizontal skew (left-right offset): adjust top/bottom of left/right edges
        if (last_analysis_.horizontal_skew > 0.01f) {
            float leftH = last_analysis_.left_height;
            float rightH = last_analysis_.right_height;
            float avgH = (leftH + rightH) / 2.0f;

            if (avgH > 0) {
                float skewDiff = (rightH - leftH) / avgH;
                float v_adjustment = guide_height * std::abs(skewDiff) / 2.0f;

                if (rightH > leftH) {
                    // Right taller: shrink left edges
                    tl_y += v_adjustment;
                    bl_y -= v_adjustment;
                } else {
                    // Left taller: shrink right edges
                    tr_y += v_adjustment;
                    br_y -= v_adjustment;
                }
            }
        }
    }

    // Output: TL, TR, BR, BL
    out_corners[0] = tl_x; out_corners[1] = tl_y;
    out_corners[2] = tr_x; out_corners[3] = tr_y;
    out_corners[4] = br_x; out_corners[5] = br_y;
    out_corners[6] = bl_x; out_corners[7] = bl_y;
}

EnhancementResult CaptureEngine::enhanceImageWithGuideFrame(
    const uint8_t* image_data,
    int width,
    int height,
    int format,
    float guide_left,
    float guide_top,
    float guide_right,
    float guide_bottom,
    const EnhancementOptions& options,
    int rotation
) {
    EnhancementResult result;

    if (!image_data || width <= 0 || height <= 0) {
        strncpy(result.error_message, "Invalid image data", sizeof(result.error_message) - 1);
        return result;
    }

    // Convert buffer to cv::Mat
    cv::Mat frame = bufferToMat(image_data, width, height, format);

    if (frame.empty()) {
        strncpy(result.error_message, "Failed to create image from buffer", sizeof(result.error_message) - 1);
        return result;
    }

    // Apply rotation if needed (SIMD optimized via OpenCV)
    if (rotation == 90) {
        cv::rotate(frame, frame, cv::ROTATE_90_CLOCKWISE);
    } else if (rotation == 180) {
        cv::rotate(frame, frame, cv::ROTATE_180);
    } else if (rotation == 270) {
        cv::rotate(frame, frame, cv::ROTATE_90_COUNTERCLOCKWISE);
    }

    // Calculate virtual trapezoid corners from guide frame
    float corners[8];
    calculateVirtualTrapezoid(guide_left, guide_top, guide_right, guide_bottom, corners);

    // Determine if we need perspective correction
    EnhancementOptions adjusted_options = options;
    adjusted_options.apply_perspective_correction = last_analysis_.table_found && last_analysis_.is_trapezoid;
    adjusted_options.apply_crop = !adjusted_options.apply_perspective_correction;

    cv::Mat processed = frame;

    // Apply simple rectangular crop
    if (adjusted_options.apply_crop && !adjusted_options.apply_perspective_correction) {
        float minX = std::min({corners[0], corners[2], corners[4], corners[6]});
        float maxX = std::max({corners[0], corners[2], corners[4], corners[6]});
        float minY = std::min({corners[1], corners[3], corners[5], corners[7]});
        float maxY = std::max({corners[1], corners[3], corners[5], corners[7]});

        int x = std::max(0, static_cast<int>(minX));
        int y = std::max(0, static_cast<int>(minY));
        int w = std::min(frame.cols - x, static_cast<int>(maxX - minX));
        int h = std::min(frame.rows - y, static_cast<int>(maxY - minY));

        if (w > 0 && h > 0) {
            cv::Rect roi(x, y, w, h);
            processed = frame(roi).clone();
        }
    }

    // Apply perspective correction
    if (adjusted_options.apply_perspective_correction) {
        std::vector<cv::Point2f> cornerPoints = {
            cv::Point2f(corners[0], corners[1]),
            cv::Point2f(corners[2], corners[3]),
            cv::Point2f(corners[4], corners[5]),
            cv::Point2f(corners[6], corners[7])
        };

        cv::Size outputSize(adjusted_options.output_width, adjusted_options.output_height);
        CorrectionResult correction = corrector_->correct(processed, cornerPoints, outputSize);

        if (correction.success) {
            processed = correction.image;
        } else {
            strncpy(result.error_message, "Perspective correction failed", sizeof(result.error_message) - 1);
            return result;
        }
    }

    // Convert to BGR if needed
    if (processed.channels() == 4) {
        cv::cvtColor(processed, processed, cv::COLOR_BGRA2BGR);
    }

    // Apply sharpening
    if (adjusted_options.apply_sharpening && enhancer_) {
        processed = enhancer_->sharpen(processed, adjusted_options.sharpening_strength);
    }

    // Apply OCR enhancement mode
    if (enhancer_) {
        switch (adjusted_options.enhance_mode) {
            case ENHANCE_WHITEN_BG:
                processed = enhancer_->whitenBackground(processed, 200);
                break;
            case ENHANCE_CONTRAST_STRETCH:
                processed = enhancer_->stretchContrast(processed);
                break;
            case ENHANCE_ADAPTIVE_BINARIZE:
                processed = enhancer_->adaptiveBinarize(processed, 11, 2);
                break;
            case ENHANCE_SAUVOLA:
                processed = enhancer_->sauvolaBinarize(processed, 15, 0.2, 128);
                break;
            case ENHANCE_NONE:
            default:
                break;
        }
    }

    // Allocate output buffer
    result.width = processed.cols;
    result.height = processed.rows;
    result.channels = processed.channels();
    result.stride = static_cast<int>(processed.step);

    size_t dataSize = processed.total() * processed.elemSize();
    result.image_data = new uint8_t[dataSize];
    memcpy(result.image_data, processed.data, dataSize);

    result.success = true;
    return result;
}
