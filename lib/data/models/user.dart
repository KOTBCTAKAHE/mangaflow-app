class UserProfile {
  const UserProfile({required this.id, required this.email, required this.username, this.displayName});
  final String id;
  final String email;
  final String username;
  final String? displayName;

  String get shownName => (displayName?.isNotEmpty ?? false) ? displayName! : username;

  factory UserProfile.fromJson(Map<String, dynamic> j) => UserProfile(
        id: j['id'] as String,
        email: j['email'] as String,
        username: j['username'] as String,
        displayName: j['display_name'] as String?,
      );

  Map<String, dynamic> toJson() => {'id': id, 'email': email, 'username': username, 'display_name': displayName};
}

class AuthTokens {
  const AuthTokens({required this.access, required this.refresh, required this.expiresAt});
  final String access;
  final String refresh;
  final DateTime expiresAt;

  bool get isExpiringSoon => DateTime.now().isAfter(expiresAt.subtract(const Duration(seconds: 60)));

  factory AuthTokens.fromJson(Map<String, dynamic> j) => AuthTokens(
        access: j['access_token'] as String,
        refresh: j['refresh_token'] as String,
        expiresAt: DateTime.now().add(Duration(seconds: j['expires_in'] as int? ?? 900)),
      );
}
