/// 由字符串种子推导的确定性采样。
///
/// 选楼流程的楼栋和房间目前是本地生成的模拟数据。用无种子的 [Random] 时，
/// 同一个小区每次进入都会得到不同的楼栋数和房间数，用户退回上一步再进来，
/// 列表就变了，看起来像是选错了。改成由小区名、楼栋名推导后，同一种子永远
/// 得到同一结果，且换一个小区仍然得到不同的列表。
///
/// 接上真实接口后这个类可以整体删掉。
class DeterministicSample {
  DeterministicSample(String seed) : _state = _hash(seed);

  int _state;

  /// FNV-1a 32 位哈希。
  ///
  /// 不直接使用 `String.hashCode`：那是运行时的实现细节，换成另一种编译目标
  /// 就可能得到不同值，而这里需要的是「同一个名字在任何设备上都得到同一个
  /// 列表」。
  static int _hash(String seed) {
    int hash = 0x811c9dc5;
    for (final int unit in seed.codeUnits) {
      hash ^= unit;
      hash = (hash * 0x01000193) & 0xFFFFFFFF;
    }
    // xorshift 的状态不能为 0，否则会一直输出 0。
    return hash == 0 ? 0x9E3779B9 : hash;
  }

  /// xorshift32，推进内部状态并返回新的值。
  int _advance() {
    int x = _state;
    x ^= (x << 13) & 0xFFFFFFFF;
    x ^= x >> 17;
    x ^= (x << 5) & 0xFFFFFFFF;
    _state = x & 0xFFFFFFFF;
    return _state;
  }

  /// 返回 `[0, max)` 区间的确定性整数；[max] 非正时返回 0。
  int nextInt(int max) {
    if (max <= 0) {
      return 0;
    }
    return _advance() % max;
  }
}
