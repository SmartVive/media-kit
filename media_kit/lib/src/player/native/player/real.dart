/// This file is a part of media_kit (https://github.com/media-kit/media-kit).
///
/// Copyright © 2021 & onwards, Hitesh Kumar Saini <saini123hitesh@gmail.com>.
/// All rights reserved.
/// Use of this source code is governed by MIT license that can be found in the LICENSE file.
import 'dart:io';
import 'dart:ffi';
import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';
import 'package:path/path.dart';
import 'package:meta/meta.dart';
import 'package:image/image.dart';
import 'package:synchronized/synchronized.dart';
import 'package:safe_local_storage/safe_local_storage.dart';

import 'package:media_kit/ffi/ffi.dart';

import 'package:media_kit/src/models/audio_device.dart';
import 'package:media_kit/src/models/audio_params.dart';
import 'package:media_kit/src/models/media/media.dart';
import 'package:media_kit/src/models/playable.dart';
import 'package:media_kit/src/models/player_log.dart';
import 'package:media_kit/src/models/player_state.dart';
import 'package:media_kit/src/models/playlist_mode.dart';
import 'package:media_kit/src/models/playlist.dart';
import 'package:media_kit/src/models/track.dart';
import 'package:media_kit/src/models/video_params.dart';
import 'package:media_kit/src/player/native/core/fallback_bitrate_handler.dart';
import 'package:media_kit/src/player/native/core/initializer.dart';
import 'package:media_kit/src/player/native/core/native_library.dart';
import 'package:media_kit/src/player/native/utils/android_asset_loader.dart';
import 'package:media_kit/src/player/native/utils/android_helper.dart';
import 'package:media_kit/src/player/native/utils/isolates.dart';
import 'package:media_kit/src/player/native/utils/native_reference_holder.dart';
import 'package:media_kit/src/player/native/utils/temp_file.dart';
import 'package:media_kit/src/player/platform_player.dart';

import 'package:media_kit/generated/libmpv/bindings.dart' as generated;

/// Initializes the native backend for package:media_kit.
void nativeEnsureInitialized({String? libmpv}) {
  AndroidHelper.ensureInitialized();
  NativeLibrary.ensureInitialized(libmpv: libmpv);
  NativeReferenceHolder.ensureInitialized((references) async {
    if (references.isEmpty) {
      return;
    }
    const tag = NativeReferenceHolder.kTag;
    print('$tag Found ${references.length} reference(s).');
    print('$tag Disposing:\n${references.map((e) => e.address).join('\n')}');

    // I can only get quit to work; [mpv_terminate_destroy] causes direct crash.
    final mpv = generated.MPV(DynamicLibrary.open(NativeLibrary.path));
    final cmd = 'quit'.toNativeUtf8();
    try {
      for (final reference in references) {
        mpv.mpv_command_string(reference.cast(), cmd.cast());
      }
    } finally {
      calloc.free(cmd);
    }
  });
}

/// {@template native_player}
///
/// NativePlayer
/// ------------
///
/// Native implementation of [PlatformPlayer].
///
/// {@endtemplate}
class NativePlayer extends PlatformPlayer {
  /// {@macro native_player}
  NativePlayer({required super.configuration})
      : mpv = generated.MPV(DynamicLibrary.open(NativeLibrary.path)) {
    future = _create()
      ..then((_) {
        try {
          configuration.ready?.call();
        } catch (_) {}
      });
  }

  /// Disposes the [Player] instance & releases the resources.
  @override
  Future<void> dispose({bool synchronized = true}) {
    Future<void> function() async {
      if (disposed) {
        throw AssertionError('[Player] has been disposed');
      }
      await waitForPlayerInitialization;
      await waitForVideoControllerInitializationIfAttached;

      await NativeReferenceHolder.instance.remove(ctx);

      disposed = true;

      await super.dispose();

      Initializer(mpv).dispose(ctx);

      Future.delayed(const Duration(seconds: 5), () {
        mpv.mpv_terminate_destroy(ctx);
      });
    }

    if (synchronized) {
      return lock.synchronized(function);
    } else {
      return function();
    }
  }

  /// Internal platform specific identifier for this [Player] instance.
  ///
  /// Since, [int] is a primitive type, it can be used to pass this [Player] instance to native code without directly depending upon this library.
  ///
  @override
  Future<int> get handle async {
    await waitForPlayerInitialization;
    return ctx.address;
  }

  /// Sets property for the internal libmpv instance of this [Player].
  /// Please use this method only if you know what you are doing, existing methods in [Player] implementation are suited for the most use cases.
  ///
  /// See:
  /// * https://mpv.io/manual/master/#options
  /// * https://mpv.io/manual/master/#properties
  ///
  Future<void> setProperty(
    String property,
    String value, {
    bool waitForInitialization = true,
  }) async {
    if (disposed) {
      throw AssertionError('[Player] has been disposed');
    }

    if (waitForInitialization) {
      await waitForPlayerInitialization;
      await waitForVideoControllerInitializationIfAttached;
    }

    final name = property.toNativeUtf8();
    final data = value.toNativeUtf8();
    mpv.mpv_set_property_string(
      ctx,
      name.cast(),
      data.cast(),
    );
    calloc.free(name);
    calloc.free(data);
  }

  /// Retrieves the value of a property from the internal libmpv instance of this [Player].
  /// Please use this method only if you know what you are doing, existing methods in [Player] implementation are suited for the most use cases.
  ///
  /// See:
  /// * https://mpv.io/manual/master/#options
  /// * https://mpv.io/manual/master/#properties
  ///
  Future<String> getProperty(
    String property, {
    bool waitForInitialization = true,
  }) async {
    if (disposed) {
      throw AssertionError('[Player] has been disposed');
    }

    if (waitForInitialization) {
      await waitForPlayerInitialization;
      await waitForVideoControllerInitializationIfAttached;
    }

    final name = property.toNativeUtf8();
    final value = mpv.mpv_get_property_string(ctx, name.cast());
    if (value != nullptr) {
      final result = value.cast<Utf8>().toDartString();
      calloc.free(name);
      mpv.mpv_free(value.cast());

      return result;
    }

    return "";
  }

