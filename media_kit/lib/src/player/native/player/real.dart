/// This file is a part of media_kit (https://github.com/media-kit/media-kit).
///
/// Copyright © 2021 & onwards, Hitesh Kumar Saini <saini123hitesh@gmail.com>.
/// All rights reserved.
/// Use of this source code is governed by MIT license that can be found in the LICENSE file.
import 'dart:ffi';
import 'dart:async';
import 'dart:collection';
import 'package:meta/meta.dart';
import 'package:synchronized/synchronized.dart';

import 'package:media_kit/ffi/ffi.dart';

import 'package:media_kit/src/models/player_log.dart';
import 'package:media_kit/src/player/native/core/initializer.dart';
import 'package:media_kit/src/player/native/core/native_library.dart';
import 'package:media_kit/src/player/native/utils/native_reference_holder.dart';
import 'package:media_kit/src/player/platform_player.dart';

import 'package:media_kit/generated/libmpv/bindings.dart' as generated;

/// Initializes the native backend for package:media_kit.
void nativeEnsureInitialized({String? libmpv}) {
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

    if (event.ref.event_id ==
        generated.mpv_event_id.MPV_EVENT_PROPERTY_CHANGE) {
      final prop = event.ref.data.cast<generated.mpv_event_property>();

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

  /// Whether the [NativePlayer] is initialized for unit-testing.
  @visibleForTesting
  static bool test = false;
}
