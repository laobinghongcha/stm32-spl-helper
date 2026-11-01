// 「使用总览」分行规则的测试（docs/contract_v2.md §8）。
//
// 这个工具的唯一价值是**渲染正确**：用户抱怨的就是「每个序号没有分行」。
// 所以这里既覆盖真实数据（GPIO/RCC/USART/TIM 的 usageOverviewZh 原文），
// 也覆盖边界情况（小数、引用式「第 ① 步」、硬换行、空输入）。
//
// 真实样例是从 assets/data/peripherals.json 里**原样抄下来的**。
// 不用读文件的方式，是因为 peripherals.json 正被 data-engineer 改造成 v2
// （会新增 libraries 字段），但 §3 规定顶层 usageOverviewZh 必须保留——
// 抄在测试里既能防"改造时把这段文案弄丢"，也不会被并发改写干扰。
// 末尾另有一条读真实文件的宽松测试，兜住"数据真的变了"的情况。

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:stm32_spl_helper/utils/usage_steps.dart';

// ---------------------------------------------------------------------------
// 真实数据原文（assets/data/peripherals.json）
// ---------------------------------------------------------------------------

const String gpioRaw =
    '标准调用顺序：① RCC_APB2PeriphClockCmd 使能 GPIOx 与 AFIO 时钟'
    '（用重映射时必须开 AFIO）；② 填写 GPIO_InitTypeDef 三个字段；'
    '③ GPIO_Init 写入配置；④ 用 GPIO_SetBits / GPIO_ResetBits / GPIO_WriteBit 操作电平，'
    '或 GPIO_ReadInputDataBit 读取。注意：忘了第 ① 步是新手最常踩的坑，'
    '配置会静默失效且不报错。';

const String rccRaw =
    '两类用法：① 系统时钟初始化——通常在 SystemInit 里用 RCC_HSEConfig / '
    'RCC_PLLConfig / RCC_SYSCLKConfig 配到 72MHz；② 外设时钟使能——'
    'RCC_APB2PeriphClockCmd（GPIO/USART1/SPI1/ADC1/TIM1 等）或 '
    'RCC_APB1PeriphClockCmd（USART2/3、TIM2~7、I2C、SPI2、PWR、BKP 等）。'
    '搞不清挂在哪条总线是常见困惑点，看函数名里的 APB1/APB2 即可。';

const String usartRaw =
    '标准调用顺序：① 开 USARTx 时钟与对应 GPIO 时钟；② GPIO 配成复用推挽'
    '（TX 用 GPIO_Mode_AF_PP，RX 用 GPIO_Mode_IN_FLOATING）；'
    '③ 填 USART_InitTypeDef 并 USART_Init；④ USART_Cmd(USARTx, ENABLE) 使能；'
    '⑤ USART_ITConfig 开中断或直接轮询 USART_GetFlagStatus；'
    '⑥ 发送用 USART_SendData，接收用 USART_ReceiveData。'
    '波特率算错会收到乱码，注意 USART1 挂 APB2（72MHz），USART2/3 挂 APB1（36MHz）。';

const String timRaw =
    '定时中断的典型顺序：① 开 TIMx 时钟；② 填 TIM_TimeBaseInitTypeDef'
    '（Prescaler 分频、Period 重装值）并 TIM_TimeBaseInit；③ TIM_ITConfig 开更新中断；'
    '④ NVIC 配置优先级并使能；⑤ TIM_Cmd 启动；'
    '⑥ 在 TIMx_IRQHandler 里判断 TIM_GetITStatus 并 TIM_ClearITPendingBit。'
    'PWM 输出还要额外配置 TIM_OCInitTypeDef 与 TIM_OCxInit。'
    '注意中断里必须清标志，否则会反复进中断。';

/// 取出所有 marker（便于整体断言"切了几步、序号对不对"）
List<String> markersOf(String raw) =>
    splitUsageSteps(raw).map((s) => s.marker).toList();