  /// Observes property for the internal libmpv instance of this [Player].
  /// Please use this method only if you know what you are doing, existing methods in [Player] implementation are suited for the most use cases.
  ///
  /// See:
  /// * https://mpv.io/manual/master/#options
  /// * https://mpv.io/manual/master/#properties
  ///
  Future<void> observeProperty(
    String property,
    Future<void> Function(String) listener, {
    bool waitForInitialization = true,
  }) async {
    if (disposed) {
      throw AssertionError('[Player] has been disposed');
    }

    if (waitForInitialization) {
      await waitForPlayerInitialization;
      await waitForVideoControllerInitializationIfAttached;
    }

    if (observed.containsKey(property)) {
      throw ArgumentError.value(
        property,
        'property',
        'Already observed',
      );
    }
    final reply = property.hashCode;
    observed[property] = listener;
    final name = property.toNativeUtf8();
    mpv.mpv_observe_property(
      ctx,
      reply,
      name.cast(),
      generated.mpv_format.MPV_FORMAT_NONE,
    );
    calloc.free(name);
  }

  /// Unobserves property for the internal libmpv instance of this [Player].
  /// Please use this method only if you know what you are doing, existing methods in [Player] implementation are suited for the most use cases.
  ///
  /// See:
  /// * https://mpv.io/manual/master/#options
  /// * https://mpv.io/manual/master/#properties
  ///
  Future<void> unobserveProperty(
    String property, {
    bool waitForInitialization = true,
  }) async {
    if (disposed) {
      throw AssertionError('[Player] has been disposed');
    }

    if (waitForInitialization) {
      await waitForPlayerInitialization;
      await waitForVideoControllerInitializationIfAttached;
    }

    if (!observed.containsKey(property)) {
      throw ArgumentError.value(
        property,
        'property',
        'Not observed',
      );
    }
    final reply = property.hashCode;
    observed.remove(property);
    mpv.mpv_unobserve_property(ctx, reply);
  }

  Future<void> observeEvent(
    int eventId,
    Future<void> Function(Pointer<void>) listener, {
    bool waitForInitialization = true,
  }) async {
    if (disposed) {
      throw AssertionError('[Player] has been disposed');
    }

    if (waitForInitialization) {
      await waitForPlayerInitialization;
      await waitForVideoControllerInitializationIfAttached;
    }

    if (eventObserved.containsKey(eventId)) {
      throw ArgumentError.value(
        eventId,
        'eventId',
        'Already observed',
      );
    }
    eventObserved[eventId] = listener;
  }

  Future<void> unobserveEvent(
    int eventId, {
    bool waitForInitialization = true,
  }) async {
    if (disposed) {
      throw AssertionError('[Player] has been disposed');
    }

    if (waitForInitialization) {
      await waitForPlayerInitialization;
      await waitForVideoControllerInitializationIfAttached;
    }

    if (!eventObserved.containsKey(eventId)) {
      throw ArgumentError.value(
        eventId,
        'eventId',
        'Not observed',
      );
    }
    eventObserved.remove(eventId);
  }

  /// Invokes command for the internal libmpv instance of this [Player].
  /// Please use this method only if you know what you are doing, existing methods in [Player] implementation are suited for the most use cases.
  ///
  /// See:
  /// * https://mpv.io/manual/master/#list-of-input-commands
  ///
  Future<void> command(
    List<String> command, {
    bool waitForInitialization = true,
  }) async {
    if (disposed) {
      throw AssertionError('[Player] has been disposed');
    }

    if (waitForInitialization) {
      await waitForPlayerInitialization;
      await waitForVideoControllerInitializationIfAttached;
    }

    await _command(command);
  }

