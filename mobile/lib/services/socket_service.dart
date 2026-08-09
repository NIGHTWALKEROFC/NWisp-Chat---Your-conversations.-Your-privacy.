import 'package:socket_io_client/socket_io_client.dart' as io;
import 'secure_storage_service.dart';
import 'api_service.dart';

class SocketService {
  io.Socket? _socket;

  Future<void> connect({required Function(Map<String, dynamic>) onNewMessage}) async {
    final token = await SecureStorageService.getAccessToken();
    _socket = io.io(
      ApiService.baseUrl,
      io.OptionBuilder()
          .setTransports(['websocket'])
          .setAuth({'token': token})
          .disableAutoConnect()
          .build(),
    );
    _socket!.connect();
    _socket!.on('message:new', (data) => onNewMessage(Map<String, dynamic>.from(data)));
  }

  void sendMessage({
    required String conversationId,
    required String ciphertext,
    String messageType = 'text',
    String? mediaUrl,
    String? replyToId,
  }) {
    _socket?.emitWithAck('message:send', {
      'conversationId': conversationId,
      'ciphertext': ciphertext,
      'messageType': messageType,
      'mediaUrl': mediaUrl,
      'replyToId': replyToId,
    }, ack: (_) {});
  }

  void dispose() => _socket?.dispose();
}
