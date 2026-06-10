import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../../shared/api_service.dart';

class AccountPage extends StatefulWidget {
  const AccountPage({super.key});

  @override
  State<AccountPage> createState() => _AccountPageState();
}

class _AccountPageState extends State<AccountPage> {
  bool _loading = true;
  String? _error;
  Map<String, dynamic>? _summary;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final data = await ApiService().getUsageSummary();
      setState(() {
        _summary = data;
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Cuenta'),
        actions: [
          IconButton(
            icon: const Icon(Icons.logout),
            tooltip: 'Cerrar sesión',
            onPressed: () => FirebaseAuth.instance.signOut(),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _UserCard(user: user),
            const SizedBox(height: 16),
            if (_loading)
              const Center(child: CircularProgressIndicator())
            else if (_error != null)
              _ErrorCard(error: _error!, onRetry: _load)
            else
              _UsageCard(summary: _summary!),
          ],
        ),
      ),
    );
  }
}

class _UserCard extends StatelessWidget {
  final User? user;
  const _UserCard({required this.user});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListTile(
        leading: const Icon(Icons.account_circle, size: 40),
        title: Text(user?.displayName ?? user?.email ?? 'Usuario'),
        subtitle: user?.email != null && user?.displayName != null
            ? Text(user!.email!)
            : null,
      ),
    );
  }
}

class _ErrorCard extends StatelessWidget {
  final String error;
  final VoidCallback onRetry;
  const _ErrorCard({required this.error, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Text('Error al cargar datos: $error',
                style: TextStyle(color: Theme.of(context).colorScheme.error)),
            const SizedBox(height: 8),
            TextButton(onPressed: onRetry, child: const Text('Reintentar')),
          ],
        ),
      ),
    );
  }
}

class _UsageCard extends StatelessWidget {
  final Map<String, dynamic> summary;
  const _UsageCard({required this.summary});

  @override
  Widget build(BuildContext context) {
    final months = (summary['months'] as List?)?.cast<Map<String, dynamic>>() ?? [];
    final currentMonth = summary['current_month'] as String? ?? '';
    final free = (summary['free_credits_per_month'] as num?)?.toDouble() ?? 30.0;
    final used = (summary['credits_used_this_month'] as num?)?.toDouble() ?? 0.0;
    final remaining = (summary['credits_remaining'] as num?)?.toDouble() ?? free;
    final progress = (used / free).clamp(0.0, 1.0);

    final currentData = months.where((m) => m['month'] == currentMonth).firstOrNull;
    final deepgramCredits = (currentData?['deepgram'] as num?)?.toDouble() ?? 0.0;
    final geminiCredits = (currentData?['gemini'] as num?)?.toDouble() ?? 0.0;

    final colorScheme = Theme.of(context).colorScheme;
    final isExhausted = remaining == 0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('Créditos este mes',
                        style: Theme.of(context).textTheme.titleMedium),
                    Text(
                      '${remaining.round()} / ${free.round()}',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            color: isExhausted
                                ? colorScheme.error
                                : colorScheme.primary,
                            fontWeight: FontWeight.bold,
                          ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: progress,
                    minHeight: 8,
                    backgroundColor: colorScheme.surfaceContainerHighest,
                    color: isExhausted ? colorScheme.error : colorScheme.primary,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  isExhausted
                      ? 'Sin créditos disponibles este mes'
                      : '${remaining.round()} créditos restantes · ${remaining.round()} min aprox.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: isExhausted
                            ? colorScheme.error
                            : colorScheme.onSurfaceVariant,
                      ),
                ),
                const Divider(height: 24),
                Row(
                  children: [
                    Expanded(
                      child: _StatItem(
                        label: 'Transcripción',
                        value: deepgramCredits.round().toString(),
                        subtitle: 'créditos',
                      ),
                    ),
                    Expanded(
                      child: _StatItem(
                        label: 'Análisis IA',
                        value: deepgramCredits + geminiCredits > 0
                            ? geminiCredits.round().toString()
                            : '—',
                        subtitle: deepgramCredits + geminiCredits > 0
                            ? 'créditos'
                            : null,
                      ),
                    ),
                    Expanded(
                      child: _StatItem(
                        label: 'Total usado',
                        value: used.round().toString(),
                        subtitle: 'créditos',
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        if (months.where((m) => m['month'] != currentMonth).isNotEmpty) ...[
          const SizedBox(height: 16),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text('Historial mensual',
                style: Theme.of(context).textTheme.titleSmall),
          ),
          const SizedBox(height: 8),
          Card(
            child: Column(
              children: months.reversed
                  .where((m) => m['month'] != currentMonth)
                  .map((m) => _MonthRow(data: m))
                  .toList(),
            ),
          ),
        ],
      ],
    );
  }
}

class _StatItem extends StatelessWidget {
  final String label;
  final String value;
  final String? subtitle;
  const _StatItem({required this.label, required this.value, this.subtitle});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant)),
        const SizedBox(height: 2),
        Text(value,
            style: Theme.of(context)
                .textTheme
                .headlineSmall
                ?.copyWith(fontWeight: FontWeight.bold)),
        if (subtitle != null)
          Text(subtitle!,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant)),
      ],
    );
  }
}

class _MonthRow extends StatelessWidget {
  final Map<String, dynamic> data;
  const _MonthRow({required this.data});

  @override
  Widget build(BuildContext context) {
    final month = data['month'] as String? ?? '';
    final total = (data['total'] as num?)?.toStringAsFixed(2) ?? '0.00';
    return ListTile(
      dense: true,
      title: Text(month),
      trailing: Text('$total cr',
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant)),
    );
  }
}