  Future<void> _handler(Pointer<generated.mpv_event> event) async {
    if(eventObserved.containsKey(event.ref.event_id)) {
      final fn = eventObserved[event.ref.event_id];
      if (fn != null) {
        final data = event.ref.data;
        try {
          await fn.call(data);
        } catch (exception, stacktrace) {
          print(exception);
          print(stacktrace);
        }
      }
    }

    if (event.ref.event_id ==
        generated.mpv_event_id.MPV_EVENT_PROPERTY_CHANGE) {
      final prop = event.ref.data.cast<generated.mpv_event_property>();
      if (prop.ref.name.cast<Utf8>().toDartString() == 'idle-active' &&
          prop.ref.format == generated.mpv_format.MPV_FORMAT_FLAG) {
        await future;
        // The [Player] has entered the idle state; initialization is complete.
        if (!completer.isCompleted) {
          completer.complete();
        }
      }
      // Following properties are unrelated to the playback lifecycle. Thus, these can be accessed before initialization is complete.
      // e.g. audio-device & audio-device-list seem to be emitted before idle-active.
      if (prop.ref.name.cast<Utf8>().toDartString() == 'audio-device' &&
          prop.ref.format == generated.mpv_format.MPV_FORMAT_NODE) {
        final value = prop.ref.data.cast<generated.mpv_node>();
        if (value.ref.format == generated.mpv_format.MPV_FORMAT_STRING) {
          final name = value.ref.u.string.cast<Utf8>().toDartString();
          final audioDevice = AudioDevice(name, '');
          state = state.copyWith(audioDevice: audioDevice);
          if (!audioDeviceController.isClosed) {
            audioDeviceController.add(audioDevice);
          }
        }
      }
      if (prop.ref.name.cast<Utf8>().toDartString() == 'audio-device-list' &&
          prop.ref.format == generated.mpv_format.MPV_FORMAT_NODE) {
        final value = prop.ref.data.cast<generated.mpv_node>();
        final audioDevices = <AudioDevice>[];
        if (value.ref.format == generated.mpv_format.MPV_FORMAT_NODE_ARRAY) {
          final list = value.ref.u.list.ref;
          for (int i = 0; i < list.num; i++) {
            if (list.values[i].format ==
                generated.mpv_format.MPV_FORMAT_NODE_MAP) {
              String name = '', description = '';
              final device = list.values[i].u.list.ref;
              for (int j = 0; j < device.num; j++) {
                if (device.values[j].format ==
                    generated.mpv_format.MPV_FORMAT_STRING) {
                  final property = device.keys[j].cast<Utf8>().toDartString();
                  final value =
                      device.values[j].u.string.cast<Utf8>().toDartString();
                  switch (property) {
                    case 'name':
                      name = value;
                      break;
                    case 'description':
                      description = value;
                      break;
                  }
                }
              }
              audioDevices.add(AudioDevice(name, description));
            }
          }
          state = state.copyWith(audioDevices: audioDevices);
          if (!audioDevicesController.isClosed) {
            audioDevicesController.add(audioDevices);
          }
        }
      }
    }
    if (event.ref.event_id ==
        generated.mpv_event_id.MPV_EVENT_SET_PROPERTY_REPLY) {
      final completer = _setPropertyRequests.remove(event.ref.reply_userdata);
      if (completer == null) {
        print(
            'Warning: Received MPV_EVENT_SET_PROPERTY_REPLY with unregistered ID ${event.ref.reply_userdata}');
      } else {
        completer.complete(event.ref.error);
      }
    }
    if (event.ref.event_id == generated.mpv_event_id.MPV_EVENT_COMMAND_REPLY) {
      final completer = _commandRequests.remove(event.ref.reply_userdata);
      if (completer == null) {
        print(
            'Warning: Received MPV_EVENT_COMMAND_REPLY with unregistered ID ${event.ref.reply_userdata}');
      } else {
        completer.complete(event.ref.error);
      }
    }

    if (!completer.isCompleted) {
      // Ignore the events which are fired before the initialization.
      return;
    }

    _logError(
      event.ref.error,
      'event:${event.ref.event_id} ${event.ref.data.cast<Uint8>()}',
    );

    if (event.ref.event_id == generated.mpv_event_id.MPV_EVENT_START_FILE) {
      if (isPlayingStateChangeAllowed) {
        state = state.copyWith(
          playing: true,
          completed: false,
        );
        if (!playingController.isClosed) {
          playingController.add(true);
        }
        if (!completedController.isClosed) {
          completedController.add(false);
        }
      }
      state = state.copyWith(buffering: true);
      if (!bufferingController.isClosed) {
        bufferingController.add(true);
      }
    }
    // NOTE: Now, --keep-open=yes is used. Thus, eof-reached property is used instead of this.
    // if (event.ref.event_id == generated.mpv_event_id.MPV_EVENT_END_FILE) {
    //   // Check for mpv_end_file_reason.MPV_END_FILE_REASON_EOF before modifying state.completed.
    //   if (event.ref.data.cast<generated.mpv_event_end_file>().ref.reason == generated.mpv_end_file_reason.MPV_END_FILE_REASON_EOF) {
    //     if (isPlayingStateChangeAllowed) {
    //       state = state.copyWith(
    //         playing: false,
    //         completed: true,
    //       );
    //       if (!playingController.isClosed) {
    //         playingController.add(false);
    //       }
    //       if (!completedController.isClosed) {
    //         completedController.add(true);
    //       }
    //     }
    //   }
    // }
    if (event.ref.event_id ==
        generated.mpv_event_id.MPV_EVENT_PROPERTY_CHANGE) {
      final prop = event.ref.data.cast<generated.mpv_event_property>();
      if (prop.ref.name.cast<Utf8>().toDartString() == 'pause' &&
          prop.ref.format == generated.mpv_format.MPV_FORMAT_FLAG) {
        final playing = prop.ref.data.cast<Int8>().value == 0;
        if (isPlayingStateChangeAllowed) {
          state = state.copyWith(playing: playing);
          if (!playingController.isClosed) {
            playingController.add(playing);
          }
        }
      }
      if (prop.ref.name.cast<Utf8>().toDartString() == 'core-idle' &&
          prop.ref.format == generated.mpv_format.MPV_FORMAT_FLAG) {
        // Check for [isBufferingStateChangeAllowed] because `pause` causes `core-idle` to be fired.
        final buffering = prop.ref.data.cast<Int8>().value == 1;
        if (buffering) {
          if (isBufferingStateChangeAllowed) {
            state = state.copyWith(buffering: true);
            if (!bufferingController.isClosed) {
              bufferingController.add(true);
            }
          }
        } else {
          state = state.copyWith(buffering: false);
          if (!bufferingController.isClosed) {
            bufferingController.add(false);
          }
        }
        isBufferingStateChangeAllowed = true;
      }
      if (prop.ref.name.cast<Utf8>().toDartString() == 'paused-for-cache' &&
          prop.ref.format == generated.mpv_format.MPV_FORMAT_FLAG) {
        final buffering = prop.ref.data.cast<Int8>().value == 1;
        state = state.copyWith(buffering: buffering);
        if (!bufferingController.isClosed) {
          bufferingController.add(buffering);
        }
      }
      if (prop.ref.name.cast<Utf8>().toDartString() == 'demuxer-cache-time' &&
          prop.ref.format == generated.mpv_format.MPV_FORMAT_DOUBLE) {
        final buffer = Duration(
          microseconds: prop.ref.data.cast<Double>().value * 1e6 ~/ 1,
        );
        state = state.copyWith(buffer: buffer);
        if (!bufferController.isClosed) {
          bufferController.add(buffer);
        }
      }
      if (prop.ref.name.cast<Utf8>().toDartString() ==
              'cache-buffering-state' &&
          prop.ref.format == generated.mpv_format.MPV_FORMAT_DOUBLE) {
        final bufferingPercentage = prop.ref.data.cast<Double>().value;

        state = state.copyWith(bufferingPercentage: bufferingPercentage);
        if (!bufferingPercentageController.isClosed) {
          bufferingPercentageController.add(bufferingPercentage);
        }
      }
      if (prop.ref.name.cast<Utf8>().toDartString() == 'time-pos' &&
          prop.ref.format == generated.mpv_format.MPV_FORMAT_DOUBLE) {
        final position = Duration(
          microseconds: prop.ref.data.cast<Double>().value * 1e6 ~/ 1,
        );
        state = state.copyWith(position: position);
        if (!positionController.isClosed) {
          positionController.add(position);
        }
      }
      if (prop.ref.name.cast<Utf8>().toDartString() == 'duration' &&
          prop.ref.format == generated.mpv_format.MPV_FORMAT_DOUBLE) {
        final duration = Duration(
          microseconds: prop.ref.data.cast<Double>().value * 1e6 ~/ 1,
        );
        state = state.copyWith(duration: duration);
        if (!durationController.isClosed) {
          durationController.add(duration);
        }
        if (state.playlist.index >= 0 &&
            state.playlist.index < state.playlist.medias.length) {
          final uri = state.playlist.medias[state.playlist.index].uri;
          if (FallbackBitrateHandler.supported(uri)) {
            if (!audioBitrateCache.containsKey(Media.normalizeURI(uri))) {
              audioBitrateCache[uri] =
                  await FallbackBitrateHandler.calculateBitrate(
                uri,
                duration,
              );
            }
            final bitrate = audioBitrateCache[uri];
            if (bitrate != null) {
              state = state.copyWith(audioBitrate: bitrate);
              if (!audioBitrateController.isClosed) {
                audioBitrateController.add(bitrate);
              }
            }
          }
        }
      }
      if (prop.ref.name.cast<Utf8>().toDartString() == 'playlist-playing-pos' &&
          prop.ref.format == generated.mpv_format.MPV_FORMAT_INT64 &&
          prop.ref.data != nullptr &&
          isPlaylistStateChangeAllowed) {
        isPlaylistStateChangeAllowed = true;

        final index = prop.ref.data.cast<Int64>().value;
        final medias = current;

        if (index >= 0) {
          final playlist = Playlist(medias, index: index);
          state = state.copyWith(playlist: playlist);
          if (!playlistController.isClosed) {
            playlistController.add(playlist);
          }
        }
      }
      if (prop.ref.name.cast<Utf8>().toDartString() == 'volume' &&
          prop.ref.format == generated.mpv_format.MPV_FORMAT_DOUBLE) {
        final volume = prop.ref.data.cast<Double>().value;
        state = state.copyWith(volume: volume);
        if (!volumeController.isClosed) {
          volumeController.add(volume);
        }
      }
      if (prop.ref.name.cast<Utf8>().toDartString() == 'audio-params' &&
          prop.ref.format == generated.mpv_format.MPV_FORMAT_NODE) {
        final data = prop.ref.data.cast<generated.mpv_node>();
        final list = data.ref.u.list.ref;
        final params = <String, dynamic>{};
        for (int i = 0; i < list.num; i++) {
          final key = list.keys[i].cast<Utf8>().toDartString();

          switch (key) {
            case 'format':
              {
                params[key] =
                    list.values[i].u.string.cast<Utf8>().toDartString();
                break;
              }
            case 'samplerate':
              {
                params[key] = list.values[i].u.int64;
                break;
              }
            case 'channels':
              {
                params[key] =
                    list.values[i].u.string.cast<Utf8>().toDartString();
                break;
              }
            case 'channel-count':
              {
                params[key] = list.values[i].u.int64;
                break;
              }
            case 'hr-channels':
              {
                params[key] =
                    list.values[i].u.string.cast<Utf8>().toDartString();
                break;
              }
            default:
              {
                break;
              }
          }
        }
        state = state.copyWith(
          audioParams: AudioParams(
            format: params['format'],
            sampleRate: params['samplerate'],
            channels: params['channels'],
            channelCount: params['channel-count'],
            hrChannels: params['hr-channels'],
          ),
        );
        if (!audioParamsController.isClosed) {
          audioParamsController.add(state.audioParams);
        }
      }
      if (prop.ref.name.cast<Utf8>().toDartString() == 'audio-bitrate' &&
          prop.ref.format == generated.mpv_format.MPV_FORMAT_DOUBLE) {
        if (state.playlist.index < state.playlist.medias.length &&
            state.playlist.index >= 0) {
          final data = prop.ref.data.cast<Double>().value;
          final uri = state.playlist.medias[state.playlist.index].uri;
          if (!FallbackBitrateHandler.supported(uri)) {
            if (!audioBitrateCache.containsKey(Media.normalizeURI(uri))) {
              audioBitrateCache[Media.normalizeURI(uri)] = data;
            }
            final bitrate = audioBitrateCache[Media.normalizeURI(uri)];
            if (!audioBitrateController.isClosed &&
                bitrate != state.audioBitrate) {
              audioBitrateController.add(bitrate);
              state = state.copyWith(audioBitrate: bitrate);
            }
          }
        } else {
          if (!audioBitrateController.isClosed) {
            audioBitrateController.add(null);
            state = state.copyWith(audioBitrate: null);
          }
        }
      }
      if (prop.ref.name.cast<Utf8>().toDartString() == 'track-list' &&
          prop.ref.format == generated.mpv_format.MPV_FORMAT_NODE) {
        final value = prop.ref.data.cast<generated.mpv_node>();
        if (value.ref.format == generated.mpv_format.MPV_FORMAT_NODE_ARRAY) {
          final video = [VideoTrack.auto(), VideoTrack.no()];
          final audio = [AudioTrack.auto(), AudioTrack.no()];
          final subtitle = [SubtitleTrack.auto(), SubtitleTrack.no()];

          final tracks = value.ref.u.list.ref;

          for (int i = 0; i < tracks.num; i++) {
            if (tracks.values[i].format ==
                generated.mpv_format.MPV_FORMAT_NODE_MAP) {
              final map = tracks.values[i].u.list.ref;
              String id = '';
              String type = '';
              String? title;
              String? language;
              bool? image;
              bool? albumart;
              String? codec;
              String? decoder;
              int? w;
              int? h;
              int? channelscount;
              String? channels;
              int? samplerate;
              double? fps;
              int? bitrate;
              int? rotate;
              double? par;
              int? audiochannels;
              for (int j = 0; j < map.num; j++) {
                final property = map.keys[j].cast<Utf8>().toDartString();
                if (map.values[j].format ==
                    generated.mpv_format.MPV_FORMAT_INT64) {
                  switch (property) {
                    case 'id':
                      id = map.values[j].u.int64.toString();
                      break;
                    case 'demux-w':
                      w = map.values[j].u.int64;
                      break;
                    case 'demux-h':
                      h = map.values[j].u.int64;
                      break;
                    case 'demux-channel-count':
                      channelscount = map.values[j].u.int64;
                      break;
                    case 'demux-samplerate':
                      samplerate = map.values[j].u.int64;
                      break;
                    case 'demux-bitrate':
                      bitrate = map.values[j].u.int64;
                      break;
                    case 'demux-rotate':
                      rotate = map.values[j].u.int64;
                      break;
                    case 'audio-channels':
                      audiochannels = map.values[j].u.int64;
                      break;
                  }
                }
                if (map.values[j].format ==
                    generated.mpv_format.MPV_FORMAT_FLAG) {
                  switch (property) {
                    case 'image':
                      image = map.values[j].u.flag > 0;
                      break;
                    case 'albumart':
                      albumart = map.values[j].u.flag > 0;
                      break;
                  }
                }
                if (map.values[j].format ==
                    generated.mpv_format.MPV_FORMAT_DOUBLE) {
                  switch (property) {
                    case 'demux-fps':
                      fps = map.values[j].u.double_;
                      break;
                    case 'demux-par':
                      par = map.values[j].u.double_;
                      break;
                  }
                }
                if (map.values[j].format ==
                    generated.mpv_format.MPV_FORMAT_STRING) {
                  final value =
                      map.values[j].u.string.cast<Utf8>().toDartString();
                  switch (property) {
                    case 'type':
                      type = value;
                      break;
                    case 'title':
                      title = value;
                      break;
                    case 'lang':
                      language = value;
                      break;
                    case 'codec':
                      codec = value;
                      break;
                    case 'decoder-desc':
                      decoder = value;
                      break;
                    case 'demux-channels':
                      channels = value;
                      break;
                  }
                }
              }
              switch (type) {
                case 'video':
                  video.add(
                    VideoTrack(
                      id,
                      title,
                      language,
                      image: image,
                      albumart: albumart,
                      codec: codec,
                      decoder: decoder,
                      w: w,
                      h: h,
                      channelscount: channelscount,
                      channels: channels,
                      samplerate: samplerate,
                      fps: fps,
                      bitrate: bitrate,
                      rotate: rotate,
                      par: par,
                      audiochannels: audiochannels,
                    ),
                  );
                  break;
                case 'audio':
                  audio.add(
                    AudioTrack(
                      id,
                      title,
                      language,
                      image: image,
                      albumart: albumart,
                      codec: codec,
                      decoder: decoder,
                      w: w,
                      h: h,
                      channelscount: channelscount,
                      channels: channels,
                      samplerate: samplerate,
                      fps: fps,
                      bitrate: bitrate,
                      rotate: rotate,
                      par: par,
                      audiochannels: audiochannels,
                    ),
                  );
                  break;
                case 'sub':
                  subtitle.add(
                    SubtitleTrack(
                      id,
                      title,
                      language,
                      image: image,
                      albumart: albumart,
                      codec: codec,
                      decoder: decoder,
                      w: w,
                      h: h,
                      channelscount: channelscount,
                      channels: channels,
                      samplerate: samplerate,
                      fps: fps,
                      bitrate: bitrate,
                      rotate: rotate,
                      par: par,
                      audiochannels: audiochannels,
                    ),
                  );
                  break;
              }
            }
          }

          state = state.copyWith(
            tracks: Tracks(
              video: video,
              audio: audio,
              subtitle: subtitle,
            ),
          );
          if (!tracksController.isClosed) {
            tracksController.add(state.tracks);
          }
        }
      }
      if (prop.ref.name.cast<Utf8>().toDartString() == 'sub-text' &&
          prop.ref.format == generated.mpv_format.MPV_FORMAT_NODE) {
        final value = prop.ref.data.cast<generated.mpv_node>();
        if (value.ref.format == generated.mpv_format.MPV_FORMAT_STRING) {
          final text = value.ref.u.string.cast<Utf8>().toDartString();
          state = state.copyWith(
            subtitle: [
              text,
              state.subtitle[1],
            ],
          );
          if (!subtitleController.isClosed) {
            subtitleController.add(state.subtitle);
          }
        }
      }
      if (prop.ref.name.cast<Utf8>().toDartString() == 'secondary-sub-text' &&
          prop.ref.format == generated.mpv_format.MPV_FORMAT_NODE) {
        final value = prop.ref.data.cast<generated.mpv_node>();
        if (value.ref.format == generated.mpv_format.MPV_FORMAT_STRING) {
          final text = value.ref.u.string.cast<Utf8>().toDartString();
          state = state.copyWith(
            subtitle: [
              state.subtitle[0],
              text,
            ],
          );
          if (!subtitleController.isClosed) {
            subtitleController.add(state.subtitle);
          }
        }
      }
      if (prop.ref.name.cast<Utf8>().toDartString() == 'eof-reached' &&
          prop.ref.format == generated.mpv_format.MPV_FORMAT_FLAG) {
        final value = prop.ref.data.cast<Bool>().value;
        if (value) {
          if (isPlayingStateChangeAllowed) {
            state = state.copyWith(
              playing: false,
              completed: true,
            );
            if (!playingController.isClosed) {
              playingController.add(false);
            }
            if (!completedController.isClosed) {
              completedController.add(true);
            }
          }

          state = state.copyWith(
            buffering: false,
            tracks: Tracks(),
            track: Track(),
          );
          if (!bufferingController.isClosed) {
            bufferingController.add(false);
          }
          if (!tracksController.isClosed) {
            tracksController.add(Tracks());
          }
          if (!trackController.isClosed) {
            trackController.add(Track());
          }
        }
      }
      if (prop.ref.name.cast<Utf8>().toDartString() == 'video-out-params' &&
          prop.ref.format == generated.mpv_format.MPV_FORMAT_NODE) {
        final node = prop.ref.data.cast<generated.mpv_node>().ref;
        final data = <String, dynamic>{};
        for (int i = 0; i < node.u.list.ref.num; i++) {
          final key = node.u.list.ref.keys[i].cast<Utf8>().toDartString();
          final value = node.u.list.ref.values[i];
          switch (value.format) {
            case generated.mpv_format.MPV_FORMAT_INT64:
              data[key] = value.u.int64;
              break;
            case generated.mpv_format.MPV_FORMAT_DOUBLE:
              data[key] = value.u.double_;
              break;
            case generated.mpv_format.MPV_FORMAT_STRING:
              data[key] = value.u.string.cast<Utf8>().toDartString();
              break;
          }
        }

        final params = VideoParams(
          pixelformat: data['pixelformat'],
          hwPixelformat: data['hw-pixelformat'],
          w: data['w'],
          h: data['h'],
          dw: data['dw'],
          dh: data['dh'],
          aspect: data['aspect'],
          par: data['par'],
          colormatrix: data['colormatrix'],
          colorlevels: data['colorlevels'],
          primaries: data['primaries'],
          gamma: data['gamma'],
          sigPeak: data['sig-peak'],
          light: data['light'],
          chromaLocation: data['chroma-location'],
          rotate: data['rotate'],
          stereoIn: data['stereo-in'],
          averageBpp: data['average-bpp'],
          alpha: data['alpha'],
        );

        state = state.copyWith(
          videoParams: params,
        );
        if (!videoParamsController.isClosed) {
          videoParamsController.add(params);
        }

        final dw = params.dw;
        final dh = params.dh;
        final rotate = params.rotate ?? 0;
        if (dw is int && dh is int) {
          final int width;
          final int height;
          if (rotate == 0 || rotate == 180) {
            width = dw;
            height = dh;
          } else {
            // width & height are swapped for 90 or 270 degrees rotation.
            width = dh;
            height = dw;
          }
          state = state.copyWith(
            width: width,
            height: height,
          );
          if (!widthController.isClosed) {
            widthController.add(width);
          }
          if (!heightController.isClosed) {
            heightController.add(height);
          }
        }
      }
      if (observed.containsKey(prop.ref.name.cast<Utf8>().toDartString())) {
        if (prop.ref.format == generated.mpv_format.MPV_FORMAT_NONE) {
          final fn = observed[prop.ref.name.cast<Utf8>().toDartString()];
          if (fn != null) {
            final data = mpv.mpv_get_property_string(ctx, prop.ref.name);
            if (data != nullptr) {
              try {
                await fn.call(data.cast<Utf8>().toDartString());
              } catch (exception, stacktrace) {
                print(exception);
                print(stacktrace);
              }
              mpv.mpv_free(data.cast());
            }
          }
        }
      }
    }
    if (event.ref.event_id == generated.mpv_event_id.MPV_EVENT_LOG_MESSAGE) {
      final eventLogMessage =
          event.ref.data.cast<generated.mpv_event_log_message>().ref;
      final prefix = eventLogMessage.prefix.cast<Utf8>().toDartString().trim();
      final level = eventLogMessage.level.cast<Utf8>().toDartString().trim();
      final text = eventLogMessage.text.cast<Utf8>().toDartString().trim();
      if (!logController.isClosed) {
        logController.add(
          PlayerLog(
            prefix: prefix,
            level: level,
            text: text,
          ),
        );
        // --------------------------------------------------
        // Emit error(s) based on the log messages.
        if (level == 'error') {
          if (prefix == 'file') {
            // file:// not found.
            if (!errorController.isClosed) {
              errorController.add(text);
            }
          }
          if (prefix == 'ffmpeg') {
            if (text.startsWith('tcp:')) {
              // http:// error of any kind.
              if (!errorController.isClosed) {
                errorController.add(text);
              }
            }
          }
          if (prefix == 'vd') {
            if (!errorController.isClosed) {
              errorController.add(text);
            }
          }
          if (prefix == 'ad') {
            if (!errorController.isClosed) {
              errorController.add(text);
            }
          }
          if (prefix == 'cplayer') {
            if (!errorController.isClosed) {
              errorController.add(text);
            }
          }
          if (prefix == 'stream') {
            if (!errorController.isClosed) {
              errorController.add(text);
            }
          }
        }
        // --------------------------------------------------
      }
    }
    if (event.ref.event_id == generated.mpv_event_id.MPV_EVENT_HOOK) {
      final prop = event.ref.data.cast<generated.mpv_event_hook>();
      if (prop.ref.name.cast<Utf8>().toDartString() == 'on_load') {
        // --------------------------------------------------
        for (final hook in onLoadHooks) {
          try {
            await hook.call();
          } catch (exception, stacktrace) {
            print(exception);
            print(stacktrace);
          }
        }
        // --------------------------------------------------
        // Handle HTTP headers specified in the [Media].
        try {
          final name = 'path'.toNativeUtf8();
          final uri = mpv.mpv_get_property_string(
            ctx,
            name.cast(),
          );
          // Get the headers for current [Media] by looking up [uri] in the [HashMap].
          final headers = Media(uri.cast<Utf8>().toDartString()).httpHeaders;
          if (headers != null) {
            final property = 'http-header-fields'.toNativeUtf8();
            // Allocate & fill the [mpv_node] with the headers.
            final value = calloc<generated.mpv_node>();
            value.ref.format = generated.mpv_format.MPV_FORMAT_NODE_ARRAY;
            value.ref.u.list = calloc<generated.mpv_node_list>();
            value.ref.u.list.ref.num = headers.length;
            value.ref.u.list.ref.values = calloc<generated.mpv_node>(
              headers.length,
            );
            final entries = headers.entries.toList();
            for (int i = 0; i < entries.length; i++) {
              final k = entries[i].key;
              final v = entries[i].value;
              final data = '$k: $v'.toNativeUtf8();
              value.ref.u.list.ref.values[i].format =
                  generated.mpv_format.MPV_FORMAT_STRING;
              value.ref.u.list.ref.values[i].u.string = data.cast();
            }
            mpv.mpv_set_property(
              ctx,
              property.cast(),
              generated.mpv_format.MPV_FORMAT_NODE,
              value.cast(),
            );
            // Free the allocated memory.
            calloc.free(property);
            for (int i = 0; i < value.ref.u.list.ref.num; i++) {
              calloc.free(value.ref.u.list.ref.values[i].u.string);
            }
            calloc.free(value.ref.u.list.ref.values);
            calloc.free(value.ref.u.list);
            calloc.free(value);
          }
          mpv.mpv_free(uri.cast());
          calloc.free(name);
        } catch (exception, stacktrace) {
          print(exception);
          print(stacktrace);
        }
        // Handle start & end position specified in the [Media].
        try {
          final name = 'playlist-pos'.toNativeUtf8();
          final value = calloc<Int64>();
          value.value = -1;

          mpv.mpv_get_property(
            ctx,
            name.cast(),
            generated.mpv_format.MPV_FORMAT_INT64,
            value.cast(),
          );

          final index = value.value;

          calloc.free(name.cast());
          calloc.free(value.cast());

          if (index >= 0) {
            final start = current[index].start;
            final end = current[index].end;

            if (start != null) {
              try {
                final property = 'start'.toNativeUtf8();
                final value = (start.inMilliseconds / 1000)
                    .toStringAsFixed(3)
                    .toNativeUtf8();
                mpv.mpv_set_property_string(
                  ctx,
                  property.cast(),
                  value.cast(),
                );
                calloc.free(property);
                calloc.free(value);
              } catch (exception, stacktrace) {
                print(exception);
                print(stacktrace);
              }
            }

            if (end != null) {
              try {
                final property = 'end'.toNativeUtf8();
                final value = (end.inMilliseconds / 1000)
                    .toStringAsFixed(3)
                    .toNativeUtf8();
                mpv.mpv_set_property_string(
                  ctx,
                  property.cast(),
                  value.cast(),
                );
                calloc.free(property);
                calloc.free(value);
              } catch (exception, stacktrace) {
                print(exception);
                print(stacktrace);
              }
            }
          }
        } catch (_) {}
        // --------------------------------------------------
        mpv.mpv_hook_continue(
          ctx,
          prop.ref.id,
        );
      }
      if (prop.ref.name.cast<Utf8>().toDartString() == 'on_unload') {
        // --------------------------------------------------
        for (final hook in onUnloadHooks) {
          try {
            await hook.call();
          } catch (exception, stacktrace) {
            print(exception);
            print(stacktrace);
          }
        }
        // --------------------------------------------------
        // Set http-header-fields as [generated.mpv_format.MPV_FORMAT_NONE] [generated.mpv_node].
        try {
          final property = 'http-header-fields'.toNativeUtf8();
          final value = calloc<generated.mpv_node>();
          value.ref.format = generated.mpv_format.MPV_FORMAT_NONE;
          mpv.mpv_set_property(
            ctx,
            property.cast(),
            generated.mpv_format.MPV_FORMAT_NODE,
            value.cast(),
          );
          calloc.free(property);
          calloc.free(value);
        } catch (exception, stacktrace) {
          print(exception);
          print(stacktrace);
        }
        // Set start & end position as [generated.mpv_format.MPV_FORMAT_NONE] [generated.mpv_node].
        try {
          final property = 'start'.toNativeUtf8();
          final value = 'none'.toNativeUtf8();
          mpv.mpv_set_property_string(
            ctx,
            property.cast(),
            value.cast(),
          );
          calloc.free(property);
          calloc.free(value);
        } catch (exception, stacktrace) {
          print(exception);
          print(stacktrace);
        }
        try {
          final property = 'end'.toNativeUtf8();
          final value = 'none'.toNativeUtf8();
          mpv.mpv_set_property_string(
            ctx,
            property.cast(),
            value.cast(),
          );
          calloc.free(property);
          calloc.free(value);
        } catch (exception, stacktrace) {
          print(exception);
          print(stacktrace);
        }
        // --------------------------------------------------
        mpv.mpv_hook_continue(
          ctx,
          prop.ref.id,
        );
      }
      if (prop.ref.name.cast<Utf8>().toDartString() == 'on_load_fail') {
        for (final hook in onLoadFailHooks) {
          try {
            await hook.call();
          } catch (exception, stacktrace) {
            print(exception);
            print(stacktrace);
          }
        }
        mpv.mpv_hook_continue(
          ctx,
          prop.ref.id,
        );
      }
      if (prop.ref.name.cast<Utf8>().toDartString() == 'on_preloaded') {
        for (final hook in onPreloadedHooks) {
          try {
            await hook.call();
          } catch (exception, stacktrace) {
            print(exception);
            print(stacktrace);
          }
        }
        mpv.mpv_hook_continue(
          ctx,
          prop.ref.id,
        );
      }
    }
  }

