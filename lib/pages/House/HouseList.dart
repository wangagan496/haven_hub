// ignore_for_file: file_names

import 'dart:async';

import 'package:flutter/material.dart';

import '../../api/house.dart';
import '../../utils/app_exception.dart';
import '../../utils/toast.dart';
import 'components/HouseItem.dart';

class HouseList extends StatefulWidget {
  const HouseList({
    this.houseListLoader = getHouseListApi,
    super.key,
  });

  static const String routeName = '/houselist';

  final HouseListLoader houseListLoader;

  @override
  State<HouseList> createState() => _HouseListState();
}

class _HouseListState extends State<HouseList> {
  List<Map<String, dynamic>> _houses = const <Map<String, dynamic>>[];
  bool _isLoading = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    unawaited(_loadHouseList());
  }

  Future<void> _loadHouseList() async {
    if (_isLoading) {
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });
    try {
      final List<Map<String, dynamic>> result = await widget.houseListLoader();
      if (!mounted) {
        return;
      }
      setState(() {
        _houses = result;
      });
    } on Object catch (error) {
      final String message = switch (error) {
        BusinessException() => error.message,
        NetworkException() => error.message,
        FormatException() => error.message,
        _ => '获取房屋列表失败，请重试',
      };
      if (!mounted) {
        return;
      }
      setState(() {
        _errorMessage = message;
      });
      await PromptAction.showError(message);
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F1F1),
      appBar: AppBar(
        title: const Text('我的房屋'),
        centerTitle: true,
        backgroundColor: const Color(0xFFF5F1F1),
        surfaceTintColor: Colors.transparent,
      ),
      body: SafeArea(
        top: false,
        child: Column(
          children: <Widget>[
            Expanded(child: _buildBody()),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
              child: SizedBox(
                width: double.infinity,
                height: 48,
                child: OutlinedButton.icon(
                  onPressed: () {
                    PromptAction.showToast('添加房屋功能暂未开放');
                  },
                  icon: const Icon(Icons.add, size: 20),
                  label: const Text('添加房屋'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFF6552B5),
                    backgroundColor: const Color(0xFFFBF8FF),
                    side: const BorderSide(color: Color(0xFFE8DFF3)),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(24),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_isLoading && _houses.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }

    final String? errorMessage = _errorMessage;
    if (errorMessage != null && _houses.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const Icon(
                Icons.error_outline_rounded,
                size: 44,
                color: Color(0xFF999999),
              ),
              const SizedBox(height: 12),
              Text(
                errorMessage,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Color(0xFF666666)),
              ),
              const SizedBox(height: 12),
              TextButton(
                onPressed: _isLoading ? null : _loadHouseList,
                child: const Text('重新加载'),
              ),
            ],
          ),
        ),
      );
    }

    if (_houses.isEmpty) {
      return RefreshIndicator(
        onRefresh: _loadHouseList,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: const <Widget>[
            SizedBox(height: 160),
            Icon(
              Icons.home_outlined,
              size: 52,
              color: Color(0xFFAAAAAA),
            ),
            SizedBox(height: 12),
            Center(
              child: Text(
                '暂无房屋',
                style: TextStyle(color: Color(0xFF777777)),
              ),
            ),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _loadHouseList,
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(10, 10, 10, 8),
        itemCount: _houses.length,
        itemBuilder: (BuildContext context, int index) {
          return HouseItem(data: _houses[index]);
        },
        separatorBuilder: (BuildContext context, int index) {
          return const SizedBox(height: 10);
        },
      ),
    );
  }
}
