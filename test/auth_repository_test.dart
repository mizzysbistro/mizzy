import 'package:flutter_test/flutter_test.dart';

import 'package:mizzy/features/auth/data/auth_repository.dart';

void main() {
  group('AuthInputValidator', () {
    test('accepts normal emails after trimming', () {
      expect(AuthInputValidator.isValidEmail('owner@example.com'), isTrue);
      expect(AuthInputValidator.isValidEmail(' owner+pos@restaurant.ph '), isTrue);
    });

    test('rejects malformed and overlong email addresses', () {
      expect(AuthInputValidator.isValidEmail(''), isFalse);
      expect(AuthInputValidator.isValidEmail('not-an-email'), isFalse);
      expect(AuthInputValidator.isValidEmail('owner@localhost'), isFalse);
      expect(
        AuthInputValidator.isValidEmail('${List<String>.filled(250, 'a').join()}@example.com'),
        isFalse,
      );
    });

    test('uses an eight-character minimum for new passwords', () {
      expect(AuthInputValidator.isValidPassword('1234567'), isFalse);
      expect(AuthInputValidator.isValidPassword('12345678'), isTrue);
      expect(AuthInputValidator.isValidPassword('longer-password'), isTrue);
    });
  });
}