  Future<void> _create() {
    return lock.synchronized(() async {
      // The options which must be set before [MPV.mpv_initialize].
      final options = <String, String>{
        // Set --vid=no by default to prevent redundant video decoding.
        // [VideoController] internally sets --vid=auto upon attachment to enable video rendering & decoding.
        if (!test) 'vid': 'no',
        ...?configuration.options,
      };

      ctx = await Initializer(mpv).create(
        _handler,
        options: options,
      );

      if (configuration.muted) {
        await _setPropertyDouble('volume', 0);

        state = state.copyWith(volume: 0.0);
        if (!volumeController.isClosed) {
          volumeController.add(0.0);
        }
      }

      // Observe the properties to update the state & feed event stream.
      <String, int>{
        'pause': generated.mpv_format.MPV_FORMAT_FLAG,
        'time-pos': generated.mpv_format.MPV_FORMAT_DOUBLE,
        'duration': generated.mpv_format.MPV_FORMAT_DOUBLE,
        'playlist-playing-pos': generated.mpv_format.MPV_FORMAT_INT64,
        'volume': generated.mpv_format.MPV_FORMAT_DOUBLE,
        'speed': generated.mpv_format.MPV_FORMAT_DOUBLE,
        'core-idle': generated.mpv_format.MPV_FORMAT_FLAG,
        'paused-for-cache': generated.mpv_format.MPV_FORMAT_FLAG,
        'demuxer-cache-time': generated.mpv_format.MPV_FORMAT_DOUBLE,
        'cache-buffering-state': generated.mpv_format.MPV_FORMAT_DOUBLE,
        'audio-params': generated.mpv_format.MPV_FORMAT_NODE,
        'audio-bitrate': generated.mpv_format.MPV_FORMAT_DOUBLE,
        'audio-device': generated.mpv_format.MPV_FORMAT_NODE,
        'audio-device-list': generated.mpv_format.MPV_FORMAT_NODE,
        'video-out-params': generated.mpv_format.MPV_FORMAT_NODE,
        'track-list': generated.mpv_format.MPV_FORMAT_NODE,
        'eof-reached': generated.mpv_format.MPV_FORMAT_FLAG,
        'idle-active': generated.mpv_format.MPV_FORMAT_FLAG,
        'sub-text': generated.mpv_format.MPV_FORMAT_NODE,
        'secondary-sub-text': generated.mpv_format.MPV_FORMAT_NODE,
      }.forEach(
        (property, format) {
          final name = property.toNativeUtf8();
          mpv.mpv_observe_property(
            ctx,
            0,
            name.cast(),
            format,
          );
          calloc.free(name);
        },
      );

      // https://github.com/mpv-player/mpv/blob/e1727553f164181265f71a20106fbd5e34fa08b0/libmpv/client.h#L1410-L1419
      final levels = {
        MPVLogLevel.error: 'error',
        MPVLogLevel.warn: 'warn',
        MPVLogLevel.info: 'info',
        MPVLogLevel.v: 'v',
        MPVLogLevel.debug: 'debug',
        MPVLogLevel.trace: 'trace',
      };
      final level = levels[configuration.logLevel];
      if (level != null) {
        final min = level.toNativeUtf8();
        mpv.mpv_request_log_messages(ctx, min.cast());
        calloc.free(min);
      }

      // Add libmpv hooks for supporting custom HTTP headers in [Media].
      final load = 'on_load'.toNativeUtf8();
      final unload = 'on_unload'.toNativeUtf8();
      final loadFail = 'on_load_fail'.toNativeUtf8();
      final preloaded = 'on_preloaded'.toNativeUtf8();
      mpv.mpv_hook_add(ctx, 0, load.cast(), 0);
      mpv.mpv_hook_add(ctx, 0, unload.cast(), 0);
      mpv.mpv_hook_add(ctx, 0, loadFail.cast(), 0);
      mpv.mpv_hook_add(ctx, 0, preloaded.cast(), 0);
      calloc.free(load);
      calloc.free(unload);
      calloc.free(loadFail);
      calloc.free(preloaded);

      await NativeReferenceHolder.instance.add(ctx);
    });
  }

