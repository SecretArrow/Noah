import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../di.dart';
import '../../l10n/app_strings.dart';
import '../../models/models.dart';
import '../theme.dart';

/// Global chat search (v1.15.0): one query box scanning every stored
/// conversation (titles + message contents). Results open the matching
/// chat. The query is debounced (300 ms) so typing stays smooth, and the
/// disk scan is capped (`ChatStore.searchAll`) so huge histories cannot
/// freeze the screen.
class SearchScreen extends ConsumerStatefulWidget {
  const SearchScreen({super.key});

  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen> {
  final TextEditingController _controller = TextEditingController();
  Timer? _debounce;
  int _seq = 0;
  bool _loading = false;

  /// False until the first search ran — keeps the "no results" state from
  /// showing on the untouched screen.
  bool _searched = false;
  String _lastQuery = '';
  List<ChatSearchHit> _results = const <ChatSearchHit>[];

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onChanged(String value) {
    _debounce?.cancel();
    if (value.trim().isEmpty) {
      setState(() {
        _results = const <ChatSearchHit>[];
        _searched = false;
        _loading = false;
      });
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 300), _runSearch);
  }

  Future<void> _runSearch() async {
    final String query = _controller.text.trim();
    if (query.isEmpty) return;
    final int token = ++_seq;
    setState(() => _loading = true);
    try {
      final List<ChatSearchHit> hits = await ref
          .read(chatStoreProvider)
          .searchAll(query);
      if (!mounted || token != _seq) return; // superseded by a newer query
      setState(() {
        _results = hits;
        _lastQuery = query;
        _searched = true;
        _loading = false;
      });
    } catch (_) {
      if (!mounted || token != _seq) return;
      // Storage failure degrades to "no results", never a crash.
      setState(() {
        _results = const <ChatSearchHit>[];
        _lastQuery = query;
        _searched = true;
        _loading = false;
      });
    }
  }

  Future<void> _openHit(ChatSearchHit hit) async {
    // v1.48.0: the chat-switch IP guard may interrupt with a confirmation
    // dialog when the current public IP equals the last one recorded for
    // the TARGET chat. Cancelling aborts the switch and keeps the search
    // screen open with NO navigation.
    final bool allowed = await ref
        .read(ipGuardProvider)
        .confirmChatSwitch(context, ref, hit.sessionId);
    if (!allowed || !mounted) return;
    ref
        .read(chatControllerProvider.notifier)
        .openChat(
          ChatSummary(
            id: hit.sessionId,
            title: hit.title,
            updatedAt: hit.createdAt,
          ),
        );
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final AppStrings strings = stringsOf(context);
    return Scaffold(
      appBar: AppBar(title: Text(strings.searchChats)),
      body: Column(
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: TextField(
              key: const Key('search-field'),
              controller: _controller,
              autofocus: true,
              onChanged: _onChanged,
              decoration: InputDecoration(
                hintText: strings.searchHint,
                prefixIcon: const Icon(Icons.search_rounded, size: 20),
                isDense: true,
                suffixIcon: _loading
                    ? const Padding(
                        padding: EdgeInsets.all(12),
                        child: SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      )
                    : null,
              ),
            ),
          ),
          Expanded(
            child: !_searched
                ? _InitialHint()
                : _results.isEmpty
                ? Center(
                    child: Text(
                      strings.noSearchResults,
                      style: TextStyle(color: context.zMuted, fontSize: 13),
                    ),
                  )
                : PagedHits(
                    hits: _results,
                    query: _lastQuery,
                    onOpen: _openHit,
                  ),
          ),
        ],
      ),
    );
  }
}

/// Quiet hint shown before the first query.
class _InitialHint extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final AppStrings strings = stringsOf(context);
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          Icon(Icons.search_rounded, size: 44, color: context.zMuted),
          const SizedBox(height: 16),
          Text(
            strings.searchInitialHint,
            textAlign: TextAlign.center,
            style: TextStyle(color: context.zMuted),
          ),
        ],
      ),
    );
  }
}

