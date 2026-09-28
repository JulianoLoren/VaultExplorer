// Offline formatters for TextEditorScreen -- see docs/text editor
// expansion plan, Phase 5. VaultExplorer has no internet permission, so
// every formatter here is a pure, local Dart function; none of them shell
// out or fetch anything.
//
// Hard rule every formatter in this file follows: never change any
// character except leading whitespace. formatJson/minifyJson are the one
// declared exception -- turning a decoded value back into text is the
// whole point of formatting JSON -- but formatMarkup and formatJavaScript
// only ever recompute each line's *indentation*; every other character is
// carried over from the original line untouched. That means a bug in the
// depth-tracking here can produce ugly indentation, but it cannot corrupt
// or delete actual file content, which matters a lot more for a vault
// full of scripts and configs than perfect formatting does.
//
// All four return null to signal "couldn't format this safely" (invalid
// JSON, an unterminated comment/string/tag) rather than guessing --
// TextEditorScreen shows an error and leaves the buffer untouched when
// that happens.
import 'dart:convert';

/// Picks the formatter for [filePath] by extension, or `null` when the
/// file isn't one of the recognized formattable types. Kept next to the
/// formatters themselves so there's one place that knows which extensions
/// map to which of them.
String? Function(String)? formatterFor(String filePath) {
  final dot = filePath.lastIndexOf('.');
  if (dot == -1 || dot == filePath.length - 1) return null;
  switch (filePath.substring(dot + 1).toLowerCase()) {
    case 'json':
    case 'password':
    case 'paymentcard':
    case 'identity':
    case 'securenote':
    case 'bankaccount':
    case 'softwarelicense':
    case 'authenticator':
      return formatJson;
    case 'txt':
    case 'log':
      return formatPlainText;
    case 'md':
    case 'markdown':
      return formatMarkdown;
    case 'html':
    case 'htm':
    case 'xhtml':
    case 'xml':
    case 'svg':
      return formatMarkup;
    case 'js':
    case 'mjs':
    case 'cjs':
      return formatJavaScript;
    default:
      return null;
  }
}

String? formatJson(String input) {
  try {
    final decoded = jsonDecode(input);
    return const JsonEncoder.withIndent('  ').convert(decoded);
  } on FormatException {
    return null;
  }
}

String? minifyJson(String input) {
  try {
    return jsonEncode(jsonDecode(input));
  } on FormatException {
    return null;
  }
}

/// Formats Markdown text while preserving trailing double-spaces that
/// indicate hard line breaks (<br>).
String formatMarkdown(String input) {
  final hadTrailingNewline = input.endsWith('\n') || input.endsWith('\r');
  final normalized = input.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  final rawLines = normalized.split('\n');
  if (hadTrailingNewline && rawLines.isNotEmpty && rawLines.last.isEmpty) {
    rawLines.removeLast();
  }

  final trimmedLines = rawLines.map((line) {
    if (line.endsWith('  ')) {
      final base = line.substring(0, line.length - 2).trimRight();
      return '$base  ';
    }
    return line.trimRight();
  });

  final collapsed = <String>[];
  for (final line in trimmedLines) {
    if (line.isEmpty && collapsed.isNotEmpty && collapsed.last.isEmpty) {
      continue;
    }
    collapsed.add(line);
  }

  final result = collapsed.join('\n');
  return hadTrailingNewline ? '$result\n' : result;
}

/// Trims trailing whitespace on every line, normalizes CRLF/CR line
/// endings to LF, and collapses runs of 2+ consecutive blank lines down
/// to 1. Preserves whether the file ends with a trailing newline.
String formatPlainText(String input) {
  final hadTrailingNewline = input.endsWith('\n') || input.endsWith('\r');
  final normalized = input.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  final rawLines = normalized.split('\n');
  if (hadTrailingNewline && rawLines.isNotEmpty && rawLines.last.isEmpty) {
    // The split() call above leaves a trailing '' for content after the
    // final newline -- that's not a real line, so drop it here and add
    // exactly one newline back at the very end instead.
    rawLines.removeLast();
  }
  final trailingWhitespace = RegExp(r'[ \t]+$');
  final trimmedLines = rawLines.map((line) => line.replaceAll(trailingWhitespace, ''));

  final collapsed = <String>[];
  for (final line in trimmedLines) {
    if (line.isEmpty && collapsed.isNotEmpty && collapsed.last.isEmpty) {
      continue;
    }
    collapsed.add(line);
  }

  final result = collapsed.join('\n');
  return hadTrailingNewline ? '$result\n' : result;
}

