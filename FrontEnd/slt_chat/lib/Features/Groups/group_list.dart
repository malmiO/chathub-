import '/common/widgets/colors.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'dart:convert';
import 'dart:io';
import 'package:socket_io_client/socket_io_client.dart' as IO;
import '/Features/Groups/create_new_group.dart';
import '/config/config.dart';
import '/Features/Groups/group_chat_screen.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:slt_chat/Features/Groups/group_localDB.dart';

class GroupListScreen extends StatefulWidget {
  final String userId;

  const GroupListScreen({super.key, required this.userId});

  @override
  _GroupListScreenState createState() => _GroupListScreenState();
}

class _GroupListScreenState extends State<GroupListScreen> {
  List<Map<String, dynamic>> groups = [];
  List<Map<String, dynamic>> filteredGroups = [];
  bool isLoading = true;
  late IOClient httpClient;
  final String baseUrl = AppConfig.baseUrl;
  final TextEditingController searchController = TextEditingController();
  late IO.Socket socket;
  final LocalDatabase _localDb = LocalDatabase();

  @override
  void initState() {
    super.initState();
    final HttpClient client =
        HttpClient()
          ..badCertificateCallback =
              (X509Certificate cert, String host, int port) => true;
    httpClient = IOClient(client);
    // Sequence initialization: init DB -> load local groups -> fetch from server
    _initLocalDatabase()
        .then((_) {
          return _loadLocalGroups(); // Load local groups first
        })
        .then((_) {
          _fetchGroups(); // Then sync with server
        })
        .catchError((e) {
          print('Initialization error: $e');
          setState(() => isLoading = false); // Stop loading on error
        });
    _initSocket(); // Socket can initialize independently
  }

  Future<void> _initLocalDatabase() async {
    await _localDb.initDatabase();
  }

  Future<void> _loadLocalGroups() async {
    if (!_localDb.isOpen) {
      print('Database is not open, cannot load local groups');
      setState(() {
        groups = [];
        filteredGroups = [];
        isLoading = false;
      });
      return;
    }
    try {
      final localGroups = await _localDb.getGroups();
      setState(() {
        groups = localGroups;
        filteredGroups = localGroups;
        isLoading = false; // Show local data immediately
      });
      print('Local groups loaded: $groups');
    } catch (e) {
      print('Error loading local groups: $e');
      setState(() {
        groups = [];
        filteredGroups = [];
        isLoading = false;
      });
    }
  }

  void _initSocket() {
    socket = IO.io(
      baseUrl,
      IO.OptionBuilder()
          .setTransports(['websocket'])
          .disableAutoConnect()
          .build(),
    );

    socket.connect();

    socket.onConnect((_) {
      print('Connected to socket server');
      socket.emit('join', widget.userId);
    });

    socket.on('group_updated', (_) {
      print('Group list changed, refetching...');
      _fetchGroups();
    });

    socket.onDisconnect((_) => print('Disconnected from socket'));
  }

  @override
  void dispose() {
    socket.dispose();
    httpClient.close();
    searchController.dispose();
    _localDb.close(); // Close database connection
    super.dispose();
  }

