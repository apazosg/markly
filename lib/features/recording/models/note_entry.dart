class NoteEntry {
  final int timestampMs;
  final String text;
  final String? title;

  const NoteEntry({required this.timestampMs, required this.text, this.title});

  String get formattedTimestamp {
    final d = Duration(milliseconds: timestampMs);
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }
}
