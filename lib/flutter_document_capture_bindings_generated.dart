// ignore_for_file: always_specify_types
// ignore_for_file: camel_case_types
// ignore_for_file: non_constant_identifier_names
// ignore_for_file: unused_field
// ignore_for_file: unused_element

import 'dart:ffi' as ffi;

/// FFI bindings for flutter_document_capture native library
class DocumentCaptureBindings {
  final ffi.Pointer<T> Function<T extends ffi.NativeType>(String symbolName) _lookup;

  DocumentCaptureBindings(ffi.DynamicLibrary dynamicLibrary)
      : _lookup = dynamicLibrary.lookup;

  /// Create capture engine instance
  ffi.Pointer<ffi.Void> capture_engine_create() {
    return _capture_engine_create();
  }

  late final _capture_engine_createPtr =
      _lookup<ffi.NativeFunction<ffi.Pointer<ffi.Void> Function()>>(
          'capture_engine_create');
  late final _capture_engine_create =
      _capture_engine_createPtr.asFunction<ffi.Pointer<ffi.Void> Function()>();

  /// Destroy capture engine instance
  void capture_engine_destroy(ffi.Pointer<ffi.Void> engine) {
    return _capture_engine_destroy(engine);
  }

  late final _capture_engine_destroyPtr =
      _lookup<ffi.NativeFunction<ffi.Void Function(ffi.Pointer<ffi.Void>)>>(
          'capture_engine_destroy');
  late final _capture_engine_destroy = _capture_engine_destroyPtr
      .asFunction<void Function(ffi.Pointer<ffi.Void>)>();

  /// Reset engine state
  void capture_engine_reset(ffi.Pointer<ffi.Void> engine) {
    return _capture_engine_reset(engine);
  }

  late final _capture_engine_resetPtr =
      _lookup<ffi.NativeFunction<ffi.Void Function(ffi.Pointer<ffi.Void>)>>(
          'capture_engine_reset');
  late final _capture_engine_reset = _capture_engine_resetPtr
      .asFunction<void Function(ffi.Pointer<ffi.Void>)>();

  /// Analyze a single frame
  ffi.Pointer<ffi.Char> analyze_frame(
    ffi.Pointer<ffi.Void> engine,
    ffi.Pointer<ffi.Uint8> image_data,
    int width,
    int height,
    int format,
    int rotation,
    int crop_x,
    int crop_y,
    int crop_w,
    int crop_h,
  ) {
    return _analyze_frame(engine, image_data, width, height, format, rotation,
        crop_x, crop_y, crop_w, crop_h);
  }

  late final _analyze_framePtr = _lookup<
      ffi.NativeFunction<
          ffi.Pointer<ffi.Char> Function(
            ffi.Pointer<ffi.Void>,
            ffi.Pointer<ffi.Uint8>,
            ffi.Int32,
            ffi.Int32,
            ffi.Int32,
            ffi.Int32,
            ffi.Int32,
            ffi.Int32,
            ffi.Int32,
            ffi.Int32,
          )>>('analyze_frame');
  late final _analyze_frame = _analyze_framePtr.asFunction<
      ffi.Pointer<ffi.Char> Function(
        ffi.Pointer<ffi.Void>,
        ffi.Pointer<ffi.Uint8>,
        int,
        int,
        int,
        int,
        int,
        int,
        int,
        int,
      )>();

  /// Enhance captured image
  ffi.Pointer<ffi.Void> enhance_image(
    ffi.Pointer<ffi.Void> engine,
    ffi.Pointer<ffi.Uint8> image_data,
    int width,
    int height,
    int format,
    ffi.Pointer<ffi.Float> corners,
    int apply_perspective,
    int apply_deskew,
    int apply_enhance,
    int apply_sharpening,
    double sharpening_strength,
    int enhance_mode,
    int output_width,
    int output_height,
  ) {
    return _enhance_image(
      engine,
      image_data,
      width,
      height,
      format,
      corners,
      apply_perspective,
      apply_deskew,
      apply_enhance,
      apply_sharpening,
      sharpening_strength,
      enhance_mode,
      output_width,
      output_height,
    );
  }

