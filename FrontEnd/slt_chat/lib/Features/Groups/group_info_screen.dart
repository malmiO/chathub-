import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:intl/intl.dart';
import 'package:image_picker/image_picker.dart';
import '/common/widgets/colors.dart';
import '/config/config.dart';

class GroupInfoScreen extends StatefulWidget {
  final String groupId;
  final String userId;
  final Map<String, dynamic> groupDetails;

  const GroupInfoScreen({
    super.key,
    required this.groupId,
    required this.userId,
    required this.groupDetails,
  });

  @override
  _GroupInfoScreenState createState() => _GroupInfoScreenState();
}

class _GroupInfoScreenState extends State<GroupInfoScreen> {
  late Map<String, dynamic> _groupDetails;
  List<Map<String, dynamic>> _members = [];
  List<Map<String, dynamic>> _mediaItems = [];
  bool _isLoading = true;
  bool _isEditingName = false;
  bool _isEditingDescription = false;
  bool _isMuted = false;
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _descriptionController = TextEditingController();
  final String baseUrl = AppConfig.baseUrl;
  List<Map<String, dynamic>> _connections = [];
  List<String> _selectedConnections = [];
  late IOClient httpClient;

  Map<String, int> _mediaCounts = {
    'images': 0,
    'videos': 0,
    'pdfs': 0,
    'voice': 0,
  };

  @override
  void initState() {
    super.initState();
    final HttpClient client =
        HttpClient()
          ..badCertificateCallback =
              (X509Certificate cert, String host, int port) => true;
    httpClient = IOClient(client);

    _groupDetails = widget.groupDetails;
    _nameController.text = _groupDetails['name'] ?? 'Unnamed Group';
    _descriptionController.text =
        _groupDetails['description'] ?? 'No description provided';
    _fetchMembers();
    _fetchMedia();
    _fetchMediaCounts();
    _fetchMuteStatus();
  }

  @override
  void dispose() {
    httpClient.close();
    _nameController.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  void _openMediaViewer(Map<String, dynamic> media) {
    // Implement full-screen viewer based on media type
    if (media['type'] == 'image') {
      // Use photo_view or similar for images
      Navigator.push(
        context,
        MaterialPageRoute(
          builder:
              (context) => Scaffold(
                appBar: AppBar(backgroundColor: Colors.black),
                backgroundColor: Colors.black,
                body: Center(
                  child: Image.network('$baseUrl/${media['image_url']}'),
                ),
              ),
        ),
      );
    } else if (media['type'] == 'video') {
      // Use video_player for videos
      _showSnackBar('Video playback not implemented yet');
    } else if (media['type'] == 'pdf') {
      // Use pdf_viewer or similar for PDFs
      _showSnackBar('PDF viewer not implemented yet');
    }
  }

  Future<void> _fetchMembers() async {
    setState(() => _isLoading = true);
    try {
      final memberIds = List<String>.from(_groupDetails['members'] ?? []);
      List<Map<String, dynamic>> members = [];
      for (String memberId in memberIds) {
        final response = await httpClient.get(
          Uri.parse('$baseUrl/user/$memberId'),
        );
        if (response.statusCode == 200) {
          final data = json.decode(response.body);
          members.add({
            'id': memberId,
            'name': data['name'] ?? 'Unknown',
            'profile_pic': data['profile_pic'] ?? 'assets/users.png',
            'isAdmin': _groupDetails['admins'].contains(memberId),
          });
        }
      }
      setState(() => _members = members);
    } catch (e) {
      _showSnackBar('Error fetching members: $e');
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _fetchMediaCounts() async {
    try {
      final response = await httpClient.get(
        Uri.parse('$baseUrl/group-media-counts/${widget.groupId}'),
      );
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        setState(() {
          _mediaCounts = Map<String, int>.from(data['media_counts']);
        });
      } else {
        _showSnackBar('Failed to load media counts');
      }
    } catch (e) {
      _showSnackBar('Error fetching media counts: $e');
    }
  }

  Future<void> _fetchMedia() async {
    try {
      final response = await httpClient.get(
        Uri.parse('$baseUrl/group-messages/${widget.groupId}'),
      );
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final mediaItems =
            List<Map<String, dynamic>>.from(data['messages'])
                .where((msg) => ['image', 'video', 'pdf'].contains(msg['type']))
                .take(6) // Limit to 6 recent media items
                .toList();
        setState(() {
          _mediaItems = mediaItems;
        });
      } else {
        _showSnackBar('Failed to load media');
      }
    } catch (e) {
      _showSnackBar('Error fetching media: $e');
    }
  }

  Future<void> _fetchMuteStatus() async {
    try {
      final response = await httpClient.get(
        Uri.parse(
          '$baseUrl/user-settings/${widget.userId}/group/${widget.groupId}',
        ),
      );
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        setState(() => _isMuted = data['mute_notifications'] ?? false);
      }
    } catch (e) {
      _showSnackBar('Error fetching mute status: $e');
    }
  }