const _voidElements = {
  'area', 'base', 'br', 'col', 'embed', 'hr', 'img', 'input',
  'link', 'meta', 'param', 'source', 'track', 'wbr',
};

// script/style/pre/textarea content isn't markup -- running the tag
// tokenizer over embedded JS/CSS (or preformatted text where whitespace is
// meaningful) would corrupt it, so this content is captured verbatim
// between the open and close tags and never touched.
const _rawTextElements = {'script', 'style', 'pre', 'textarea'};

/// Re-indents HTML/XML/SVG by tag nesting depth, one tag or text run per
/// line. Every tag is carried over byte-for-byte (attributes, quoting,
/// casing) -- only its position and the indentation in front of it
/// change. Returns null for anything that doesn't look well-formed enough
/// to track depth safely, rather than guessing.
String? formatMarkup(String input) {
  final buffer = StringBuffer();
  var depth = 0;
  var i = 0;
  final n = input.length;
  var wroteAny = false;

  void emit(String text, int atDepth) {
    if (text.isEmpty) return;
    if (wroteAny) buffer.write('\n');
    wroteAny = true;
    buffer.write('  ' * (atDepth < 0 ? 0 : atDepth));
    buffer.write(text);
  }

  while (i < n) {
    if (input[i] == '<') {
      if (input.startsWith('<!--', i)) {
        final end = input.indexOf('-->', i);
        if (end == -1) return null;
        emit(input.substring(i, end + 3), depth);
        i = end + 3;
      } else if (input.startsWith('<![CDATA[', i)) {
        final end = input.indexOf(']]>', i);
        if (end == -1) return null;
        emit(input.substring(i, end + 3), depth);
        i = end + 3;
      } else if (input.startsWith('<!', i) || input.startsWith('<?', i)) {
        // DOCTYPE, or an XML declaration/processing instruction.
        final end = input.indexOf('>', i);
        if (end == -1) return null;
        emit(input.substring(i, end + 1), depth);
        i = end + 1;
      } else if (i + 1 < n && input[i + 1] == '/') {
        final end = input.indexOf('>', i);
        if (end == -1) return null;
        if (depth > 0) depth--;
        emit(input.substring(i, end + 1), depth);
        i = end + 1;
      } else {
        final end = _findTagEnd(input, i);
        if (end == -1) return null;
        final tagText = input.substring(i, end + 1);
        final selfClosing = tagText.endsWith('/>');
        final name = _tagName(tagText);
        emit(tagText, depth);
        i = end + 1;
        if (selfClosing || _voidElements.contains(name)) {
          continue;
        }
        if (_rawTextElements.contains(name)) {
          final closeMatch = RegExp(
            '</\\s*${RegExp.escape(name)}\\s*>',
            caseSensitive: false,
          ).firstMatch(input.substring(i));
          if (closeMatch == null) return null;
          final closeIndex = i + closeMatch.start;
          final raw = input.substring(i, closeIndex).trim();
          if (raw.isNotEmpty) emit(raw, depth + 1);
          i = closeIndex; // the closing tag itself is handled next loop
        } else {
          depth++;
        }
      }
    } else {
      final nextTag = input.indexOf('<', i);
      final textEnd = nextTag == -1 ? n : nextTag;
      final text = input.substring(i, textEnd).trim();
      if (text.isNotEmpty) emit(text, depth);
      i = textEnd;
    }
  }

  return buffer.toString();
}

/// Finds the '>' that closes the tag starting at [start], respecting
/// quoted attribute values so a stray '>' inside e.g. `title=">"` doesn't
/// end the tag early.
int _findTagEnd(String input, int start) {
  var i = start;
  String? quote;
  while (i < input.length) {
    final c = input[i];
    if (quote != null) {
      if (c == quote) quote = null;
    } else if (c == '"' || c == "'") {
      quote = c;
    } else if (c == '>') {
      return i;
    }
    i++;
  }
  return -1;
}

