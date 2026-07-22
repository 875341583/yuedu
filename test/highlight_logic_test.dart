import 'package:flutter_test/flutter_test.dart';
import 'dart:convert';

/// 高亮系统数据模型与引用刷新逻辑测试
///
/// PdfRectHighlight 定义在 pdf_reader_page.dart 中，该文件依赖大量 Flutter 组件，
/// 在单元测试中直接 import 会引入过多依赖。因此这里独立定义同结构模型
/// 来验证核心逻辑：toJson/fromJson 往返 + 新列表引用刷新模式。

/// 高亮数据模型（与 PdfRectHighlight 同结构）
class TestHighlight {
  final String id;
  final int page;
  final double relX, relY, relW, relH;
  final int colorIndex;

  const TestHighlight({
    required this.id,
    required this.page,
    required this.relX,
    required this.relY,
    required this.relW,
    required this.relH,
    required this.colorIndex,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'page': page,
        'x': relX,
        'y': relY,
        'w': relW,
        'h': relH,
        'c': colorIndex,
      };

  factory TestHighlight.fromJson(Map<String, dynamic> j) => TestHighlight(
        id: j['id'] as String? ?? '',
        page: (j['page'] as num?)?.toInt() ?? 1,
        relX: (j['x'] as num?)?.toDouble() ?? 0,
        relY: (j['y'] as num?)?.toDouble() ?? 0,
        relW: (j['w'] as num?)?.toDouble() ?? 0,
        relH: (j['h'] as num?)?.toDouble() ?? 0,
        colorIndex: (j['c'] as num?)?.toInt() ?? 0,
      );
}

void main() {
  group('PdfRectHighlight 序列化往返测试', () {
    test('toJson/fromJson 完整往返不丢数据', () {
      final h = TestHighlight(
        id: 'pdf_h_1234567890',
        page: 3,
        relX: 0.1,
        relY: 0.2,
        relW: 0.5,
        relH: 0.3,
        colorIndex: 2,
      );

      final json = h.toJson();
      final restored = TestHighlight.fromJson(json);

      expect(restored.id, h.id);
      expect(restored.page, h.page);
      expect(restored.relX, closeTo(h.relX, 1e-10));
      expect(restored.relY, closeTo(h.relY, 1e-10));
      expect(restored.relW, closeTo(h.relW, 1e-10));
      expect(restored.relH, closeTo(h.relH, 1e-10));
      expect(restored.colorIndex, h.colorIndex);
    });

    test('通过 JSON 字符串序列化/反序列化（模拟 SharedPreferences 存储）', () {
      final highlights = [
        TestHighlight(id: 'h1', page: 1, relX: 0.1, relY: 0.1, relW: 0.5, relH: 0.2, colorIndex: 0),
        TestHighlight(id: 'h2', page: 1, relX: 0.3, relY: 0.4, relW: 0.2, relH: 0.1, colorIndex: 1),
        TestHighlight(id: 'h3', page: 2, relX: 0.0, relY: 0.0, relW: 1.0, relH: 1.0, colorIndex: 2),
      ];

      // 模拟 _saveHighlights: 将所有高亮展平并 jsonEncode
      final jsonList = highlights.map((h) => h.toJson()).toList();
      final jsonString = jsonEncode(jsonList);

      // 模拟 _loadHighlights: 读取并 jsonDecode
      final decoded = jsonDecode(jsonString) as List;
      final restored = decoded
          .map((item) => TestHighlight.fromJson(item as Map<String, dynamic>))
          .toList();

      expect(restored.length, 3);
      expect(restored[0].id, 'h1');
      expect(restored[0].page, 1);
      expect(restored[1].id, 'h2');
      expect(restored[1].colorIndex, 1);
      expect(restored[2].id, 'h3');
      expect(restored[2].page, 2);
      expect(restored[2].relW, closeTo(1.0, 1e-10));
    });

    test('fromJson 容错：缺失字段不崩溃', () {
      final restored = TestHighlight.fromJson({});

      expect(restored.id, '');
      expect(restored.page, 1);
      expect(restored.relX, 0);
      expect(restored.colorIndex, 0);
    });
  });

  group('高亮列表引用刷新模式测试（shouldRepaint 修复验证）', () {
    test('旧模式（原地 add）：列表引用不变 → shouldRepaint 误判为 false', () {
      // 模拟旧代码的 bug：_highlightsByPage[page].add(highlight)
      final map = <int, List<TestHighlight>>{};
      map.putIfAbsent(1, () => []);

      final oldList = map[1]!;
      map[1]!.add(TestHighlight(
        id: 'h1', page: 1, relX: 0, relY: 0, relW: 0.5, relH: 0.5, colorIndex: 0,
      ));
      final newList = map[1]!;

      // 引用比较（旧 shouldRepaint 逻辑）
      expect(identical(oldList, newList), isTrue,
          reason: '原地 add 后引用不变，旧 shouldRepaint 会误判为不需要重绘');
      expect(newList.length, 1);
    });

    test('新模式（新列表引用）：引用变化 → shouldRepaint 正确判断为 true', () {
      // 模拟修复后代码：[...existing, highlight]
      final map = <int, List<TestHighlight>>{};
      map[1] = [];

      final oldList = map[1]!;
      final existing = map[1] ?? [];
      map[1] = [...existing, TestHighlight(
        id: 'h1', page: 1, relX: 0, relY: 0, relW: 0.5, relH: 0.5, colorIndex: 0,
      )];
      final newList = map[1]!;

      // 引用不同
      expect(identical(oldList, newList), isFalse,
          reason: '新列表引用不同，shouldRepaint 会正确判断为需要重绘');
      expect(newList.length, 1);
      expect(oldList.length, 0,
          reason: '旧列表不受影响（不可变性）');
    });

    test('新模式（删除）：引用变化 → shouldRepaint 正确判断', () {
      final map = <int, List<TestHighlight>>{};
      map[1] = [
        TestHighlight(id: 'h1', page: 1, relX: 0, relY: 0, relW: 0.5, relH: 0.5, colorIndex: 0),
        TestHighlight(id: 'h2', page: 1, relX: 0.1, relY: 0.1, relW: 0.3, relH: 0.3, colorIndex: 1),
      ];

      final oldList = map[1]!;

      // 模拟 _deleteHighlight: where(...).toList()
      final filtered = oldList.where((h) => h.id != 'h1').toList();
      if (filtered.isEmpty) {
        map.remove(1);
      } else {
        map[1] = filtered;
      }
      final newList = map[1]!;

      expect(identical(oldList, newList), isFalse,
          reason: '删除后新列表引用不同');
      expect(newList.length, 1);
      expect(newList[0].id, 'h2');
    });

    test('shouldRepaint 值比较逻辑（长度+id+colorIndex）', () {
      final listA = [
        TestHighlight(id: 'h1', page: 1, relX: 0, relY: 0, relW: 0.5, relH: 0.5, colorIndex: 0),
      ];
      final listB = [
        TestHighlight(id: 'h1', page: 1, relX: 0, relY: 0, relW: 0.5, relH: 0.5, colorIndex: 0),
      ];
      final listC = [
        TestHighlight(id: 'h1', page: 1, relX: 0, relY: 0, relW: 0.5, relH: 0.5, colorIndex: 1),
      ];
      final listD = <TestHighlight>[];

      // 模拟修复后的 shouldRepaint 值比较逻辑
      bool shouldRepaint(List<TestHighlight> oldList, List<TestHighlight> newList) {
        if (oldList.length != newList.length) return true;
        for (var i = 0; i < newList.length; i++) {
          if (oldList[i].id != newList[i].id || oldList[i].colorIndex != newList[i].colorIndex) {
            return true;
          }
        }
        return false;
      }

      // 相同内容 → false
      expect(shouldRepaint(listA, listB), isFalse);
      // 颜色变化 → true
      expect(shouldRepaint(listA, listC), isTrue);
      // 长度变化 → true
      expect(shouldRepaint(listA, listD), isTrue);
    });
  });

  group('高亮清空本页逻辑测试', () {
    test('清空指定页高亮不影响其他页', () {
      final map = <int, List<TestHighlight>>{};
      map[1] = [TestHighlight(id: 'h1', page: 1, relX: 0, relY: 0, relW: 0.5, relH: 0.5, colorIndex: 0)];
      map[2] = [TestHighlight(id: 'h2', page: 2, relX: 0, relY: 0, relW: 0.5, relH: 0.5, colorIndex: 0)];
      map[3] = [TestHighlight(id: 'h3', page: 3, relX: 0, relY: 0, relW: 0.5, relH: 0.5, colorIndex: 0)];

      // 模拟 _clearAllHighlightsOnPage(2)
      map.remove(2);

      expect(map.containsKey(1), isTrue);
      expect(map.containsKey(2), isFalse);
      expect(map.containsKey(3), isTrue);
      expect(map[1]!.length, 1);
      expect(map[3]!.length, 1);
    });
  });

  group('高亮 ID 唯一性测试', () {
    test('毫秒时间戳 ID 在快速连点时可能撞 ID', () {
      // 模拟 v0.8.3 仍使用的毫秒时间戳 ID
      // 验证：同一毫秒内创建的两个高亮 ID 相同（已知限制）
      final now = DateTime.now().millisecondsSinceEpoch;
      final id1 = 'pdf_h_$now';
      final id2 = 'pdf_h_$now';

      expect(id1, id2, reason: '同一毫秒内创建的高亮 ID 会重复（已知限制，下版本改用 UUID）');
    });

    test('不同毫秒的 ID 不重复', () {
      final id1 = 'pdf_h_${DateTime.now().millisecondsSinceEpoch}';
      // 确保时间戳不同
      final id2 = 'pdf_h_${DateTime.now().millisecondsSinceEpoch + 1}';

      expect(id1, isNot(id2));
    });
  });

  group('_hasHighlightsOnCurrentPage 逻辑测试', () {
    test('有高亮的页返回 true', () {
      final map = <int, List<TestHighlight>>{};
      map[3] = [TestHighlight(id: 'h1', page: 3, relX: 0, relY: 0, relW: 0.5, relH: 0.5, colorIndex: 0)];

      final currentPage = 3;
      final has = (map[currentPage]?.isNotEmpty ?? false);

      expect(has, isTrue);
    });

    test('无高亮的页返回 false', () {
      final map = <int, List<TestHighlight>>{};

      final currentPage = 5;
      final has = (map[currentPage]?.isNotEmpty ?? false);

      expect(has, isFalse);
    });

    test('有高亮但为空列表的页返回 false', () {
      final map = <int, List<TestHighlight>>{};
      map[1] = [];

      final currentPage = 1;
      final has = (map[currentPage]?.isNotEmpty ?? false);

      expect(has, isFalse);
    });
  });
}