/// Paged result list following the app-wide [listPageSize] convention.
class PagedHits extends StatefulWidget {
  const PagedHits({
    super.key,
    required this.hits,
    required this.query,
    required this.onOpen,
  });

  final List<ChatSearchHit> hits;

  /// The active query — used to bold the matched substring in snippets.
  final String query;
  final ValueChanged<ChatSearchHit> onOpen;

  @override
  State<PagedHits> createState() => _PagedHitsState();
}

class _PagedHitsState extends State<PagedHits> {
  int _page = 0;

  @override
  Widget build(BuildContext context) {
    final AppStrings strings = stringsOf(context);
    final int pageCount = (widget.hits.length / listPageSize).ceil();
    final int current = _page.clamp(0, pageCount - 1);
    final int start = current * listPageSize;
    final List<ChatSearchHit> slice = widget.hits
        .skip(start)
        .take(listPageSize)
        .toList();

    return Column(
      children: <Widget>[
        Expanded(
          child: ListView.builder(
            key: Key('search-list-page-$current'),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            itemCount: slice.length,
            itemBuilder: (BuildContext context, int index) {
              final ChatSearchHit hit = slice[index];
              return Container(
                margin: const EdgeInsets.only(bottom: 8),
                decoration: BoxDecoration(
                  color: context.zSurface,
                  borderRadius: BorderRadius.circular(kCardRadius),
                  border: Border.all(color: context.zBorder),
                ),
                child: Material(
                  // Interactive ListTile inside a decorated Container needs
                  // its own Material or the ink splashes (and the framework
                  // assertion) break.
                  type: MaterialType.transparency,
                  child: ListTile(
                    key: Key('search-hit-${hit.sessionId}-$start-$index'),
                    onTap: () => widget.onOpen(hit),
                    leading: const Icon(
                      Icons.chat_bubble_outline_rounded,
                      size: 18,
                      color: kMutedTextColor,
                    ),
                    title: Text(
                      hit.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        const SizedBox(height: 2),
                        _HighlightedSnippet(
                          snippet: hit.snippet,
                          query: widget.query,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '${hit.createdAt.day}/${hit.createdAt.month}/${hit.createdAt.year}',
                          style: TextStyle(fontSize: 11, color: context.zMuted),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
        if (pageCount > 1)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            child: Row(
              children: <Widget>[
                IconButton(
                  key: Key('search-page-prev'),
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.chevron_left_rounded, size: 22),
                  onPressed: current > 0
                      ? () => setState(() => _page = current - 1)
                      : null,
                ),
                Expanded(
                  child: Text(
                    strings.pageIndicator(current + 1, pageCount),
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 12,
                      color: context.zMuted,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                IconButton(
                  key: Key('search-page-next'),
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.chevron_right_rounded, size: 22),
                  onPressed: current < pageCount - 1
                      ? () => setState(() => _page = current + 1)
                      : null,
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// Renders the snippet with the matching substring bolded (simple, greppy,
/// and testable through the RichText's plain text).
class _HighlightedSnippet extends StatelessWidget {
  const _HighlightedSnippet({required this.snippet, required this.query});

  final String snippet;
  final String query;

  @override
  Widget build(BuildContext context) {
    final String q = query.toLowerCase();
    final String lower = snippet.toLowerCase();
    final int index = q.isEmpty ? -1 : lower.indexOf(q);
    if (index < 0) {
      return Text(
        snippet,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 12, color: context.zMuted),
      );
    }
    return Text.rich(
      TextSpan(
        children: <InlineSpan>[
          TextSpan(text: snippet.substring(0, index)),
          TextSpan(
            text: snippet.substring(index, index + q.length),
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          TextSpan(text: snippet.substring(index + q.length)),
        ],
      ),
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(fontSize: 12, color: context.zMuted),
    );
  }
}
