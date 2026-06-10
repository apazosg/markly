import 'dart:convert';
import 'dart:io';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:http/http.dart' as http;

const String _baseUrl = String.fromEnvironment(
  'API_BASE_URL',
  defaultValue: 'https://markly.adriangp.com',
);

class ApiService {
  static final ApiService _instance = ApiService._();
  factory ApiService() => _instance;
  ApiService._();

  Future<String> _token() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) throw Exception('No autenticado');
    return await user.getIdToken() ?? '';
  }

  Future<Map<String, dynamic>> getSession(String serverId) async {
    final token = await _token();
    final response = await http.get(
      Uri.parse('$_baseUrl/sessions/$serverId'),
      headers: {'Authorization': 'Bearer $token'},
    );
    if (response.statusCode != 200) throw HttpException('Error ${response.statusCode}');
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  Future<List<Map<String, dynamic>>> listSessions() async {
    final token = await _token();
    final response = await http.get(
      Uri.parse('$_baseUrl/sessions'),
      headers: {'Authorization': 'Bearer $token'},
    );
    if (response.statusCode != 200) throw HttpException('Error ${response.statusCode}');
    return (jsonDecode(response.body) as List).cast<Map<String, dynamic>>();
  }

  Future<String> uploadSession(String audioPath, String notesPath) async {
    final token = await _token();
    final request = http.MultipartRequest('POST', Uri.parse('$_baseUrl/sessions'))
      ..headers['Authorization'] = 'Bearer $token'
      ..files.add(await http.MultipartFile.fromPath('audio', audioPath))
      ..files.add(await http.MultipartFile.fromPath('notes', notesPath));

    final streamed = await request.send();
    final body = await streamed.stream.bytesToString();
    if (streamed.statusCode != 201) throw HttpException('Error ${streamed.statusCode}: $body');
    return (jsonDecode(body) as Map<String, dynamic>)['id'] as String;
  }

  Future<void> deleteSession(String serverId) async {
    final token = await _token();
    final response = await http.delete(
      Uri.parse('$_baseUrl/sessions/$serverId'),
      headers: {'Authorization': 'Bearer $token'},
    );
    if (response.statusCode != 204) throw HttpException('Error ${response.statusCode}');
  }

  Future<void> reprocessSession(String serverId) async {
    final token = await _token();
    final response = await http.post(
      Uri.parse('$_baseUrl/sessions/$serverId/reprocess'),
      headers: {'Authorization': 'Bearer $token'},
    );
    if (response.statusCode != 200) throw HttpException('Error ${response.statusCode}');
  }

  Future<Map<String, dynamic>> mergeSessions(List<String> sessionIds) async {
    final token = await _token();
    final response = await http.post(
      Uri.parse('$_baseUrl/sessions/merge'),
      headers: {'Authorization': 'Bearer $token', 'Content-Type': 'application/json'},
      body: jsonEncode({'session_ids': sessionIds}),
    );
    if (response.statusCode != 201) throw HttpException('Error ${response.statusCode}');
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> getUsageSummary() async {
    final token = await _token();
    final response = await http.get(
      Uri.parse('$_baseUrl/usage/summary'),
      headers: {'Authorization': 'Bearer $token'},
    );
    if (response.statusCode != 200) throw HttpException('Error ${response.statusCode}');
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  Future<void> updateMetadata(String serverId, Map<String, dynamic> patch) async {
    final token = await _token();
    final response = await http.patch(
      Uri.parse('$_baseUrl/sessions/$serverId/metadata'),
      headers: {'Authorization': 'Bearer $token', 'Content-Type': 'application/json'},
      body: jsonEncode(patch),
    );
    if (response.statusCode != 200) throw HttpException('Error ${response.statusCode}');
  }
}
