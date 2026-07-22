import 'package:flutter_test/flutter_test.dart';
import 'dart:convert';
import 'package:archive/archive.dart';
import 'package:yuedu/utils/ofd_text_extractor.dart';

/// 直接测试 OFD 提取器的核心过滤逻辑
/// 由于 OfdTextExtractor 的 _hasReadableChars 和 _extractAllReadableText 是私有方法，
/// 我们通过构建模拟 OFD ZIP 包来端到端验证

void main() {
  group('OFD 路径指令过滤测试', () {
    /// 构建一个模拟 OFD 文件（ZIP 包），内含指定 XML 内容
    List<int> buildMockOfd(Map<String, String> xmlFiles) {
      final archive = Archive();
      xmlFiles.forEach((name, content) {
        final bytes = utf8.encode(content);
        archive.addFile(ArchiveFile(name, bytes.length, bytes));
      });
      return ZipEncoder().encode(archive)!;
    }

    test('Bug A 复现：标签间路径指令文本应被过滤', () {
      // 模拟真实场景：路径指令作为标签间文本内容出现
      final xml = '''<?xml version="1.0" encoding="UTF-8"?>
<Page Content="true">
  <Draw>L 172.549 Q 8.549 12.3 4.5 Z M 0 0 L 100 200 C 50 50 60 60 70 70</Draw>
  <Draw>M 0 0 L 200 100</Draw>
  <TextCode>发票</TextCode>
</Page>''';

      final ofdBytes = buildMockOfd({
        'OFD.xml': '<?xml version="1.0"?><OFD><DocBody><DocRoot>Doc_0/Document.xml</DocRoot></DocBody></OFD>',
        'Doc_0/Document.xml': '<?xml version="1.0"?><Document><Pages><Page ID="Page_0" BaseLoc="Page_0/Content.xml"/></Pages></Document>',
        'Doc_0/Pages/Page_0/Content.xml': xml,
      });

      final result = OfdTextExtractor.extract(ofdBytes);

      // 中文应被提取
      expect(result, contains('发票'));
      // 路径指令数据不应出现
      expect(result, isNot(contains('172.549')));
      expect(result, isNot(contains('8.549')));
    });

    test('真实 OFD 发票：TextCode 内中文应正常提取', () {
      final xml = '''<?xml version="1.0" encoding="UTF-8"?>
<Page Content="true">
  <TextObject ID="1" Boundary="0 0 210 297">
    <TextCode X="10" Y="280" DeltaX="100">增值税电子普通发票</TextCode>
    <TextCode X="10" Y="260" DeltaX="100">购货单位：测试公司</TextCode>
    <TextCode X="10" Y="240" DeltaX="100">金额：壹佰元整</TextCode>
  </TextObject>
</Page>''';

      final ofdBytes = buildMockOfd({
        'OFD.xml': '<?xml version="1.0"?><OFD><DocBody><DocRoot>Doc_0/Document.xml</DocRoot></DocBody></OFD>',
        'Doc_0/Document.xml': '<?xml version="1.0"?><Document><Pages><Page ID="Page_0" BaseLoc="Page_0/Content.xml"/></Pages></Document>',
        'Doc_0/Pages/Page_0/Content.xml': xml,
      });

      final result = OfdTextExtractor.extract(ofdBytes);

      expect(result, contains('增值税电子普通发票'));
      expect(result, contains('购货单位'));
      expect(result, contains('金额'));
    });

    test('混合场景：路径指令与中文文本混合时只提取中文', () {
      final xml = '''<?xml version="1.0" encoding="UTF-8"?>
<Page>
  <Draw>L 172.549 Q 8.549</Draw>
  <TextCode>发票代码</TextCode>
  <Draw>M 0 0 L 100 200</Draw>
  <TextCode>发票号码</TextCode>
</Page>''';

      final ofdBytes = buildMockOfd({
        'OFD.xml': '<?xml version="1.0"?><OFD><DocBody><DocRoot>Doc_0/Document.xml</DocRoot></DocBody></OFD>',
        'Doc_0/Document.xml': '<?xml version="1.0"?><Document><Pages><Page ID="Page_0" BaseLoc="Page_0/Content.xml"/></Pages></Document>',
        'Doc_0/Pages/Page_0/Content.xml': xml,
      });

      final result = OfdTextExtractor.extract(ofdBytes);

      expect(result, contains('发票代码'));
      expect(result, contains('发票号码'));
      expect(result, isNot(contains('172.549')));
      expect(result, isNot(contains('8.549')));
    });

    test('纯路径指令无任何中文时抛异常', () {
      final xml = '''<?xml version="1.0"?>
<Page>
  <Draw>L 172.549 Q 8.549 12.3 4.5 Z</Draw>
  <Draw>M 0 0 L 100 200 C 50 50 60 60 70 70</Draw>
</Page>''';

      final ofdBytes = buildMockOfd({
        'OFD.xml': '<?xml version="1.0"?><OFD><DocBody><DocRoot>Doc_0/Document.xml</DocRoot></DocBody></OFD>',
        'Doc_0/Document.xml': '<?xml version="1.0"?><Document><Pages><Page ID="Page_0" BaseLoc="Page_0/Content.xml"/></Pages></Document>',
        'Doc_0/Pages/Page_0/Content.xml': xml,
      });

      expect(
        () => OfdTextExtractor.extract(ofdBytes),
        throwsA(isA<Exception>()),
      );
    });
  });

  group('OFD 多页排序测试', () {
    List<int> buildMockOfd(Map<String, String> xmlFiles) {
      final archive = Archive();
      xmlFiles.forEach((name, content) {
        final bytes = utf8.encode(content);
        archive.addFile(ArchiveFile(name, bytes.length, bytes));
      });
      return ZipEncoder().encode(archive)!;
    }

    test('多页内容按 Page_N 顺序排列', () {
      // Document.xml 含 "Page" 关键词会被匹配为条目，但无有效文本会被跳过
      final ofdBytes = buildMockOfd({
        'OFD.xml': '<?xml version="1.0"?><OFD><DocBody><DocRoot>Doc_0/Document.xml</DocRoot></DocBody></OFD>',
        'Doc_0/Document.xml': '<?xml version="1.0"?><Document><Pages>'
            '<Page ID="Page_0" BaseLoc="Page_0/Content.xml"/>'
            '<Page ID="Page_1" BaseLoc="Page_1/Content.xml"/>'
            '<Page ID="Page_2" BaseLoc="Page_2/Content.xml"/>'
            '</Pages></Document>',
        'Doc_0/Pages/Page_0/Content.xml': '<?xml version="1.0"?><Page><TextCode>第一页</TextCode></Page>',
        'Doc_0/Pages/Page_1/Content.xml': '<?xml version="1.0"?><Page><TextCode>第二页</TextCode></Page>',
        'Doc_0/Pages/Page_2/Content.xml': '<?xml version="1.0"?><Page><TextCode>第三页</TextCode></Page>',
      });

      final result = OfdTextExtractor.extract(ofdBytes);

      // 三个页面的文本都应在结果中
      expect(result, contains('第一页'));
      expect(result, contains('第二页'));
      expect(result, contains('第三页'));

      // 验证顺序
      final idx1 = result.indexOf('第一页');
      final idx2 = result.indexOf('第二页');
      final idx3 = result.indexOf('第三页');
      expect(idx1, lessThan(idx2));
      expect(idx2, lessThan(idx3));
    });
  });
}
