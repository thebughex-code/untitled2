/// Payload for passing arguments to isolate compute functions
class ManifestParsePayload {
  final String content;
  final String manifestUrl;
  final String proxyBaseUrl;

  const ManifestParsePayload(this.content, this.manifestUrl, this.proxyBaseUrl);
}

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
}

/// Internal helper class to sort HLS variants by Bandwidth for zero-latency booting.
class _Variant {
  final int bandwidth;
  final String streamInfLine;
  final String proxiedUrlLine;
  final String absoluteUrl;

  _Variant({
    required this.bandwidth,
    required this.streamInfLine,
    required this.proxiedUrlLine,
    required this.absoluteUrl,
  });
}

// ---------------------------------------------------------------------------
// Isolate-safe top-level parse functions
// ---------------------------------------------------------------------------

/// Parse a master playlist, rewriting every variant / I-frame URI to route
/// through the local proxy. Safe to run in `compute()`.
ManifestResult parseMasterPlaylistIsolate(ManifestParsePayload payload) {
  final content = payload.content;
  final manifestUrl = payload.manifestUrl;
  final proxyBaseUrl = payload.proxyBaseUrl;

    final lines = content.split('\n');
    final buffer = StringBuffer();
    final variants = <_Variant>[];

    for (int i = 0; i < lines.length; i++) {
      final line = lines[i].trimRight();

      if (line.startsWith('#EXT-X-STREAM-INF')) {
        // Extract Bandwidth mathematically for sorting.
        // Default to a massive number (999M) so unparsed variants fall to the bottom.
        int bandwidth = 999000000;
        final bwMatch = RegExp(r'BANDWIDTH=(\d+)').firstMatch(line);
        if (bwMatch != null) {
          bandwidth = int.tryParse(bwMatch.group(1) ?? '') ?? 999000000;
        }

        // Next non-empty line is the variant URI.
        if (i + 1 < lines.length) {
          i++;
          final rawUrl = lines[i].trim();
          if (rawUrl.isEmpty) {
            continue;
          }
          final absoluteUrl = _resolveUrl(manifestUrl, rawUrl);
          final proxied =
              '/manifest.m3u8?url=${Uri.encodeComponent(absoluteUrl)}';

          // Store the variant logic in memory instead of writing it directly
          variants.add(_Variant(
            bandwidth: bandwidth,
            streamInfLine: line,
            proxiedUrlLine: proxied,
            absoluteUrl: absoluteUrl,
          ));
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

    // ── The TikTok Sorting Hack ──
    // Sort all discovered variants by BANDWIDTH ASCENDING (Lowest to Highest).
    // By artificially re-writing the Master Playlist to list 144p/240p as the
    // very first stream, we force the ExoPlayer engine and Preloader to legally
    // download the microscopic 100KB segment FIRST instead of a 20MB 4K segment.
    // This allows the video to boot on 3G/Edge instantly.
    variants.sort((a, b) => a.bandwidth.compareTo(b.bandwidth));

    for (final variant in variants) {
      buffer.writeln(variant.streamInfLine);
      buffer.writeln(variant.proxiedUrlLine);
    }

    return ManifestResult(
      rewrittenContent: buffer.toString(),
      segmentUrls: const [],
      variantUrls: variants.map((v) => v.absoluteUrl).toList(),
      isMaster: true,
    );
}

// ---------------------------------------------------------------------------
// Media playlist
// ---------------------------------------------------------------------------

/// Parse a media (variant) playlist. Segment and init-section URIs are
/// rewritten to the proxy's `/segment` endpoint. Safe to run in `compute()`.
ManifestResult parseMediaPlaylistIsolate(ManifestParsePayload payload) {
  final content = payload.content;
  final manifestUrl = payload.manifestUrl;
  final proxyBaseUrl = payload.proxyBaseUrl;
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
          if (lower.endsWith('.mp4')) {
            extension = '.mp4';
          } else if (lower.endsWith('.m4s')) {
            extension = '.m4s';
          }
          
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
        if (lower.endsWith('.mp4')) {
          extension = '.mp4';
        } else if (lower.endsWith('.m4s')) {
          extension = '.m4s';
        }

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
String _resolveUrl(String baseUrl, String url) {
    if (url.startsWith('http://') || url.startsWith('https://')) return url;
    final base = Uri.parse(baseUrl);
    return base.resolve(url).toString();
  }

/// Rewrite the `URI="…"` attribute inside an HLS tag line.
String _rewriteUriAttribute(
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
      if (lower.endsWith('.mp4')) {
        extension = '.mp4';
      } else if (lower.endsWith('.m4s')) {
        extension = '.m4s';
      } else if (lower.endsWith('.ts')) {
        extension = '.ts';
      } else {
        extension = '.ts'; // Default to ts for segments
      }
    }

    // Use relative URL (no scheme/host/port) so it works across restarts/port changes.
    // The player will resolve this against the manifest URL which is on the correct port.
    final proxied =
        '/$endpoint$extension?url=${Uri.encodeComponent(absoluteUrl)}';
    return line.replaceFirst(rawUrl, proxied);
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
