import 'package:supabase_flutter/supabase_flutter.dart';

/// Supabase 后端配置（复用 legacy 后端，零改）。
///
/// 连接信息来源（只读参考，勿改）：
///   /Users/serein/Desktop/《三猫书桌》/01_代码工程/深海2/三猫书桌/ThreeCatsKit/Sources/CatAccount/Backend.swift
/// anon key 受 RLS 保护，可入端；service_role 绝不入端（铁律）。
///
/// local-first：未初始化 / 未登录时所有云调用静默跳过，本地 drift 不破。
class SupabaseConfig {
  static const String url = 'https://wbopbcjrxmsvsinttrdz.supabase.co';
  static const String anonKey = 'sb_publishable_YNWE5VgJ27_sXTrK-_qYog_43oii0XP';

  static bool _initialized = false;
  static bool get isInitialized => _initialized;

  /// 初始化。失败（无网/配置错）不抛，降级 local-first。
  static Future<bool> initialize() async {
    try {
      await Supabase.initialize(url: url, anonKey: anonKey);
      _initialized = true;
      return true;
    } catch (e) {
      _initialized = false;
      return false;
    }
  }

  /// 客户端（仅在 isInitialized 时用）。
  static SupabaseClient get client => Supabase.instance.client;

  /// 当前用户（未登录为 null）。
  static User? get currentUser =>
      _initialized ? Supabase.instance.client.auth.currentUser : null;

  static bool get isLoggedIn => currentUser != null;
}
