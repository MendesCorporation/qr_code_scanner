// ignore_for_file: avoid_web_libraries_in_flutter

import 'dart:async';
import 'dart:core';
import 'dart:html' as html;
import 'dart:js_util';

import 'package:flutter/material.dart';
import 'package:flutter_web_plugins/flutter_web_plugins.dart' as web_plugins; // ✅ Correto para Flutter 3.22+

import '../../qr_code_scanner.dart';
import 'jsqr.dart';
import 'media.dart';

class WebQrView extends StatefulWidget {
  final QRViewCreatedCallback onPlatformViewCreated;
  final PermissionSetCallback? onPermissionSet;
  final CameraFacing? cameraFacing;

  const WebQrView({
    Key? key,
    required this.onPlatformViewCreated,
    this.onPermissionSet,
    this.cameraFacing = CameraFacing.front,
  }) : super(key: key);

  @override
  _WebQrViewState createState() => _WebQrViewState();

  static html.DivElement vidDiv = html.DivElement();

  static Future<bool> cameraAvailable() async {
    final sources = await html.window.navigator.mediaDevices!.enumerateDevices();
    return sources.any((e) => e.kind == 'videoinput');
  }
}

class _WebQrViewState extends State<WebQrView> {
  html.MediaStream? _localStream;
  bool _currentlyProcessing = false;
  QRViewControllerWeb? _controller;

  late Size _size = const Size(0, 0);
  Timer? timer;
  String? code;
  String? _errorMsg;
  html.VideoElement video = html.VideoElement();
  String viewID = 'QRVIEW-' + DateTime.now().millisecondsSinceEpoch.toString();

  final StreamController<Barcode> _scanUpdateController = StreamController<Barcode>();
  late CameraFacing facing;

  Timer? _frameIntervall;

  @override
  void initState() {
    super.initState();

    facing = widget.cameraFacing ?? CameraFacing.front;

    WebQrView.vidDiv.children = [video];
    web_plugins.registerViewFactory(viewID, (int id) => WebQrView.vidDiv); // ✅ atualizado

    Timer(const Duration(milliseconds: 500), () {
      start();
    });
  }

  Future start() async {
    await _makeCall();
    _frameIntervall?.cancel();
    _frameIntervall = Timer.periodic(const Duration(milliseconds: 200), (timer) {
      _captureFrame2();
    });
  }

  void cancel() {
    timer?.cancel();
    timer = null;
    if (_currentlyProcessing) {
      _stopStream();
    }
  }

  @override
  void dispose() {
    cancel();
    super.dispose();
  }

  Future<void> _makeCall() async {
    if (_localStream != null) return;

    try {
      var constraints = UserMediaOptions(
        video: VideoOptions(
          facingMode: (facing == CameraFacing.front ? 'user' : 'environment'),
        ),
      );

      if (_controller == null) {
        _controller = QRViewControllerWeb(this);
        widget.onPlatformViewCreated(_controller!);
      }

      var stream = await promiseToFuture(getUserMedia(constraints));
      widget.onPermissionSet?.call(_controller!, true);
      _localStream = stream;
      video.srcObject = _localStream;
      video.setAttribute('playsinline', 'true');
      await video.play();
    } catch (e) {
      cancel();
      if (e.toString().contains("NotAllowedError")) {
        widget.onPermissionSet?.call(_controller!, false);
      }
      setState(() {
        _errorMsg = e.toString();
      });
      return;
    }

    if (!mounted) return;

    setState(() {
      _currentlyProcessing = true;
    });
  }

  Future<void> _stopStream() async {
    try {
      _localStream?.getTracks().forEach((track) {
        if (track.readyState == 'live') {
          track.stop();
        }
      });
      video.srcObject = null;
      _localStream = null;
    } catch (_) {}
  }

  Future<void> _captureFrame2() async {
    if (_localStream == null) return;

    final canvas = html.CanvasElement(width: video.videoWidth, height: video.videoHeight);
    final ctx = canvas.context2D;
    ctx.drawImage(video, 0, 0);
    final imgData = ctx.getImageData(0, 0, canvas.width!, canvas.height!);

    final size = Size(canvas.width?.toDouble() ?? 0, canvas.height?.toDouble() ?? 0);
    if (size != _size) {
      setState(() {
        _setCanvasSize(size);
      });
    }

    try {
      final code = jsQR(imgData.data, canvas.width, canvas.height);
      if (code != null && code.data != null) {
        _scanUpdateController.add(
          Barcode(code.data, BarcodeFormat.qrcode, code.data.codeUnits),
        );
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    if (_errorMsg != null) {
      return Center(child: Text(_errorMsg!));
    }
    if (_localStream == null) {
      return const Center(child: CircularProgressIndicator());
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        var zoom = 1.0;

        if (_size.height != 0) zoom = constraints.maxHeight / _size.height;

        if (_size.width != 0) {
          final horizontalZoom = constraints.maxWidth / _size.width;
          if (horizontalZoom > zoom) {
            zoom = horizontalZoom;
          }
        }

        return SizedBox(
          width: constraints.maxWidth,
          height: constraints.maxHeight,
          child: Center(
            child: SizedBox.fromSize(
              size: _size,
              child: Transform.scale(
                alignment: Alignment.center,
                scale: zoom,
                child: HtmlElementView(viewType: viewID),
              ),
            ),
          ),
        );
      },
    );
  }

  void _setCanvasSize(Size size) {
    setState(() {
      _size = size;
    });
  }
}

class QRViewControllerWeb implements QRViewController {
  final _WebQrViewState _state;

  QRViewControllerWeb(this._state);

  @override
  void dispose() => _state.cancel();

  @override
  Future<CameraFacing> flipCamera() async {
    _state.facing = _state.facing == CameraFacing.front
        ? CameraFacing.back
        : CameraFacing.front;
    await _state.start();
    return _state.facing;
  }

  @override
  Future<CameraFacing> getCameraInfo() async => _state.facing;

  @override
  Future<bool?> getFlashStatus() async => false;

  @override
  Future<SystemFeatures> getSystemFeatures() => throw UnimplementedError();

  @override
  bool get hasPermissions => throw UnimplementedError();

  @override
  Future<void> pauseCamera() => throw UnimplementedError();

  @override
  Future<void> resumeCamera() => throw UnimplementedError();

  @override
  Stream<Barcode> get scannedDataStream => _state._scanUpdateController.stream;

  @override
  Future<void> stopCamera() => throw UnimplementedError();

  @override
  Future<void> toggleFlash() async {}

  @override
  Future<void> scanInvert(bool isScanInvert) => throw UnimplementedError();
}

Widget createWebQrView({
  required QRViewCreatedCallback onPlatformViewCreated,
  PermissionSetCallback? onPermissionSet,
  CameraFacing? cameraFacing,
}) {
  return WebQrView(
    onPlatformViewCreated: onPlatformViewCreated,
    onPermissionSet: onPermissionSet,
    cameraFacing: cameraFacing,
  );
}
