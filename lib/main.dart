import 'dart:convert';
import 'dart:io';
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:record/record.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:http/http.dart' as http;

Future<Map<String, dynamic>> sendToBackend(String filePath) async {
  const backendUrl = 'http://10.0.3.49:8000/upload';
  final file = File(filePath);
  if (!file.existsSync() || file.lengthSync() == 0) {
    return {"error": "File not found"};
  }

  try {
    var uri = Uri.parse(backendUrl);
    var request = http.MultipartRequest('POST', uri);
    final timestampStr = DateTime.now().toLocal().toString().split('.')[0];
    request.fields['timestamp'] = timestampStr;
    request.files.add(await http.MultipartFile.fromPath('file', filePath));

    var streamedResponse = await request.send().timeout(const Duration(seconds: 30));
    var response = await http.Response.fromStream(streamedResponse);

    print("Backend response: ${response.body}");
    
    if (response.statusCode == 200) {
      return {"body": jsonDecode(response.body), "timestamp": timestampStr};
    } else {
      return {"error": "Processing error"};
    }
  } catch (e) {
    print("Network Error: $e");
    return {"error": "Network Error"};
  }
}

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
               // Push chunk to background api sync safely without blocking UI
               _uploadAudioAndTranscribe(path);
             }
             
             await Future.delayed(const Duration(seconds: 2));
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
    await Future.delayed(const Duration(milliseconds: 10));
    final result = await compute(sendToBackend, filePath);
    
    if (!mounted) return;
    
    if (result.containsKey("error")) {
        setState(() {
            _statusText = result["error"];
            _isProcessing = false;
        });
        return;
    }
    
    final responseData = result["body"];
    final timestampStr = result["timestamp"];
    
    final data = responseData["data"];
    final summary = responseData["summary"];
    final message = responseData["message"];

    if (data == null) {
      print("No financial insight");
      if (mounted) {
          setState(() {
            _statusText = "Done: No Insight";
            _isProcessing = false;
          });
      }
      return;
    }

    String text = data["text"] ?? "";
    double? amount;
    if (data["amount"] != null) {
        amount = (data["amount"] is int) ? (data["amount"] as int).toDouble() : data["amount"];
    }
    String? person = data["person"];
    String? intent = data["intent"];
    String? emotion = data["emotion"];

    if (mounted) {
      setState(() {
        _transcriptions.insert(0, {
             "text": summary ?? "No insight", 
             "language": "Parsed",
             "timestamp": timestampStr,
        });
        
        _statusText = "Done";
        _isProcessing = false;
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
            icon: const Icon(Icons.bar_chart),
            tooltip: 'Analytics',
            onPressed: () {
              Navigator.push(context, MaterialPageRoute(builder: (_) => const AnalyticsPage()));
            },
          ),
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

// ─────────────────────────────────────────────────────
//  ANALYTICS PAGE
// ─────────────────────────────────────────────────────

class AnalyticsPage extends StatefulWidget {
  const AnalyticsPage({Key? key}) : super(key: key);
  @override
  State<AnalyticsPage> createState() => _AnalyticsPageState();
}

class _AnalyticsPageState extends State<AnalyticsPage> {
  Map<String, dynamic>? _data;
  Map<String, dynamic>? _groqInsights;
  bool _isLoading = true;
  String? _error;

  static const String _baseUrl = 'http://10.0.3.49:8000';

  @override
  void initState() {
    super.initState();
    _fetchAll();
  }

  Future<void> _fetchAll() async {
    setState(() { _isLoading = true; _error = null; });
    try {
      // Fetch charts + Groq insights in parallel
      final results = await Future.wait([
        http.get(Uri.parse('$_baseUrl/analytics')).timeout(const Duration(seconds: 20)),
        http.get(Uri.parse('$_baseUrl/groq-insights')).timeout(const Duration(seconds: 25)),
      ]);

      final chartsResp = results[0];
      final insightsResp = results[1];

      setState(() {
        if (chartsResp.statusCode == 200) _data = json.decode(chartsResp.body);
        if (insightsResp.statusCode == 200) {
          final body = json.decode(insightsResp.body);
          _groqInsights = body['insights'] as Map<String, dynamic>?;
        }
        _isLoading = false;
      });
    } catch (e) {
      setState(() { _error = 'Network error: $e'; _isLoading = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0F1117),
      appBar: AppBar(
        title: const Text('Analytics', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white)),
        backgroundColor: const Color(0xFF1A1D27),
        iconTheme: const IconThemeData(color: Colors.white),
        elevation: 0,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh, color: Colors.white),
            onPressed: _fetchAll,
          )
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator(color: Color(0xFF6C63FF)))
          : _error != null
              ? Center(child: Text(_error!, style: const TextStyle(color: Colors.redAccent)))
              : _buildDashboard(),
    );
  }

  Widget _buildDashboard() {
    if (_data == null) {
      return const Center(child: Text('No data', style: TextStyle(color: Colors.white54)));
    }
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _sectionHeader('📦 Product Distribution'),
        _barChart(_data!['product_distribution']),
        const SizedBox(height: 24),
        _sectionHeader('🎯 Intent Distribution'),
        _barChart(_data!['intent_distribution']),
        const SizedBox(height: 24),
        _sectionHeader('✅ Decision Confidence'),
        _confidenceChart(_data!['confidence_distribution']),
        const SizedBox(height: 24),
        _sectionHeader('📅 Timeline Trend'),
        _timelineChart(_data!['timeline_trend']),
        const SizedBox(height: 24),
        _riskBanner(_data!['risk_proxy']),
        const SizedBox(height: 32),
      ],
    );
  }

  Widget _sectionHeader(String title) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white)),
  );

  Widget _barChart(dynamic rows) {
    if (rows == null || (rows as List).isEmpty) {
      return const Text('No data yet', style: TextStyle(color: Colors.white38));
    }
    final items = rows as List;
    final maxCount = items.map((r) => (r['count'] ?? 0) as num).reduce((a, b) => a > b ? a : b);
    return Column(
      children: items.map<Widget>((row) {
        final label = row['label']?.toString() ?? '?';
        final count = (row['count'] ?? 0) as num;
        final ratio = maxCount > 0 ? count / maxCount : 0.0;
        return Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Row(
            children: [
              SizedBox(
                width: 90,
                child: Text(label, style: const TextStyle(color: Colors.white70, fontSize: 12), overflow: TextOverflow.ellipsis),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: ratio.toDouble(),
                    minHeight: 20,
                    backgroundColor: const Color(0xFF2A2D3E),
                    valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFF6C63FF)),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text('$count', style: const TextStyle(color: Colors.white54, fontSize: 12)),
            ],
          ),
        );
      }).toList(),
    );
  }

  static const _confColors = {
    'DECIDED':     Color(0xFF4CAF50),
    'CONSIDERING': Color(0xFFFFC107),
    'MENTIONED':   Color(0xFF9E9E9E),
  };

  Widget _confidenceChart(dynamic rows) {
    if (rows == null || (rows as List).isEmpty) {
      return const Text('No data yet', style: TextStyle(color: Colors.white38));
    }
    final items = rows as List;
    final total = items.map((r) => (r['count'] ?? 0) as num).fold<num>(0, (a, b) => a + b);
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: items.map<Widget>((row) {
        final label = row['label']?.toString() ?? '?';
        final count = (row['count'] ?? 0) as num;
        final pct = total > 0 ? (count / total * 100).toStringAsFixed(0) : '0';
        final color = _confColors[label] ?? Colors.blueGrey;
        return Column(
          children: [
            Container(
              width: 64, height: 64,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: color, width: 3),
              ),
              child: Center(child: Text('$pct%', style: TextStyle(color: color, fontWeight: FontWeight.bold))),
            ),
            const SizedBox(height: 6),
            Text(label, style: const TextStyle(color: Colors.white60, fontSize: 11)),
            Text('($count)', style: const TextStyle(color: Colors.white38, fontSize: 11)),
          ],
        );
      }).toList(),
    );
  }

  Widget _timelineChart(dynamic rows) {
    if (rows == null || (rows as List).isEmpty) {
      return const Text('No data yet', style: TextStyle(color: Colors.white38));
    }
    final items = rows as List;
    final maxCount = items.map((r) => (r['count'] ?? 0) as num).reduce((a, b) => a > b ? a : b);
    return SizedBox(
      height: 80,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: items.map<Widget>((row) {
          final count = (row['count'] ?? 0) as num;
          final ratio = maxCount > 0 ? count / maxCount : 0.0;
          final day = row['day']?.toString().split('T')[0] ?? '';
          return Expanded(
            child: Tooltip(
              message: '$day: $count',
              child: Container(
                margin: const EdgeInsets.symmetric(horizontal: 2),
                height: (60 * ratio + 4).toDouble(),
                decoration: BoxDecoration(
                  color: const Color(0xFF6C63FF).withOpacity(0.75),
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _riskBanner(dynamic rows) {
    if (rows == null || (rows as List).isEmpty) return const SizedBox();
    final riskCount = (rows[0]['risk_count'] ?? 0) as num;
    final color = riskCount > 5 ? Colors.redAccent : riskCount > 1 ? Colors.orangeAccent : Colors.greenAccent;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        border: Border.all(color: color.withOpacity(0.4)),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(Icons.warning_amber_rounded, color: color, size: 32),
          const SizedBox(width: 12),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('⚠️ Risk Events', style: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 15)),
              Text('$riskCount loan/EMI/credit events found',
                  style: const TextStyle(color: Colors.white54, fontSize: 12)),
            ],
          ),
        ],
      ),
    );
  }
}