  /// Adds an error to the [Player.stream.error].
  void _logError(int code, String? text) {
    if (code < 0 && !logController.isClosed) {
      final message = mpv.mpv_error_string(code).cast<Utf8>().toDartString();
      logController.add(
        PlayerLog(
          prefix: 'media_kit',
          level: 'error',
          text: 'error: $message $text',
        ),
      );
    }
  }

  int _asyncRequestNumber = 0;
  final Map<int, Completer<int>> _setPropertyRequests = {};
  final Map<int, Completer<int>> _commandRequests = {};

  Future<void> _setProperty(String name, int format, Pointer<Void> data) async {
    final requestNumber = _asyncRequestNumber++;
    final completer = _setPropertyRequests[requestNumber] = Completer<int>();
    final namePtr = name.toNativeUtf8();
    if (configuration.async) {
      final immediate = mpv.mpv_set_property_async(
        ctx,
        requestNumber,
        namePtr.cast(),
        format,
        data,
      );
      final text = '_setProperty($name, $format)';
      if (immediate < 0) {
        // Sending failed.
        _logError(immediate, text);
        return;
      }
      _logError(await completer.future, text);
    } else {
      mpv.mpv_set_property(
        ctx,
        namePtr.cast(),
        format,
        data,
      );
    }
    calloc.free(namePtr);
  }

