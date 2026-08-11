import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/providers.dart';
import '../../core/supabase_client.dart';

/// 邮箱登录屏（简陋即可，统一后做）。
/// 未配置/未初始化 Supabase 时显示「离线可用」提示，允许跳过（local-first 不破）。
class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;
  String? _message;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _signIn() async {
    setState(() { _busy = true; _message = null; });
    try {
      await SupabaseConfig.client.auth.signInWithPassword(
        email: _email.text.trim(),
        password: _password.text,
      );
      // 登录成功由 authStateProvider 广播，go_router 重定向回主页
      if (mounted) setState(() => _message = '✓ 已登录');
    } on AuthException catch (e) {
      setState(() => _message = '登录失败：${e.message}');
    } catch (e) {
      setState(() => _message = '网络错误：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _signUp() async {
    setState(() { _busy = true; _message = null; });
    try {
      await SupabaseConfig.client.auth.signUp(
        email: _email.text.trim(),
        password: _password.text,
      );
      if (mounted) setState(() => _message = '✓ 已注册（若需邮箱验证请查收）');
    } on AuthException catch (e) {
      setState(() => _message = '注册失败：${e.message}');
    } catch (e) {
      setState(() => _message = '网络错误：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final configured = SupabaseConfig.isInitialized;
    return Scaffold(
      appBar: AppBar(title: const Text('登录 · 三猫书桌')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 380),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text('🐱', style: TextStyle(fontSize: 48), textAlign: TextAlign.center),
                const SizedBox(height: 16),
                if (!configured)
                  const Card(
                    color: Color(0xFFFFF3CD),
                    child: Padding(
                      padding: EdgeInsets.all(12),
                      child: Text('Supabase 未连接，离线可用（local-first）。登录后可云同步。'),
                    ),
                  ),
                TextField(
                  controller: _email,
                  keyboardType: TextInputType.emailAddress,
                  decoration: const InputDecoration(labelText: '邮箱'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _password,
                  obscureText: true,
                  decoration: const InputDecoration(labelText: '密码'),
                  onSubmitted: (_) => _signIn(),
                ),
                const SizedBox(height: 20),
                FilledButton(
                  onPressed: (_busy || !configured) ? null : _signIn,
                  child: Text(_busy ? '…' : '登录'),
                ),
                const SizedBox(height: 8),
                OutlinedButton(
                  onPressed: (_busy || !configured) ? null : _signUp,
                  child: const Text('注册新账号'),
                ),
                if (_message != null) ...[
                  const SizedBox(height: 16),
                  Text(_message!, textAlign: TextAlign.center),
                ],
                const SizedBox(height: 24),
                Consumer(builder: (context, ref, _) {
                  final user = ref.watch(authStateProvider).value;
                  if (user == null) return const SizedBox.shrink();
                  return Text('当前：${user.email}', textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.green));
                }),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
