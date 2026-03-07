import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

// Firebase Auth 인스턴스 Provider
final firebaseAuthProvider = Provider<FirebaseAuth>((ref) {
  return FirebaseAuth.instance;
});

// Firebase Firestore 인스턴스 Provider
final firestoreProvider = Provider<FirebaseFirestore>((ref) {
  return FirebaseFirestore.instance;
});

// 현재 Auth 상태를 Stream으로 감시
final authStateProvider = StreamProvider<User?>((ref) {
  return ref.watch(firebaseAuthProvider).authStateChanges();
});

// Auth 관련 비즈니스 로직을 담당하는 Notifier
class AuthNotifier extends AsyncNotifier<void> {
  @override
  Future<void> build() async {}

  FirebaseAuth get _auth => ref.read(firebaseAuthProvider);
  FirebaseFirestore get _firestore => ref.read(firestoreProvider);

  /// 이메일/비밀번호 로그인
  Future<void> signInWithEmail({
    required String email,
    required String password,
  }) async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(() async {
      await _auth.signInWithEmailAndPassword(
        email: email,
        password: password,
      );
    });
  }

  /// 이메일/비밀번호 회원가입 + Firestore 초기 데이터 생성
  Future<void> registerWithEmail({
    required String email,
    required String password,
    required String displayName,
  }) async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(() async {
      // 1. Firebase Auth 계정 생성
      final credential = await _auth.createUserWithEmailAndPassword(
        email: email,
        password: password,
      );
      final user = credential.user!;

      // 2. displayName 업데이트
      await user.updateDisplayName(displayName);

      // 3. Firestore users 컬렉션에 초기 데이터 생성
      await _createUserDocument(user, displayName);
    });
  }

  /// Firestore users 컬렉션 초기 문서 생성
  Future<void> _createUserDocument(User user, String displayName) async {
    final userDoc = _firestore.collection('users').doc(user.uid);
    final docSnapshot = await userDoc.get();

    // 이미 존재하면 생성하지 않음 (중복 방지)
    if (!docSnapshot.exists) {
      await userDoc.set({
        'uid': user.uid,
        'email': user.email,
        'displayName': displayName,
        'createdAt': FieldValue.serverTimestamp(),
        'portfolio': {
          'cash': 10000000, // 초기 현금 1000만원
          'totalAsset': 10000000,
          'stocks': {}, // 보유 주식 (종목코드: {quantity, avgPrice})
        },
        'tradeHistory': [], // 거래 내역
      });
    }
  }

  /// 로그아웃
  Future<void> signOut() async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(() async {
      await _auth.signOut();
    });
  }
}

final authNotifierProvider =
    AsyncNotifierProvider<AuthNotifier, void>(AuthNotifier.new);

/// Firebase Auth 에러 코드 → 한국어 메시지 변환
String getAuthErrorMessage(String code) {
  switch (code) {
    case 'user-not-found':
      return '등록되지 않은 이메일입니다.';
    case 'wrong-password':
      return '비밀번호가 올바르지 않습니다.';
    case 'email-already-in-use':
      return '이미 사용 중인 이메일입니다.';
    case 'invalid-email':
      return '올바른 이메일 형식이 아닙니다.';
    case 'weak-password':
      return '비밀번호는 6자 이상이어야 합니다.';
    case 'too-many-requests':
      return '잠시 후 다시 시도해 주세요.';
    case 'network-request-failed':
      return '네트워크 연결을 확인해 주세요.';
    default:
      return '오류가 발생했습니다. 다시 시도해 주세요.';
  }
}