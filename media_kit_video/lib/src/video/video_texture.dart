/// This file is a part of media_kit (https://github.com/media-kit/media-kit).
///
/// Copyright © 2021 & onwards, Hitesh Kumar Saini <saini123hitesh@gmail.com>.
/// All rights reserved.
/// Use of this source code is governed by MIT license that can be found in the LICENSE file.
import 'dart:io';
import 'dart:async';
import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';

import 'package:media_kit_video/media_kit_video_controls/media_kit_video_controls.dart'
    as media_kit_video_controls;

import 'package:media_kit_video/src/video_controller/video_controller.dart';
import 'package:media_kit_video/src/video_controller/platform_video_controller.dart';

/// {@template video}
///
/// Video
/// -----
/// [Video] widget is used to display video output.
///
/// Use [VideoController] to initialize & handle the video rendering.
///
/// **Example:**
///
/// ```dart
/// class MyScreen extends StatefulWidget {
///   const MyScreen({Key? key}) : super(key: key);
///   @override
///   State<MyScreen> createState() => MyScreenState();
/// }
///
/// class MyScreenState extends State<MyScreen> {
///   late final player = Player();
///   late final controller = VideoController(player);
///
///   @override
///   void initState() {
///     super.initState();
///     player.open(Media('https://user-images.githubusercontent.com/28951144/229373695-22f88f13-d18f-4288-9bf1-c3e078d83722.mp4'));
///   }
///
///   @override
///   void dispose() {
///     player.dispose();
///     super.dispose();
///   }
///
///   @override
///   Widget build(BuildContext context) {
///     return Scaffold(
///       body: Video(
///         controller: controller,
///       ),
///     );
///   }
/// }
/// ```
///
/// {@endtemplate}
class Video extends StatefulWidget {
  /// The [VideoController] reference to control this [Video] output.
  final VideoController controller;

  /// Video controls builder.
  final VideoControlsBuilder? controls;

  /// FocusNode for keyboard input.
  final FocusNode? focusNode;

  /// {@macro video}
  const Video({
    Key? key,
    required this.controller,
    this.controls = media_kit_video_controls.AdaptiveVideoControls,
    this.focusNode,
  }) : super(key: key);

  @override
  State<Video> createState() => VideoState();
}

class VideoState extends State<Video> with WidgetsBindingObserver {
  final _subscriptions = <StreamSubscription>[];
  late int? _width = widget.controller.player.state.width;
  late int? _height = widget.controller.player.state.height;
  late bool _visible = (_width ?? 0) > 0 && (_height ?? 0) > 0;

  @override
  void didChangeDependencies() {
    _calculateVideoViewSize();
    super.didChangeDependencies();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // --------------------------------------------------
    // Do not show the video frame until width & height are available.
    // Since [ValueNotifier<Rect?>] inside [VideoController] only gets updated by the render loop (i.e. it will not fire when video's width & height are not available etc.), it's important to handle this separately here.
    _subscriptions.addAll(
      [
        widget.controller.player.stream.width.listen(
          (value) {
            _width = value;
            final visible = (_width ?? 0) > 0 && (_height ?? 0) > 0;
            if (_visible != visible) {
              setState(() {
                _visible = visible;
              });
            }
          },
        ),
        widget.controller.player.stream.height.listen(
          (value) {
            _height = value;
            final visible = (_width ?? 0) > 0 && (_height ?? 0) > 0;
            if (_visible != visible) {
              setState(() {
                _visible = visible;
              });
            }
          },
        ),
      ],
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }

    super.dispose();
  }

  @override
  void didChangeMetrics() {
    super.didChangeMetrics();
    _calculateVideoViewSize();
  }

  void _calculateVideoViewSize() async {
    final Size? displaySize = View.maybeOf(context)?.physicalSize;
    if (displaySize == null || displaySize.isEmpty) return;

    final PlatformPlayer? platform = widget.controller.player.platform;
    if (platform is NativePlayer) {
      await platform.videoControllerCompleter.future;
      if (!platform.videoViewSizeController.isClosed) {
        platform.videoViewSizeController.add([displaySize.width.toInt(), displaySize.height.toInt()]);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      clipBehavior: Clip.none,
      child: Stack(
        fit: StackFit.expand,
        children: [
          ClipRect(
            child: FittedBox(
              child: ValueListenableBuilder<PlatformVideoController?>(
                valueListenable: widget.controller.notifier,
                builder: (context, notifier, _) => notifier == null
                    ? const SizedBox.shrink()
                    : ValueListenableBuilder<int?>(
                  valueListenable: notifier.id,
                  builder: (context, id, _) {
                    return ValueListenableBuilder<Rect?>(
                      valueListenable: notifier.rect,
                      builder: (context, rect, _) {
                        if (id != null &&
                            rect != null &&
                            _visible) {
                          return SizedBox(
                            // Apply aspect ratio if provided.
                            width:  rect.width,
                            height: rect.height,
                            child: Stack(
                              children: [
                                const SizedBox(),
                                Positioned.fill(
                                  child: Texture(
                                    textureId: id,
                                  ),
                                ),
                                // Keep the |Texture| hidden before the first frame renders. In native implementation, if no default frame size is passed (through VideoController), a starting 1 pixel sized texture/surface is created to initialize the render context & check for H/W support.
                                // This is then resized based on the video dimensions & accordingly texture ID, texture, EGLDisplay, EGLSurface etc. (depending upon platform) are also changed. Just don't show that 1 pixel texture to the UI.
                                // NOTE: Unmounting |Texture| causes the |MarkTextureFrameAvailable| to not do anything on GNU/Linux.
                                if (rect.width <= 1.0 &&
                                    rect.height <= 1.0)
                                  Positioned.fill(
                                    child: Container(
                                      color: const Color(0xFF000000),
                                    ),
                                  ),
                              ],
                            ),
                          );
                        }
                        return const SizedBox.shrink();
                      },
                    );
                  },
                ),
              ),
            ),
          ),
          if (widget.controls != null)
            Positioned.fill(
              child: widget.controls!.call(this),
            ),
        ],
      ),
    );
  }
}

typedef VideoControlsBuilder = Widget Function(VideoState state);