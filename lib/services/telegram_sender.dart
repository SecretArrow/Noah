import 'dart:convert';

import 'package:http/http.dart' as http;

/// Telegram Bot API sender (v1.51.0, Fase F). The payload builder and
/// response parser are PURE functions (unit-tested without network);
/// [TelegramSender] itself is a thin http wrapper. The bot token is a
/// user secret: it is only ever placed in the request URL (Telegram's
/// API design), never logged by this class.
class TelegramResult {
  const TelegramResult({required this.ok, required this.message});

  final bool ok;

  /// Short human summary, safe to store as a job's lastStatus.
  final String message;
}

/// Builds the sendMessage payload (chat_id + text), text clamped to
/// Telegram's 4096-char limit.
Map<String, dynamic> buildSendMessagePayload({
  required String chatId,
  required String text,
}) {
  final String trimmed = text.trim();
  return <String, dynamic>{
    'chat_id': chatId.trim(),
    'text': trimmed.length > 4096 ? trimmed.substring(0, 4096) : trimmed,
  };
}

/// Parses a Telegram API response body into a [TelegramResult].
TelegramResult parseTelegramResponse(int statusCode, String body) {
  try {
    final Object? decoded = jsonDecode(body);
    if (decoded is Map<String, dynamic>) {
      if (decoded['ok'] == true) {
        return const TelegramResult(ok: true, message: 'ok');
      }
      final String desc = decoded['description']?.toString() ?? 'error';
      return TelegramResult(ok: false, message: 'error: $desc');
    }
  } catch (_) {
    // Fall through to the status-code summary.
  }
  return TelegramResult(ok: false, message: 'error: HTTP $statusCode');
}

class TelegramSender {
  TelegramSender({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  Future<TelegramResult> send({
    required String botToken,
    required String chatId,
    required String text,
  }) async {
    final String token = botToken.trim();
    if (token.isEmpty || chatId.trim().isEmpty) {
      return const TelegramResult(
        ok: false,
        message: 'error: Telegram bot token / chat id not configured',
      );
    }
    try {
      final http.Response response = await _client
          .post(
            Uri.parse('https://api.telegram.org/bot$token/sendMessage'),
            headers: <String, String>{'Content-Type': 'application/json'},
            body: jsonEncode(
              buildSendMessagePayload(chatId: chatId, text: text),
            ),
          )
          .timeout(const Duration(seconds: 15));
      return parseTelegramResponse(response.statusCode, response.body);
    } catch (e) {
      return TelegramResult(ok: false, message: 'error: $e');
    }
  }
}
