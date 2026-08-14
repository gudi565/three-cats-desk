import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'pack_import_button.dart';
import 'user_profile.dart';

/// 本地专属初始化向导（本地部署方向）：首次启动时填写 昵称/目标院校/专业/考试日期。
///
/// 这是「专属考研系统」的第一触点——不是登录（无账号），而是"让这只猫认识你"。
/// 填完后首页/开机语都带上用户身份与目标，形成「XX 的专属备考系统」的专属感。
///
/// 全部可跳过/留空：昵称必填（猫要叫他），院校/专业/日期可后补（设置页改）。
class OnboardingScreen extends ConsumerStatefulWidget {
  const OnboardingScreen({super.key});

  @override
  ConsumerState<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends ConsumerState<OnboardingScreen> {
  final _nickname = TextEditingController();
  final _school = TextEditingController();
  final _major = TextEditingController();
  DateTime? _examDate;

  @override
  void dispose() {
    _nickname.dispose();
    _school.dispose();
    _major.dispose();
    super.dispose();
  }

  String _fmt(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: DateTime(now.year, 12, 21), // 考研初试默认 12 月下旬
      firstDate: now,
      lastDate: DateTime(now.year + 3),
      helpText: '选择考试日期',
    );
    if (picked != null) setState(() => _examDate = picked);
  }

  Future<void> _finish() async {
    final nick = _nickname.text.trim();
    if (nick.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('给自己起个名字吧，猫咪想认识你')),
      );
      return;
    }
    await ref.read(userProfileProvider.notifier).save(UserProfile(
          nickname: nick,
          school: _school.text.trim(),
          major: _major.text.trim(),
          examDate: _examDate == null ? '' : _fmt(_examDate!),
          setupDone: true,
        ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(28),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text('🐱', style: TextStyle(fontSize: 64), textAlign: TextAlign.center),
                  const SizedBox(height: 16),
                  const Text(
                    '欢迎来到你的书桌',
                    style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '这是为你一个人准备的备考系统。\n先认识一下，猫会陪你到考场那天。',
                    style: TextStyle(fontSize: 14, color: Colors.grey.shade600, height: 1.5),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 32),
                  TextField(
                    controller: _nickname,
                    decoration: const InputDecoration(
                      labelText: '怎么称呼你 *',
                      hintText: '名字或昵称',
                      prefixIcon: Icon(Icons.person_outline),
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _school,
                    decoration: const InputDecoration(
                      labelText: '目标院校',
                      hintText: '如：北京大学',
                      prefixIcon: Icon(Icons.school_outlined),
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _major,
                    decoration: const InputDecoration(
                      labelText: '专业方向',
                      hintText: '如：新闻与传播',
                      prefixIcon: Icon(Icons.menu_book_outlined),
                    ),
                  ),
                  const SizedBox(height: 16),
                  OutlinedButton.icon(
                    onPressed: _pickDate,
                    icon: const Icon(Icons.event_outlined),
                    label: Text(_examDate == null ? '选考试日期（可后补）' : '考试日期：${_fmt(_examDate!)}'),
                  ),
                  const SizedBox(height: 32),
                  FilledButton(
                    onPressed: _finish,
                    style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 16)),
                    child: const Text('开始我的备考', style: TextStyle(fontSize: 16)),
                  ),
                  const SizedBox(height: 12),
                  // 有 .smpack 专属资源包的用户：这里一键导入，院校/专业/日期自动预填
                  const Text('已购买专属资源包？', style: TextStyle(fontSize: 13)),
                  const SizedBox(height: 6),
                  const PackImportButton(),
                  const SizedBox(height: 12),
                  Text(
                    '数据只存在这台设备上，无需联网。',
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade500),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