void main() {
  group('真实数据：GPIO', () {
    test('切成「引导语 + 4 步」', () {
      final steps = splitUsageSteps(gpioRaw);
      expect(steps.length, 5, reason: '引导语 + ①②③④ 共 5 项');
      expect(steps.first.marker, '', reason: '「标准调用顺序：」应是无序号引导语');
      expect(steps.first.text, '标准调用顺序：');
      expect(
        steps.skip(1).map((s) => s.marker).toList(),
        <String>['①', '②', '③', '④'],
      );
    });

    test('每一步的正文非空，且不含别的序号', () {
      for (final s in splitUsageSteps(gpioRaw).skip(1)) {
        expect(s.text, isNotEmpty);
        expect(s.text.contains('②'), isFalse, reason: '② 应已切走');
        expect(s.text.contains('③'), isFalse, reason: '③ 应已切走');
      }
    });

    test('「忘了第 ① 步」里的 ① 不被当成新的一步', () {
      final steps = splitUsageSteps(gpioRaw);
      // 若被误切，会多出一项 marker=① 、正文以「步是新手」开头
      for (final s in steps) {
        expect(s.text.startsWith('步是新手'), isFalse,
            reason: '引用式的「第 ① 步」不应切开');
      }
      expect(steps.where((s) => s.marker == '①').length, 1,
          reason: '① 只应作为第 1 步的序号出现一次');
    });

    test('最后一步保留原文结尾的注意事项（不丢内容）', () {
      final last = splitUsageSteps(gpioRaw).last;
      expect(last.text, contains('配置会静默失效且不报错'));
    });
  });

  group('真实数据：RCC', () {
    test('「两类用法：」作引导语，切出 2 步', () {
      final steps = splitUsageSteps(rccRaw);
      expect(steps.length, 3, reason: '引导语 + ①② 共 3 项');
      expect(steps.first.marker, '');
      expect(steps.first.text, '两类用法：');
      expect(steps[1].marker, '①');
      expect(steps[2].marker, '②');
    });

    test('总线名里的数字（USART2/3、TIM2~7、72MHz）不产生伪序号', () {
      final steps = splitUsageSteps(rccRaw);
      expect(steps.map((s) => s.marker).toList(), <String>['', '①', '②']);
      // 正文里的这些片段必须完好
      expect(steps[2].text, contains('USART2/3'));
      expect(steps[2].text, contains('TIM2~7'));
      expect(steps[1].text, contains('72MHz'));
    });
  });

  group('真实数据：USART', () {
    test('切成「引导语 + 6 步」', () {
      final steps = splitUsageSteps(usartRaw);
      expect(steps.length, 7, reason: '引导语 + ①-⑥ 共 7 项');
      expect(steps.first.marker, '');
      expect(
        steps.skip(1).map((s) => s.marker).toList(),
        <String>['①', '②', '③', '④', '⑤', '⑥'],
      );
    });

    test('函数调用里的括号与逗号不被当成序号', () {
      final steps = splitUsageSteps(usartRaw);
      final s4 = steps.firstWhere((s) => s.marker == '④');
      expect(s4.text, contains('USART_Cmd(USARTx, ENABLE)'));
    });
  });

  group('真实数据：TIM', () {
    test('引导语是不带冒号的短句也能识别', () {
      final steps = splitUsageSteps(timRaw);
      expect(steps.first.marker, '');
      expect(steps.first.text, '定时中断的典型顺序：');
      expect(steps.length, 7, reason: '引导语 + ①-⑥ 共 7 项');
    });

    test('每一步都以序号开头且序号互不重复', () {
      final steps = splitUsageSteps(timRaw).skip(1).toList();
      final markers = steps.map((s) => s.marker).toList();
      expect(markers.toSet().length, markers.length);
      for (final s in steps) {
        expect(s.text.trim(), isNotEmpty);
      }
    });
  });

  group('分行：已含换行的文本', () {
    test('按行切，每行一步', () {
      const raw = '① 开时钟\n② 填结构体\n③ 调 Init';
      final steps = splitUsageSteps(raw);
      expect(steps.map((s) => s.marker).toList(), <String>['①', '②', '③']);
      expect(steps[0].text, '开时钟');
      expect(steps[2].text, '调 Init');
    });

    test('引导语单独一行时是首项', () {
      const raw = '标准调用顺序：\n① 开时钟\n② 填结构体';
      final steps = splitUsageSteps(raw);
      expect(steps.length, 3);
      expect(steps.first.marker, '');
      expect(steps.first.text, '标准调用顺序：');
    });

    test('空行被去掉', () {
      const raw = '① 开时钟\n\n\n② 填结构体\n   \n';
      final steps = splitUsageSteps(raw);
      expect(steps.length, 2);
      expect(steps.map((s) => s.text).toList(), <String>['开时钟', '填结构体']);
    });

    test('CRLF 换行也能处理（从 Excel / Windows 编辑器粘来的）', () {
      const raw = '① 开时钟\r\n② 填结构体\r\n③ 调 Init';
      expect(splitUsageSteps(raw).length, 3);
    });

    test('单独的反斜杠 r 换行也能处理', () {
      const raw = '① 开时钟\r② 填结构体';
      expect(splitUsageSteps(raw).length, 2);
    });

    test('一行里既有换行又有多个序号，两种规则叠加', () {
      const raw = '顺序：① 开时钟；② 填结构体\n③ 调 Init；④ 收尾';
      final steps = splitUsageSteps(raw);
      expect(steps.map((s) => s.marker).toList(),
          <String>['', '①', '②', '③', '④']);
    });
  });

  group('分行：各种序号写法', () {
    test('1) / 2) 形式', () {
      const raw = '1) 开时钟 2) 填结构体';
      final steps = splitUsageSteps(raw);
      expect(steps.length, 2, reason: '实际：${steps.map((s) => s.marker)}');
      expect(steps[0].marker, '1)');
      expect(steps[1].marker, '2)');
    });

    test('1. / 2. 形式', () {
      const raw = '1. 开时钟 2. 填结构体';
      final steps = splitUsageSteps(raw);
      expect(steps.length, 2, reason: '实际：${steps.map((s) => s.marker)}');
      expect(steps[0].marker, '1.');
      expect(steps[1].marker, '2.');
    });

    test('(1) / （2） 形式（半角 + 全角括号）', () {
      const raw = '(1) 开时钟；（2）填结构体';
      final steps = splitUsageSteps(raw);
      expect(steps.map((s) => s.marker).toList(), <String>['(1)', '（2）']);
    });

    test('1、 形式（中文顿号）', () {
      const raw = '1、开时钟；2、填结构体';
      final steps = splitUsageSteps(raw);
      expect(steps.map((s) => s.marker).toList(), <String>['1、', '2、']);
    });

    test('「第N步」形式', () {
      const raw = '第一步 开时钟；第二步 填结构体；第三步 调 Init';
      final steps = splitUsageSteps(raw);
      expect(steps.length, 3, reason: '实际：${steps.map((s) => s.marker)}');
      expect(steps[0].marker, '第一步');
      expect(steps[2].marker, '第三步');
    });

    test('圈号边界：⑩ / ⑳ / ⑴ 都认', () {
      const raw = '⑩ 十；⑳ 二十；⑴ 带括号的一';
      final steps = splitUsageSteps(raw);
      expect(steps.map((s) => s.marker).toList(), <String>['⑩', '⑳', '⑴']);
    });
  });

  group('分行：不该切的情况', () {
    test('小数不被当成序号', () {
      const raw = '增益设为 1.5 倍，误差 0.25 dB。';
      final steps = splitUsageSteps(raw);
      expect(steps.length, 1);
      expect(steps.single.marker, '');
      expect(steps.single.text, raw);
    });

    test('纯文本（没有任何序号）原样返回一项', () {
      const raw = '常见：忘了开时钟是新手最常踩的坑。';
      final steps = splitUsageSteps(raw);
      expect(steps.length, 1);
      expect(steps.single.marker, '');
      expect(steps.single.text, raw);
    });

    test('圈号顶点标记不误切（顶点数据里的数字）', () {
      const raw = 'PA9 默认 AF 为 USART1_TX（第 9 脚）。';
      final steps = splitUsageSteps(raw);
      expect(steps.length, 1);
      expect(steps.single.marker, '');
    });

    test('「第 ① 步」这类引用式不切', () {
      const raw = '注意：忘了第 ① 步会静默失效。';
      final steps = splitUsageSteps(raw);
      expect(steps.length, 1, reason: '实际：${steps.map((s) => s.toString())}');
      expect(steps.single.text, raw);
    });
  });

  group('分行：输入容错', () {
    test('null 返回空列表', () {
      expect(splitUsageSteps(null), isEmpty);
    });

    test('空串 / 纯空白返回空列表', () {
      expect(splitUsageSteps(''), isEmpty);
      expect(splitUsageSteps('   \n\t\n  '), isEmpty);
    });

    test('首尾空白被去掉', () {
      const raw = '  ① 开时钟  ';
      final steps = splitUsageSteps(raw);
      expect(steps.single.marker, '①');
      expect(steps.single.text, '开时钟');
    });

    test('行尾多打了个序号不会产生空步骤', () {
      const raw = '① 开时钟 ②';
      final steps = splitUsageSteps(raw);
      expect(steps.length, 1);
      expect(steps.single.text, '开时钟');
    });
  });

  group('UsageStep', () {
    test('hasMarker 区分有无序号', () {
      expect(const UsageStep('①', '开时钟').hasMarker, isTrue);
      expect(const UsageStep('', '标准调用顺序：').hasMarker, isFalse);
    });

    test('相等性按 marker + text 判断', () {
      expect(const UsageStep('①', '开时钟'), const UsageStep('①', '开时钟'));
      expect(
        const UsageStep('①', '开时钟'),
        isNot(const UsageStep('②', '开时钟')),
      );
      expect(
        const UsageStep('①', '开时钟'),
        isNot(const UsageStep('①', '填结构体')),
      );
    });

    test('toString 便于测试失败时定位', () {
      expect(const UsageStep('①', '开时钟').toString(), '① 开时钟');
      expect(const UsageStep('', '引导语').toString(), '引导语');
    });
  });

  group('渲染前提：每个序号另起一行、序号顶格', () {
    // 用户的核心抱怨是「每个序号没有分行」。
    // UsageStepsView 一行一个 Row，所以断言"步数 >= 序号个数"即可保证
    // 每个序号都占独立的一行；这里额外断言序号确实被切到了行首
    // （正文里不再残留**开启新步骤**的圈号）。
    //
    // 例外：「注意：忘了第 ① 步…」这类**引用式**圈号应当保留在正文里，
    // 那是原文语义的一部分，不是没切干净的序号。
    final quotedRef = RegExp(r'第\s*[\u2460-\u2473\u2474-\u2487]\s*步');

    for (final entry in <String, String>{
      'GPIO': gpioRaw,
      'RCC': rccRaw,
      'USART': usartRaw,
      'TIM': timRaw,
    }.entries) {
      test('${entry.key}：每个序号各占一项，正文不再以序号开头', () {
        final steps = splitUsageSteps(entry.value);
        final withMarker = steps.where((s) => s.hasMarker).toList();
        expect(withMarker.length, greaterThanOrEqualTo(2));
        for (final s in withMarker) {
          // 去掉「第 ① 步」这类引用后，正文里不该再有圈号（说明切干净了）
          final residual = s.text.replaceAll(quotedRef, '');
          expect(
            RegExp(r'[\u2460-\u2473\u2474-\u2487]').hasMatch(residual),
            isFalse,
            reason: '正文仍含未切开的圈号：${s.text}',
          );
        }
      });
    }
  });

  group('真实数据文件（宽松校验，允许数据继续演进）', () {
    final f = File('assets/data/peripherals.json');

    test('peripherals.json 存在且 usageOverviewZh 都能被切开', () {
      if (!f.existsSync()) {
        markTestSkipped('assets/data/peripherals.json 不存在（数据尚未生成）');
        return;
      }
      final json = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
      final list = (json['peripherals'] as List).cast<Map<String, dynamic>>();
      expect(list, isNotEmpty);

      var checked = 0;
      for (final p in list) {
        // 兼容 v1（顶层 usageOverviewZh）与 v2（顶层保留主库值 + libraries 各库）
        final raws = <String>[];
        final top = p['usageOverviewZh'];
        if (top is String) raws.add(top);
        final libs = p['libraries'];
        if (libs is Map) {
          for (final v in libs.values) {
            if (v is Map && v['usageOverviewZh'] is String) {
              raws.add(v['usageOverviewZh'] as String);
            }
          }
        }
        for (final raw in raws) {
          if (raw.trim().isEmpty) continue;
          final steps = splitUsageSteps(raw);
          expect(steps, isNotEmpty, reason: '${p['id']} 的 usageOverviewZh 切完是空的');
          for (final s in steps) {
            expect(s.text.trim(), isNotEmpty, reason: '${p['id']} 出现空步骤');
          }
          checked++;
        }
      }
      expect(checked, greaterThan(0), reason: '没找到任何 usageOverviewZh');
    });

    test('GPIO 在真实文件里仍切出 4 个序号', () {
      if (!f.existsSync()) {
        markTestSkipped('assets/data/peripherals.json 不存在（数据尚未生成）');
        return;
      }
      final json = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
      final list = (json['peripherals'] as List).cast<Map<String, dynamic>>();
      final gpio = list.firstWhere(
        (p) => p['id'] == 'GPIO',
        orElse: () => <String, dynamic>{},
      );
      if (gpio.isEmpty) {
        markTestSkipped('真实数据里没有 GPIO');
        return;
      }
      final raw = gpio['usageOverviewZh'] as String?;
      if (raw == null || raw.trim().isEmpty) {
        markTestSkipped('GPIO 没有 usageOverviewZh');
        return;
      }
      final markers = markersOf(raw).where((m) => m.isNotEmpty).toList();
      expect(markers.length, 4, reason: 'GPIO 应有 ①②③④ 四步，实际 $markers');
    });
  });
}
