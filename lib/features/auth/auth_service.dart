import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

// OAuth2 Desktop client (GCP → Credentials → OAuth 2.0 → Desktop app).
// El secret se inyecta en build via --dart-define=GOOGLE_DESKTOP_CLIENT_SECRET=...
const _kWindowsClientId =
    '169364452296-h3elfg2ebbh939ntkanvbm3bf7o035li.apps.googleusercontent.com';
const _kWindowsClientSecret =
    String.fromEnvironment('GOOGLE_DESKTOP_CLIENT_SECRET');

class AuthService {
  static final AuthService _instance = AuthService._();
  factory AuthService() => _instance;
  AuthService._();

  final _auth = FirebaseAuth.instance;
  final _google = GoogleSignIn(
    clientId: '169364452296-p4641gjh9k1ok6lnf120ptthbr8poo0q.apps.googleusercontent.com',
  );

  Stream<User?> get userStream => _auth.authStateChanges();
  User? get currentUser => _auth.currentUser;

  Future<UserCredential?> signInWithGoogle() async {
    if (!kIsWeb && Platform.isWindows) return _signInWindowsPkce();
    final account = await _google.signIn();
    if (account == null) return null;
    final googleAuth = await account.authentication;
    final credential = GoogleAuthProvider.credential(
      accessToken: googleAuth.accessToken,
      idToken: googleAuth.idToken,
    );
    return _auth.signInWithCredential(credential);
  }

  Future<void> signOut() async {
    if (!kIsWeb && Platform.isWindows) {
      await _auth.signOut();
      return;
    }
    await Future.wait([_google.signOut(), _auth.signOut()]);
  }

  // ---------------------------------------------------------------------------
  // PKCE OAuth2 para Windows desktop
  // ---------------------------------------------------------------------------

  Future<UserCredential?> _signInWindowsPkce() async {
    final verifier = _codeVerifier();
    final challenge = _codeChallenge(verifier);

    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final redirectUri = 'http://localhost:${server.port}';

    final authUrl = Uri.https('accounts.google.com', '/o/oauth2/v2/auth', {
      'client_id': _kWindowsClientId,
      'redirect_uri': redirectUri,
      'response_type': 'code',
      'scope': 'openid email profile',
      'code_challenge': challenge,
      'code_challenge_method': 'S256',
    });

    await launchUrl(authUrl, mode: LaunchMode.externalApplication);

    String? code;
    await for (final req in server) {
      code = req.uri.queryParameters['code'];
      req.response
        ..statusCode = 200
        ..headers.set('content-type', 'text/html; charset=utf-8')
        ..write(
          '<html><body style="font-family:sans-serif;padding:2em">'
          '<h2>✓ Autenticación completada</h2>'
          '<p>Puedes cerrar esta pestaña y volver a Markly.</p>'
          '</body></html>',
        );
      await req.response.close();
      break;
    }
    await server.close();
    if (code == null) return null;

    final tokenRes = await http.post(
      Uri.https('oauth2.googleapis.com', '/token'),
      headers: {'content-type': 'application/x-www-form-urlencoded'},
      body: {
        'code': code,
        'client_id': _kWindowsClientId,
        'client_secret': _kWindowsClientSecret,
        'redirect_uri': redirectUri,
        'grant_type': 'authorization_code',
        'code_verifier': verifier,
      },
    );

    final tokenData = json.decode(tokenRes.body) as Map<String, dynamic>;
    final idToken = tokenData['id_token'] as String?;
    if (idToken == null) {
      throw Exception('Google OAuth: no id_token — ${tokenRes.body}');
    }

    return _auth.signInWithCredential(
      GoogleAuthProvider.credential(idToken: idToken),
    );
  }

  static String _codeVerifier() {
    const chars =
        'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~';
    final rng = Random.secure();
    return List.generate(64, (_) => chars[rng.nextInt(chars.length)]).join();
  }

  static String _codeChallenge(String verifier) {
    final digest = sha256.convert(utf8.encode(verifier));
    return base64Url.encode(digest.bytes).replaceAll('=', '');
  }
}