final _tagNamePattern = RegExp(r'^<\s*([a-zA-Z][a-zA-Z0-9:_-]*)');

String _tagName(String tagText) => _tagNamePattern.firstMatch(tagText)?.group(1)?.toLowerCase() ?? '';

enum _JsScanMode { normal, lineComment, blockComment, string }

/// Re-indents JavaScript by `{`/`(`/`[` .. `}`/`)`/`]` nesting depth, one
/// level of two spaces per level, the way the plan's Auto-Indent Engine
/// already indents new lines as you type. Every character except each
/// line's leading whitespace is carried over untouched.
///
/// Known, accepted gap: distinguishing a regex literal's `/` from
/// division needs tracking the previous token, which this lightweight
/// scanner doesn't do -- brackets inside a regex literal (`/[{}]/`) can
/// throw off the depth count for lines after it. That's a
/// wrong-indentation bug, not a content-corrupting one: nothing this
/// function does can alter what's actually on any line, only how far in
/// it starts.
String? formatJavaScript(String input) {
  final n = input.length;
  final lineStartDepths = <int>[0];
  var depth = 0;
  var mode = _JsScanMode.normal;
  var stringQuote = '';
  var i = 0;

  while (i < n) {
    final c = input[i];
    switch (mode) {
      case _JsScanMode.normal:
        if (c == '/' && i + 1 < n && input[i + 1] == '/') {
          mode = _JsScanMode.lineComment;
          i += 2;
          continue;
        } else if (c == '/' && i + 1 < n && input[i + 1] == '*') {
          mode = _JsScanMode.blockComment;
          i += 2;
          continue;
        } else if (c == '"' || c == "'" || c == '`') {
          mode = _JsScanMode.string;
          stringQuote = c;
          i++;
          continue;
        } else if (c == '{' || c == '(' || c == '[') {
          depth++;
        } else if (c == '}' || c == ')' || c == ']') {
          if (depth > 0) depth--;
        } else if (c == '\n') {
          lineStartDepths.add(depth);
        }
        i++;
        break;
      case _JsScanMode.lineComment:
        if (c == '\n') {
          mode = _JsScanMode.normal;
          lineStartDepths.add(depth);
        }
        i++;
        break;
      case _JsScanMode.blockComment:
        if (c == '*' && i + 1 < n && input[i + 1] == '/') {
          mode = _JsScanMode.normal;
          i += 2;
          continue;
        }
        if (c == '\n') lineStartDepths.add(depth);
        i++;
        break;
      case _JsScanMode.string:
        if (c == '\\' && i + 1 < n) {
          i += 2;
          continue;
        }
        if (c == stringQuote) {
          mode = _JsScanMode.normal;
          i++;
          continue;
        }
        if (c == '\n') {
          // A raw newline inside a ' or " string is invalid JS -- rather
          // than guess at malformed input, bail out. Template literals
          // (`) legitimately span lines, so only bail for the other two.
          if (stringQuote != '`') return null;
          lineStartDepths.add(depth);
        }
        i++;
    }
  }
  if (mode == _JsScanMode.string || mode == _JsScanMode.blockComment) {
    return null; // unterminated string or comment
  }

  final lines = input.split('\n');
  if (lineStartDepths.length < lines.length) {
    return null; // shouldn't happen given the scan above, but don't guess
  }

  final buffer = StringBuffer();
  for (var idx = 0; idx < lines.length; idx++) {
    if (idx > 0) buffer.write('\n');
    final trimmed = lines[idx].trim();
    if (trimmed.isEmpty) continue;
    var lineDepth = lineStartDepths[idx];
    if (trimmed.startsWith('}') || trimmed.startsWith(')') || trimmed.startsWith(']')) {
      lineDepth = lineDepth > 0 ? lineDepth - 1 : 0;
    }
    buffer.write('  ' * lineDepth);
    buffer.write(trimmed);
  }

  return buffer.toString();
}