  Future<void> _setPropertyFlag(String name, bool value) async {
    final ptr = calloc<Bool>(1)..value = value;
    await _setProperty(
      name,
      generated.mpv_format.MPV_FORMAT_FLAG,
      ptr.cast(),
    );
    calloc.free(ptr);
  }

  Future<void> _setPropertyDouble(String name, double value) async {
    final ptr = calloc<Double>(1)..value = value;
    await _setProperty(
      name,
      generated.mpv_format.MPV_FORMAT_DOUBLE,
      ptr.cast(),
    );
    calloc.free(ptr);
  }

  Future<void> _setPropertyInt64(String name, int value) async {
    final ptr = calloc<Int64>(1)..value = value;
    await _setProperty(
      name,
      generated.mpv_format.MPV_FORMAT_INT64,
      ptr.cast(),
    );
    calloc.free(ptr);
  }

  Future<void> _setPropertyString(String name, String value) async {
    final string = value.toNativeUtf8();
    // API requires char**.
    final ptr = calloc<Pointer<Void>>(1);
    ptr.value = Pointer.fromAddress(string.address);
    await _setProperty(
      name,
      generated.mpv_format.MPV_FORMAT_STRING,
      ptr.cast(),
    );
    calloc.free(ptr);
    calloc.free(string);
  }

