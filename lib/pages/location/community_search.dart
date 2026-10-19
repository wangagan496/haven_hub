import 'dart:async';

import 'package:flutter/material.dart';

import '../../api/location.dart';
import '../../utils/app_exception.dart';
import '../../utils/toast.dart';

class CommunitySearchPage extends StatefulWidget {
  const CommunitySearchPage({
    required this.search,
    this.initialCity = '',
    super.key,
  });

  final CommunitySearch search;
  final String initialCity;

  @override
  State<CommunitySearchPage> createState() => _CommunitySearchPageState();
}

class _CommunitySearchPageState extends State<CommunitySearchPage> {
  late final TextEditingController _city;
  final TextEditingController _keyword = TextEditingController();
  bool _isLoading = false;
  bool _searched = false;
  int _requestId = 0;
  String? _error;
  List<NearbyCommunity> _results = const <NearbyCommunity>[];

  @override
  void initState() {
    super.initState();
    _city = TextEditingController(text: widget.initialCity);
    _city.addListener(_invalidateResults);
    _keyword.addListener(_invalidateResults);
  }

  void _invalidateResults() {
    // 编辑搜索条件立即作废旧请求，防止旧城市的结果覆盖新条件。
    _requestId++;
    setState(() {
      _isLoading = false;
      _searched = false;
      _error = null;
      _results = const <NearbyCommunity>[];
    });
  }

  @override
  void dispose() {
    _city.dispose();
    _keyword.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    if (_isLoading) return;
    final String city = _city.text.trim();
    final String keyword = _keyword.text.trim();
    if (city.isEmpty || keyword.isEmpty) {
      await PromptAction.showWarning('请填写城市和小区名称');
      return;
    }
    FocusScope.of(context).unfocus();
    final int requestId = ++_requestId;
    setState(() {
      _isLoading = true;
      _error = null;
      _results = const <NearbyCommunity>[];
    });
    try {
      final List<NearbyCommunity> results = await widget
          .search(city, keyword)
          .timeout(const Duration(seconds: 20));
      if (!mounted || requestId != _requestId) return;
      setState(() {
        _results = results;
        _searched = true;
      });
    } on Object catch (error) {
      if (!mounted || requestId != _requestId) return;
      final String message = describeError(error,
          fallback: '搜索失败，请重试',
          onOtherError: (Object error) =>
              error is TimeoutException ? '搜索超时，请重试' : null);
      setState(() => _error = message);
      await PromptAction.showError(message);
    } finally {
      if (mounted && requestId == _requestId) {
        setState(() => _isLoading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('搜索小区')),
      body: SafeArea(
        child: CustomScrollView(
          slivers: <Widget>[
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    const Text('定位不准或找不到小区时，可指定城市搜索。请选择地址相符的小区。'),
                    const SizedBox(height: 16),
                    TextField(
                      key: const Key('community-search-city'),
                      controller: _city,
                      maxLength: 50,
                      textInputAction: TextInputAction.next,
                      decoration: const InputDecoration(
                          labelText: '城市', hintText: '例如：佛山市', counterText: ''),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      key: const Key('community-search-keyword'),
                      controller: _keyword,
                      maxLength: 100,
                      textInputAction: TextInputAction.search,
                      onSubmitted: (_) => unawaited(_search()),
                      decoration: const InputDecoration(
                          labelText: '小区名称',
                          hintText: '例如：榴苑三街',
                          counterText: ''),
                    ),
                    const SizedBox(height: 16),
                    FilledButton(
                      key: const Key('community-search-submit'),
                      onPressed: _isLoading ? null : _search,
                      child: Text(_isLoading ? '正在搜索…' : '搜索'),
                    ),
                    if (_isLoading) const LinearProgressIndicator(),
                    if (_error != null) Text(_error!),
                    if (!_isLoading && _searched && _results.isEmpty)
                      const Text('没有找到匹配的小区，请检查城市或换个名称重试'),
                    if (_results.isNotEmpty)
                      const Text('搜索结果（最多展示 10 项，可补全名称缩小范围）'),
                  ],
                ),
              ),
            ),
            SliverList.builder(
              itemCount: _results.length,
              itemBuilder: (BuildContext context, int index) {
                final NearbyCommunity community = _results[index];
                return ListTile(
                  title: Text(community.name),
                  subtitle: Text(community.address),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.pop(context, community),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}