  Future<void> _fetchConnections() async {
    try {
      final response = await httpClient.get(
        Uri.parse('$baseUrl/connections/${widget.userId}'),
      );
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final connections = List<Map<String, dynamic>>.from(
          data['connections'],
        );
        final memberIds = List<String>.from(_groupDetails['members'] ?? []);
        setState(
          () =>
              _connections =
                  connections
                      .where((conn) => !memberIds.contains(conn['id']))
                      .toList(),
        );
      } else {
        _showSnackBar('Failed to load connections');
      }
    } catch (e) {
      _showSnackBar('Error fetching connections: $e');
    }
  }

  void _showAddMembersDialog() async {
    await _fetchConnections();
    setState(() => _selectedConnections = []);

    showDialog(
      context: context,
      builder:
          (context) => StatefulBuilder(
            builder:
                (context, setDialogState) => AlertDialog(
                  backgroundColor: backgroundColor,
                  title: const Text(
                    'Add Members',
                    style: TextStyle(color: Colors.white),
                  ),
                  content:
                      _connections.isEmpty
                          ? const Text(
                            'No connections available to add.',
                            style: TextStyle(color: Colors.white),
                          )
                          : SizedBox(
                            width: double.maxFinite,
                            child: ListView.builder(
                              shrinkWrap: true,
                              itemCount: _connections.length,
                              itemBuilder: (context, index) {
                                final connection = _connections[index];
                                final isSelected = _selectedConnections
                                    .contains(connection['id']);
                                return CheckboxListTile(
                                  title: Text(
                                    connection['name'] ?? 'Unknown',
                                    style: const TextStyle(color: Colors.white),
                                  ),
                                  value: isSelected,
                                  onChanged: (value) {
                                    setDialogState(() {
                                      if (value == true) {
                                        _selectedConnections.add(
                                          connection['id'],
                                        );
                                      } else {
                                        _selectedConnections.remove(
                                          connection['id'],
                                        );
                                      }
                                    });
                                  },
                                  activeColor: Colors.green,
                                  checkColor: Colors.white,
                                  tileColor: Colors.grey[800],
                                  subtitle: Text(
                                    connection['email'] ?? '',
                                    style: TextStyle(color: Colors.grey[400]),
                                  ),
                                );
                              },
                            ),
                          ),
                  actions: [
                    TextButton(
                      onPressed:
                          () => Navigator.pop(context, {
                            'refresh': true,
                            'profilePic': widget.groupDetails['profile_pic'],
                          }),
                      child: const Text(
                        'Cancel',
                        style: TextStyle(color: Colors.grey),
                      ),
                    ),
                    ElevatedButton(
                      onPressed:
                          _selectedConnections.isEmpty
                              ? null
                              : () async {
                                await _addMembers();
                                Navigator.pop(context);
                              },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.green,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(20),
                        ),
                      ),
                      child: const Text(
                        'Add',
                        style: TextStyle(color: Colors.white),
                      ),
                    ),
                  ],
                ),
          ),
    );
  }

  Future<void> _addMembers() async {
    try {
      final updatedMembers = List<String>.from(_groupDetails['members'] ?? [])
        ..addAll(_selectedConnections);
      final response = await httpClient.put(
        Uri.parse('$baseUrl/update-group'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({
          'group_id': widget.groupId,
          'updates': {'members': updatedMembers},
        }),
      );

      if (response.statusCode == 200) {
        setState(() => _groupDetails['members'] = updatedMembers);
        await _fetchMembers();
        _showSnackBar('Members added successfully');
        Navigator.pop(context, true);
      } else {
        _showSnackBar('Failed to add members');
      }
    } catch (e) {
      _showSnackBar('Error adding members: $e');
    }
  }

  Future<void> _removeMember(String memberId) async {
    bool? confirm = await showDialog(
      context: context,
      builder:
          (context) => AlertDialog(
            backgroundColor: backgroundColor,
            title: const Text(
              'Remove Member',
              style: TextStyle(color: Colors.white),
            ),
            content: const Text(
              'Are you sure you want to remove this member?',
              style: TextStyle(color: Colors.white),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text(
                  'Cancel',
                  style: TextStyle(color: Colors.grey),
                ),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text(
                  'Remove',
                  style: TextStyle(color: Colors.red),
                ),
              ),
            ],
          ),
    );

    if (confirm != true) return;

    try {
      final updatedMembers = List<String>.from(_groupDetails['members'] ?? [])
        ..remove(memberId);
      final response = await httpClient.put(
        Uri.parse('$baseUrl/update-group'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({
          'group_id': widget.groupId,
          'updates': {'members': updatedMembers},
        }),
      );

      if (response.statusCode == 200) {
        setState(() => _groupDetails['members'] = updatedMembers);
        await _fetchMembers();
        _showSnackBar('Member removed successfully');
        Navigator.pop(context, true);
      } else {
        _showSnackBar('Failed to remove member');
      }
    } catch (e) {
      _showSnackBar('Error removing member: $e');
    }
  }

  Future<void> _leaveGroup() async {
    final isAdmin = _groupDetails['admins'].contains(widget.userId);
    final isOnlyAdmin = isAdmin && _groupDetails['admins'].length == 1;

    if (isOnlyAdmin) {
      bool? confirmDelete = await showDialog(
        context: context,
        builder:
            (context) => AlertDialog(
              backgroundColor: backgroundColor,
              title: const Text(
                'Warning',
                style: TextStyle(color: Colors.white),
              ),
              content: const Text(
                "You can't leave the group as you are the only admin. Do you want to delete this group and leave?",
                style: TextStyle(color: Colors.white),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text(
                    'Cancel',
                    style: TextStyle(color: Colors.grey),
                  ),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: const Text(
                    'Delete',
                    style: TextStyle(color: Colors.red),
                  ),
                ),
              ],
            ),
      );

      if (confirmDelete == true) {
        try {
          final response = await httpClient.delete(
            Uri.parse('$baseUrl/delete-group/${widget.groupId}'),
            headers: {'Content-Type': 'application/json'},
          );
          if (response.statusCode == 200) {
            _showSnackBar('Group deleted successfully');
            Navigator.pop(context, true);
            Navigator.pop(context);
          } else {
            _showSnackBar('Failed to delete group');
          }
        } catch (e) {
          _showSnackBar('Error deleting group: $e');
        }
      }
      return;
    }

    bool? confirm = await showDialog(
      context: context,
      builder:
          (context) => AlertDialog(
            backgroundColor: backgroundColor,
            title: const Text(
              'Exit Group',
              style: TextStyle(color: Colors.white),
            ),
            content: const Text(
              'Are you sure you want to exit this group?',
              style: TextStyle(color: Colors.white),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text(
                  'Cancel',
                  style: TextStyle(color: Colors.grey),
                ),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Exit', style: TextStyle(color: Colors.red)),
              ),
            ],
          ),
    );

    if (confirm != true) return;

    try {
      final updatedMembers = List<String>.from(_groupDetails['members'] ?? [])
        ..remove(widget.userId);
      final updatedAdmins = List<String>.from(_groupDetails['admins'] ?? [])
        ..remove(widget.userId);
      final response = await httpClient.put(
        Uri.parse('$baseUrl/update-group'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({
          'group_id': widget.groupId,
          'updates': {'members': updatedMembers, 'admins': updatedAdmins},
        }),
      );

      if (response.statusCode == 200) {
        _showSnackBar('You have exited the group');
        Navigator.pop(context, true);
        Navigator.pop(context);
      } else {
        _showSnackBar('Failed to exit group');
      }
    } catch (e) {
      _showSnackBar('Error exiting group: $e');
    }
  }

  Future<void> _updateGroupName() async {
    try {
      final response = await httpClient.put(
        Uri.parse('$baseUrl/update-group'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({
          'group_id': widget.groupId,
          'updates': {'name': _nameController.text},
        }),
      );
      if (response.statusCode == 200) {
        setState(() {
          _groupDetails['name'] = _nameController.text;
          _isEditingName = false;
        });
        _showSnackBar('Group name updated successfully');
        Navigator.pop(context, true);
      } else {
        _showSnackBar('Failed to update group name');
      }
    } catch (e) {
      _showSnackBar('Error updating group name: $e');
    }
  }

  Future<void> _updateDescription() async {
    try {
      final response = await httpClient.put(
        Uri.parse('$baseUrl/update-group'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({
          'group_id': widget.groupId,
          'updates': {'description': _descriptionController.text},
        }),
      );
      if (response.statusCode == 200) {
        setState(() {
          _groupDetails['description'] = _descriptionController.text;
          _isEditingDescription = false;
        });
        _showSnackBar('Description updated successfully');
        Navigator.pop(context, true);
      } else {
        _showSnackBar('Failed to update description');
      }
    } catch (e) {
      _showSnackBar('Error updating description: $e');
    }
  }

  Future<void> _updateProfilePicture(XFile image) async {
    try {
      // Show preview dialog
      bool? confirmed = await showDialog(
        context: context,
        builder:
            (context) => AlertDialog(
              backgroundColor: backgroundColor,
              title: const Text(
                'Preview Profile Picture',
                style: TextStyle(color: Colors.white),
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Image.file(
                    File(image.path),
                    width: 200,
                    height: 200,
                    fit: BoxFit.cover,
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    'Do you want to set this as the group profile picture?',
                    style: TextStyle(color: Colors.white),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text(
                    'Cancel',
                    style: TextStyle(color: Colors.grey),
                  ),
                ),
                ElevatedButton(
                  onPressed: () => Navigator.pop(context, true),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.green,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(20),
                    ),
                  ),
                  child: const Text(
                    'Set Picture',
                    style: TextStyle(color: Colors.white),
                  ),
                ),
              ],
            ),
      );

      if (confirmed != true) return;

      // Create multipart request
      var request = http.MultipartRequest(
        'POST',
        Uri.parse('$baseUrl/update-group-image'),
      );

      // Add fields
      request.fields['group_id'] = widget.groupId;

      // Add image file
      request.files.add(
        await http.MultipartFile.fromPath(
          'profile_pic',
          image.path,
          filename:
              'group_${widget.groupId}_${DateTime.now().millisecondsSinceEpoch}.jpg',
        ),
      );

      // Send request
      var streamedResponse = await httpClient.send(request);
      var response = await http.Response.fromStream(streamedResponse);

      if (response.statusCode == 200) {
        var jsonData = json.decode(response.body);
        setState(() {
          _groupDetails['profile_pic'] = jsonData['profile_pic'];
        });
        _showSnackBar('Profile picture updated successfully');
        if (mounted) {
          Navigator.pop(context, true);
        }
      } else {
        _showSnackBar(
          'Failed to update profile picture: ${response.statusCode}',
        );
      }
    } catch (e) {
      _showSnackBar('Error updating profile picture: $e');
    }
  }

  Future<void> _toggleMuteNotifications() async {
    try {
      final response = await httpClient.post(
        Uri.parse(
          '$baseUrl/user-settings/${widget.userId}/group/${widget.groupId}',
        ),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({'mute_notifications': !_isMuted}),
      );
      if (response.statusCode == 200) {
        setState(() => _isMuted = !_isMuted);
        _showSnackBar(
          _isMuted ? 'Notifications muted' : 'Notifications unmuted',
        );
      } else {
        _showSnackBar('Failed to update notification settings');
      }
    } catch (e) {
      _showSnackBar('Error updating notification settings: $e');
    }
  }

  void _showCustomNotificationsDialog() {
    showDialog(
      context: context,
      builder:
          (context) => AlertDialog(
            backgroundColor: backgroundColor,
            title: const Text(
              'Custom Notifications',
              style: TextStyle(color: Colors.white),
            ),
            content: const Text(
              'Customize notification settings for this group.',
              style: TextStyle(color: Colors.white),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text(
                  'Cancel',
                  style: TextStyle(color: Colors.grey),
                ),
              ),
              ElevatedButton(
                onPressed: () {
                  // Implement custom notification logic here
                  _showSnackBar('Custom notifications saved');
                  Navigator.pop(context);
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.green,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(20),
                  ),
                ),
                child: const Text(
                  'Save',
                  style: TextStyle(color: Colors.white),
                ),
              ),
            ],
          ),
    );
  }

  void _showSnackBar(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final createdAt = DateTime.parse(_groupDetails['created_at']).toLocal();
    final formattedDate = DateFormat('MMM d, yyyy').format(createdAt);
    final isAdmin = _groupDetails['admins'].contains(widget.userId);

    return Scaffold(
      backgroundColor: backgroundColor,
      appBar: AppBar(
        backgroundColor: backgroundColor,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: () => Navigator.pop(context),
        ),
        title: const Text(
          'Group Info',
          style: TextStyle(
            color: Colors.white,
            fontSize: 20,
            fontWeight: FontWeight.w500,
          ),
        ),
        elevation: 0,
      ),
      body:
          _isLoading
              ? const Center(child: CircularProgressIndicator())
              : SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Group Profile Section
                    Container(
                      color: backgroundColor,
                      padding: const EdgeInsets.all(16.0),
                      child: Column(
                        children: [
                          Stack(
                            alignment: Alignment.bottomRight,
                            children: [
                              CircleAvatar(
                                radius: 60,
                                backgroundImage:
                                    _groupDetails['profile_pic'] != "default"
                                        ? NetworkImage(
                                          '$baseUrl/${_groupDetails['profile_pic']}',
                                        )
                                        : const AssetImage(
                                              'assets/images/group_default.jpg',
                                            )
                                            as ImageProvider,
                                backgroundColor: Colors.grey[800],
                              ),
                              if (isAdmin)
                                Positioned(
                                  bottom: 0,
                                  right: 0,
                                  child: GestureDetector(
                                    onTap: () async {
                                      final ImagePicker picker = ImagePicker();
                                      final XFile? image = await picker
                                          .pickImage(
                                            source: ImageSource.gallery,
                                            maxWidth: 512,
                                            maxHeight: 512,
                                            imageQuality: 80,
                                          );
                                      if (image != null && mounted) {
                                        await _updateProfilePicture(image);
                                      }
                                    },
                                    child: Container(
                                      padding: const EdgeInsets.all(8),
                                      decoration: BoxDecoration(
                                        color: Colors.green,
                                        shape: BoxShape.circle,
                                        border: Border.all(
                                          color: Colors.white,
                                          width: 2,
                                        ),
                                      ),
                                      child: const Icon(
                                        Icons.camera_alt,
                                        color: Colors.white,
                                        size: 24,
                                      ),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          _isEditingName
                              ? Row(
                                children: [
                                  Expanded(
                                    child: TextField(
                                      controller: _nameController,
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 24,
                                      ),
                                      textAlign: TextAlign.center,
                                      decoration: InputDecoration(
                                        filled: true,
                                        fillColor: Colors.grey[800],
                                        border: OutlineInputBorder(
                                          borderRadius: BorderRadius.circular(
                                            8.0,
                                          ),
                                          borderSide: BorderSide.none,
                                        ),
                                      ),
                                    ),
                                  ),
                                  IconButton(
                                    icon: const Icon(
                                      Icons.check,
                                      color: Colors.green,
                                    ),
                                    onPressed: _updateGroupName,
                                  ),
                                  IconButton(
                                    icon: const Icon(
                                      Icons.cancel,
                                      color: Colors.grey,
                                    ),
                                    onPressed:
                                        () => setState(() {
                                          _isEditingName = false;
                                          _nameController.text =
                                              _groupDetails['name'] ??
                                              'Unnamed Group';
                                        }),
                                  ),
                                ],
                              )
                              : Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Text(
                                    _groupDetails['name'] ?? 'Unnamed Group',
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 24,
                                      fontWeight: FontWeight.bold,
                                    ),
                                    textAlign: TextAlign.center,
                                  ),
                                  if (isAdmin)
                                    IconButton(
                                      icon: const Icon(
                                        Icons.edit,
                                        color: Colors.white,
                                      ),
                                      onPressed:
                                          () => setState(
                                            () => _isEditingName = true,
                                          ),
                                    ),
                                ],
                              ),
                          const SizedBox(height: 8),
                          Text(
                            'Group · Created on $formattedDate',
                            style: TextStyle(
                              color: Colors.grey[400],
                              fontSize: 14,
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ],
                      ),
                    ),
                    Divider(color: Colors.grey[800], height: 1),
                    // Media, Links, and Docs Section
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16.0,
                        vertical: 8.0,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Media, Links, and Docs',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 8),
                          // Media Counts
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              _buildMediaCount(
                                'Images',
                                _mediaCounts['images'] ?? 0,
                              ),
                              _buildMediaCount(
                                'Videos',
                                _mediaCounts['videos'] ?? 0,
                              ),
                              _buildMediaCount(
                                'Docs',
                                _mediaCounts['pdfs'] ?? 0,
                              ),
                              _buildMediaCount(
                                'Voice',
                                _mediaCounts['voice'] ?? 0,
                              ),
                            ],
                          ),
                          const SizedBox(height: 16),
                          // Recent Media
                          _mediaItems.isEmpty
                              ? const Text(
                                'No media, links, or docs shared',
                                style: TextStyle(color: Colors.grey),
                              )
                              : GridView.builder(
                                shrinkWrap: true,
                                physics: const NeverScrollableScrollPhysics(),
                                gridDelegate:
                                    const SliverGridDelegateWithFixedCrossAxisCount(
                                      crossAxisCount: 3,
                                      crossAxisSpacing: 8,
                                      mainAxisSpacing: 8,
                                      childAspectRatio: 1,
                                    ),
                                itemCount: _mediaItems.length,
                                itemBuilder: (context, index) {
                                  final media = _mediaItems[index];
                                  String? url;
                                  IconData? icon;
                                  if (media['type'] == 'image') {
                                    url = media['image_url'];
                                  } else if (media['type'] == 'video') {
                                    url = media['video_url'];
                                    icon = Icons.videocam;
                                  } else if (media['type'] == 'pdf') {
                                    url = media['pdf_url'];
                                    icon = Icons.picture_as_pdf;
                                  }
                                  return GestureDetector(
                                    onTap: () {
                                      _openMediaViewer(media);
                                      _showSnackBar(
                                        'Opening ${media['type']}...',
                                      );
                                    },
                                    child: ClipRRect(
                                      borderRadius: BorderRadius.circular(8),
                                      child: Stack(
                                        fit: StackFit.expand,
                                        children: [
                                          if (url != null)
                                            Image.network(
                                              '$baseUrl/$url',
                                              fit: BoxFit.cover,
                                              errorBuilder:
                                                  (
                                                    context,
                                                    error,
                                                    stackTrace,
                                                  ) => Container(
                                                    color: Colors.grey[800],
                                                    child: const Icon(
                                                      Icons.broken_image,
                                                      color: Colors.grey,
                                                      size: 50,
                                                    ),
                                                  ),
                                            ),
                                          if (icon != null)
                                            Center(
                                              child: Icon(
                                                icon,
                                                color: Colors.white.withOpacity(
                                                  0.7,
                                                ),
                                                size: 40,
                                              ),
                                            ),
                                        ],
                                      ),
                                    ),
                                  );
                                },
                              ),
                        ],
                      ),
                    ),
                    Divider(color: Colors.grey[800], height: 1),
                    // Description Section
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16.0,
                        vertical: 8.0,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              const Text(
                                'Description',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 18,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              if (isAdmin && !_isEditingDescription)
                                IconButton(
                                  icon: const Icon(
                                    Icons.edit,
                                    color: Colors.white,
                                  ),
                                  onPressed:
                                      () => setState(
                                        () => _isEditingDescription = true,
                                      ),
                                ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          _isEditingDescription
                              ? Column(
                                children: [
                                  TextField(
                                    controller: _descriptionController,
                                    style: const TextStyle(color: Colors.white),
                                    maxLines: 3,
                                    decoration: InputDecoration(
                                      filled: true,
                                      fillColor: Colors.grey[800],
                                      border: OutlineInputBorder(
                                        borderRadius: BorderRadius.circular(
                                          8.0,
                                        ),
                                        borderSide: BorderSide.none,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                  Row(
                                    mainAxisAlignment: MainAxisAlignment.end,
                                    children: [
                                      TextButton(
                                        onPressed: () {
                                          setState(() {
                                            _isEditingDescription = false;
                                            _descriptionController.text =
                                                _groupDetails['description'] ??
                                                'No description provided';
                                          });
                                        },
                                        child: const Text(
                                          'Cancel',
                                          style: TextStyle(color: Colors.grey),
                                        ),
                                      ),
                                      ElevatedButton(
                                        onPressed: _updateDescription,
                                        style: ElevatedButton.styleFrom(
                                          backgroundColor: Colors.green,
                                          shape: RoundedRectangleBorder(
                                            borderRadius: BorderRadius.circular(
                                              20,
                                            ),
                                          ),
                                        ),
                                        child: const Text(
                                          'Save',
                                          style: TextStyle(color: Colors.white),
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              )
                              : Text(
                                _groupDetails['description'] ??
                                    'No description provided',
                                style: TextStyle(
                                  color: Colors.grey[400],
                                  fontSize: 16,
                                ),
                              ),
                        ],
                      ),
                    ),
                    Divider(color: Colors.grey[800], height: 1),
                    // Settings Section
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16.0,
                        vertical: 8.0,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Settings',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          ListTile(
                            leading: Icon(
                              _isMuted
                                  ? Icons.notifications_off
                                  : Icons.notifications,
                              color: Colors.white,
                            ),
                            title: const Text(
                              'Mute Notifications',
                              style: TextStyle(color: Colors.white),
                            ),
                            trailing: Switch(
                              value: _isMuted,
                              onChanged: (value) => _toggleMuteNotifications(),
                              activeColor: Colors.green,
                            ),
                          ),
                          ListTile(
                            leading: const Icon(
                              Icons.tune,
                              color: Colors.white,
                            ),
                            title: const Text(
                              'Custom Notifications',
                              style: TextStyle(color: Colors.white),
                            ),
                            onTap: _showCustomNotificationsDialog,
                          ),
                          ListTile(
                            leading: const Icon(
                              Icons.lock,
                              color: Colors.white,
                            ),
                            title: const Text(
                              'Encryption',
                              style: TextStyle(color: Colors.white),
                            ),
                            subtitle: const Text(
                              'Messages are end-to-end encrypted',
                              style: TextStyle(color: Colors.grey),
                            ),
                            onTap:
                                () => _showSnackBar(
                                  'Messages are secured with end-to-end encryption',
                                ),
                          ),
                        ],
                      ),
                    ),
                    Divider(color: Colors.grey[800], height: 1),
                    // Members Section
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16.0,
                        vertical: 8.0,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(
                                '${_members.length} Participants',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 18,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              if (isAdmin)
                                TextButton.icon(
                                  onPressed: _showAddMembersDialog,
                                  icon: const Icon(
                                    Icons.person_add,
                                    color: Colors.green,
                                  ),
                                  label: const Text(
                                    'Add Participant',
                                    style: TextStyle(color: Colors.green),
                                  ),
                                ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          ListView.builder(
                            shrinkWrap: true,
                            physics: const NeverScrollableScrollPhysics(),
                            itemCount: _members.length,
                            itemBuilder: (context, index) {
                              final member = _members[index];
                              return ListTile(
                                leading: CircleAvatar(
                                  radius: 24,
                                  backgroundImage:
                                      member['profile_pic'] != 'default.jpg'
                                          ? NetworkImage(
                                            '$baseUrl/${member['profile_pic']}',
                                          )
                                          : const AssetImage(
                                                'assets/images/default.jpg',
                                              )
                                              as ImageProvider,
                                ),
                                title: Text(
                                  member['name'],
                                  style: const TextStyle(color: Colors.white),
                                ),
                                subtitle: Text(
                                  member['isAdmin'] ? 'Admin' : 'Participant',
                                  style: TextStyle(color: Colors.grey[400]),
                                ),
                                trailing:
                                    isAdmin && member['id'] != widget.userId
                                        ? IconButton(
                                          icon: const Icon(
                                            Icons.remove_circle,
                                            color: Colors.red,
                                          ),
                                          onPressed:
                                              () => _removeMember(member['id']),
                                        )
                                        : null,
                              );
                            },
                          ),
                        ],
                      ),
                    ),
                    Divider(color: Colors.grey[800], height: 1),
                    // Exit Group
                    Padding(
                      padding: const EdgeInsets.all(16.0),
                      child: Center(
                        child: ElevatedButton.icon(
                          onPressed: _leaveGroup,
                          icon: const Icon(
                            Icons.exit_to_app,
                            color: Colors.white,
                          ),
                          label: Text(
                            isAdmin && _groupDetails['admins'].length == 1
                                ? 'Delete and Exit'
                                : 'Exit Group',
                            style: const TextStyle(color: Colors.white),
                          ),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.red,
                            minimumSize: const Size(double.infinity, 50),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(20),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
    );
  }

  Widget _buildMediaCount(String label, int count) {
    return Column(
      children: [
        Text(
          count.toString(),
          style: const TextStyle(
            color: Colors.white,
            fontSize: 16,
            fontWeight: FontWeight.bold,
          ),
        ),
        Text(label, style: TextStyle(color: Colors.grey[400], fontSize: 14)),
      ],
    );
  }
}
