// IFSC code lookup — resolves a bank IFSC to bank name + branch
// using Razorpay's free public directory API.
//
//   GET https://ifsc.razorpay.com/<IFSC>
//
// The API returns a JSON object with the bank metadata when the
// IFSC is valid, or HTTP 404 when it isn't. No API key, no auth,
// no rate-limit headers documented — Razorpay publishes this as a
// community utility.
//
// We use dart:io HttpClient instead of pulling in the `http`
// package to avoid adding a dependency for a single GET call. The
// per-IFSC result is memoised in a process-lifetime cache so the
// priest re-editing the bank details page doesn't pay the
// round-trip a second time.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

class IfscLookupResult {
  final String bankName;
  final String branchName;
  final String city;
  final String state;

  const IfscLookupResult({
    required this.bankName,
    required this.branchName,
    required this.city,
    required this.state,
  });
}

class IfscLookupService {
  // Process-lifetime cache. Tiny — a typical priest looks up one or
  // two IFSCs in their lifetime, so an unbounded map is safe.
  // Keyed by the normalised (upper-cased) IFSC string.
  static final Map<String, IfscLookupResult> _cache = {};

  // Tracks the most recent in-flight lookup so a debounce caller
  // can ignore stale responses if the user keeps editing the field.
  static int _requestSeq = 0;

  /// Returns the metadata for `ifsc` or `null` if the code isn't
  /// known to the directory (404) or the network call fails. Never
  /// throws — bank-name autofill is a convenience, not a gate.
  ///
  /// Pass a [timeout] tighter than the default 5 s if the caller has
  /// its own snappier UX deadline.
  static Future<IfscLookupResult?> lookup(
    String ifsc, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final normalised = ifsc.trim().toUpperCase();
    if (normalised.length != 11) return null;

    final cached = _cache[normalised];
    if (cached != null) return cached;

    final mySeq = ++_requestSeq;

    HttpClient? client;
    try {
      client = HttpClient()
        ..connectionTimeout = timeout
        ..idleTimeout = const Duration(seconds: 1);
      final uri = Uri.parse('https://ifsc.razorpay.com/$normalised');
      final req = await client.getUrl(uri).timeout(timeout);
      final resp = await req.close().timeout(timeout);

      // A stale request fired before the user kept typing — drop it.
      // We still let the network call complete (so the connection
      // pool stays warm), we just don't return its data to the
      // caller.
      if (mySeq != _requestSeq) return null;

      if (resp.statusCode != 200) return null;

      final body = await resp
          .transform(utf8.decoder)
          .join()
          .timeout(timeout);

      final json = jsonDecode(body) as Map<String, dynamic>;

      final result = IfscLookupResult(
        bankName: (json['BANK'] as String?)?.trim() ?? '',
        branchName: (json['BRANCH'] as String?)?.trim() ?? '',
        city: (json['CITY'] as String?)?.trim() ?? '',
        state: (json['STATE'] as String?)?.trim() ?? '',
      );

      // Only cache positive hits — a transient network failure for
      // a valid IFSC shouldn't poison the cache.
      if (result.bankName.isNotEmpty) {
        _cache[normalised] = result;
      }

      return result;
    } on TimeoutException {
      return null;
    } on SocketException {
      return null;
    } on FormatException {
      // Malformed JSON — directory bug or HTML error page. Treat
      // the same as "not found" so the priest can still proceed by
      // typing the bank name manually.
      return null;
    } catch (_) {
      return null;
    } finally {
      client?.close(force: true);
    }
  }
}
