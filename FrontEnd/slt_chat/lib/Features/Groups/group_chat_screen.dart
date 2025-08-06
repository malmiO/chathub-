import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:http_parser/http_parser.dart';
import 'package:image_picker/image_picker.dart';
import 'package:mime/mime.dart';
import 'package:path/path.dart' as path;
import 'package:socket_io_client/socket_io_client.dart' as socket_io;
import 'package:intl/intl.dart';
import 'package:flutter_sound/flutter_sound.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import '/common/widgets/colors.dart';
import '/config/config.dart';
import '/Features/Groups/group_info_screen.dart';
import '/Features/Groups/group_localDB.dart';
import 'package:video_player/video_player.dart';
import 'package:video_thumbnail/video_thumbnail.dart';
import 'package:syncfusion_flutter_pdfviewer/pdfviewer.dart';
import '/Features/Groups/delete_group_message_sheet.dart';

class GroupChatScreen extends StatefulWidget {
  final String userId;
  final String groupId;
  final String groupName;
  final String initialGroupProfilePic;

  const GroupChatScreen({
    super.key,
    required this.userId,
    required this.groupId,
    required this.groupName,
    required this.initialGroupProfilePic,
  });

  @override
  State<GroupChatScreen> createState() => _GroupChatScreenState();
}

class _GroupChatScreenState extends State<GroupChatScreen> {
  // Constants
  static const _voiceMimeType = 'audio/aac';
  static const _voiceCodec = Codec.aacADTS;
  static const _voiceSampleRate = 44100;
  static const _voiceBitRate = 128000;
  static const _tempIdPrefix = 'temp-';
  static const _retryIdPrefix = 'retry-';

  // Controllers and state
  final TextEditingController _messageController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final ImagePicker _picker = ImagePicker();
  final FlutterSoundRecorder _recorder = FlutterSoundRecorder();
  final FlutterSoundPlayer _player = FlutterSoundPlayer();
  final Set<String> _processedMessageIds = {};
  final LocalDatabase _localDb = LocalDatabase();

  List<Map<String, dynamic>> _messages = [];
  late socket_io.Socket _socket;
  late IOClient _httpClient;

  bool _isLoading = true;
  bool _isRecording = false;
  bool _isPlaying = false;
  bool _isRecorderInitialized = false;
  bool _isPermissionRequestInProgress = false;

  String? _typingUser;
  String? _currentlyPlayingUrl;
  String? _audioPath;
  String? _adminName;
  Map<String, dynamic>? _groupDetails;
  late String _groupProfilePic; // Dynamic profile picture state

  bool _isEmojiVisible = false;
  FocusNode _focusNode = FocusNode();
  Duration _recordingDuration = Duration.zero;
  StreamSubscription<RecordingDisposition>? _recorderSubscription;

  @override
  void initState() {
    super.initState();
    _groupProfilePic = widget.initialGroupProfilePic;
    _initializeServices();
  }

  Future<void> _initializeServices() async {
    await _localDb.initDatabase();
    _initializeHttpClient();
    _initializeRecorder();
    _initializePlayer();
    _fetchGroupDetails();
    _fetchMessages();
    _connectSocket();
  }