  Future<void> _command(List<String> args) async {
    final pointers = args.map<Pointer<Utf8>>((e) => e.toNativeUtf8()).toList();
    final arr = calloc<Pointer<Utf8>>(128);
    for (int i = 0; i < args.length; i++) {
      (arr + i).value = pointers[i];
    }

    if (configuration.async) {
      final requestNumber = _asyncRequestNumber++;
      final completer = _commandRequests[requestNumber] = Completer<int>();
      final immediate = mpv.mpv_command_async(ctx, requestNumber, arr.cast());
      final text = '_command(${args.join(', ')})';
      if (immediate < 0) {
        // Sending failed.
        _logError(immediate, text);
        return;
      }
      _logError(await completer.future, text);
    } else {
      mpv.mpv_command(ctx, arr.cast());
    }

    calloc.free(arr);
    pointers.forEach(calloc.free);
  }

  /// Generated libmpv C API bindings.
  final generated.MPV mpv;

  /// [Pointer] to [generated.mpv_handle] of this instance.
  Pointer<generated.mpv_handle> ctx = nullptr;

  /// The [Future] to wait for [_create] completion.
  /// This is used to prevent signaling [completer] (from [PlatformPlayer]) before [_create] completes in any hypothetical situation (because `idle-active` may fire before it).
  Future<void>? future;

