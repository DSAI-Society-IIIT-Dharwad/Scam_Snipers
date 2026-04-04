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
  
  final List<Map<String, dynamic>> _transcriptions = [];
  Timer? _chunkTimer;

  @override
  void initState() {
    super.initState();
    _audioRecorder = AudioRecorder();
  }

  @override
  void dispose() {
    _chunkTimer?.cancel();
    _audioRecorder.dispose();
    super.dispose();
  }

  Future<void> _startRecordingChunk() async {
    final dir = await getApplicationDocumentsDirectory();
    final path = '${dir.path}/talk_tally_${DateTime.now().millisecondsSinceEpoch}.m4a';
    await _audioRecorder.start(
      const RecordConfig(
        encoder: AudioEncoder.aacLc,
        sampleRate: 44100,
        bitRate: 128000,
        numChannels: 1, // Mono channel
      ),
      path: path,
    );
  }

  Future<void> _toggleRecording() async {
    try {
      if (_isRecording) {
        // Stop recording
        _chunkTimer?.cancel();
        final path = await _audioRecorder.stop();
        print("Recording stopped manually");
        
        setState(() {
          _isRecording = false;
          _isProcessing = true;
          _statusText = "Stopping and processing last chunk...";
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
        if (_isProcessing) return; // Wait until ready
        
        // Request permissions
        if (await _requestMicrophonePermission()) {
          // Clear history on new sessions
          setState(() {
            _isRecording = true;
            _statusText = "Recording continuously...";
            _transcriptions.clear();
          });

          // Start initial segment
          await _startRecordingChunk();
          print("Recording started");

          // Start continuous chunk loop (8 second chunks)
          _chunkTimer = Timer.periodic(const Duration(seconds: 8), (timer) async {
             if (!_isRecording) {
                 timer.cancel();
                 return;
             }
             final path = await _audioRecorder.stop();
             print("Chunk stopped. Restarting...");
             
             // Immediately start next segment seamlessly
             await _startRecordingChunk(); 
             
             if (path != null) {
               // Push chunk to background api sync silently
               _uploadAudioAndTranscribe(path);
             }
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
      if (!_isRecording) {
          setState(() {
            _statusText = "File not found";
            _isProcessing = false;
          });
      }
      return;
    }

    try {
      print("Sending chunk to backend...");
      var uri = Uri.parse(backendUrl);
      var request = http.MultipartRequest('POST', uri);
      
      // 3. Attach standard fields
      final timestampStr = DateTime.now().toLocal().toString().split('.')[0];
      request.fields['timestamp'] = timestampStr;
      request.files.add(await http.MultipartFile.fromPath('file', filePath));

      var streamedResponse = await request.send().timeout(const Duration(seconds: 30));
      var response = await http.Response.fromStream(streamedResponse);

      print("Response status: ${response.statusCode}");
      
      if (response.statusCode == 200) {
        final Map<String, dynamic> responseData = json.decode(response.body);
        
        setState(() {
          // Push new transcription to top of list
          _transcriptions.insert(0, {
             "text": responseData['text'] ?? "Unable to parse text",
             "language": responseData['language'] ?? "Unknown",
             "timestamp": responseData['timestamp'] ?? timestampStr,
          });
          
          if (!_isRecording) _statusText = "Done";
        });
      } else {
        if (!_isRecording) {
          setState(() {
            _statusText = "Processing error";
          });
        }
      }
    } on TimeoutException {
      if (!_isRecording) {
        setState(() {
            _statusText = "Network Error";
        });
      }
    } catch (e) {
      if (!_isRecording) {
        setState(() {
            _statusText = "Network Error";
        });
      }
    } finally {
      if (!_isRecording) {
          setState(() {
            _isProcessing = false;
            if (_statusText != "Done" && _statusText != "Network Error" && _statusText != "Processing error" && _statusText != "File not found") {
               _statusText = "Tap to start recording";
            }
          });
      }
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
                'Continuous Financial Recorder',
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
              ElevatedButton.icon(
                onPressed: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (context) => const InsightsPage()),
                  );
                },
                icon: const Icon(Icons.insights),
                label: const Text("View Insights"),
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  backgroundColor: Colors.white,
                  foregroundColor: Colors.blueAccent,
                  elevation: 2,
                ),
              ),
              const SizedBox(height: 24),
              if (_transcriptions.isNotEmpty)
                ListView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: _transcriptions.length,
                  itemBuilder: (context, index) {
                    final item = _transcriptions[index];
                    
                    // We extract safe fallbacks out of the nested dictionary response data natively:
                    String displayText = item['text'] ?? '';
                    if (item.containsKey('data') && item['data'] is Map && item['data']['text'] != null) {
                        displayText = item['data']['text'];
                    }
                    
                    return Container(
                      margin: const EdgeInsets.only(bottom: 12),
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
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(
                                item['timestamp'] ?? '',
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: Colors.grey,
                                ),
                              ),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                decoration: BoxDecoration(
                                  color: Colors.blue.withOpacity(0.1),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Text(
                                  item['language'] ?? 'Processed',
                                  style: const TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.bold,
                                    color: Colors.blue,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Text(
                            displayText,
                            style: const TextStyle(
                              fontSize: 16,
                              height: 1.5,
                              color: Colors.black87,
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class InsightsPage extends StatefulWidget {
  const InsightsPage({Key? key}) : super(key: key);

  @override
  State<InsightsPage> createState() => _InsightsPageState();
}

class _InsightsPageState extends State<InsightsPage> {
  List<dynamic> _insights = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _fetchInsights();
  }

  Future<void> _fetchInsights() async {
    setState(() {
      _isLoading = true;
    });
    try {
      final response = await http.get(Uri.parse('http://10.0.3.49:8000/insights'));
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        setState(() {
          _insights = data['insights'] ?? [];
          _isLoading = false;
        });
      } else {
        setState(() {
          _isLoading = false;
        });
      }
    } catch (e) {
      print("Error fetching insights: \$e");
      setState(() {
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F7FA),
      appBar: AppBar(
        title: const Text('Financial Insights', style: TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: Colors.white,
        foregroundColor: Colors.black87,
        elevation: 0,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _fetchInsights,
          )
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _insights.isEmpty
              ? const Center(child: Text("No insights available yet."))
              : RefreshIndicator(
                  onRefresh: _fetchInsights,
                  child: ListView.builder(
                    padding: const EdgeInsets.all(16.0),
                    itemCount: _insights.length,
                    itemBuilder: (context, index) {
                      final item = _insights[index];
                      final amount = item['amount'];
                      final person = item['person'] ?? 'Unknown';
                      final intent = item['intent'] ?? 'Unknown';
                      final emotion = item['emotion'] ?? 'neutral';
                      
                      String amountText = amount != null ? '₹\$amount' : '₹--';
                      String heading = '💰 \$amountText → \$person';
                      
                      String intentEmoji = '📌';
                      if (intent == 'transfer') intentEmoji = '💸';
                      if (intent == 'investment') intentEmoji = '📈';
                      if (intent == 'loan') intentEmoji = '🏦';
                      
                      String emotionEmoji = '😐';
                      if (emotion == 'stress') emotionEmoji = '😰';
                      if (emotion == 'positive') emotionEmoji = '😊';

                      return Card(
                        margin: const EdgeInsets.only(bottom: 16.0),
                        elevation: 2,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        child: Padding(
                          padding: const EdgeInsets.all(16.0),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  Expanded(
                                    child: Text(
                                      heading,
                                      style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.black87),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                  Text(
                                    item['created_at']?.split(' ')[0] ?? '',
                                    style: const TextStyle(fontSize: 12, color: Colors.grey),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 12),
                              Row(
                                children: [
                                  Text('\$intentEmoji \${intent.toString().toUpperCase()}', style: const TextStyle(color: Colors.blueGrey, fontWeight: FontWeight.w600)),
                                  const SizedBox(width: 16),
                                  Text('\$emotionEmoji \${emotion.toString().toUpperCase()}', style: const TextStyle(color: Colors.orange, fontWeight: FontWeight.w600)),
                                ],
                              ),
                              const Divider(height: 24, thickness: 1),
                              const Text(
                                '📝 Summary:',
                                style: TextStyle(fontWeight: FontWeight.bold, color: Colors.black54),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                item['summary'] ?? item['text'] ?? 'No summary available',
                                style: const TextStyle(fontSize: 15, height: 1.4),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
    );
  }
}