  late final _enhance_imagePtr = _lookup<
      ffi.NativeFunction<
          ffi.Pointer<ffi.Void> Function(
            ffi.Pointer<ffi.Void>,
            ffi.Pointer<ffi.Uint8>,
            ffi.Int32,
            ffi.Int32,
            ffi.Int32,
            ffi.Pointer<ffi.Float>,
            ffi.Int32,
            ffi.Int32,
            ffi.Int32,
            ffi.Int32,
            ffi.Float,
            ffi.Int32,
            ffi.Int32,
            ffi.Int32,
          )>>('enhance_image');
  late final _enhance_image = _enhance_imagePtr.asFunction<
      ffi.Pointer<ffi.Void> Function(
        ffi.Pointer<ffi.Void>,
        ffi.Pointer<ffi.Uint8>,
        int,
        int,
        int,
        ffi.Pointer<ffi.Float>,
        int,
        int,
        int,
        int,
        double,
        int,
        int,
        int,
      )>();

  /// Enhance image with guide frame (auto-calculate virtual trapezoid)
  ffi.Pointer<ffi.Void> enhance_image_with_guide_frame(
    ffi.Pointer<ffi.Void> engine,
    ffi.Pointer<ffi.Uint8> image_data,
    int width,
    int height,
    int format,
    double guide_left,
    double guide_top,
    double guide_right,
    double guide_bottom,
    int apply_sharpening,
    double sharpening_strength,
    int enhance_mode,
    int rotation,
  ) {
    return _enhance_image_with_guide_frame(
      engine,
      image_data,
      width,
      height,
      format,
      guide_left,
      guide_top,
      guide_right,
      guide_bottom,
      apply_sharpening,
      sharpening_strength,
      enhance_mode,
      rotation,
    );
  }

  late final _enhance_image_with_guide_framePtr = _lookup<
      ffi.NativeFunction<
          ffi.Pointer<ffi.Void> Function(
            ffi.Pointer<ffi.Void>,
            ffi.Pointer<ffi.Uint8>,
            ffi.Int32,
            ffi.Int32,
            ffi.Int32,
            ffi.Float,
            ffi.Float,
            ffi.Float,
            ffi.Float,
            ffi.Int32,
            ffi.Float,
            ffi.Int32,
            ffi.Int32,
          )>>('enhance_image_with_guide_frame');
  late final _enhance_image_with_guide_frame = _enhance_image_with_guide_framePtr.asFunction<
      ffi.Pointer<ffi.Void> Function(
        ffi.Pointer<ffi.Void>,
        ffi.Pointer<ffi.Uint8>,
        int,
        int,
        int,
        double,
        double,
        double,
        double,
        int,
        double,
        int,
        int,
      )>();

  /// Get enhancement success status
  int get_enhancement_success(ffi.Pointer<ffi.Void> result) {
    return _get_enhancement_success(result);
  }

  late final _get_enhancement_successPtr =
      _lookup<ffi.NativeFunction<ffi.Int32 Function(ffi.Pointer<ffi.Void>)>>(
          'get_enhancement_success');
  late final _get_enhancement_success = _get_enhancement_successPtr
      .asFunction<int Function(ffi.Pointer<ffi.Void>)>();

  /// Get enhancement image data pointer
  ffi.Pointer<ffi.Uint8> get_enhancement_image_data(ffi.Pointer<ffi.Void> result) {
    return _get_enhancement_image_data(result);
  }

  late final _get_enhancement_image_dataPtr = _lookup<
      ffi.NativeFunction<
          ffi.Pointer<ffi.Uint8> Function(
              ffi.Pointer<ffi.Void>)>>('get_enhancement_image_data');
  late final _get_enhancement_image_data = _get_enhancement_image_dataPtr
      .asFunction<ffi.Pointer<ffi.Uint8> Function(ffi.Pointer<ffi.Void>)>();

