import 'package:flutter_test/flutter_test.dart';
import 'package:mizzy/features/auth/data/auth_repository.dart';

void main() {
  group('AuthRepository sync event role preflight', () {
    test('owner can process all currently supported event kinds', () {
      expect(_allows('owner', 'owner', 'order', 'create'), isTrue);
      expect(_allows('owner', 'owner', 'kitchen_ticket', 'create'), isTrue);
      expect(_allows('owner', 'owner', 'kitchen_ticket', 'transition'), isTrue);
    });

    test('manager can create orders and apply Kitchen transitions', () {
      expect(_allows('member', 'manager', 'order', 'create'), isTrue);
      expect(_allows('member', 'manager', 'kitchen_ticket', 'create'), isTrue);
      expect(_allows('member', 'manager', 'kitchen_ticket', 'transition'), isTrue);
    });

    test('counter can save order and acknowledge order-created Kitchen ticket', () {
      expect(_allows('member', 'counter', 'order', 'create'), isTrue);
      expect(_allows('member', 'counter', 'kitchen_ticket', 'create'), isTrue);
      expect(_allows('member', 'counter', 'kitchen_ticket', 'transition'), isFalse);
    });

    test('Kitchen role can transition tickets but cannot upload orders', () {
      expect(_allows('member', 'kitchen', 'order', 'create'), isFalse);
      expect(_allows('member', 'kitchen', 'kitchen_ticket', 'create'), isFalse);
      expect(_allows('member', 'kitchen', 'kitchen_ticket', 'transition'), isTrue);
    });

    test('unknown event kind or operation fails closed', () {
      expect(_allows('member', 'counter', 'payment', 'create'), isFalse);
      expect(_allows('member', 'manager', 'order', 'delete'), isFalse);
      expect(_allows('member', 'kitchen', 'kitchen_ticket', 'delete'), isFalse);
    });

    test('organization membership without a branch role fails closed', () {
      expect(_allows('member', '', 'order', 'create'), isFalse);
      expect(_allows('member', '', 'kitchen_ticket', 'transition'), isFalse);
    });
  });
}

bool _allows(
  String organizationRole,
  String branchRole,
  String entityType,
  String operation,
) => AuthRepository.allowsSyncEventForRoles(
  organizationRole: organizationRole,
  branchRole: branchRole,
  entityType: entityType,
  operation: operation,
);
