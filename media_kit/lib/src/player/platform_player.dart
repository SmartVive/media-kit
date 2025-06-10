/// This file is a part of media_kit (https://github.com/media-kit/media-kit).
///
/// Copyright © 2021 & onwards, Hitesh Kumar Saini <saini123hitesh@gmail.com>.
/// All rights reserved.
/// Use of this source code is governed by MIT license that can be found in the LICENSE file.

import 'dart:async';
import 'package:meta/meta.dart';
import 'package:collection/collection.dart';

import 'package:media_kit/src/models/player_log.dart';
import 'package:media_kit/src/models/player_stream.dart';

/// {@template platform_player}
/// PlatformPlayer
/// --------------
///
/// This class provides the interface for platform specific [Player] implementations.
/// The platform specific implementations are expected to implement the methods accordingly.
///
/// The subclasses are then used in composition with the [Player] class, based on the platform the application is running on.
///
/// {@endtemplate}
abstract class PlatformPlayer {
  /// {@macro platform_player}
  PlatformPlayer({required this.configuration});

  /// User defined configuration for [Player].
  final PlayerConfiguration configuration;

  /// Current state of the player available as listenable [Stream]s.
  late PlayerStream stream = PlayerStream(
    logController.stream.distinct(
      (previous, current) => previous == current,
    ),
    /* ERROR STREAM SHOULD NOT BE DISTINCT */
    errorController.stream,
    videoViewSizeController.stream.distinct(
      (previous, current) => ListEquality().equals(previous, current),
    )
  );

  @mustCallSuper
  Future<void> dispose() async {
    await Future.wait(
      [
        logController.close(),
        errorController.close(),
        videoViewSizeController.close()
      ],
    );
    for (final callback in release) {
      try {
        await callback.call();
      } catch (exception, stacktrace) {
        print(exception.toString());
        print(stacktrace.toString());
      }
    }
  }

  Future<int> get handle {
    throw UnimplementedError(
      '[PlatformPlayer.handle] is not implemented',
    );
  }

  @protected
  final StreamController<PlayerLog> logController =
      StreamController<PlayerLog>.broadcast();

  @protected
  final StreamController<String> errorController =
      StreamController<String>.broadcast();

  final StreamController<List<int>> videoViewSizeController =
      StreamController<List<int>>.broadcast();

  // --------------------------------------------------

  /// [Completer] to wait for initialization of this instance.
  final Completer<void> completer = Completer<void>();

  /// [Future<void>] to wait for initialization of this instance.
  Future<void> get waitForPlayerInitialization => completer.future;

  // --------------------------------------------------

  /// [bool] for signaling [VideoController] (from `package:media_kit_video`) initialization.
  bool isVideoControllerAttached = false;

  /// [Completer] for signaling [VideoController] (from `package:media_kit_video`) initialization.
  final Completer<void> videoControllerCompleter = Completer<void>();

  /// [Future<void>] to wait for [VideoController] (from `package:media_kit_video`) initialization.
  Future<void> get waitForVideoControllerInitializationIfAttached {
    if (isVideoControllerAttached) {
      return videoControllerCompleter.future;
    }
    return Future.value(null);
  }

  // --------------------------------------------------

  /// Publicly defined clean-up [Function]s which must be called before [dispose].
  final List<Future<void> Function()> release = [];
}

/// {@template player_configuration}
///
/// PlayerConfiguration
/// --------------------
/// Configurable options for customizing the [Player] behavior.
///
/// {@endtemplate}
class PlayerConfiguration {
  /// Enables or disables pitch shift control for native backend.
  ///
  /// Enabling this option may result in de-syncing of audio & video.
  /// Thus, usage in audio only applications is recommended.
  /// This uses `scaletempo` under the hood & disables `audio-pitch-correction`.
  ///
  /// See: https://github.com/media-kit/media-kit/issues/45
  ///
  /// Default: `false`.
  final bool pitch;

  /// Sets the name of the underlying window & process for native backend.
  /// This is visible inside the Windows' volume mixer.
  ///
  /// Default: `null`.
  final String title;

  /// Optional callback invoked when the internals of the [Player] are initialized & ready for playback.
  ///
  /// Default: `null`.
  final void Function()? ready;

  /// Whether [Player] must be started in muted state.
  ///
  /// Default: `false`.
  final bool muted;

  /// Whether to use the async API for native backend.
  ///
  /// Default: `true`.
  final bool async;

  /// Whether to use [libass](https://github.com/libass/libass) based subtitle rendering for native backend.
  ///
  /// By default, subtitles rendering is Flutter `Widget` based.
  ///
  /// On Android, this option requires [libassAndroidFont] to be set.
  final bool libass;

  /// Sets the log level on native backend.
  /// Default: `none`.
  final MPVLogLevel logLevel;

  ///  Sets the options for native backend.
  final Map<String, String>? options;

  /// {@macro player_configuration}
  const PlayerConfiguration({
    this.pitch = false,
    this.title = 'package:media_kit',
    this.ready,
    this.muted = false,
    this.async = true,
    this.libass = false,
    this.logLevel = MPVLogLevel.error,
    this.options,
  });
}

/// {@template mpv_log_level}
///
/// MPVLogLevel
/// --------------------
/// Options to customise the [Player] native backend log level.
///
/// {@endtemplate}
enum MPVLogLevel {
  /// Disable absolutely all messages.
  /* none, */

  /// Critical/aborting errors.
  /* fatal, */

  // package:media_kit internally consumes logs of level error.

  /// Simple errors.
  error,

  /// Possible problems.
  warn,

  /// Informational message.
  info,

  /// Noisy informational message.
  v,

  /// Very noisy technical information.
  debug,

  /// Extremely noisy.
  trace,
}