  Future<void> _fetchGroups() async {
    try {
      final response = await httpClient.get(
        Uri.parse('$baseUrl/user-groups/${widget.userId}'),
      );
      print('API Response: ${response.statusCode} - ${response.body}');
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        if (data['groups'] is List) {
          final serverGroups = List<Map<String, dynamic>>.from(data['groups']);
          print('Raw server groups: $serverGroups');
          final validGroups = <Map<String, dynamic>>[];
          for (var group in serverGroups) {
            try {
              if (group['group_id'] == null || group['name'] == null) {
                print('Skipping group with missing group_id or name: $group');
                continue;
              }
              validGroups.add({
                'group_id': group['group_id'].toString(),
                'name': group['name'] ?? 'Unnamed Group',
                'profile_pic': group['profile_pic'],
                'members': group['members'] ?? [],
                'last_message': group['last_message'],
                'last_message_time': group['last_message_time'],
                'unread_count': group['unread_count'] ?? 0,
                'is_typing': group['is_typing'] ?? false,
              });
            } catch (e) {
              print('Error processing group ${group['group_id']}: $e');
              continue;
            }
          }
          if (_localDb.isOpen) {
            await _localDb.replaceGroups(validGroups);
            print('Server groups saved to local database');
          } else {
            print('Database is not open, skipping replaceGroups');
          }
          setState(() {
            groups = validGroups;
            filteredGroups = validGroups;
            print('Groups loaded from server: $groups');
          });
        } else {
          print(
            'Error: "groups" key is missing or not a list in response: $data',
          );
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Invalid group data received')),
          );
        }
      } else {
        print(
          'Failed to load groups: ${response.statusCode} - ${response.body}',
        );
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to load groups: ${response.statusCode}'),
          ),
        );
      }
    } catch (e) {
      print('Error fetching groups: $e');
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Error fetching groups: $e')));
    } finally {
      // Only update isLoading if local groups weren't loaded
      if (groups.isEmpty) {
        setState(() => isLoading = false);
      }
    }
  }

  void _filterGroups(String query) {
    setState(() {
      filteredGroups =
          groups
              .where(
                (group) =>
                    group['name'].toLowerCase().contains(query.toLowerCase()),
              )
              .toList();
    });
  }

  String getInitials(String name) {
    final parts = name.split(' ');
    if (parts.length > 1) {
      return parts[0][0].toUpperCase() + parts[1][0].toUpperCase();
    }
    return name.isNotEmpty ? name[0].toUpperCase() : '';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: backgroundColor,
      appBar: AppBar(
        title: const Text(
          'Groups',
          style: TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.bold,
            fontSize: 28,
          ),
        ),
        backgroundColor: backgroundColor,
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(48),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: TextField(
              controller: searchController,
              onChanged: _filterGroups,
              decoration: InputDecoration(
                hintText: 'Search groups',
                fillColor: Colors.grey[800],
                filled: true,
                prefixIcon: const Icon(Icons.search, color: Colors.white70),
                hintStyle: const TextStyle(color: Colors.white54),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
              ),
              style: const TextStyle(color: Colors.white),
            ),
          ),
        ),
      ),
      body:
          isLoading
              ? const Center(child: CircularProgressIndicator())
              : filteredGroups.isEmpty
              ? Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.group, size: 64, color: Colors.grey),
                    const SizedBox(height: 16),
                    const Text(
                      'No groups found',
                      style: TextStyle(color: Colors.white, fontSize: 18),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Try searching something else',
                      style: TextStyle(color: Colors.grey[400]),
                    ),
                  ],
                ),
              )
              : RefreshIndicator(
                onRefresh: _fetchGroups,
                child: ListView.builder(
                  itemCount: filteredGroups.length,
                  itemBuilder: (context, index) {
                    final group = filteredGroups[index];
                    final groupName = group['name'] ?? 'Unnamed Group';
                    final unreadCount = group['unread_count'] ?? 0;

                    return Card(
                      color: backgroundColor.withOpacity(0.8),
                      margin: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      child: ListTile(
                        leading: CircleAvatar(
                          radius: 24,
                          backgroundColor: Colors.grey[300],
                          child: ClipOval(
                            child:
                                group['profile_pic'] != null &&
                                        !group['profile_pic'].contains(
                                          'default',
                                        )
                                    ? CachedNetworkImage(
                                      imageUrl:
                                          '$baseUrl/${group['profile_pic']}',
                                      width: 48,
                                      height: 48,
                                      fit: BoxFit.cover,
                                      errorWidget:
                                          (_, __, ___) => Center(
                                            child: Text(
                                              getInitials(groupName),
                                              style: const TextStyle(
                                                color: Colors.black,
                                                fontWeight: FontWeight.bold,
                                              ),
                                            ),
                                          ),
                                    )
                                    : Center(
                                      child: Text(
                                        getInitials(groupName),
                                        style: const TextStyle(
                                          color: Colors.black,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                    ),
                          ),
                        ),
                        title: Text(
                          groupName,
                          style: const TextStyle(color: Colors.white),
                        ),
                        subtitle: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '${group['members']?.length ?? 0} members',
                              style: TextStyle(
                                color: Colors.grey[300],
                                fontSize: 12,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              (group['is_typing'] ?? false)
                                  ? 'Typing...'
                                  : (group['last_message'] ??
                                      'No messages yet'),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: Colors.grey[400],
                                fontSize: 13,
                              ),
                            ),
                          ],
                        ),
                        trailing: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(
                              group['last_message_time'] != null
                                  ? _formatTime(group['last_message_time'])
                                  : '',
                              style: TextStyle(
                                color: Colors.grey[400],
                                fontSize: 12,
                              ),
                            ),
                            if (unreadCount > 0)
                              Container(
                                margin: const EdgeInsets.only(top: 4),
                                padding: const EdgeInsets.all(6),
                                decoration: const BoxDecoration(
                                  color: Colors.green,
                                  shape: BoxShape.circle,
                                ),
                                child: Text(
                                  '$unreadCount',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 12,
                                  ),
                                ),
                              ),
                          ],
                        ),
                        onTap: () async {
                          final groupId = group['group_id']?.toString();
                          final groupProfilePic =
                              group['profile_pic'] != null
                                  ? '$baseUrl/${group['profile_pic']}'
                                  : 'default';

                          if (groupId == null) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('Error: Group ID is missing'),
                              ),
                            );
                            return;
                          }

                          await Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder:
                                  (context) => GroupChatScreen(
                                    groupId: groupId,
                                    groupName: groupName,
                                    userId: widget.userId,
                                    initialGroupProfilePic: groupProfilePic,
                                  ),
                            ),
                          );
                          _fetchGroups();
                        },
                      ),
                    );
                  },
                ),
              ),
      floatingActionButton: FloatingActionButton(
        onPressed: () async {
          final result = await Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => CreateGroupScreen(userId: widget.userId),
            ),
          );
          if (result == true) {
            _fetchGroups();
          }
        },
        backgroundColor: Colors.green,
        child: const Icon(Icons.add, color: Colors.white),
      ),
    );
  }

  String _formatTime(String timestamp) {
    try {
      final dateTime = DateTime.parse(timestamp);
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      final yesterday = DateTime(now.year, now.month, now.day - 1);
      final messageDate = DateTime(dateTime.year, dateTime.month, dateTime.day);

      if (messageDate == today) {
        return '${dateTime.hour}:${dateTime.minute.toString().padLeft(2, '0')}';
      } else if (messageDate == yesterday) {
        return 'Yesterday';
      } else {
        return '${dateTime.day}/${dateTime.month}/${dateTime.year}';
      }
    } catch (e) {
      return timestamp;
    }
  }
}
