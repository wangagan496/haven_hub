import 'dart:async';

import 'package:flutter/material.dart';

import '../../api/house.dart';
import '../../theme/app_colors.dart';
import '../../models/house.dart';
import '../../utils/app_exception.dart';
import '../../utils/toast.dart';
import '../../widgets/async_state_view.dart';
import '../location/location_list.dart';
import 'house_detail.dart';
import 'components/house_item.dart';

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
  List<House> _houses = const <House>[];
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
      final List<House> result = await widget.houseListLoader();
      if (!mounted) {
        return;
      }
      setState(() {
        _houses = result;
      });
    } on Object catch (error) {
      final String message = describeError(
        error,
        fallback: '获取房屋列表失败，请重试',
      );
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

  Future<void> _openHouseDetail(House house) async {
    if (house.id.isEmpty) {
      await PromptAction.showWarning('房屋参数不正确');
      return;
    }

    await Navigator.pushNamed<void>(
      context,
      HouseDetail.routeName,
      arguments: house.id,
    );
    if (!mounted) return;
    await _loadHouseList();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('我的房屋'),
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
                    Navigator.pushNamed<void>(
                      context,
                      LocationList.routeName,
                    );
                  },
                  icon: const Icon(Icons.add, size: 20),
                  label: const Text('添加房屋'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.accent,
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
    return AsyncStateView(
      isLoading: _isLoading,
      errorMessage: _errorMessage,
      onRetry: _loadHouseList,
      hasContent: _houses.isNotEmpty,
      builder: (BuildContext context) {
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
                  color: AppColors.divider,
                ),
                SizedBox(height: 12),
                Center(
                  child: Text(
                    '暂无房屋',
                    style: TextStyle(color: AppColors.textTertiary),
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
              final House house = _houses[index];
              return HouseItem(
                house: house,
                onTap: () => _openHouseDetail(house),
              );
            },
            separatorBuilder: (BuildContext context, int index) {
              return const SizedBox(height: 10);
            },
          ),
        );
      },
    );
  }
}
