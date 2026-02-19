/// Parses and rewrites HLS m3u8 manifests so that all URIs route through the
/// local proxy server, enabling transparent caching of segments and
/// sub-playlists.
class ManifestParser {
  // ---------------------------------------------------------------------------
  // Detection
  // ---------------------------------------------------------------------------

  /// Returns `true` when [content] is a *master* playlist (contains variant
  /// stream references).
  static bool isMasterPlaylist(String content) {
    return content.contains('#EXT-X-STREAM-INF') ||
        content.contains('#EXT-X-I-FRAME-STREAM-INF');
  }

  // ---------------------------------------------------------------------------
  // Master playlist
  // ---------------------------------------------------------------------------

  /// Parse a master playlist, rewriting every variant / I-frame URI to route
  /// through the local proxy.
  static ManifestResult parseMasterPlaylist(
    String content,
    String manifestUrl,
    String proxyBaseUrl,
  ) {
    final lines = content.split('\n');
    final buffer = StringBuffer();
    final variantUrls = <String>[];

    for (int i = 0; i < lines.length; i++) {
      final line = lines[i].trimRight();

      if (line.startsWith('#EXT-X-STREAM-INF')) {
        buffer.writeln(line);
        // Next non-empty line is the variant URI.
        if (i + 1 < lines.length) {
          i++;
          final rawUrl = lines[i].trim();
          if (rawUrl.isEmpty) {
            buffer.writeln(rawUrl);
            continue;
          }
          final absoluteUrl = _resolveUrl(manifestUrl, rawUrl);
          variantUrls.add(absoluteUrl);
          final proxied =
              '/manifest.m3u8?url=${Uri.encodeComponent(absoluteUrl)}';
          buffer.writeln(proxied);
        }
      } else if (line.startsWith('#EXT-X-I-FRAME-STREAM-INF')) {
        // Rewrite the URI= attribute inline.
        buffer.writeln(_rewriteUriAttribute(line, manifestUrl, proxyBaseUrl,
            isManifest: true));
      } else if (line.startsWith('#EXT-X-MEDIA') && line.contains('URI=')) {
        buffer.writeln(_rewriteUriAttribute(line, manifestUrl, proxyBaseUrl,
            isManifest: true));
      } else {
        buffer.writeln(line);
      }
    }

    return ManifestResult(
      rewrittenContent: buffer.toString(),
      segmentUrls: const [],
      variantUrls: variantUrls,
      isMaster: true,
    );
  }

  // ---------------------------------------------------------------------------
  // Media playlist
  // ---------------------------------------------------------------------------

  /// Parse a media (variant) playlist. Segment and init-section URIs are
  /// rewritten to the proxy's `/segment` endpoint.
  static ManifestResult parseMediaPlaylist(
    String content,
    String manifestUrl,
    String proxyBaseUrl,
  ) {
    final lines = content.split('\n');
    final buffer = StringBuffer();
    final segmentUrls = <String>[];

    for (int i = 0; i < lines.length; i++) {
      final line = lines[i].trimRight();

      if (line.startsWith('#EXT-X-MAP')) {
        // Init segment
        final uriMatch = RegExp(r'URI="([^"]+)"').firstMatch(line);
        if (uriMatch != null) {
          final rawUrl = uriMatch.group(1)!;
          final absoluteUrl = _resolveUrl(manifestUrl, rawUrl);
          segmentUrls.add(absoluteUrl);
          
          // Determine extension
          String extension = '.ts';
          final lower = rawUrl.toLowerCase();
          if (lower.endsWith('.mp4')) extension = '.mp4';
          else if (lower.endsWith('.m4s')) extension = '.m4s';
          
          final proxied =
              '/segment$extension?url=${Uri.encodeComponent(absoluteUrl)}';
          buffer.writeln(line.replaceFirst(rawUrl, proxied));
        } else {
          buffer.writeln(line);
        }
      } else if (line.startsWith('#EXT-X-KEY') && line.contains('URI=')) {
        // Encryption key – proxy it as a segment.
        buffer.writeln(_rewriteUriAttribute(line, manifestUrl, proxyBaseUrl,
            isManifest: false));
      } else if (line.startsWith('#')) {
        // Other tags – pass through.
        buffer.writeln(line);
      } else if (line.isNotEmpty) {
        // Segment URL
        final absoluteUrl = _resolveUrl(manifestUrl, line);
        segmentUrls.add(absoluteUrl);
        
        // Determine extension
        String extension = '.ts';
        final lower = line.toLowerCase();
        if (lower.endsWith('.mp4')) extension = '.mp4';
        else if (lower.endsWith('.m4s')) extension = '.m4s';

        final proxied =
            '/segment$extension?url=${Uri.encodeComponent(absoluteUrl)}';
        buffer.writeln(proxied);
      } else {
        buffer.writeln(line);
      }
    }

    return ManifestResult(
      rewrittenContent: buffer.toString(),
      segmentUrls: segmentUrls,
      variantUrls: const [],
      isMaster: false,
    );
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  /// Resolve a possibly-relative [url] against [baseUrl].
  static String _resolveUrl(String baseUrl, String url) {
    if (url.startsWith('http://') || url.startsWith('https://')) return url;
    final base = Uri.parse(baseUrl);
    return base.resolve(url).toString();
  }

  /// Rewrite the `URI="…"` attribute inside an HLS tag line.
  static String _rewriteUriAttribute(
    String line,
    String manifestUrl,
    String proxyBaseUrl, {
    required bool isManifest,
  }) {
    final uriMatch = RegExp(r'URI="([^"]+)"').firstMatch(line);
    if (uriMatch == null) return line;

    final rawUrl = uriMatch.group(1)!;
    final absoluteUrl = _resolveUrl(manifestUrl, rawUrl);
    final endpoint = isManifest ? 'manifest' : 'segment';
    
    // Append extension to help player detection
    String extension = '';
    if (isManifest) {
      extension = '.m3u8';
    } else {
      final lower = rawUrl.toLowerCase();
      if (lower.endsWith('.mp4')) extension = '.mp4';
      else if (lower.endsWith('.m4s')) extension = '.m4s';
      else if (lower.endsWith('.ts')) extension = '.ts';
      else extension = '.ts'; // Default to ts for segments
    }

    // Use relative URL (no scheme/host/port) so it works across restarts/port changes.
    // The player will resolve this against the manifest URL which is on the correct port.
    final proxied =
        '/$endpoint$extension?url=${Uri.encodeComponent(absoluteUrl)}';
    return line.replaceFirst(rawUrl, proxied);
  }
}

/// Result of parsing/rewriting an m3u8 manifest.
class ManifestResult {
  /// The full m3u8 text with all URIs pointing to the local proxy.
  final String rewrittenContent;

  /// Absolute segment URLs extracted from a media playlist.
  final List<String> segmentUrls;

  /// Absolute variant playlist URLs from a master playlist.
  final List<String> variantUrls;

  /// Whether this was a master playlist.
  final bool isMaster;

  const ManifestResult({
    required this.rewrittenContent,
    required this.segmentUrls,
    required this.variantUrls,
    required this.isMaster,
  });
}
