/// This file is a part of media_kit (https://github.com/media-kit/media-kit).
///
/// Copyright © 2021 & onwards, Hitesh Kumar Saini <saini123hitesh@gmail.com>.
/// All rights reserved.
/// Use of this source code is governed by MIT license that can be found in the LICENSE file.
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

  /// {@macro video}
  const Video({
    Key? key,
    required this.controller,
    this.controls = media_kit_video_controls.AdaptiveVideoControls,
  }) : super(key: key);

  @override
  State<Video> createState() => VideoState();
}

class VideoState extends State<Video> with WidgetsBindingObserver {

  @override
  void didChangeDependencies() {
    _calculateVideoViewSize();
    super.didChangeDependencies();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
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
      color: const Color(0xFF000000),
      child: Stack(
        fit: StackFit.expand,
        children: [
          FittedBox(
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
                      if (id != null && rect != null) {
                        return Container(
                          width:  rect.width,
                          height: rect.height,
                          child: Texture(
                            textureId: id,
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