  @override
  void dispose() {
    _recorderSubscription?.cancel();
    _focusNode.dispose();
    _recorder.closeRecorder();
    _player.closePlayer();
    _localDb.close();
    _httpClient.close();
    _socket.emit('leave_group', {'group_id': widget.groupId});
    _socket.disconnect();
    _socket.off('receive_group_message');
    _messageController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _sortMessagesByTime() {
    _messages.sort((a, b) {
      final aTime = DateTime.tryParse(a['timestamp'] ?? '') ?? DateTime.now();
      final bTime = DateTime.tryParse(b['timestamp'] ?? '') ?? DateTime.now();
      return aTime.compareTo(bTime);
    });
  }

  void _toggleEmojiKeyboard() {
    if (_isEmojiVisible) {
      _focusNode.requestFocus();
    } else {
      _focusNode.unfocus();
    }
    setState(() => _isEmojiVisible = !_isEmojiVisible);
  }

  void _initializeHttpClient() {
    final client = HttpClient()..badCertificateCallback = (_, __, ___) => true;
    _httpClient = IOClient(client);
  }

  Future<void> _initializeRecorder() async {
    if (_isPermissionRequestInProgress) return;

    try {
      _isPermissionRequestInProgress = true;
      final status = await Permission.microphone.request();

      if (status != PermissionStatus.granted) {
        _showSnackBar('Microphone permission denied');
        return;
      }

      await _recorder.openRecorder();
      _isRecorderInitialized = true;
    } catch (e) {
      _showSnackBar('Failed to initialize recorder: $e');
    } finally {
      _isPermissionRequestInProgress = false;
    }
  }

  Future<void> _initializePlayer() async {
    try {
      await _player.openPlayer();
    } catch (e) {
      _showSnackBar('Failed to initialize player: $e');
    }
  }

  // Media handling
  Future<void> _startRecording() async {
    if (!_isRecorderInitialized) {
      _showSnackBar('Recorder not initialized. Please try again.');
      await _initializeRecorder();
      if (!_isRecorderInitialized) return;
    }

    try {
      final appDir = await getApplicationDocumentsDirectory();
      final voiceDir = Directory('${appDir.path}/voice_messages');
      if (!await voiceDir.exists()) await voiceDir.create(recursive: true);

      _audioPath =
          '${voiceDir.path}/voice_${DateTime.now().millisecondsSinceEpoch}.aac';
      await _recorder.startRecorder(
        toFile: _audioPath!,
        codec: _voiceCodec,
        sampleRate: _voiceSampleRate,
        bitRate: _voiceBitRate,
      );
      setState(() {
        _isRecording = true;
        _recordingDuration = Duration.zero;
      });
      _recorderSubscription = _recorder.onProgress!.listen((event) {
        if (mounted) {
          setState(() => _recordingDuration = event.duration);
        }
      }, onError: (error) => print('Recorder error: $error'));
    } catch (e) {
      _showSnackBar('Failed to start recording: $e');
    }
  }

  Future<void> _stopRecording() async {
    try {
      await _recorder.stopRecorder();
      if (_audioPath != null) await _saveAndSendVoiceMessage(_audioPath!);
      _recorderSubscription?.cancel();
      setState(() {
        _isRecording = false;
        _recordingDuration = Duration.zero;
      });
    } catch (e) {
      _showSnackBar('Failed to stop recording: $e');
    }
  }

  Future<void> _saveAndSendVoiceMessage(String filePath) async {
    try {
      final tempId = '$_tempIdPrefix${DateTime.now().millisecondsSinceEpoch}';

      await _localDb.insertMediaMessage(
        filePath: filePath,
        content: filePath,
        type: 'voice',
        isMe: 1,
        status: 'uploading',
        createdAt: DateTime.now().toIso8601String(),
        tempId: tempId,
      );

      setState(() {
        _messages.add({
          '_id': tempId,
          'tempId': tempId,
          'sender_id': widget.userId,
          'sender': {'name': 'You', 'id': widget.userId},
          'group_id': widget.groupId,
          'voice_url': filePath,
          'type': 'voice',
          'status': 'uploading',
          'timestamp': DateTime.now().toIso8601String(),
          'read_by': [widget.userId],
        });
        _sortMessagesByTime();
      });

      _scrollToBottom();
      await _uploadVoiceMessage(filePath, tempId);
    } catch (e) {
      _showSnackBar('Error saving voice message: $e');
    }
  }

  Future<void> _uploadVoiceMessage(String filePath, String tempId) async {
    try {
      final file = File(filePath);
      if (!await file.exists()) {
        await _updateVoiceMessageStatus(
          tempId: tempId,
          status: 'failed',
          error: 'File not found',
        );
        return;
      }

      final bytes = await file.readAsBytes();
      final fileName = path.basename(filePath);

      final request =
          http.MultipartRequest(
              'POST',
              Uri.parse('${AppConfig.baseUrl}/upload-group-voice'),
            )
            ..fields['sender_id'] = widget.userId
            ..fields['group_id'] = widget.groupId
            ..fields['temp_id'] = tempId
            ..files.add(
              http.MultipartFile.fromBytes(
                'file',
                bytes,
                filename: fileName,
                contentType: MediaType.parse(_voiceMimeType),
              ),
            );

      final response = await request.send();
      final responseData = await response.stream.bytesToString();
      final jsonResponse = json.decode(responseData);

      if (response.statusCode >= 200 && response.statusCode < 300) {
        await _updateVoiceMessageStatus(
          tempId: tempId,
          status: 'success',
          voiceUrl: jsonResponse['voice_url'],
        );
        // Fetch all messages after successful upload
        await _fetchMessages();
      } else {
        throw Exception('Upload failed: ${jsonResponse['error']}');
      }
    } catch (e) {
      await _updateVoiceMessageStatus(
        tempId: tempId,
        status: 'failed',
        error: e.toString(),
      );
    }
  }

  Future<void> _updateVoiceMessageStatus({
    required String tempId,
    required String status,
    String? voiceUrl,
    String? error,
  }) async {
    try {
      await _localDb.updateMessageStatus(
        tempId: tempId,
        status: status,
        content: voiceUrl ?? '',
      );

      // Update local message status without triggering UI update
      final index = _messages.indexWhere((msg) => msg['tempId'] == tempId);
      if (index != -1) {
        _messages[index] = {
          ..._messages[index],
          'status': status,
          if (voiceUrl != null) 'voice_url': _getFullUrl(voiceUrl),
        };
      }

      if (status == 'success') {
        _showSnackBar('Voice message uploaded successfully');
      } else {
        _showSnackBar('Upload failed: ${error ?? 'Unknown error'}');
      }
    } catch (e) {
      _showSnackBar('Error updating message status: $e');
    }
  }

  Future<void> _retryVoiceMessage(String filePath, String messageId) async {
    try {
      final file = File(filePath);
      if (!await file.exists()) {
        _showSnackBar('Audio file no longer exists');
        return;
      }

      setState(() {
        final index = _messages.indexWhere((msg) => msg['_id'] == messageId);
        if (index != -1) {
          _messages[index]['status'] = 'uploading';
        }
      });

      final tempId = '$_retryIdPrefix${DateTime.now().millisecondsSinceEpoch}';

      await _localDb.updateMessage(
        whereColumn: 'content',
        whereValue: filePath,
        values: {'status': 'uploading', 'tempId': tempId},
      );

      setState(() {
        final index = _messages.indexWhere((msg) => msg['_id'] == messageId);
        if (index != -1) {
          _messages[index]['_id'] = tempId;
          _messages[index]['tempId'] = tempId;
        }
      });

      await _uploadVoiceMessage(filePath, tempId);
    } catch (e) {
      _showSnackBar('Error retrying voice message: $e');
    }
  }

  Future<void> _pickAndSendImage(ImageSource source) async {
    try {
      final XFile? image = await _picker.pickImage(source: source);
      if (image == null) return;

      final tempId = '$_tempIdPrefix${DateTime.now().millisecondsSinceEpoch}';
      final filePath = image.path;

      await _localDb.insertMediaMessage(
        filePath: filePath,
        content: filePath,
        type: 'image',
        isMe: 1,
        status: 'uploading',
        createdAt: DateTime.now().toIso8601String(),
        tempId: tempId,
      );

      setState(() {
        _messages.add({
          '_id': tempId,
          'tempId': tempId,
          'sender_id': widget.userId,
          'sender': {'name': 'You', 'id': widget.userId},
          'group_id': widget.groupId,
          'image_url': filePath,
          'type': 'image',
          'status': 'uploading',
          'timestamp': DateTime.now().toIso8601String(),
          'read_by': [widget.userId],
        });
        _sortMessagesByTime();
      });

      _scrollToBottom();
      await _uploadImage(filePath, tempId);
    } catch (e) {
      _showSnackBar('Error picking image: $e');
    }
  }

  Future<void> _uploadImage(String filePath, String tempId) async {
    try {
      final file = File(filePath);
      if (!await file.exists()) {
        await _updateImageStatus(
          tempId: tempId,
          status: 'failed',
          error: 'File not found',
        );
        return;
      }

      final bytes = await file.readAsBytes();
      final fileName = path.basename(filePath);
      final mimeType = lookupMimeType(filePath) ?? 'image/jpeg';

      final request =
          http.MultipartRequest(
              'POST',
              Uri.parse('${AppConfig.baseUrl}/upload-group-image'),
            )
            ..fields['sender_id'] = widget.userId
            ..fields['group_id'] = widget.groupId
            ..fields['temp_id'] = tempId
            ..files.add(
              http.MultipartFile.fromBytes(
                'file',
                bytes,
                filename: fileName,
                contentType: MediaType.parse(mimeType),
              ),
            );

      final response = await request.send();
      final responseData = await response.stream.bytesToString();
      final jsonResponse = json.decode(responseData);

      if (response.statusCode >= 200 && response.statusCode < 300) {
        await _updateImageStatus(
          tempId: tempId,
          status: 'success',
          imageUrl: jsonResponse['image_url'],
        );
        // Fetch all messages after successful upload
        await _fetchMessages();
      } else {
        throw Exception(
          'Upload failed: ${jsonResponse['error'] ?? 'Unknown error'}',
        );
      }
    } catch (e) {
      await _updateImageStatus(
        tempId: tempId,
        status: 'failed',
        error: e.toString(),
      );
    }
  }

  Future<void> _updateImageStatus({
    required String tempId,
    required String status,
    String? imageUrl,
    String? error,
  }) async {
    try {
      await _localDb.updateMessageStatus(
        tempId: tempId,
        status: status,
        content: imageUrl ?? '',
      );

      // Update local message status without triggering UI update
      final index = _messages.indexWhere((msg) => msg['tempId'] == tempId);
      if (index != -1) {
        _messages[index] = {
          ..._messages[index],
          'status': status,
          if (imageUrl != null) 'image_url': _getFullUrl(imageUrl),
        };
      }

      if (status == 'success') {
        _showSnackBar('Image uploaded successfully');
      } else {
        _showSnackBar('Upload failed: ${error ?? 'Unknown error'}');
      }
    } catch (e) {
      _showSnackBar('Error updating image status: $e');
    }
  }

  Future<void> _retryImage(String filePath, String messageId) async {
    try {
      final file = File(filePath);
      if (!await file.exists()) {
        _showSnackBar('Image file no longer exists');
        return;
      }

      setState(() {
        final index = _messages.indexWhere((msg) => msg['_id'] == messageId);
        if (index != -1) {
          _messages[index]['status'] = 'uploading';
        }
      });

      final tempId = '$_retryIdPrefix${DateTime.now().millisecondsSinceEpoch}';

      await _localDb.updateMessage(
        whereColumn: 'content',
        whereValue: filePath,
        values: {'status': 'uploading', 'tempId': tempId},
      );

      setState(() {
        final index = _messages.indexWhere((msg) => msg['_id'] == messageId);
        if (index != -1) {
          _messages[index]['_id'] = tempId;
          _messages[index]['tempId'] = tempId;
        }
      });

      await _uploadImage(filePath, tempId);
    } catch (e) {
      _showSnackBar('Error retrying image: $e');
    }
  }

  // PDF Handling
  Future<void> _pickAndSendPdf() async {
    try {
      // Pick PDF file
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['pdf'],
      );

      if (result == null || result.files.isEmpty) return;

      final filePath = result.files.single.path!;
      final file = File(filePath);
      final fileName = path.basename(filePath);

      // Save PDF to local storage
      final appDir = await getApplicationDocumentsDirectory();
      final pdfDir = Directory('${appDir.path}/pdfs');
      if (!await pdfDir.exists()) await pdfDir.create();
      final localPath = '${pdfDir.path}/$fileName';
      await file.copy(localPath);

      // Show preview and handle send
      await _showPdfPreview(filePath, localPath, fileName);
    } catch (e) {
      _showSnackBar('Error picking PDF: $e');
    }
  }

