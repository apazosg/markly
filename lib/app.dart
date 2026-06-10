import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:url_launcher/url_launcher.dart';
import 'features/recording/recording_page.dart';
import 'features/history/history_page.dart';
import 'features/account/account_page.dart';
import 'features/auth/login_page.dart';
import 'shared/theme.dart';
import 'shared/update_service.dart';

class RecorderApp extends StatelessWidget {
  const RecorderApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Markly',
      theme: AppTheme.dark,
      debugShowCheckedModeBanner: false,
      home: StreamBuilder<User?>(
        stream: FirebaseAuth.instance.authStateChanges(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Scaffold(
              body: Center(child: CircularProgressIndicator()),
            );
          }
          if (snapshot.data == null) return const LoginPage();
          return const _MainShell();
        },
      ),
    );
  }
}

class _UpdateBanner extends StatelessWidget {
  final String version;
  final VoidCallback onInstall;
  final VoidCallback onDismiss;

  const _UpdateBanner({
    required this.version,
    required this.onInstall,
    required this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      color: cs.primaryContainer,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          Icon(Icons.system_update_outlined, size: 18, color: cs.onPrimaryContainer),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Nueva versión $version disponible',
              style: TextStyle(color: cs.onPrimaryContainer, fontSize: 13),
            ),
          ),
          TextButton(
            onPressed: onInstall,
            style: TextButton.styleFrom(
              foregroundColor: cs.onPrimaryContainer,
              padding: const EdgeInsets.symmetric(horizontal: 8),
            ),
            child: const Text('Actualizar', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
          IconButton(
            icon: Icon(Icons.close, size: 18, color: cs.onPrimaryContainer),
            onPressed: onDismiss,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
          ),
        ],
      ),
    );
  }
}

class _MainShell extends StatefulWidget {
  const _MainShell();

  @override
  State<_MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<_MainShell> {
  int _selectedIndex = 0;
  UpdateInfo? _pendingUpdate;

  static const _pages = [RecordingPage(), HistoryPage(), AccountPage()];

  @override
  void initState() {
    super.initState();
    _checkUpdate();
  }

  Future<void> _checkUpdate() async {
    final info = await UpdateService.checkForUpdate();
    if (info != null && mounted) {
      setState(() => _pendingUpdate = info);
    }
  }

  Future<void> _installUpdate() async {
    final info = _pendingUpdate;
    if (info == null) return;
    final url = Uri.parse(UpdateService.installUrl(info));
    if (await canLaunchUrl(url)) await launchUrl(url);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(index: _selectedIndex, children: _pages),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _selectedIndex,
        onDestinationSelected: (i) => setState(() => _selectedIndex = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.mic), label: 'Grabar'),
          NavigationDestination(icon: Icon(Icons.history), label: 'Historial'),
          NavigationDestination(icon: Icon(Icons.person_outline), label: 'Cuenta'),
        ],
      ),
      bottomSheet: _pendingUpdate == null
          ? null
          : _UpdateBanner(
              version: _pendingUpdate!.version,
              onInstall: _installUpdate,
              onDismiss: () => setState(() => _pendingUpdate = null),
            ),
    );
  }
}
