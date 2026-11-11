import 'package:flutter/material.dart';

import '../../l10n/app_strings.dart';
import '../../models/models.dart';
import '../theme.dart';

/// Reusable searchable + paged list used by EVERY list surface in the app
/// (model picker dropdown, fetched model list, providers, chat history,
/// file manager, context manager, npm libraries).
///
/// Contract:
/// * max [listPageSize] (5) items per page so the UI stays comfortable;
/// * a search box on top (optional via [showSearch]) filtering through
///   [filter] — page resets automatically whenever the query or
///   [resetKey] changes (external filters like the picker's chips);
/// * `first / prev / page x of y / next / last` pager, shown only when
///   more than one page exists;
/// * stable test keys: `<prefix>-page-first|prev|next|last` for the pager
///   buttons and `<prefix>-list-page-<n>` for the visible page list.
class PagedList<T> extends StatefulWidget {
  const PagedList({
    super.key,
    required this.items,
    required this.itemBuilder,
    this.filter,
    this.pageSize = listPageSize,
    this.showSearch = true,
    this.searchHint,
    this.searchFieldKey,
    this.prefix = 'paged',
    this.resetKey,
    this.emptyBuilder,
    this.header = const <Widget>[],
    this.footer = const <Widget>[],
    this.padding = const EdgeInsets.all(16),
  });

  /// Full item list (unfiltered).
  final List<T> items;

  /// Builds one row for an item.
  final Widget Function(BuildContext context, T item) itemBuilder;

  /// Case-insensitive match used when the search query is not empty.
  final bool Function(T item, String query)? filter;

  /// Items per page (defaults to [listPageSize] = 5).
  final int pageSize;

  /// Whether the built-in search field is rendered.
  final bool showSearch;

  /// Hint of the built-in search field.
  final String? searchHint;

  /// Key of the built-in search field.
  final Key? searchFieldKey;

  /// Prefix for the pager/list test keys.
  final String prefix;

  /// When this value changes the page resets to 0 (used by owners that
  /// keep their own search/filter state, like the model picker chips).
  final Object? resetKey;

  /// Shown instead of the list when nothing matches (or [items] is empty).
  final WidgetBuilder? emptyBuilder;

  /// Widgets rendered above the search field (cards, hints, counters...).
  final List<Widget> header;

  /// Widgets rendered below the pager (bottom buttons...).
  final List<Widget> footer;

  /// Padding of the scrollable list area.
  final EdgeInsets padding;

  @override
  State<PagedList<T>> createState() => _PagedListState<T>();
}

class _PagedListState<T> extends State<PagedList<T>> {
  final TextEditingController _search = TextEditingController();
  String _query = '';
  int _page = 0;
  Object? _lastReset;

  @override
  void initState() {
    super.initState();
    _lastReset = widget.resetKey;
  }

  @override
  void didUpdateWidget(covariant PagedList<T> old) {
    super.didUpdateWidget(old);
    if (widget.resetKey != old.resetKey || widget.resetKey != _lastReset) {
      _lastReset = widget.resetKey;
      if (_page != 0) _page = 0;
    }
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  List<T> get _filtered {
    final String q = _query.trim().toLowerCase();
    if (q.isEmpty) return widget.items;
    // Without an explicit filter, fall back to a sensible default: match
    // the item's text representation (works for plain String lists and
    // any type with a meaningful toString).
    final bool Function(T, String) match =
        widget.filter ??
        (T item, String query) => item.toString().toLowerCase().contains(query);
    return widget.items.where((T item) => match(item, q)).toList();
  }

  void _setQuery(String value) {
    setState(() {
      _query = value;
      _page = 0;
    });
  }

  @override
  Widget build(BuildContext context) {
    final AppStrings strings = stringsOf(context);
    final List<T> filtered = _filtered;
    final int pageCount = filtered.isEmpty
        ? 1
        : (filtered.length / widget.pageSize).ceil();
    final int current = _page.clamp(0, pageCount - 1);
    final int start = current * widget.pageSize;
    final List<T> slice = filtered.skip(start).take(widget.pageSize).toList();

    return Column(
      children: <Widget>[
        for (final Widget w in widget.header) w,
        if (widget.showSearch)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: TextField(
              key: widget.searchFieldKey,
              controller: _search,
              onChanged: _setQuery,
              decoration: InputDecoration(
                hintText: widget.searchHint ?? strings.searchModelsHint,
                prefixIcon: const Icon(Icons.search_rounded, size: 20),
                isDense: true,
                suffixIcon: _query.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.close_rounded, size: 18),
                        onPressed: () {
                          _search.clear();
                          _setQuery('');
                        },
                      ),
              ),
            ),
          ),
        Expanded(
          child: slice.isEmpty
              ? (widget.emptyBuilder?.call(context) ?? const SizedBox.shrink())
              : ListView.builder(
                  key: Key('${widget.prefix}-list-page-$current'),
                  padding: widget.padding,
                  itemCount: slice.length,
                  itemBuilder: (BuildContext context, int index) =>
                      widget.itemBuilder(context, slice[index]),
                ),
        ),
        if (pageCount > 1)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            child: Row(
              children: <Widget>[
                IconButton(
                  key: Key('${widget.prefix}-page-first'),
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.first_page_rounded, size: 20),
                  tooltip: '«',
                  onPressed: current > 0
                      ? () => setState(() => _page = 0)
                      : null,
                ),
                IconButton(
                  key: Key('${widget.prefix}-page-prev'),
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
                  key: Key('${widget.prefix}-page-next'),
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.chevron_right_rounded, size: 22),
                  onPressed: current < pageCount - 1
                      ? () => setState(() => _page = current + 1)
                      : null,
                ),
                IconButton(
                  key: Key('${widget.prefix}-page-last'),
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.last_page_rounded, size: 20),
                  tooltip: '»',
                  onPressed: current < pageCount - 1
                      ? () => setState(() => _page = pageCount - 1)
                      : null,
                ),
              ],
            ),
          ),
        for (final Widget w in widget.footer) w,
      ],
    );
  }
}
