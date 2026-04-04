import 'dart:convert';
import 'dart:io';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:record/record.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:http/http.dart' as http;

void main() {
  runApp(const TalkTallyApp());
}

class TalkTallyApp extends StatelessWidget {
  const TalkTallyApp({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Talk Tally',
      theme: ThemeData(
        primarySwatch: Colors.blue,
        brightness: Brightness.light,
        fontFamily: 'Roboto',
      ),
      home: const RecorderScreen(),
      debugShowCheckedModeBanner: false,
    );
  }
}

class RecorderScreen extends StatefulWidget {
  const RecorderScreen({Key? key}) : super(key: key);

  @override
  State<RecorderScreen> createState() => _RecorderScreenState();
}

class _RecorderScreenState extends State<RecorderScreen> {
  late final AudioRecorder _audioRecorder;
  bool _isRecording = false;
  bool _isProcessing = false;
  String _statusText = "Tap to start recording";
  String? _transcriptionText;

  @override
  void initState() {
    super.initState();
    _audioRecorder = AudioRecorder();
  }

  @override
  void dispose() {
    _audioRecorder.dispose();
    super.dispose();
  }

  Future<void> _toggleRecording() async {
    if (_isProcessing) return; // Prevent action while processing

    try {
      if (_isRecording) {
        // Stop recording
        final path = await _audioRecorder.stop();
        print("Recording stopped");
        print("File path: $path");
        
        setState(() {
          _isRecording = false;
          _isProcessing = true;
          _statusText = "Uploading...";
          _transcriptionText = null;
        });

        if (path != null) {
          await _uploadAudioAndTranscribe(path);
        } else {
          setState(() {
            _isProcessing = false;
            _statusText = "Tap to start recording";
          });
        }
      } else {
        // Request permissions
        if (await _requestMicrophonePermission()) {
          final dir = await getApplicationDocumentsDirectory();
          final path = '${dir.path}/talk_tally_${DateTime.now().millisecondsSinceEpoch}.m4a';

          // Start recording
          await _audioRecorder.start(
            const RecordConfig(
              encoder: AudioEncoder.aacLc,
              sampleRate: 44100,
              bitRate: 128000,
              numChannels: 1, // Mono channel
            ),
            path: path,
          );

          setState(() {
            _isRecording = true;
            _statusText = "Recording...";
            _transcriptionText = null;
          });
        }
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error: $e')),
      );
      setState(() {
        _isRecording = false;
        _isProcessing = false;
        _statusText = "Tap to start recording";
      });
    }
  }

  Future<void> _uploadAudioAndTranscribe(String filePath) async {
    // 1. URL for physical device over WiFi
    const backendUrl = 'http://10.0.3.49:8000/upload';

    // 2. Validate audio file
    final file = File(filePath);
    if (!await file.exists() || await file.length() == 0) {
      setState(() {
        _statusText = "File not found";
        _isProcessing = false;
      });
      return;
    }

    setState(() {
      _statusText = "Uploading...";
    });

    try {
      print("Sending request to backend...");
      var uri = Uri.parse(backendUrl);
      var request = http.MultipartRequest('POST', uri);
      request.files.add(await http.MultipartFile.fromPath('file', filePath));

      // Use a timeout to handle network failure gracefully
      var streamedResponse = await request.send().timeout(const Duration(seconds: 30));
      var response = await http.Response.fromStream(streamedResponse);

      print("Response status: ${response.statusCode}");
      print("Response body: ${response.body}");

      setState(() {
        _statusText = "Processing...";
      });

      if (response.statusCode == 200) {
        final Map<String, dynamic> responseData = json.decode(response.body);
        
        setState(() {
          _transcriptionText = responseData['text'];
          _statusText = "Done";
        });
      } else {
        setState(() {
          _statusText = "Processing error";
        });
      }
    } on TimeoutException {
      setState(() {
        _statusText = "Network Error";
      });
    } catch (e) {
      setState(() {
        _statusText = "Network Error";
      });
    } finally {
      setState(() {
        _isProcessing = false;
        if (_statusText != "Done" && _statusText != "Network Error" && _statusText != "Processing error" && _statusText != "File not found") {
           _statusText = "Tap to start recording";
        }
      });
    }
  }

  Future<bool> _requestMicrophonePermission() async {
    final status = await Permission.microphone.request();
    if (status != PermissionStatus.granted) {
      setState(() {
        _statusText = "Microphone permission required";
      });
      return false;
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F7FA), // minimal background
      appBar: AppBar(
        title: const Text('Talk Tally', style: TextStyle(fontWeight: FontWeight.bold)),
        centerTitle: true,
        backgroundColor: Colors.white,
        foregroundColor: Colors.black87,
        elevation: 0,
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Text(
                'Financial Conversation Recorder',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w500,
                  color: Colors.blueGrey,
                  letterSpacing: 0.5,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 64),
              GestureDetector(
                onTap: _toggleRecording,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 300),
                  height: 160,
                  width: 160,
                  decoration: BoxDecoration(
                    color: _isRecording ? Colors.redAccent : (_isProcessing ? Colors.orangeAccent : Colors.white),
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: _isRecording 
                            ? Colors.redAccent.withOpacity(0.4) 
                            : (_isProcessing ? Colors.orangeAccent.withOpacity(0.4) : Colors.black.withOpacity(0.1)),
                        blurRadius: 20,
                        spreadRadius: 5,
                        offset: const Offset(0, 8),
                      )
                    ],
                  ),
                  child: _isProcessing 
                      ? const Center(child: CircularProgressIndicator(color: Colors.white))
                      : Icon(
                          _isRecording ? Icons.stop_rounded : Icons.mic_rounded,
                          size: 80,
                          color: _isRecording ? Colors.white : Colors.blueAccent,
                        ),
                ),
              ),
              const SizedBox(height: 48),
              Text(
                _statusText,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: _isRecording ? Colors.redAccent : Colors.black87,
                ),
              ),
              const SizedBox(height: 32),
              if (_transcriptionText != null)
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(12),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.05),
                        blurRadius: 10,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Text(
                        "Transcription:",
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                          color: Colors.blueGrey,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        _transcriptionText!,
                        style: const TextStyle(
                          fontSize: 16,
                          height: 1.5,
                          color: Colors.black87,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
