/// This file is a part of media_kit (https://github.com/media-kit/media-kit).
///
/// Copyright © 2021 & onwards, Hitesh Kumar Saini <saini123hitesh@gmail.com>.
/// All rights reserved.
/// Use of this source code is governed by MIT license that can be found in the LICENSE file.

import 'package:media_kit/src/models/player_log.dart';

/// {@template player_stream}
///
/// PlayerStream
/// ------------
///
/// Event [Stream]s for subscribing to [Player] events.
///
/// {@endtemplate}
class PlayerStream {

  /// [Stream] emitting internal logs.
  final Stream<PlayerLog> log;

  /// [Stream] emitting error messages. This may be used to handle & display errors to the user.
  final Stream<String> error;

  final Stream<List<int>> videoViewSize;

  /// {@macro player_stream}
  const PlayerStream(
    this.log,
    this.error,
    this.videoViewSize,
  );
}