  /// Whether the [Player] has been disposed. This is used to prevent accessing dangling [ctx] after [dispose].
  bool disposed = false;

  /// A flag to keep track of [setShuffle] calls.
  bool isShuffleEnabled = false;

  /// A flag to prevent changes to [state.playing] due to `loadfile` commands in [open].
  ///
  /// By default, `MPV_EVENT_START_FILE` is fired when a new media source is loaded.
  /// This event modifies the [state.playing] & [stream.playing] to `true`.
  ///
  /// However, the [Player] is in paused state before the media source is loaded.
  /// Thus, [state.playing] should not be changed, unless the user explicitly calls [play] or [playOrPause].
  ///
  /// We set [isPlayingStateChangeAllowed] to `false` at the start of [open] to prevent this unwanted change & set it to `true` at the end of [open].
  /// While [isPlayingStateChangeAllowed] is `false`, any change to [state.playing] & [stream.playing] is ignored.
  bool isPlayingStateChangeAllowed = false;

  /// A flag to prevent changes to [state.buffering] due to `pause` causing `core-idle` to be `true`.
  ///
  /// This is used to prevent [state.buffering] being set to `true` when [pause] or [playOrPause] is called.
  bool isBufferingStateChangeAllowed = true;

  /// A flag to prevent changes to the [state.playlist] due to `playlist-shuffle` or `playlist-unshuffle` in [setShuffle].
  ///
  /// This is used to prevent a duplicate update by the `playlist-playing-pos` event.
  bool isPlaylistStateChangeAllowed = true;

  /// Current loaded [Media] queue.
  List<Media> current = <Media>[];

  /// Currently observed properties through [observeProperty].
  final HashMap<String, Future<void> Function(String)> observed =
      HashMap<String, Future<void> Function(String)>();

  final HashMap<int, Future<void> Function(Pointer<Void>)> eventObserved =
      HashMap<int, Future<void> Function(Pointer<Void>)>();

  /// The methods which must execute synchronously before playback of a source can begin.
  final List<Future<void> Function()> onLoadHooks = [];

  /// The methods which must execute synchronously before playback of a source can end.
  final List<Future<void> Function()> onUnloadHooks = [];

  final List<Future<void> Function()> onLoadFailHooks = [];

  final List<Future<void> Function()> onPreloadedHooks = [];

  /// Synchronization & mutual exclusion between methods of this class.
  static final Lock lock = Lock();

  /// [HashMap] for retrieving previously fetched audio-bitrate(s).
  static final HashMap<String, double> audioBitrateCache =
      HashMap<String, double>();

  /// Whether the [NativePlayer] is initialized for unit-testing.
  @visibleForTesting
  static bool test = false;
}