  Future<void> _showPdfPreview(
    String filePath,
    String localPath,
    String fileName,
  ) async {
    final file = File(filePath);
    final fileSize = await file.length();
    final fileSizeMB = (fileSize / (1024 * 1024)).toStringAsFixed(2);

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (BuildContext context) {
        String caption = '';
        return StatefulBuilder(
          builder: (context, setState) {
            return FractionallySizedBox(
              heightFactor: 0.9,
              child: Container(
                color: Colors.white,
                child: Stack(
                  children: [
                    Padding(
                      padding: EdgeInsets.all(16.0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // Header with close button
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(
                                'Send PDF',
                                style: TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              IconButton(
                                icon: Icon(Icons.close),
                                onPressed: () => Navigator.pop(context),
                              ),
                            ],
                          ),
                          SizedBox(height: 16),
                          // PDF icon and file info
                          Row(
                            children: [
                              Icon(
                                Icons.picture_as_pdf,
                                size: 50,
                                color: Colors.blue,
                              ),
                              SizedBox(width: 16),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      fileName,
                                      style: TextStyle(fontSize: 16),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    Text(
                                      '$fileSizeMB MB',
                                      style: TextStyle(
                                        fontSize: 14,
                                        color: Colors.grey,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                          SizedBox(height: 16),
                          // Caption text field
                          /*Expanded(
                          child: TextField(
                            decoration: InputDecoration(
                              hintText: 'Add a caption...',
                              border: InputBorder.none,
                            ),
                            maxLines: null,
                            onChanged: (value) => caption = value,
                          ),
                        ),*/
                        ],
                      ),
                    ),
                    // Send button
                    Positioned(
                      bottom: 16,
                      right: 16,
                      child: FloatingActionButton(
                        onPressed: () async {
                          Navigator.pop(context);
                          await _uploadAndSendPdf(
                            filePath,
                            localPath,
                            fileName,
                          );
                        },
                        child: Icon(Icons.send),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _uploadAndSendPdf(
    String filePath,
    String localPath,
    String fileName,
  ) async {
    try {
      final tempId = '$_tempIdPrefix${DateTime.now().millisecondsSinceEpoch}';

      // Insert temporary message into local DB
      await _localDb.insertMediaMessage(
        filePath: localPath,
        content: '', // Will be updated with server URL
        type: 'pdf',
        isMe: 1,
        status: 'uploading',
        createdAt: DateTime.now().toIso8601String(),
        tempId: tempId,
      );

      // Add to UI
      setState(() {
        _messages.add({
          '_id': tempId,
          'tempId': tempId,
          'sender_id': widget.userId,
          'sender': {'name': 'You', 'id': widget.userId},
          'group_id': widget.groupId,
          'pdf_url': localPath,
          'type': 'pdf',
          'status': 'uploading',
          'timestamp': DateTime.now().toIso8601String(),
          'read_by': [widget.userId],
          'filename': fileName,
        });
        _sortMessagesByTime();
      });

      _scrollToBottom();

      // Upload PDF
      await _uploadPdf(localPath, tempId);
    } catch (e) {
      _showSnackBar('Error sending PDF: $e');
    }
  }

  Future<void> _uploadPdf(String localPath, String tempId) async {
    try {
      final file = File(localPath);
      if (!await file.exists()) {
        await _updatePdfStatus(
          tempId: tempId,
          status: 'failed',
          error: 'File not found',
        );
        return;
      }

      final bytes = await file.readAsBytes();
      final fileName = path.basename(localPath);
      final mimeType = 'application/pdf';

      final request =
          http.MultipartRequest(
              'POST',
              Uri.parse('${AppConfig.baseUrl}/upload-group-pdf'),
            )
            ..fields['sender_id'] = widget.userId
            ..fields['group_id'] = widget.groupId
            ..fields['temp_id'] = tempId
            ..files.add(
              http.MultipartFile.fromBytes(
                'file',
                bytes,
                filename: fileName,
                contentType: MediaType.parse(mimeType),
              ),
            );

      // Add this to help server create directories
      request.fields['create_dirs'] = 'true';

      final response = await request.send();
      final responseData = await response.stream.bytesToString();
      final jsonResponse = json.decode(responseData);

      if (response.statusCode >= 200 && response.statusCode < 300) {
        await _updatePdfStatus(
          tempId: tempId,
          status: 'success',
          pdfUrl:
              '${AppConfig.baseUrl}/get-group-pdf/${jsonResponse['pdf_id']}',
        );
      } else {
        throw Exception('Upload failed: ${jsonResponse['error']}');
      }
    } catch (e) {
      await _updatePdfStatus(
        tempId: tempId,
        status: 'failed',
        error: e.toString(),
      );
    }
  }

  Future<void> _updatePdfStatus({
    required String tempId,
    required String status,
    String? pdfUrl,
    String? error,
  }) async {
    try {
      await _localDb.updateMessageStatus(
        tempId: tempId,
        status: status,
        content: pdfUrl ?? '',
      );

      final index = _messages.indexWhere((msg) => msg['tempId'] == tempId);
      if (index != -1) {
        setState(() {
          _messages[index] = {
            ..._messages[index],
            'status': status,
            'pdf_url':
                pdfUrl != null
                    ? _getFullUrl(pdfUrl)
                    : _messages[index]['pdf_url'],
            'filePath':
                _messages[index]['filePath'] ?? _messages[index]['pdf_url'],
            'filename': _messages[index]['filename'] ?? 'PDF Document',
          };
        });
      }

      if (status == 'success') {
        _showSnackBar('PDF uploaded successfully');
        // Add delay to ensure server has processed the file
        await Future.delayed(Duration(seconds: 2));
        await _fetchMessages();
      } else {
        final errorMsg =
            error!.contains('No such file or directory')
                ? 'Server storage error. Contact support.'
                : error ?? 'Unknown error';
        _showSnackBar('Upload failed: $errorMsg');
      }
    } catch (e) {
      _showSnackBar('Error updating PDF status: $e');
    }
  }

  Future<void> _retryPdf(String filePath, String messageId) async {
    try {
      final file = File(filePath);
      if (!await file.exists()) {
        _showSnackBar('PDF file no longer exists');
        return;
      }

      setState(() {
        final index = _messages.indexWhere((msg) => msg['_id'] == messageId);
        if (index != -1) {
          _messages[index]['status'] = 'uploading';
        }
      });

      final tempId = '$_retryIdPrefix${DateTime.now().millisecondsSinceEpoch}';

      await _localDb.updateMessage(
        whereColumn: 'filePath',
        whereValue: filePath,
        values: {'status': 'uploading', 'tempId': tempId},
      );

      setState(() {
        final index = _messages.indexWhere((msg) => msg['_id'] == messageId);
        if (index != -1) {
          _messages[index]['_id'] = tempId;
          _messages[index]['tempId'] = tempId;
        }
      });

      await _uploadPdf(filePath, tempId);
    } catch (e) {
      _showSnackBar('Error retrying PDF: $e');
    }
  }

  Future<void> _showImageSourceOptions() async {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder:
          (context) => Container(
            decoration: BoxDecoration(
              color: Colors.black,
              borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
            ),
            child: SafeArea(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Header
                  Padding(
                    padding: EdgeInsets.all(16),
                    child: Text(
                      'Upload media',
                      style: TextStyle(color: Colors.white),
                    ),
                  ),
                  Divider(color: Colors.grey),
                  // Options
                  Padding(
                    padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceAround,
                      children: [
                        _buildMediaOption(
                          icon: Icons.insert_photo,
                          label: 'Gallery',
                          color: Colors.purple,
                          onTap: () => _pickAndSendImage(ImageSource.gallery),
                        ),
                        _buildMediaOption(
                          icon: Icons.camera_alt,
                          label: 'Camera',
                          color: Colors.red,
                          onTap: () => _pickAndSendImage(ImageSource.camera),
                        ),
                        _buildMediaOption(
                          icon: Icons.picture_as_pdf,
                          label: 'Document',
                          color: Colors.blue,
                          onTap: () => _pickAndSendPdf(),
                        ),
                        _buildMediaOption(
                          icon: Icons.videocam,
                          label: 'Video',
                          color: Colors.green,
                          onTap: () => _pickAndSendVideo(ImageSource.gallery),
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

  Widget _buildMediaOption({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    Color? color,
  }) {
    return InkWell(
      onTap: () {
        Navigator.pop(context);
        onTap();
      },
      child: Column(
        children: [
          Icon(icon, color: color ?? Colors.white, size: 30),
          SizedBox(height: 4),
          Text(label, style: TextStyle(color: Colors.white)),
        ],
      ),
    );
  }

  // Socket handling
  void _connectSocket() {
    try {
      _socket = socket_io.io(AppConfig.baseUrl, {
        'transports': ['websocket'],
        'autoConnect': true,
        'forceNew': true,
      });

      _socket
        ..onConnect((_) => _joinGroup())
        ..on('receive_group_message', _handleIncomingMessage)
        ..on('join_confirmation', _handleJoinConfirmation)
        ..on('group_deleted', _handleGroupDeleted)
        ..on('messages_read_group', (data) {
          final messageId = data['message_id'];
          final readerId = data['reader_id'];

          setState(() {
            final index = _messages.indexWhere(
              (msg) => msg['_id'] == messageId,
            );
            if (index != -1) {
              final readBy = List<String>.from(
                _messages[index]['read_by'] ?? [],
              )..add(readerId);
              _messages[index]['read_by'] = readBy;
            }
          });
        })
        ..on('group_updated', (data) {
          print('Received group_updated: $data');
          _fetchGroupDetails(); // Refresh group details
        })
        ..on('group_message_deleted', (data) {
          final deletedMessageId = data['message_id'];
          if (mounted) {
            setState(
              () => _messages.removeWhere(
                (msg) => msg['_id'] == deletedMessageId,
              ),
            );
          }
          _localDb.deleteMessage(deletedMessageId).catchError((e) {});
        })
        ..connect();
    } catch (e) {
      _showSnackBar('Socket connection error: $e');
    }
  }

  void _joinGroup() {
    _socket.emit('join_group', {
      'group_id': widget.groupId,
      'user_id': widget.userId,
    });
  }

  void _handleIncomingMessage(dynamic data) {
    if (!mounted) return;

    final messageId = data['_id']?.toString();
    if (messageId == null) return;

    // Only add new messages from other users, avoid duplicates
    if (!_messages.any((msg) => msg['_id'] == messageId)) {
      setState(() {
        if (data['type'] == 'image') {
          data['image_url'] = _getFullUrl(data['image_url']);
        } else if (data['type'] == 'voice') {
          data['voice_url'] = _getFullUrl(data['voice_url']);
        } else if (data['type'] == 'video') {
          data['video_url'] = _getFullUrl(data['video_url']);
        } else if (data['type'] == 'pdf') {
          data['pdf_url'] = _getFullUrl(data['pdf_url']);
        }
        _messages.add(Map<String, dynamic>.from(data));
        _sortMessagesByTime();
      });
      _scrollToBottom();

      // Mark message as read
      if (data['sender_id'] != widget.userId &&
          !(data['read_by']?.contains(widget.userId) ?? false)) {
        _markMessagesAsRead([messageId]);
      }
    } else {
      final tempId = data['temp_id'];
      if (tempId != null) {
        final index = _messages.indexWhere((msg) => msg['tempId'] == tempId);
        if (index != -1) {
          setState(() {
            _messages[index] = Map<String, dynamic>.from(data);
            if (data['type'] == 'video') {
              _messages[index]['video_url'] = _getFullUrl(data['video_url']);
            }
          });
        }
      }
    }
  }

  void _handleJoinConfirmation(dynamic data) {
    if (data['status'] != 'success') {
      _showSnackBar('Failed to join group: ${data['message']}');
    }
  }

  void _handleGroupDeleted(dynamic data) {
    if (data['group_id'] == widget.groupId) {
      Navigator.of(context).popUntil((route) => route.isFirst);
      _showSnackBar(data['message']);
    }
  }

  // Message handling
  void _sendMessage() {
    final messageText = _messageController.text.trim();
    if (messageText.isEmpty) return;

    try {
      final tempId = '$_tempIdPrefix${DateTime.now().millisecondsSinceEpoch}';

      setState(() {
        _messages.add({
          '_id': tempId,
          'tempId': tempId,
          'sender_id': widget.userId,
          'sender': {'name': 'You', 'id': widget.userId},
          'group_id': widget.groupId,
          'message': messageText,
          'timestamp': DateTime.now().toIso8601String(),
          'read_by': [widget.userId],
          'type': 'text',
          'status': 'sending',
        });
        _sortMessagesByTime();
      });

      _scrollToBottom();
      _messageController.clear();

      _socket.emit('send_group_message', {
        'sender_id': widget.userId,
        'group_id': widget.groupId,
        'message': messageText,
        'type': 'text',
        'tempId': tempId,
      });

      _fetchMessages(); // Refresh messages after sending
    } catch (e) {
      _showSnackBar('Error sending message: $e');
    }
  }

  // Data fetching
  Future<void> _fetchGroupDetails() async {
    try {
      final response = await _httpClient.get(
        Uri.parse('${AppConfig.baseUrl}/group/${widget.groupId}'),
      );
      print(
        'Group details response: ${response.statusCode} - ${response.body}',
      );
      if (response.statusCode == 200) {
        final groupData = json.decode(response.body);
        print('Group profile pic from backend: ${groupData['profile_pic']}');
        setState(() {
          _groupDetails = groupData;
          if (groupData['profile_pic'] != null &&
              groupData['profile_pic'] != _groupProfilePic) {
            _groupProfilePic = groupData['profile_pic'];
          }
          _groupProfilePic = groupData['profile_pic'] ?? _groupProfilePic;
          print('Updated _groupProfilePic: $_groupProfilePic');
        });
        if (_groupDetails?['admins']?.isNotEmpty == true) {
          await _fetchAdminName(_groupDetails!['admins'][0]);
        }
      }
    } catch (e) {
      _showSnackBar('Failed to fetch group details: $e');
    }
  }

  Future<void> _fetchAdminName(String adminId) async {
    try {
      final response = await _httpClient.get(
        Uri.parse('${AppConfig.baseUrl}/user/$adminId'),
      );

      setState(() {
        _adminName =
            response.statusCode == 200
                ? json.decode(response.body)['name']
                : 'Unknown';
      });
    } catch (e) {
      setState(() => _adminName = 'Unknown');
    }
  }

  Future<void> _fetchMessages() async {
    try {
      final response = await _httpClient.get(
        Uri.parse('${AppConfig.baseUrl}/group-messages/${widget.groupId}'),
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final serverMessages = _processServerMessages(data['messages']);
        final localMessages = await _localDb.getMessages();
        final mergedMessages = _mergeMessages(serverMessages, localMessages);

        // Identify messages to mark as read
        final messagesToMarkRead =
            mergedMessages
                .where(
                  (msg) =>
                      msg['sender_id'] != widget.userId &&
                      !(msg['read_by']?.contains(widget.userId) ?? false),
                )
                .map((msg) => msg['_id'].toString())
                .toList();

        setState(() {
          _messages = mergedMessages;
          _isLoading = false;
        });
        _scrollToBottom();

        await _markMessagesAsRead(messagesToMarkRead);
      } else {
        await _loadLocalMessages();
      }
    } catch (e) {
      await _loadLocalMessages();
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  List<Map<String, dynamic>> _processServerMessages(List<dynamic> messages) {
    return messages.map((msg) {
      // Convert msg to Map<String, dynamic>
      final message = Map<String, dynamic>.from(msg as Map);
      if (message['type'] == 'voice' &&
          !message['voice_url'].startsWith('http')) {
        message['voice_url'] = '${AppConfig.baseUrl}${message['voice_url']}';
      }
      if (message['type'] == 'image' &&
          !message['image_url'].startsWith('http')) {
        message['image_url'] = '${AppConfig.baseUrl}${message['image_url']}';
      }
      if (message['type'] == 'video' &&
          !message['video_url'].startsWith('http')) {
        message['video_url'] = '${AppConfig.baseUrl}${message['video_url']}';
      }
      if (message['type'] == 'pdf' && !message['pdf_url'].startsWith('http')) {
        message['pdf_url'] = '${AppConfig.baseUrl}${message['pdf_url']}';
      }
      if (message['type'] == 'text' && message['content'] != null) {
        message['message'] = message['content'];
      }
      message['type'] = message['type'] ?? 'text';
      // Ensure sender is a Map<String, dynamic>
      message['sender'] =
          message['sender'] is Map
              ? Map<String, dynamic>.from(message['sender'] as Map)
              : {'name': 'Unknown', 'id': ''};
      return message;
    }).toList();
  }

  List<Map<String, dynamic>> _mergeMessages(
    List<Map<String, dynamic>> serverMessages,
    List<Map<String, dynamic>> localMessages,
  ) {
    final mergedMessages = <Map<String, dynamic>>[];

    for (final serverMsg in serverMessages) {
      final localMatch = localMessages.firstWhere(
        (localMsg) =>
            localMsg['tempId'] == serverMsg['tempId'] ||
            localMsg['content'] == serverMsg['voice_url'] ||
            localMsg['content'] == serverMsg['image_url'] ||
            localMsg['content'] == serverMsg['video_url'] ||
            localMsg['content'] == serverMsg['pdf_url'],
        orElse: () => <String, dynamic>{},
      );

      if (localMatch.isNotEmpty) {
        mergedMessages.add({
          ...serverMsg,
          'status': localMatch['status'],
          'filePath': localMatch['filePath'],
        });
      } else {
        mergedMessages.add(serverMsg);
      }
    }

    for (final localMsg in localMessages) {
      if (localMsg['status'] == 'uploading' || localMsg['status'] == 'failed') {
        final existsInServer = serverMessages.any(
          (serverMsg) => serverMsg['tempId'] == localMsg['tempId'],
        );
        if (!existsInServer) {
          mergedMessages.add({
            '_id': localMsg['tempId'],
            'sender_id': widget.userId,
            'sender': {'name': 'You', 'id': widget.userId},
            'group_id': widget.groupId,
            'voice_url':
                localMsg['type'] == 'voice' ? localMsg['filePath'] : null,
            'image_url':
                localMsg['type'] == 'image' ? localMsg['filePath'] : null,
            'video_url':
                localMsg['type'] == 'video' ? localMsg['filePath'] : null,
            'pdf_url': localMsg['type'] == 'pdf' ? localMsg['filePath'] : null,
            'message': localMsg['type'] == 'text' ? localMsg['content'] : null,
            'timestamp': localMsg['createdAt'],
            'read_by': [widget.userId],
            'type': localMsg['type'],
            'status': localMsg['status'],
            'tempId': localMsg['tempId'],
            'filename': localMsg['filename'], // Ensure filename is included
          });
        }
      }
    }

    return mergedMessages;
  }

  Future<void> _loadLocalMessages() async {
    final localMessages = await _localDb.getMessages();
    final videoMessages =
        localMessages.where((msg) => msg['type'] == 'video').toList();

    setState(() {
      _messages =
          localMessages
              .map(
                (msg) => {
                  '_id': msg['tempId'],
                  'sender_id': widget.userId,
                  'sender': {'name': 'You', 'id': widget.userId},
                  'group_id': widget.groupId,
                  'voice_url': msg['type'] == 'voice' ? msg['filePath'] : null,
                  'image_url': msg['type'] == 'image' ? msg['filePath'] : null,
                  'video_url': msg['type'] == 'video' ? msg['filePath'] : null,
                  'pdf_url': msg['type'] == 'pdf' ? msg['filePath'] : null,
                  'message': msg['type'] == 'text' ? msg['content'] : null,
                  'timestamp': msg['createdAt'],
                  'read_by': [widget.userId],
                  'type': msg['type'],
                  'status': msg['status'],
                  'tempId': msg['tempId'],
                },
              )
              .toList();
    });
  }

  // UI helpers
  String _getFullUrl(String url) {
    return url.startsWith('http')
        ? url
        : '${AppConfig.baseUrl}/${url.startsWith('/') ? url.substring(1) : url}';
  }

  void _scrollToBottom() {
    Future.delayed(const Duration(milliseconds: 100), () {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _showSnackBar(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  // UI components
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: backgroundColor,
      appBar: _buildAppBar(),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child:
                  _isLoading
                      ? const Center(child: CircularProgressIndicator())
                      : Builder(
                        builder: (context) {
                          try {
                            return ListView.builder(
                              controller: _scrollController,
                              padding: const EdgeInsets.all(8.0),
                              reverse: false,
                              itemCount: _messages.length + 1,
                              itemBuilder: (context, index) {
                                if (index == 0) return _buildChatHeader();
                                final message = _messages[index - 1];
                                final isMe =
                                    message['sender_id'] == widget.userId;
                                return KeyedSubtree(
                                  key: ValueKey(
                                    message['tempId'] ??
                                        message['_id'] ??
                                        UniqueKey().toString(),
                                  ),
                                  child: _buildMessageBubble(message, isMe),
                                );
                              },
                            );
                          } catch (e) {
                            print('Error in ListView.builder: $e');
                            return const Center(
                              child: Text(
                                'Error displaying messages. Please try again.',
                                style: TextStyle(color: Colors.white),
                              ),
                            );
                          }
                        },
                      ),
            ),
            _buildMessageInput(),
          ],
        ),
      ),
    );
  }

  AppBar _buildAppBar() {
    return AppBar(
      backgroundColor: backgroundColor,
      leading: IconButton(
        icon: const Icon(Icons.arrow_back, color: Colors.white),
        onPressed: () => Navigator.pop(context),
      ),
      title: GestureDetector(
        onTap: _navigateToGroupInfo,
        child: Row(
          children: [
            CircleAvatar(radius: 20, backgroundImage: _getGroupProfileImage()),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                widget.groupName,
                style: const TextStyle(color: Colors.white, fontSize: 18),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
      actions: [
        IconButton(
          icon: const Icon(Icons.info_outline, color: Colors.white),
          onPressed: _navigateToGroupInfo,
        ),
      ],
    );
  }

  ImageProvider _getGroupProfileImage() {
    return widget.initialGroupProfilePic != "default"
        ? NetworkImage(widget.initialGroupProfilePic)
        : const AssetImage('assets/users.png') as ImageProvider;
  }

  Future<void> _navigateToGroupInfo() async {
    if (_groupDetails == null) return;
    final result = await Navigator.push(
      context,
      MaterialPageRoute(
        builder:
            (context) => GroupInfoScreen(
              groupId: widget.groupId,
              userId: widget.userId,
              groupDetails: _groupDetails!,
            ),
      ),
    );
    print('Result from GroupInfoScreen: $result');
    if (result is Map<String, dynamic> && result['refresh'] == true) {
      setState(() {
        _groupProfilePic = result['profile_pic'] ?? _groupProfilePic;
        print(
          'Updated _groupProfilePic from GroupInfoScreen: $_groupProfilePic',
        );
      });
      await _fetchGroupDetails();
    }
  }

  Widget _buildChatHeader() {
    if (_groupDetails == null || _adminName == null) {
      return const SizedBox.shrink();
    }

    final createdAt = DateTime.parse(_groupDetails!['created_at']).toLocal();
    final formattedDate = DateFormat('MMM d, yyyy').format(createdAt);
    final isAdmin = _groupDetails!['admins'].contains(widget.userId);
    final adminDisplayName = isAdmin ? 'You' : _adminName;

    return Container(
      padding: const EdgeInsets.all(16.0),
      color: backgroundColor,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          CircleAvatar(radius: 40, backgroundImage: _getGroupProfileImage()),
          const SizedBox(height: 12),
          Text(
            widget.groupName,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 20,
              fontWeight: FontWeight.bold,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          Text(
            'Admin: $adminDisplayName',
            style: TextStyle(color: Colors.grey[400], fontSize: 16),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          Text(
            _groupDetails!['description'] ?? 'No description provided',
            style: TextStyle(
              color: Colors.grey[400],
              fontSize: 14,
              fontStyle: FontStyle.italic,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          Text(
            'Created on: $formattedDate',
            style: TextStyle(color: Colors.grey[400], fontSize: 14),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          Divider(color: Colors.grey[600]),
        ],
      ),
    );
  }

  Widget _buildMessageBubble(Map<String, dynamic> message, bool isMe) {
    print('Building message bubble: $message');
    final sender =
        message['sender'] is Map
            ? Map<String, dynamic>.from(message['sender'] as Map)
            : <String, dynamic>{'name': 'Unknown', 'id': ''};
    final readBy = List<String>.from(message['read_by'] ?? []);
    final type = message['type'] ?? 'text';
    final isImage = type == 'image';
    final isVoice = type == 'voice';
    final isVideo = type == 'video';
    final isPdf = type == 'pdf';
    final imageUrl = message['image_url'];
    final voiceUrl = message['voice_url'];
    final videoUrl = message['video_url'];
    final pdfUrl = message['pdf_url'];
    final status = message['status'] ?? 'success';
    final fileName = message['filename'];

    return GestureDetector(
      onLongPress: () => _showDeleteOptions(message, isMe),
      child: Align(
        alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 4.0, horizontal: 8.0),
          padding: const EdgeInsets.all(10.0),
          decoration: BoxDecoration(
            color: isMe ? Colors.green[300] : Colors.grey[300],
            borderRadius: BorderRadius.circular(12.0),
          ),
          child: Column(
            crossAxisAlignment:
                isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
            children: [
              if (!isMe)
                Text(
                  sender['name']?.toString() ?? 'Unknown',
                  style: const TextStyle(
                    fontSize: 12.0,
                    color: Colors.black54,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              const SizedBox(height: 4.0),
              if (isVoice)
                Row(
                  children: [
                    Icon(
                      Icons.audiotrack,
                      color: isMe ? Colors.white : Colors.black,
                    ),
                    const SizedBox(width: 8),
                    if (status == 'uploading')
                      const CircularProgressIndicator()
                    else
                      Text(
                        status == 'failed' ? 'Failed to send' : 'Voice message',
                        style: TextStyle(
                          color: isMe ? Colors.white : Colors.black,
                        ),
                      ),
                    const SizedBox(width: 12),
                    if (status != 'uploading')
                      IconButton(
                        icon: Icon(
                          _currentlyPlayingUrl == voiceUrl && _isPlaying
                              ? Icons.stop
                              : Icons.play_arrow,
                          color: isMe ? Colors.white : Colors.black,
                        ),
                        onPressed:
                            status == 'failed'
                                ? null
                                : () => _playVoiceMessage(voiceUrl),
                      ),
                    if (status == 'failed' && isMe)
                      IconButton(
                        icon: const Icon(Icons.refresh, color: Colors.white),
                        onPressed:
                            () => _retryVoiceMessage(voiceUrl, message['_id']),
                      ),
                  ],
                )
              else if (isImage)
                Column(
                  children: [
                    if (status == 'uploading')
                      const CircularProgressIndicator()
                    else if (status == 'failed')
                      Column(
                        children: [
                          const Icon(Icons.error, color: Colors.red, size: 50),
                          const Text('Failed to load image'),
                          if (isMe)
                            IconButton(
                              icon: const Icon(
                                Icons.refresh,
                                color: Colors.white,
                              ),
                              onPressed:
                                  () => _retryImage(imageUrl, message['_id']),
                            ),
                        ],
                      )
                    else
                      Container(
                        constraints: const BoxConstraints(
                          maxWidth: 200,
                          maxHeight: 200,
                        ),
                        child: _buildImageWidget(imageUrl),
                      ),
                  ],
                )
              else if (isVideo)
                Column(
                  children: [
                    if (status == 'uploading')
                      const CircularProgressIndicator()
                    else if (status == 'failed')
                      Column(
                        children: [
                          const Icon(Icons.error, color: Colors.red, size: 50),
                          const Text('Failed to load video'),
                          if (isMe)
                            IconButton(
                              icon: const Icon(
                                Icons.refresh,
                                color: Colors.white,
                              ),
                              onPressed:
                                  () => _retryVideo(
                                    message['video_url'],
                                    message['_id'],
                                  ),
                            ),
                        ],
                      )
                    else
                      GestureDetector(
                        onTap: () => _playVideo(message['video_url']),
                        child: Container(
                          width: 200,
                          height: 100,
                          decoration: BoxDecoration(
                            color: Colors.black,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Stack(
                            alignment: Alignment.center,
                            children: [
                              if (status == 'success')
                                FutureBuilder(
                                  future: _getVideoThumbnail(
                                    message['video_url'],
                                  ),
                                  builder: (context, snapshot) {
                                    if (snapshot.hasData) {
                                      return Image.memory(snapshot.data!);
                                    }
                                    return const CircularProgressIndicator();
                                  },
                                ),
                              const Icon(
                                Icons.play_circle_outline,
                                color: Colors.white,
                                size: 50,
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                )
              else if (isPdf)
                _buildPdfWidget(message, isMe)
              else
                Text(
                  message['message'] ?? '',
                  style: TextStyle(
                    fontSize: 16.0,
                    color: isMe ? Colors.white : Colors.black,
                  ),
                ),
              const SizedBox(height: 4.0),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    DateFormat('hh:mm a').format(
                      DateTime.parse(
                        message['timestamp'] ??
                            DateTime.now().toIso8601String(),
                      ).toLocal(),
                    ),
                    style: TextStyle(
                      fontSize: 10.0,
                      color: isMe ? Colors.white70 : Colors.black54,
                    ),
                  ),
                  const SizedBox(width: 4),
                  if (isMe)
                    Icon(
                      readBy.length > 1 ? Icons.done_all : Icons.done,
                      size: 14,
                      color: readBy.length > 1 ? Colors.blue : Colors.grey,
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showDeleteOptions(
    Map<String, dynamic> message,
    bool isMyMessage,
  ) async {
    final action = await showModalBottomSheet<DeleteGroupAction>(
      context: context,
      builder:
          (context) => DeleteGroupMessageSheet(
            isMyMessage: isMyMessage,
            isAdmin: _groupDetails?['admins']?.contains(widget.userId) ?? false,
            isOnline: true, // Replace with actual connectivity status if needed
          ),
    );

    if (action == null) return;

    switch (action) {
      case DeleteGroupAction.deleteForEveryone:
        _deleteMessageForEveryone(message);
        break;
      case DeleteGroupAction.deleteForMe:
        _deleteMessageForMe(message);
        break;
      case DeleteGroupAction.cancel:
        // Do nothing
        break;
    }
  }

  Future<void> _deleteMessageForEveryone(Map<String, dynamic> message) async {
    try {
      // Optimistically remove from UI
      setState(() => _messages.removeWhere((m) => m['_id'] == message['_id']));

      // Remove from local DB
      await _localDb.deleteMessage(message['_id']);

      // Send socket event to server
      _socket.emit('delete_group_message', {
        'message_id': message['_id'],
        'group_id': widget.groupId,
        'user_id': widget.userId,
        'delete_for_everyone': true,
      });

      // Delete associated files
      _deleteMessageFiles(message);
    } catch (e) {
      _showSnackBar('Failed to delete message: $e');
      // Re-add message if deletion fails
      setState(() => _messages.add(message));
    }
  }

  Future<void> _deleteMessageForMe(Map<String, dynamic> message) async {
    try {
      setState(() => _messages.removeWhere((m) => m['_id'] == message['_id']));
      await _localDb.deleteMessage(message['_id']);
      _deleteMessageFiles(message);
    } catch (e) {
      _showSnackBar('Failed to delete message: $e');
      setState(() => _messages.add(message));
    }
  }

  void _deleteMessageFiles(Map<String, dynamic> message) {
    final type = message['type'];
    final content = message['${type}_url'] ?? message['filePath'];

    if (content != null && content.startsWith('/')) {
      try {
        final file = File(content);
        if (file.existsSync()) file.delete();
      } catch (e) {
        print('Error deleting file: $e');
      }
    }
  }

  Widget _buildImageWidget(String? imageUrl) {
    if (imageUrl == null || imageUrl.isEmpty) {
      return const Icon(Icons.broken_image, color: Colors.red, size: 50);
    }

    // Check if it's a local file path
    if (!imageUrl.startsWith('http')) {
      final file = File(imageUrl);
      return FutureBuilder<bool>(
        future: file.exists(),
        builder: (context, snapshot) {
          if (snapshot.data == true) {
            return Image.file(
              file,
              fit: BoxFit.cover,
              errorBuilder: (context, error, stackTrace) {
                return const Icon(
                  Icons.broken_image,
                  color: Colors.red,
                  size: 50,
                );
              },
            );
          } else {
            return const Icon(Icons.file_present, color: Colors.grey, size: 50);
          }
        },
      );
    }

    // Network image
    return Image.network(
      imageUrl,
      fit: BoxFit.cover,
      loadingBuilder: (context, child, loadingProgress) {
        if (loadingProgress == null) return child;
        return const CircularProgressIndicator();
      },
      errorBuilder: (context, error, stackTrace) {
        return const Icon(Icons.broken_image, color: Colors.red, size: 50);
      },
    );
  }

  Future<Uint8List> _getVideoThumbnail(String videoUrl) async {
    final fileName = await VideoThumbnail.thumbnailFile(
      video: videoUrl,
      thumbnailPath: (await getTemporaryDirectory()).path,
      imageFormat: ImageFormat.JPEG,
      maxHeight: 100,
      quality: 75,
    );

    final file = File(fileName!);
    return file.readAsBytesSync();
  }

  Future<void> _playVoiceMessage(String url) async {
    try {
      if (_isPlaying) {
        await _player.stopPlayer();
        setState(() {
          _isPlaying = false;
          _currentlyPlayingUrl = null;
        });
        return;
      }

      await _player.startPlayer(
        fromURI: url,
        codec: Codec.aacADTS,
        whenFinished: () {
          if (mounted) {
            setState(() {
              _isPlaying = false;
              _currentlyPlayingUrl = null;
            });
          }
        },
      );

      setState(() {
        _isPlaying = true;
        _currentlyPlayingUrl = url;
      });
    } catch (e) {
      _showSnackBar('Failed to play voice message: $e');
    }
  }

  Future<void> _viewPdf(String? pdfUrl, String? localPath) async {
    if (pdfUrl == null && localPath == null) {
      _showSnackBar('Invalid PDF URL or path');
      return;
    }

    final effectiveUrl =
        localPath != null && File(localPath).existsSync() ? localPath : pdfUrl;

    if (effectiveUrl == null) {
      _showSnackBar('PDF not available');
      return;
    }

    print(
      'Navigating to PdfViewerScreen with URL: $effectiveUrl',
    ); // Add logging
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder:
            (context) => PdfViewerScreen(
              pdfUrl: effectiveUrl.startsWith('http') ? effectiveUrl : null,
              localPdfPath:
                  effectiveUrl.startsWith('http') ? null : effectiveUrl,
            ),
      ),
    );
  }

  Widget _buildMessageInput() {
    return Column(
      children: [
        if (_typingUser != null)
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: Text(
              '$_typingUser is typing...',
              style: TextStyle(color: Colors.white54, fontSize: 12),
            ),
          ),
        // Recording indicator
        if (_isRecording)
          Container(
            padding: EdgeInsets.symmetric(vertical: 8),
            color: Colors.red.withOpacity(0.1),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.mic, color: Colors.red),
                SizedBox(width: 8),
                Text("Recording...", style: TextStyle(color: Colors.red)),
                SizedBox(width: 16),
                Text(
                  '${_recordingDuration.inSeconds}s',
                  style: TextStyle(color: Colors.red),
                ),
              ],
            ),
          ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 10.0),
          color: backgroundColor,
          child: Row(
            children: [
              IconButton(
                icon: Icon(Icons.add_box_outlined, color: Colors.grey),
                onPressed: _showImageSourceOptions,
              ),
              Expanded(
                child: Container(
                  padding: EdgeInsets.symmetric(horizontal: 12),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(24),
                  ),
                  child: Row(
                    children: [
                      // Emoji button
                      IconButton(
                        icon: Icon(
                          _isEmojiVisible
                              ? Icons.keyboard
                              : Icons.emoji_emotions_outlined,
                          color: Colors.grey,
                        ),
                        onPressed: _toggleEmojiKeyboard,
                      ),

                      // Text field
                      Expanded(
                        child: TextField(
                          controller: _messageController,
                          focusNode: _focusNode,
                          decoration: InputDecoration(
                            hintText: 'Type a message...',
                            border: InputBorder.none,
                          ),
                        ),
                      ),

                      // Microphone button
                      IconButton(
                        icon: Icon(
                          _isRecording ? Icons.stop : Icons.mic,
                          color: _isRecording ? Colors.red : Colors.grey,
                        ),
                        onPressed:
                            _isRecording ? _stopRecording : _startRecording,
                      ),
                    ],
                  ),
                ),
              ),

              // Send button
              IconButton(
                icon: const Icon(Icons.send, color: Colors.green),
                onPressed: _sendMessage,
              ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _pickAndSendVideo(ImageSource source) async {
    try {
      final XFile? video = await _picker.pickVideo(source: source);
      if (video == null) return;

      final filePath = video.path;
      final extension = path.extension(filePath).toLowerCase();

      // Validate video format
      if (extension != '.mp4' && extension != '.mov') {
        _showSnackBar('Only MP4 and MOV are supported');
        return;
      }

      // Generate temporary ID
      final tempId = '$_tempIdPrefix${DateTime.now().millisecondsSinceEpoch}';

      // Store in local DB
      await _localDb.insertMediaMessage(
        filePath: filePath,
        content: filePath, // Store local path initially
        type: 'video',
        isMe: 1,
        status: 'uploading',
        createdAt: DateTime.now().toIso8601String(),
        tempId: tempId,
      );

      // Add to UI immediately
      setState(() {
        _messages.add({
          '_id': tempId,
          'tempId': tempId,
          'sender_id': widget.userId,
          'sender': {'name': 'You', 'id': widget.userId},
          'group_id': widget.groupId,
          'video_url': filePath, // Local file path
          'type': 'video',
          'status': 'uploading',
          'timestamp': DateTime.now().toIso8601String(),
          'read_by': [widget.userId],
        });
        _sortMessagesByTime();
      });

      _scrollToBottom();

      // Start upload process
      await _uploadVideo(filePath, tempId);
    } catch (e) {
      _showSnackBar('Error picking video: $e');
    }
  }

  Future<void> _uploadVideo(String filePath, String tempId) async {
    try {
      final file = File(filePath);
      if (!await file.exists()) {
        await _updateVideoStatus(
          tempId: tempId,
          status: 'failed',
          error: 'File not found',
        );
        return;
      }

      final bytes = await file.readAsBytes();
      final fileName = path.basename(filePath);
      final mimeType = lookupMimeType(filePath) ?? 'video/mp4';

      final request =
          http.MultipartRequest(
              'POST',
              Uri.parse('${AppConfig.baseUrl}/upload-group-video'),
            )
            ..fields['sender_id'] = widget.userId
            ..fields['group_id'] = widget.groupId
            ..fields['temp_id'] = tempId
            ..files.add(
              http.MultipartFile.fromBytes(
                'file',
                bytes,
                filename: fileName,
                contentType: MediaType.parse(mimeType),
              ),
            );

      final response = await request.send();
      final responseData = await response.stream.bytesToString();
      final jsonResponse = json.decode(responseData);

      if (response.statusCode >= 200 && response.statusCode < 300) {
        await _updateVideoStatus(
          tempId: tempId,
          status: 'success',
          videoUrl: jsonResponse['video_url'],
        );
        await _fetchMessages(); // Refresh messages from server
      } else {
        throw Exception('Upload failed: ${jsonResponse['error']}');
      }
    } catch (e) {
      await _updateVideoStatus(
        tempId: tempId,
        status: 'failed',
        error: e.toString(),
      );
    }
  }

  Future<void> _updateVideoStatus({
    required String tempId,
    required String status,
    String? videoUrl,
    String? error,
  }) async {
    try {
      // Update local database
      await _localDb.updateMessageStatus(
        tempId: tempId,
        status: status,
        content: videoUrl, // Update with server URL on success
      );

      // Update UI without full refresh
      final index = _messages.indexWhere((msg) => msg['tempId'] == tempId);
      if (index != -1) {
        setState(() {
          _messages[index] = {
            ..._messages[index],
            'status': status,
            if (videoUrl != null) 'video_url': _getFullUrl(videoUrl),
          };
        });
      }

      if (status == 'success') {
        _showSnackBar('Video uploaded successfully');
      } else {
        _showSnackBar('Upload failed: ${error ?? 'Unknown error'}');
      }
    } catch (e) {
      _showSnackBar('Error updating video status: $e');
    }
  }

  Future<void> _retryVideo(String filePath, String messageId) async {
    try {
      final file = File(filePath);
      if (!await file.exists()) {
        _showSnackBar('Video file no longer exists');
        return;
      }

      setState(() {
        final index = _messages.indexWhere((msg) => msg['_id'] == messageId);
        if (index != -1) {
          _messages[index]['status'] = 'uploading';
        }
      });

      final tempId = '$_retryIdPrefix${DateTime.now().millisecondsSinceEpoch}';

      // Update local DB with new temp ID
      await _localDb.updateMessage(
        whereColumn: 'content',
        whereValue: filePath,
        values: {'status': 'uploading', 'tempId': tempId},
      );

      // Update UI
      setState(() {
        final index = _messages.indexWhere((msg) => msg['_id'] == messageId);
        if (index != -1) {
          _messages[index]['_id'] = tempId;
          _messages[index]['tempId'] = tempId;
        }
      });

      // Retry upload
      await _uploadVideo(filePath, tempId);
    } catch (e) {
      _showSnackBar('Error retrying video: $e');
    }
  }

  Future<void> _playVideo(String? videoUrl) async {
    if (videoUrl == null || videoUrl.isEmpty) {
      _showSnackBar('Invalid video URL');
      return;
    }
    print('Attempting to play video from: $videoUrl');
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => VideoPlayerScreen(videoUrl: videoUrl),
      ),
    );
  }

  Future<void> _markMessagesAsRead(List<String> messageIds) async {
    try {
      final response = await _httpClient.post(
        Uri.parse(
          '${AppConfig.baseUrl}/mark-group-messages-read/${widget.groupId}/${widget.userId}',
        ),
      );

      if (response.statusCode == 200) {
        setState(() {
          for (var msg in _messages) {
            if (msg['sender_id'] != widget.userId &&
                !(msg['read_by']?.contains(widget.userId) ?? false)) {
              final readBy = List<String>.from(msg['read_by'] ?? [])
                ..add(widget.userId);
              msg['read_by'] = readBy;
            }
          }
        });
      } else {
        _showSnackBar('Failed to mark messages as read');
      }
    } catch (e) {
      _showSnackBar('Error marking messages as read: $e');
    }
  }

  Widget _buildPdfWidget(Map<String, dynamic> message, bool isMe) {
    final pdfUrl = message['pdf_url'] as String?;
    final status = message['status'] ?? 'success';
    final fileName = message['filename'] as String? ?? 'PDF Document';
    final filePath = message['filePath'] as String?;

    if (status == 'uploading') {
      return const CircularProgressIndicator();
    } else if (status == 'failed') {
      return Column(
        children: [
          const Icon(Icons.error, color: Colors.red, size: 50),
          const Text('Failed to load PDF'),
          if (isMe)
            IconButton(
              icon: const Icon(Icons.refresh, color: Colors.white),
              onPressed:
                  () => _retryPdf(filePath ?? pdfUrl ?? '', message['_id']),
            ),
        ],
      );
    } else {
      return GestureDetector(
        onTap: () => _viewPdf(pdfUrl, filePath),
        child: Container(
          padding: const EdgeInsets.all(8.0),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.picture_as_pdf,
                color: isMe ? Colors.white : Colors.black,
                size: 30,
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  fileName,
                  style: TextStyle(
                    color: isMe ? Colors.white : Colors.black,
                    fontSize: 16,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      );
    }
  }

  void methodnotimplemented() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Feature not implemented yet!')),
    );
  }
}

enum DeleteGroupAction { deleteForEveryone, deleteForMe, cancel }

class DeleteGroupMessageSheet extends StatelessWidget {
  final bool isMyMessage;
  final bool isAdmin;
  final bool isOnline;

  const DeleteGroupMessageSheet({
    super.key,
    required this.isMyMessage,
    this.isAdmin = false,
    this.isOnline = true,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (isMyMessage || isAdmin)
              _DeleteOptionTile(
                icon: Icons.delete_outline,
                text: 'Delete for everyone',
                color: Colors.red,
                onTap:
                    () => Navigator.pop(
                      context,
                      DeleteGroupAction.deleteForEveryone,
                    ),
                enabled: isOnline,
              ),
            _DeleteOptionTile(
              icon: Icons.delete,
              text: 'Delete for me',
              color: Colors.red,
              onTap:
                  () => Navigator.pop(context, DeleteGroupAction.deleteForMe),
            ),
            const Divider(height: 1),
            _DeleteOptionTile(
              icon: Icons.close,
              text: 'Cancel',
              onTap: () => Navigator.pop(context, DeleteGroupAction.cancel),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}

class _DeleteOptionTile extends StatelessWidget {
  final IconData icon;
  final String text;
  final Color? color;
  final VoidCallback onTap;
  final bool enabled;

  const _DeleteOptionTile({
    required this.icon,
    required this.text,
    this.color,
    required this.onTap,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon, color: enabled ? color : Colors.grey),
      title: Text(
        text,
        style: TextStyle(
          color: enabled ? color : Colors.grey,
          fontWeight: FontWeight.w500,
        ),
      ),
      onTap: enabled ? onTap : null,
    );
  }
}

// Video Player Screen
class VideoPlayerScreen extends StatefulWidget {
  final String videoUrl;

  const VideoPlayerScreen({super.key, required this.videoUrl});

  @override
  State<VideoPlayerScreen> createState() => _VideoPlayerScreenState();
}

class _VideoPlayerScreenState extends State<VideoPlayerScreen> {
  late VideoPlayerController _controller;
  Future<void>? _initializeVideoPlayerFuture;
  bool _isPlaying = false;
  bool _hasError = false;

  @override
  void initState() {
    super.initState();
    _initializeController();
  }

  void _initializeController() {
    _controller = VideoPlayerController.networkUrl(
      Uri.parse(widget.videoUrl),
      videoPlayerOptions: VideoPlayerOptions(
        allowBackgroundPlayback: false,
        mixWithOthers: true,
      ),
    );

    _initializeVideoPlayerFuture = _controller
        .initialize()
        .then((_) {
          if (mounted) {
            setState(() {
              _controller.addListener(_videoListener);
              _controller.setLooping(false);
            });
          }
        })
        .catchError((error) {
          if (mounted) {
            setState(() => _hasError = true);
          }
        });
  }

  void _videoListener() {
    if (mounted) {
      setState(() => _isPlaying = _controller.value.isPlaying);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.black,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: Center(
        child:
            _hasError
                ? _buildErrorWidget()
                : FutureBuilder(
                  future: _initializeVideoPlayerFuture,
                  builder: (context, snapshot) {
                    if (snapshot.connectionState == ConnectionState.done) {
                      return AspectRatio(
                        aspectRatio: _controller.value.aspectRatio,
                        child: VideoPlayer(_controller),
                      );
                    }
                    return const CircularProgressIndicator();
                  },
                ),
      ),
      floatingActionButton:
          _hasError
              ? null
              : FloatingActionButton(
                onPressed: _togglePlayPause,
                child: Icon(_isPlaying ? Icons.pause : Icons.play_arrow),
              ),
    );
  }

  Widget _buildErrorWidget() {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Icon(Icons.error_outline, color: Colors.red, size: 50),
        const SizedBox(height: 20),
        const Text(
          'Failed to load video',
          style: TextStyle(color: Colors.white),
        ),
        const SizedBox(height: 20),
        ElevatedButton(onPressed: _retryVideo, child: const Text('Retry')),
      ],
    );
  }

  void _togglePlayPause() {
    setState(() {
      if (_controller.value.isPlaying) {
        _controller.pause();
      } else {
        _controller.play();
      }
      _isPlaying = _controller.value.isPlaying;
    });
  }

  void _retryVideo() {
    setState(() {
      _hasError = false;
      _controller.dispose();
      _initializeController();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }
}

// PDF Viewer Screen
class PdfViewerScreen extends StatefulWidget {
  final String? pdfUrl;
  final String? localPdfPath;

  const PdfViewerScreen({super.key, this.pdfUrl, this.localPdfPath});

  @override
  State<PdfViewerScreen> createState() => _PdfViewerScreenState();
}

class _PdfViewerScreenState extends State<PdfViewerScreen> {
  late PdfViewerController _pdfController;
  bool _isLoading = true;
  bool _hasError = false;
  String? _effectiveLocalPdfPath;

  @override
  void initState() {
    super.initState();
    _pdfController = PdfViewerController();
    _effectiveLocalPdfPath = widget.localPdfPath;
    _loadPdf();
  }

  Future<void> _loadPdf() async {
    try {
      if (_effectiveLocalPdfPath != null &&
          File(_effectiveLocalPdfPath!).existsSync()) {
        setState(() => _isLoading = false);
      } else if (widget.pdfUrl != null) {
        // Verify URL accessibility
        final headResponse = await http.head(Uri.parse(widget.pdfUrl!));
        if (headResponse.statusCode != 200) {
          throw Exception('PDF URL inaccessible: ${headResponse.statusCode}');
        }

        final response = await http.get(Uri.parse(widget.pdfUrl!));
        if (response.statusCode == 200) {
          final appDir = await getApplicationDocumentsDirectory();
          final pdfDir = Directory('${appDir.path}/pdfs');
          if (!await pdfDir.exists()) await pdfDir.create(recursive: true);
          final fileName = path.basename(widget.pdfUrl!);
          final localPath = '${pdfDir.path}/$fileName';
          await File(localPath).writeAsBytes(response.bodyBytes);
          setState(() {
            _effectiveLocalPdfPath = localPath;
            _isLoading = false;
          });
        } else {
          throw Exception('Failed to download PDF: ${response.statusCode}');
        }
      } else {
        throw Exception('No valid PDF source');
      }
    } catch (e) {
      print('Error loading PDF: $e');
      setState(() {
        _hasError = true;
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.black,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: () => Navigator.pop(context),
        ),
        title: const Text('PDF Viewer', style: TextStyle(color: Colors.white)),
      ),
      body: _buildPdfView(),
    );
  }

  Widget _buildPdfView() {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_hasError) {
      return const Center(
        child: Text(
          'Failed to load PDF',
          style: TextStyle(color: Colors.white),
        ),
      );
    }

    return SfPdfViewer.file(
      File(_effectiveLocalPdfPath!),
      controller: _pdfController,
      onDocumentLoaded: (details) {
        print("PDF loaded successfully");
      },
      onDocumentLoadFailed: (details) {
        setState(() => _hasError = true);
      },
    );
  }

  @override
  void dispose() {
    _pdfController.dispose();
    if (_effectiveLocalPdfPath != null && widget.localPdfPath == null) {
      File(_effectiveLocalPdfPath!).delete().catchError((e) {
        print('Error deleting cached PDF: $e');
      });
    }
    super.dispose();
  }
}
