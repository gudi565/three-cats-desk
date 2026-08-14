import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:three_cats_desk/core/profile/pack_installer.dart';
import 'package:three_cats_desk/core/profile/profile_notifier.dart';
import 'user_profile.dart';

/// .smpack 资源包导入交互（一键：选文件 → 安装 → 弹摘要）。
///
/// 客户交付模式（2026-08-14）：客户收到 .smpack 后在 App 里点一下即完成内置。
/// 全程不要求用户理解"词书/题库/考纲"——装完弹一句人话摘要。
class PackImportButton extends ConsumerWidget {
  final bool compact; // true=图标按钮（AppBar），false=大按钮（引导卡/向导）
  final void Function()? onInstalled; // 装完回调（向导页用它预填院校专业）
  const PackImportButton({super.key, this.compact = false, this.onInstalled});

  Future<void> _pickAndInstall(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    final files = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['smpack'],
    );
    final file = files.isEmpty ? null : files.single;
    if (file == null) return; // 用户取消
    final bytes = await file.readAsBytes();
    if (bytes.isEmpty) {
      messenger.showSnackBar(const SnackBar(content: Text('无法读取文件')));
      return;
    }
    final navigator = Navigator.of(context);
    messenger.showSnackBar(const SnackBar(content: Text('正在安装资源包…'), duration: Duration(seconds: 1)));
    try {
      final result = await ref
          .read(contentProfileProvider.notifier)
          .applyPack(bytes);
      // 装完顺手把包里的院校/专业/考试日期建议预填进档案（不覆盖已填的）
      final pack = result.profile;
      if (pack.suggestSchool.isNotEmpty || pack.suggestMajor.isNotEmpty) {
        final cur = ref.read(userProfileProvider);
        if (!cur.setupDone || (cur.school.isEmpty && cur.major.isEmpty)) {
          await ref.read(userProfileProvider.notifier).save(UserProfile(
                nickname: cur.nickname,
                school: cur.school.isNotEmpty ? cur.school : pack.suggestSchool,
                major: cur.major.isNotEmpty ? cur.major : pack.suggestMajor,
                examDate: cur.examDate.isNotEmpty ? cur.examDate : pack.examDate,
                setupDone: cur.setupDone,
              ));
        }
      }
      messenger.showSnackBar(SnackBar(
        content: Text('✅ 已安装 ${result.summary}'),
        duration: const Duration(seconds: 4),
      ));
      onInstalled?.call();
    } on PackFormatException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('导入失败：$e')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('导入失败：$e')));
    } finally {
      // 关闭文件选择器可能留下的过渡动画
      navigator.popUntil((route) => route.isFirst || route is DialogRoute);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (compact) {
      return IconButton(
        icon: const Icon(Icons.download_rounded),
        tooltip: '导入我的专属资源包',
        onPressed: () => _pickAndInstall(context, ref),
      );
    }
    return FilledButton.tonalIcon(
      onPressed: () => _pickAndInstall(context, ref),
      icon: const Icon(Icons.download_rounded),
      label: const Text('导入我的专属资源包'),
    );
  }
}

/// 首页「未装包」引导卡：装了之后消失。
class PackGuideCard extends ConsumerWidget {
  const PackGuideCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hasPack = ref.watch(contentProfileProvider).id != 'standard';
    if (hasPack) return const SizedBox.shrink();
    return Card(
      color: const Color(0xFFEAF4F7),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(children: [
              Icon(Icons.card_giftcard, size: 20, color: Color(0xFF3E8EAA)),
              SizedBox(width: 8),
              Text('激活你的专属系统',
                  style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
            ]),
            const SizedBox(height: 6),
            const Text('收到 .smpack 资源包文件后，点下面导入，'
                '你的词书、题库、考纲、文献会全部就位。',
                style: TextStyle(fontSize: 13, color: Colors.black54)),
            const SizedBox(height: 12),
            const PackImportButton(),
          ],
        ),
      ),
    );
  }
}
