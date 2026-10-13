import 'package:supabase_flutter/supabase_flutter.dart';

class BranchAccess {
  const BranchAccess({
    required this.id,
    required this.organizationId,
    required this.name,
    required this.role,
  });

  final String id;
  final String organizationId;
  final String name;
  final String role;
}

class OrganizationAccess {
  const OrganizationAccess({
    required this.id,
    required this.name,
    required this.role,
    required this.branches,
  });

  final String id;
  final String name;
  final String role;
  final List<BranchAccess> branches;
}

class AuthSignUpResult {
  const AuthSignUpResult({required this.emailConfirmationRequired});

  final bool emailConfirmationRequired;
}

/// Narrow wrapper over Supabase Auth and the tenant bootstrap RPC.
///
/// No service-role credential is accepted here. The caller's signed-in session
/// and PostgreSQL RLS policies determine which tenant/branch records are visible.
class AuthRepository {
  AuthRepository({SupabaseClient? client})
    : _client = client ?? Supabase.instance.client;

  final SupabaseClient _client;

  bool get isSignedIn => _client.auth.currentSession != null;

  String? get currentUserEmail => _client.auth.currentUser?.email;

  String? get currentUserId => _client.auth.currentUser?.id;

  Stream<bool> get authStateChanges => _client.auth.onAuthStateChange
      .map((state) => state.session != null)
      .distinct();

  Future<void> signIn({required String email, required String password}) async {
    final normalizedEmail = email.trim().toLowerCase();
    if (!AuthInputValidator.isValidEmail(normalizedEmail)) {
      throw ArgumentError.value(email, 'email', 'Enter a valid email address.');
    }
    if (password.isEmpty) {
      throw ArgumentError.value(password, 'password', 'Enter your password.');
    }
    await _client.auth.signInWithPassword(
      email: normalizedEmail,
      password: password,
    );
  }

  Future<AuthSignUpResult> signUp({
    required String email,
    required String password,
  }) async {
    final normalizedEmail = email.trim().toLowerCase();
    if (!AuthInputValidator.isValidEmail(normalizedEmail)) {
      throw ArgumentError.value(email, 'email', 'Enter a valid email address.');
    }
    if (!AuthInputValidator.isValidPassword(password)) {
      throw ArgumentError.value(
        password,
        'password',
        'Use at least 8 characters for your password.',
      );
    }
    final response = await _client.auth.signUp(
      email: normalizedEmail,
      password: password,
    );
    return AuthSignUpResult(
      emailConfirmationRequired: response.session == null,
    );
  }

  Future<void> signOut() => _client.auth.signOut();

  Future<void> createOrganization({
    required String name,
    required String firstBranchName,
  }) async {
    if (name.trim().isEmpty || name.trim().length > 120) {
      throw ArgumentError.value(name, 'name', 'Use 1 to 120 characters.');
    }
    if (firstBranchName.trim().isEmpty || firstBranchName.trim().length > 120) {
      throw ArgumentError.value(
        firstBranchName,
        'firstBranchName',
        'Use 1 to 120 characters.',
      );
    }
    if (!isSignedIn) {
      throw StateError('Sign in before creating a restaurant workspace.');
    }

    final response = await _client.rpc(
      'create_organization',
      params: <String, Object?>{
        'p_organization_name': name.trim(),
        'p_first_branch_name': firstBranchName.trim(),
      },
    );

    // The RPC returns one row. Validate the shape before telling the user
    // creation succeeded; never silently treat an unexpected response as success.
    if (response is! List || response.isEmpty || response.first is! Map) {
      throw const FormatException(
        'The server returned an unexpected organization response.',
      );
    }
    final row = Map<String, Object?>.from(response.first as Map);
    if (row['organization_id'] is! String || row['branch_id'] is! String) {
      throw const FormatException(
        'The server did not return the organization and branch identifiers.',
      );
    }
  }