  /// Get enhancement width
  int get_enhancement_width(ffi.Pointer<ffi.Void> result) {
    return _get_enhancement_width(result);
  }

  late final _get_enhancement_widthPtr =
      _lookup<ffi.NativeFunction<ffi.Int32 Function(ffi.Pointer<ffi.Void>)>>(
          'get_enhancement_width');
  late final _get_enhancement_width = _get_enhancement_widthPtr
      .asFunction<int Function(ffi.Pointer<ffi.Void>)>();

  /// Get enhancement height
  int get_enhancement_height(ffi.Pointer<ffi.Void> result) {
    return _get_enhancement_height(result);
  }

  late final _get_enhancement_heightPtr =
      _lookup<ffi.NativeFunction<ffi.Int32 Function(ffi.Pointer<ffi.Void>)>>(
          'get_enhancement_height');
  late final _get_enhancement_height = _get_enhancement_heightPtr
      .asFunction<int Function(ffi.Pointer<ffi.Void>)>();

  /// Get enhancement channels
  int get_enhancement_channels(ffi.Pointer<ffi.Void> result) {
    return _get_enhancement_channels(result);
  }

  late final _get_enhancement_channelsPtr =
      _lookup<ffi.NativeFunction<ffi.Int32 Function(ffi.Pointer<ffi.Void>)>>(
          'get_enhancement_channels');
  late final _get_enhancement_channels = _get_enhancement_channelsPtr
      .asFunction<int Function(ffi.Pointer<ffi.Void>)>();

  /// Get enhancement stride
  int get_enhancement_stride(ffi.Pointer<ffi.Void> result) {
    return _get_enhancement_stride(result);
  }

  late final _get_enhancement_stridePtr =
      _lookup<ffi.NativeFunction<ffi.Int32 Function(ffi.Pointer<ffi.Void>)>>(
          'get_enhancement_stride');
  late final _get_enhancement_stride = _get_enhancement_stridePtr
      .asFunction<int Function(ffi.Pointer<ffi.Void>)>();

  /// Get enhancement error message
  ffi.Pointer<ffi.Char> get_enhancement_error(ffi.Pointer<ffi.Void> result) {
    return _get_enhancement_error(result);
  }

  late final _get_enhancement_errorPtr = _lookup<
      ffi.NativeFunction<
          ffi.Pointer<ffi.Char> Function(
              ffi.Pointer<ffi.Void>)>>('get_enhancement_error');
  late final _get_enhancement_error = _get_enhancement_errorPtr
      .asFunction<ffi.Pointer<ffi.Char> Function(ffi.Pointer<ffi.Void>)>();

  /// Free enhancement result
  void free_enhancement_result(ffi.Pointer<ffi.Void> result) {
    return _free_enhancement_result(result);
  }

  late final _free_enhancement_resultPtr =
      _lookup<ffi.NativeFunction<ffi.Void Function(ffi.Pointer<ffi.Void>)>>(
          'free_enhancement_result');
  late final _free_enhancement_result = _free_enhancement_resultPtr
      .asFunction<void Function(ffi.Pointer<ffi.Void>)>();

  /// Free string
  void free_string(ffi.Pointer<ffi.Char> str) {
    return _free_string(str);
  }

  late final _free_stringPtr =
      _lookup<ffi.NativeFunction<ffi.Void Function(ffi.Pointer<ffi.Char>)>>(
          'free_string');
  late final _free_string =
      _free_stringPtr.asFunction<void Function(ffi.Pointer<ffi.Char>)>();

  /// Get version
  ffi.Pointer<ffi.Char> get_version() {
    return _get_version();
  }

  late final _get_versionPtr =
      _lookup<ffi.NativeFunction<ffi.Pointer<ffi.Char> Function()>>(
          'get_version');
  late final _get_version =
      _get_versionPtr.asFunction<ffi.Pointer<ffi.Char> Function()>();
}
