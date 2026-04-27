import 'package:dio/dio.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:html/dom.dart' as dom;

/// Scrapes `https://ollama.com/library` to build a catalog of every model
/// published on the Ollama registry.
///
/// Ollama does not expose a public JSON API for the registry, so this is
/// the only way to discover models the local daemon hasn't pulled yet. The
/// page is server-rendered HTML; we extract one card per model with the
/// information visible online (description, capabilities, parameter sizes,
/// pull count, last-updated label).
///
/// The DOM shape is not contractual — Ollama could redesign the page at
/// any time. Parsing is therefore deliberately tolerant: missing fields
/// degrade to empty strings instead of throwing.
class OllamaLibraryService {
  OllamaLibraryService._();
  static final OllamaLibraryService instance = OllamaLibraryService._();

  static const String libraryUrl = 'https://ollama.com/library';

  final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 30),
      headers: {
        // A real-browser UA avoids the off-chance of being served a bot
        // splash page. We're hitting one URL once per session.
        'User-Agent':
            'Mozilla/5.0 (compatible; hf-chat-flutter/1.0; +https://ollama.com/library)',
        'Accept': 'text/html,application/xhtml+xml',
      },
    ),
  );

  Future<List<OllamaLibraryModel>> fetchLibrary() async {
    final resp = await _dio.get<String>(
      libraryUrl,
      options: Options(responseType: ResponseType.plain),
    );
    if (resp.statusCode != 200 || resp.data == null) {
      throw Exception('ollama.com/library returned ${resp.statusCode}');
    }
    return _parse(resp.data!);
  }

  /// Parse the library HTML. Public so it can be unit-tested with a fixture.
  List<OllamaLibraryModel> _parse(String htmlText) {
    final doc = html_parser.parse(htmlText);
    final out = <OllamaLibraryModel>[];

    // Model cards on /library are anchors that link to /library/<name>.
    // We pick those rather than depending on a specific class name, which
    // makes the parser a bit more redesign-tolerant.
    final anchors = doc.querySelectorAll('a[href^="/library/"]');
    final seen = <String>{};

    for (final a in anchors) {
      final href = a.attributes['href'] ?? '';
      // /library/<name> — anything deeper (tags page, blob URLs) is skipped.
      final name = href.replaceFirst('/library/', '').split('/').first.trim();
      if (name.isEmpty || !seen.add(name)) continue;
      // Skip the link if it doesn't look like a model card (no descendant
      // text — could be a nav anchor, a tag chip, etc.).
      final cardText = a.text.trim();
      if (cardText.isEmpty) continue;

      out.add(_buildModel(name, a));
    }

    out.sort((x, y) => x.name.toLowerCase().compareTo(y.name.toLowerCase()));
    return out;
  }

  OllamaLibraryModel _buildModel(String name, dom.Element card) {
    String firstText(String selector) {
      final el = card.querySelector(selector);
      return el?.text.trim() ?? '';
    }

    // Description: usually a <p> directly inside the card.
    String description = firstText('p');

    // All chip-like spans inside the card. We classify each by its text:
    // - parameter sizes: matches \d+(\.\d+)?[bm] (e.g. 7b, 70b, 1.5b, 270m)
    // - "cloud" or other special-purpose tags
    // - capabilities: tools, vision, thinking, embedding
    // - pull count / updated label end up in a stats list and are pulled
    //   from text patterns instead.
    final chips = <String>[];
    for (final s in card.querySelectorAll('span')) {
      final t = s.text.trim();
      if (t.isEmpty || t.length > 32) continue;
      chips.add(t);
    }

    final sizes = <String>[];
    final capabilities = <String>[];
    final tags = <String>[];
    final sizeRe = RegExp(r'^\d+(\.\d+)?[bm]$', caseSensitive: false);
    const knownCaps = {'tools', 'vision', 'thinking', 'embedding'};
    const knownTagWords = {'cloud'};
    for (final t in chips) {
      final lower = t.toLowerCase();
      if (sizeRe.hasMatch(lower)) {
        if (!sizes.contains(lower)) sizes.add(lower);
      } else if (knownCaps.contains(lower)) {
        if (!capabilities.contains(lower)) capabilities.add(lower);
      } else if (knownTagWords.contains(lower)) {
        if (!tags.contains(lower)) tags.add(lower);
      }
    }

    // Pull count + updated: best-effort regex over the card text. Examples
    // visible on the page: "12.3M Pulls", "Updated 2 weeks ago".
    final blob = card.text;
    final pullsMatch = RegExp(
      r'([\d.,]+\s*[KMB]?)\s*(?:Pulls|pulls|downloads)',
    ).firstMatch(blob);
    final updatedMatch = RegExp(
      r'Updated\s+([^\n•·|]+?)(?=\s{2,}|$|\n)',
      caseSensitive: false,
    ).firstMatch(blob);

    return OllamaLibraryModel(
      name: name,
      description: description,
      sizes: sizes,
      tags: tags,
      capabilities: capabilities,
      pulls: pullsMatch?.group(1)?.trim() ?? '',
      updated: updatedMatch?.group(1)?.trim() ?? '',
      url: 'https://ollama.com/library/$name',
    );
  }
}

/// One model card from `https://ollama.com/library`.
class OllamaLibraryModel {
  final String name;
  final String description;

  /// Parameter-size tags exactly as printed on the site, e.g. `["7b","70b"]`.
  final List<String> sizes;

  /// Special-purpose tags such as `cloud`.
  final List<String> tags;

  /// Capability badges (e.g. `tools`, `vision`, `thinking`, `embedding`).
  final List<String> capabilities;

  /// Human-readable pull count as shown on the page, e.g. `"12.3M"`.
  final String pulls;

  /// Human-readable freshness label, e.g. `"2 weeks ago"`.
  final String updated;

  /// Marketplace URL for the model.
  final String url;

  const OllamaLibraryModel({
    required this.name,
    required this.description,
    required this.sizes,
    required this.tags,
    required this.capabilities,
    required this.pulls,
    required this.updated,
    required this.url,
  });

  bool get isCloud => tags.contains('cloud');
  bool get supportsTools => capabilities.contains('tools');
  bool get supportsVision => capabilities.contains('vision');
  bool get supportsThinking => capabilities.contains('thinking');
  bool get isEmbedding => capabilities.contains('embedding');
}
