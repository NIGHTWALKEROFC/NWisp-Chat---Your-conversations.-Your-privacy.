import 'dart:convert';
import 'package:http/http.dart' as http;
import 'secure_storage_service.dart';

class ApiService {
  // Replace with your deployed backend URL
  static const String baseUrl = 'https://api.yourapp.example.com';

  static Future<Map<String, dynamic>> register({
    required String username,
    String? email,
    String? phone,
    required String password,
    required Map<String, dynamic> deviceKeys,
  }) async {
    final res = await http.post(
      Uri.parse('$baseUrl/api/auth/register'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'username': username,
        'email': email,
        'phone': phone,
        'password': password,
        'deviceKeys': deviceKeys,
      }),
    );
    final data = jsonDecode(res.body);
    if (res.statusCode != 201) throw Exception(data['error'] ?? 'Registration failed');
    await SecureStorageService.saveTokens(data['accessToken'], data['refreshToken']);
    return data;
  }

  static Future<Map<String, dynamic>> login(String identifier, String password) async {
    final res = await http.post(
      Uri.parse('$baseUrl/api/auth/login'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'identifier': identifier, 'password': password}),
    );
    final data = jsonDecode(res.body);
    if (res.statusCode != 200) throw Exception(data['error'] ?? 'Login failed');
    await SecureStorageService.saveTokens(data['accessToken'], data['refreshToken']);
    return data;
  }

  static Future<List<dynamic>> getMessages(String conversationId) async {
    final token = await SecureStorageService.getAccessToken();
    final res = await http.get(
      Uri.parse('$baseUrl/api/messages/$conversationId'),
      headers: {'Authorization': 'Bearer $token'},
    );
    final data = jsonDecode(res.body);
    if (res.statusCode != 200) throw Exception(data['error'] ?? 'Failed to load messages');
    return data['messages'];
  }
}