  Future<List<OrganizationAccess>> listMyOrganizations() async {
    final user = _client.auth.currentUser;
    if (user == null) {
      throw StateError('Sign in to view restaurant workspaces.');
    }

    final rawOrganizations = await _client
        .from('organizations')
        .select('id, name')
        .order('created_at', ascending: true);
    final organizations = <OrganizationAccess>[];

    for (final rawOrganization in rawOrganizations) {
      final organization = Map<String, Object?>.from(rawOrganization);
      final organizationId = organization['id']! as String;
      final membership = await _client
          .from('organization_memberships')
          .select('role, is_active')
          .eq('organization_id', organizationId)
          .eq('user_id', user.id)
          .maybeSingle();
      if (membership == null || membership['is_active'] == false) {
        continue;
      }

      final organizationRole = membership['role']! as String;
      final rawBranches = await _client
          .from('branches')
          .select('id, organization_id, name')
          .eq('organization_id', organizationId)
          .eq('is_active', true)
          .order('name', ascending: true);
      final rawBranchMemberships = await _client
          .from('branch_memberships')
          .select('branch_id, role')
          .eq('organization_id', organizationId)
          .eq('user_id', user.id)
          .eq('is_active', true);
      final branchRoles = <String, String>{
        for (final membershipRow in rawBranchMemberships)
          membershipRow['branch_id']! as String:
              membershipRow['role']! as String,
      };
      final branches = <BranchAccess>[];

      for (final rawBranch in rawBranches) {
        final branch = Map<String, Object?>.from(rawBranch);
        final branchId = branch['id']! as String;
        final role = organizationRole == 'owner'
            ? 'owner'
            : branchRoles[branchId];
        if (role == null) {
          // RLS should already exclude non-assigned branches. This defensive
          // check avoids displaying a branch without an explicit role mapping.
          continue;
        }
        branches.add(
          BranchAccess(
            id: branchId,
            organizationId: organizationId,
            name: branch['name']! as String,
            role: role,
          ),
        );
      }

      organizations.add(
        OrganizationAccess(
          id: organizationId,
          name: organization['name']! as String,
          role: organizationRole,
          branches: List<BranchAccess>.unmodifiable(branches),
        ),
      );
    }

    return List<OrganizationAccess>.unmodifiable(organizations);
  }

  /// Client-side preflight for the current user's role in a branch.
  ///
  /// This helper prevents the sync worker from needlessly quarantining valid
  /// events when the active account is signed into a different staff role.
  /// The server RPC/RLS remains authoritative and must recheck every write.
  Future<bool> canPerformSyncEvent({
    required String organizationId,
    required String branchId,
    required String entityType,
    required String operation,
  }) async {
    final organizations = await listMyOrganizations();
    for (final organization in organizations) {
      if (organization.id != organizationId) continue;
      for (final branch in organization.branches) {
        if (branch.id != branchId ||
            branch.organizationId != organizationId) {
          continue;
        }
        return allowsSyncEventForRoles(
          organizationRole: organization.role,
          branchRole: branch.role,
          entityType: entityType,
          operation: operation,
        );
      }
    }
    return false;
  }

  /// Pure role matrix so sync event permissions can be tested without a live
  /// Supabase session. These are preflight rules, not an authorization boundary.
  static bool allowsSyncEventForRoles({
    required String organizationRole,
    required String branchRole,
    required String entityType,
    required String operation,
  }) {
    if (organizationRole == 'owner' || branchRole == 'owner' ||
        branchRole == 'manager') {
      return (entityType == 'order' && operation == 'create') ||
          (entityType == 'kitchen_ticket' &&
              (operation == 'create' || operation == 'transition'));
    }

    if ((entityType == 'order' && operation == 'create') ||
        (entityType == 'kitchen_ticket' && operation == 'create')) {
      // Kitchen-create verifies/replays save_order; its RPC requires counter
      // or manager privileges because save_order creates the ticket atomically.
      return branchRole == 'counter';
    }
    if (entityType == 'kitchen_ticket' && operation == 'transition') {
      return branchRole == 'kitchen';
    }
    return false;
  }
}

class AuthInputValidator {
  const AuthInputValidator._();

  static bool isValidEmail(String value) {
    final email = value.trim();
    if (email.length > 254) {
      return false;
    }
    return RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(email);
  }

  static bool isValidPassword(String value) => value.length >= 8;
}
