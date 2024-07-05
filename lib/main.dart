import 'dart:async';
import 'dart:convert';
import 'dart:developer';
import 'dart:io';
import 'package:camera/camera.dart';
import 'package:crypto/crypto.dart';
import 'package:ffmpeg_kit_flutter_full/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_full/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter_full/return_code.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:gallery_saver/gallery_saver.dart';
import 'package:geolocator/geolocator.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ss());
}

class ss extends StatelessWidget {
  const ss({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      home: Scaffold(
        body: VerificationApp(),
      ),
    );
  }
}

class VerificationApp extends StatefulWidget {
  const VerificationApp({super.key});

  @override
  State<VerificationApp> createState() => _VerificationAppState();
}

class _VerificationAppState extends State<VerificationApp> {
  CameraController? controller;
  List<CameraDescription>? cameras;
  bool isRecording = false;
  late DateTime startTime;
  late Directory directory;
  bool isProcessing = false;
  Position? position;
  String verificationCode = 'fetching..';
  String userID = "A59994";

  @override
  void initState() {
    super.initState();
    initialize();
  }

  @override
  void dispose() {
    controller?.dispose();
    super.dispose();
  }

  void initialize() async {
    directory = (await getApplicationDocumentsDirectory());
    await determinePosition();
    await initializeCamera();
    setState(() {});
  }

  Future<void> determinePosition() async {
    bool serviceEnabled;
    LocationPermission permission;
    serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      log("Location services are disabled.");
      return Future.error('Location services are disabled.');
    }

    permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        log('Location permissions are denied');
        return Future.error('Location permissions are denied');
      }
    }
    if (permission == LocationPermission.deniedForever) {
      log('Location permissions are denied forever');
      return Future.error('Location permissions are permanently denied, we cannot request permissions.');
    }
    position = await Geolocator.getCurrentPosition();
    log("location - ${position?.longitude} ${position?.latitude}");
  }

  Future<void> initializeCamera() async {
    cameras = await availableCameras();
    controller = CameraController(cameras![0], ResolutionPreset.high);
    await controller?.initialize().then((_) {
      if (!mounted) {
        return;
      }
    }).catchError((Object e) {
      if (e is CameraException) {
        switch (e.code) {
          case 'CameraAccessDenied':
            // Handle access errors here.
            break;
          default:
            // Handle other errors here.
            break;
        }
      }
    });
  }

  void startRecording() async {
    startTime = DateTime.now();
    String nn = await generateSecureVerificationCode(DateFormat('dd-MM-yyyy h:mm:ss a').format(startTime), userID, position!);
    showSnackBar(context, "recording started.");
    setState(() {
      isRecording = true;
      verificationCode = nn;
    });
    await controller?.startVideoRecording();
  }

  void stopRecording() async {
    try {
      final videoFile = await controller?.stopVideoRecording();
      setState(() {
        isRecording = false;
        isProcessing = true;
      });
      await generateFinalVideo(videoFile!.path);
    } catch (e) {
      log("stopRecording error ${e.toString()}");
    }
  }

  Future<void> generateFinalVideo(String recordedVideoPath) async {
    showSnackBar(context, "saving video...");
    final fontPath = '${directory.path}/Roboto-Regular.ttf';
    final outputPath = '${directory.path}/output.mp4';
    final fontFile = File(fontPath);
    if (!fontFile.existsSync()) {
      final byteData = await rootBundle.load('assets/Roboto-Regular.ttf');
      await fontFile.writeAsBytes(byteData.buffer.asUint8List(byteData.offsetInBytes, byteData.lengthInBytes));
    }
    final outputFile = File(outputPath);
    if (outputFile.existsSync()) {
      await outputFile.delete();
    }
    Map<String, String> metadata = {
      'title': 'Recorded Video',
      'date': DateFormat('dd-MM-yyyy h:mm:ss a').format(startTime),
      'location': "${position?.latitude} ${position?.longitude}",
      'comment':
          'Video taken by $userID at Location - ${position!.latitude}, ${position!.longitude} on ${DateFormat('dd-MM-yyyy h:mm:ss a').format(startTime)}. Verification code is $verificationCode.',
    };
    String metadataString = metadata.entries.map((entry) => '-metadata ${entry.key}="${entry.value}"').join(' ');
    String dateString = DateFormat('dd-MM-yyyy').format(startTime).replaceAll(':', '\\:');

    final String command = '-i $recordedVideoPath -vf "drawtext=fontfile=$fontPath:'
        'text=\'User ID\\: $userID\n${position!.latitude}, ${position!.longitude}\nVerification Code\\: $verificationCode\n$dateString %{pts\\:localtime\\:${startTime.millisecondsSinceEpoch ~/ 1000}\\:%I\\\\\\:%M\\\\\\:%S %p}\''
        ':x=32:y=H-th-32:fontsize=36:fontcolor=white:line_spacing=20:'
        'box=1:boxcolor=black@0.6:boxborderw=10" -c:v mpeg4 -q:v 2 -preset slow '
        '$metadataString $outputPath';


    final session = await FFmpegKit.execute(command);
    final logs = await session.getLogs();
    for (final l in logs) {
      log(l.getMessage());
    }
    if (ReturnCode.isSuccess(await session.getReturnCode())) {
      await GallerySaver.saveVideo(outputPath);
      showSnackBar(context, "Video saved");
      log('hogayaa');
      checkMetadata(outputPath);
    } else {
      showSnackBar(context, "Unable to save video");
      log('Error: Video creation failed');
    }
    setState(() {
      isProcessing = false;
    });
  }

  String generateSecureVerificationCode(String dateTime, String userID, Position position) {
    String combinedText = '${dateTime}YeToCrazyHai$userID${position.latitude}${position.longitude}';
    var bytes = utf8.encode(combinedText);
    var hash = sha256.convert(bytes);
    return hash.toString().substring(0, 6);
  }

  Future<void> checkMetadata(String filePath) async {
    final session = await FFprobeKit.getMediaInformation(filePath);
    for (final l in (await session.getLogs())) {
      log(l.getMessage());
    }
    log(' ${session.getMediaInformation()?.getTags()}');
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(
          title: const Text("Record with Details"),
        ),
        body: (isProcessing || position == null || controller == null || !controller!.value.isInitialized)
            ? const Center(
                child: CircularProgressIndicator(),
              )
            : Stack(
                children: [
                  CameraPreview(controller!),
                  if (isRecording)
                    Positioned(
                      bottom: 16,
                      left: 16,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 5),
                        color: Colors.black54,
                        child: StreamBuilder(
                            stream: Stream.periodic(const Duration(seconds: 1)),
                            builder: (context, snapshot) {
                              return Text(
                                'User ID: $userID\n${position == null ? 'loading..' : '${position!.latitude}, ${position!.longitude}'}\nVerification Code: $verificationCode \n${DateFormat('dd-MM-yyyy h:mm:ss a').format(DateTime.now())}',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 18,
                                ),
                              );
                            }),
                      ),
                    ),
                ],
              ),
        floatingActionButton: (isProcessing || position == null || controller == null || !controller!.value.isInitialized)
            ? null
            : Padding(
              padding: const EdgeInsets.only(bottom: 40),
              child: FloatingActionButton(
                  backgroundColor: isRecording ? Colors.red.shade100 : Colors.blue.shade100,
                  onPressed: !(controller == null || !controller!.value.isInitialized) ? (isRecording ? stopRecording : startRecording) : () {},
                  child: Icon(
                    isRecording ? Icons.stop : Icons.videocam,
                    color: isRecording ? Colors.red.shade300 : Colors.blue.shade400,
                  ),
                ),
            ),
      ),
    );
  }
}

void showSnackBar(BuildContext context, String text) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
    duration: const Duration(seconds: 2),
    content: Text(
      text,
      style: const TextStyle(color: Colors.white),
    ),
    backgroundColor: Colors.black87,
    elevation: 10,
    behavior: SnackBarBehavior.floating,
    margin: const EdgeInsets.all(5),
  ));
}
