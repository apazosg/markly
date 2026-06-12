/// Normaliza markdown generado por el modelo para que el parser CommonMark
/// (flutter_markdown_plus) lo renderice como se espera.
///
/// El fallo más habitual: una lista que viene pegada a la línea anterior (un
/// nombre en negrita, un encabezado, un párrafo) sin línea en blanco de
/// separación. CommonMark engancha esas líneas y "se come" el salto, sobre
/// todo en listas de varios niveles. Insertamos una línea en blanco antes del
/// primer ítem de cada bloque de lista cuando la línea previa no es lista.
final _listItem = RegExp(r'^\s*([-*+]|\d+[.)])\s+');
final _fence = RegExp(r'^\s*(```|~~~)');

String normalizeMarkdown(String input) {
  final lines = input.split('\n');
  final out = <String>[];
  var inFence = false;

  for (final line in lines) {
    if (_fence.hasMatch(line)) {
      inFence = !inFence;
      out.add(line);
      continue;
    }

    if (!inFence && out.isNotEmpty) {
      final prev = out.last;
      final prevIsBlank = prev.trim().isEmpty;
      final prevIsList = _listItem.hasMatch(prev);
      final isList = _listItem.hasMatch(line);
      final isIndented = line.startsWith(' ') || line.startsWith('\t');

      // Lista que cuelga de una línea normal (negrita, encabezado, párrafo).
      if (isList && !prevIsBlank && !prevIsList) {
        out.add('');
      }
      // Línea normal pegada al final de una lista: CommonMark la absorbería
      // como continuación del último ítem. La separamos (si no está indentada,
      // para no romper continuaciones ni ítems anidados).
      else if (!isList && !isIndented && line.trim().isNotEmpty && prevIsList) {
        out.add('');
      }
    }

    out.add(line);
  }

  return out.join('\n');
}
