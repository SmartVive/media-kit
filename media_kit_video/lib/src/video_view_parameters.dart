/// This file is a part of media_kit (https://github.com/media-kit/media-kit).
///
/// Copyright © 2023 & onwards, Abdelaziz Mahdy <abdelaziz.h.mahdy@gmail.com>.
/// All rights reserved.
/// Use of this source code is governed by MIT license that can be found in the LICENSE file.
import 'dart:async';
import 'package:flutter/widgets.dart';

import 'package:media_kit_video/src/video/video.dart';

/// {@template video_view_parameters}
///
/// VideoViewParameters
/// -------------------
///
/// The attributes of a [Video] widget composed into a single class.
///
/// {@endtemplate}
class VideoViewParameters {
  final double? width;
  final double? height;
  final BoxFit fit;
  final Color fill;
  final Alignment alignment;
  final double? aspectRatio;
  final FilterQuality filterQuality;
  final /* VideoControlsBuilder? */ dynamic controls;
  final FocusNode? focusNode;

  /// {@macro video_view_parameters}
  VideoViewParameters({
    required this.width,
    required this.height,
    required this.fit,
    required this.fill,
    required this.alignment,
    required this.aspectRatio,
    required this.filterQuality,
    required this.controls,
    this.focusNode,
  });

  VideoViewParameters copyWith({
    double? width,
    double? height,
    BoxFit? fit,
    Color? fill,
    Alignment? alignment,
    double? aspectRatio,
    FilterQuality? filterQuality,
    /* VideoControlsBuilder? */ dynamic controls,
    bool? pauseUponEnteringBackgroundMode,
    bool? resumeUponEnteringForegroundMode,
    Future<void> Function()? onEnterFullscreen,
    Future<void> Function()? onExitFullscreen,
    FocusNode? focusNode,
  }) {
    return VideoViewParameters(
      width: width ?? this.width,
      height: height ?? this.height,
      fit: fit ?? this.fit,
      fill: fill ?? this.fill,
      alignment: alignment ?? this.alignment,
      aspectRatio: aspectRatio ?? this.aspectRatio,
      filterQuality: filterQuality ?? this.filterQuality,
      controls: controls ?? this.controls,
      focusNode: focusNode ?? this.focusNode,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is VideoViewParameters &&
          other.width == width &&
          other.height == height &&
          other.fit == fit &&
          other.fill == fill &&
          other.alignment == alignment &&
          other.aspectRatio == aspectRatio &&
          other.filterQuality == filterQuality &&
          other.controls == controls &&
          other.focusNode == focusNode;

  @override
  int get hashCode =>
      width.hashCode ^
      height.hashCode ^
      fit.hashCode ^
      fill.hashCode ^
      alignment.hashCode ^
      aspectRatio.hashCode ^
      filterQuality.hashCode ^
      controls.hashCode ^
      focusNode.hashCode;
}
