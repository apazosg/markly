import 'dart:async';
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

  Future<String> uploadSession(String audioPath, String notesPath,
      {List<String> labels = const [], void Function(double progress)? onProgress}) async {
    final token = await _token();
    final request = _ProgressMultipartRequest('POST', Uri.parse('$_baseUrl/sessions'),
        onProgress: onProgress)
      ..headers['Authorization'] = 'Bearer $token'
      ..files.add(await http.MultipartFile.fromPath('audio', audioPath))
      ..files.add(await http.MultipartFile.fromPath('notes', notesPath));
    // Las etiquetas viajan en el upload para que el backend elija el formato
    // del resumen (p. ej. "one to one") ya en la primera pasada.
    if (labels.isNotEmpty) request.fields['labels'] = jsonEncode(labels);

    final streamed = await request.send();
    final body = await streamed.stream.bytesToString();
    if (streamed.statusCode != 201) throw HttpException('Error ${streamed.statusCode}: $body');
    return (jsonDecode(body) as Map<String, dynamic>)['id'] as String;
  }

  /// Re-sube el audio local de una sesión existente (cuyo original purgó la
  /// retención del servidor) y dispara una nueva transcripción.
  Future<void> reattachAudio(String serverId, String audioPath,
      {void Function(double progress)? onProgress}) async {
    final token = await _token();
    final request = _ProgressMultipartRequest('POST', Uri.parse('$_baseUrl/sessions/$serverId/audio'),
        onProgress: onProgress)
      ..headers['Authorization'] = 'Bearer $token'
      ..files.add(await http.MultipartFile.fromPath('audio', audioPath));
    final streamed = await request.send();
    final body = await streamed.stream.bytesToString();
    if (streamed.statusCode != 200) throw HttpException('Error ${streamed.statusCode}: $body');
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

  Future<Map<String, dynamic>> chatText(List<Map<String, String>> messages) async {
    final token = await _token();
    final response = await http.post(
      Uri.parse('$_baseUrl/chat'),
      headers: {'Authorization': 'Bearer $token', 'Content-Type': 'application/json'},
      body: jsonEncode({'messages': messages}),
    );
    if (response.statusCode != 200) {
      throw HttpException('Error ${response.statusCode}: ${response.body}');
    }
    return jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> chatAudio(String audioPath, List<Map<String, String>> history) async {
    final token = await _token();
    final request = http.MultipartRequest('POST', Uri.parse('$_baseUrl/chat/audio'))
      ..headers['Authorization'] = 'Bearer $token'
      ..fields['history'] = jsonEncode(history)
      ..files.add(await http.MultipartFile.fromPath('audio', audioPath));
    final streamed = await request.send();
    final body = await streamed.stream.bytesToString();
    if (streamed.statusCode != 200) throw HttpException('Error ${streamed.statusCode}: $body');
    return jsonDecode(body) as Map<String, dynamic>;
  }

  Future<List<Map<String, dynamic>>> listTasks({String? status}) async {
    final token = await _token();
    final uri = Uri.parse('$_baseUrl/tasks')
        .replace(queryParameters: status != null ? {'status': status} : null);
    final response = await http.get(uri, headers: {'Authorization': 'Bearer $token'});
    if (response.statusCode != 200) throw HttpException('Error ${response.statusCode}');
    return (jsonDecode(utf8.decode(response.bodyBytes)) as List).cast<Map<String, dynamic>>();
  }

  Future<Map<String, dynamic>> createTask(Map<String, dynamic> task) async {
    final token = await _token();
    final response = await http.post(
      Uri.parse('$_baseUrl/tasks'),
      headers: {'Authorization': 'Bearer $token', 'Content-Type': 'application/json'},
      body: jsonEncode(task),
    );
    if (response.statusCode != 201) throw HttpException('Error ${response.statusCode}: ${response.body}');
    return jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> updateTask(String taskId, Map<String, dynamic> patch) async {
    final token = await _token();
    final response = await http.patch(
      Uri.parse('$_baseUrl/tasks/$taskId'),
      headers: {'Authorization': 'Bearer $token', 'Content-Type': 'application/json'},
      body: jsonEncode(patch),
    );
    if (response.statusCode != 200) throw HttpException('Error ${response.statusCode}');
    return jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
  }

  Future<void> deleteTask(String taskId) async {
    final token = await _token();
    final response = await http.delete(
      Uri.parse('$_baseUrl/tasks/$taskId'),
      headers: {'Authorization': 'Bearer $token'},
    );
    if (response.statusCode != 204) throw HttpException('Error ${response.statusCode}');
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

/// MultipartRequest que informa de los bytes enviados. `package:http` no expone
/// progreso de subida, así que interceptamos finalize() y contamos el cuerpo a
/// medida que el socket lo consume (≈ velocidad de red por backpressure).
class _ProgressMultipartRequest extends http.MultipartRequest {
  final void Function(double progress)? onProgress;

  _ProgressMultipartRequest(super.method, super.url, {this.onProgress});

  @override
  http.ByteStream finalize() {
    final byteStream = super.finalize();
    final total = contentLength;
    if (onProgress == null || total == 0) return byteStream;

    int sent = 0;
    final transformer = StreamTransformer<List<int>, List<int>>.fromHandlers(
      handleData: (chunk, sink) {
        sent += chunk.length;
        onProgress!(sent / total);
        sink.add(chunk);
      },
    );
    return http.ByteStream(byteStream.transform(transformer));
  }
}
