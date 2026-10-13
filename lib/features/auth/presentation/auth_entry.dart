import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../data/auth_repository.dart';

class AuthEntry extends StatelessWidget {
  const AuthEntry({super.key, required this.repository});

  final AuthRepository repository;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<bool>(
      stream: repository.authStateChanges,
      initialData: repository.isSignedIn,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return const _MessageScreen(
            title: 'Authentication unavailable',
            message:
                'Mizzy could not read the current sign-in state. Check the '
                'connection and app configuration, then restart the app.',
          );
        }
        if (!snapshot.hasData) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        return snapshot.data!
            ? WorkspaceScreen(repository: repository)
            : SignInScreen(repository: repository);
      },
    );
  }
}

class SignInScreen extends StatefulWidget {
  const SignInScreen({super.key, required this.repository});

  final AuthRepository repository;

  @override
  State<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends State<SignInScreen> {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();
  bool _createAccount = false;
  bool _busy = false;
  String? _message;
  bool _messageIsError = false;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    FocusScope.of(context).unfocus();
    if (!_formKey.currentState!.validate()) {
      return;
    }

    setState(() {
      _busy = true;
      _message = null;
      _messageIsError = false;
    });

    try {
      if (_createAccount) {
        final result = await widget.repository.signUp(
          email: _emailController.text,
          password: _passwordController.text,
        );
        if (!mounted) return;
        setState(() {
          _message = result.emailConfirmationRequired
              ? 'Check your email to confirm the account, then sign in.'
              : 'Account created. Your session is being opened.';
        });
      } else {
        await widget.repository.signIn(
          email: _emailController.text,
          password: _passwordController.text,
        );
      }
    } on AuthException catch (error) {
      _showError(error.message);
    } on ArgumentError catch (error) {
      _showError(error.message?.toString() ?? 'Review the fields and retry.');
    } on Object {
      _showError(
        'Mizzy could not complete authentication. Check your connection and '
        'project Auth settings, then retry.',
      );
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  void _showError(String message) {
    if (!mounted) return;
    setState(() {
      _message = message;
      _messageIsError = true;
    });
  }

  String? _validateEmail(String? value) {
    if (!AuthInputValidator.isValidEmail(value ?? '')) {
      return 'Enter a valid email address.';
    }
    return null;
  }

  String? _validatePassword(String? value) {
    final password = value ?? '';
    if (_createAccount && !AuthInputValidator.isValidPassword(password)) {
      return 'Use at least 8 characters.';
    }
    if (password.isEmpty) {
      return 'Enter your password.';
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Mizzy POS')),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Form(
                  key: _formKey,
                  child: AutofillGroup(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Icon(
                          Icons.storefront_outlined,
                          size: 48,
                          color: theme.colorScheme.primary,
                        ),
                        const SizedBox(height: 16),
                        Text(
                          _createAccount ? 'Create your Mizzy account' : 'Welcome back',
                          style: theme.textTheme.headlineSmall,
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          _createAccount
                              ? 'Use your email to create an owner account.'
                              : 'Sign in to access your restaurant workspaces.',
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 24),
                        TextFormField(
                          key: const ValueKey('auth-email'),
                          controller: _emailController,
                          keyboardType: TextInputType.emailAddress,
                          textInputAction: TextInputAction.next,
                          autofillHints: const [AutofillHints.username, AutofillHints.email],
                          autocorrect: false,
                          decoration: const InputDecoration(
                            labelText: 'Email',
                            prefixIcon: Icon(Icons.email_outlined),
                            border: OutlineInputBorder(),
                          ),
                          validator: _validateEmail,
                        ),
                        const SizedBox(height: 16),
                        TextFormField(
                          key: const ValueKey('auth-password'),
                          controller: _passwordController,
                          obscureText: true,
                          textInputAction: _createAccount
                              ? TextInputAction.next
                              : TextInputAction.done,
                          autofillHints: [
                            _createAccount
                                ? AutofillHints.newPassword
                                : AutofillHints.password,
                          ],
                          decoration: const InputDecoration(
                            labelText: 'Password',
                            prefixIcon: Icon(Icons.lock_outline),
                            border: OutlineInputBorder(),
                          ),
                          validator: _validatePassword,
                          onFieldSubmitted: (_) {
                            if (!_createAccount) _submit();
                          },
                        ),
                        if (_createAccount) ...[
                          const SizedBox(height: 16),
                          TextFormField(
                            key: const ValueKey('auth-confirm-password'),
                            controller: _confirmPasswordController,
                            obscureText: true,
                            autofillHints: const [AutofillHints.newPassword],
                            decoration: const InputDecoration(
                              labelText: 'Confirm password',
                              prefixIcon: Icon(Icons.lock_reset_outlined),
                              border: OutlineInputBorder(),
                            ),
                            validator: (value) {
                              if (value != _passwordController.text) {
                                return 'Passwords do not match.';
                              }
                              return null;
                            },
                          ),
                        ],
                        if (_message != null) ...[
                          const SizedBox(height: 16),
                          Text(
                            _message!,
                            key: const ValueKey('auth-message'),
                            style: TextStyle(
                              color: _messageIsError
                                  ? theme.colorScheme.error
                                  : theme.colorScheme.primary,
                            ),
                          ),
                        ],
                        const SizedBox(height: 20),
                        FilledButton(
                          onPressed: _busy ? null : _submit,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            child: _busy
                                ? const SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: CircularProgressIndicator(strokeWidth: 2),
                                  )
                                : Text(_createAccount ? 'Create account' : 'Sign in'),
                          ),
                        ),
                        const SizedBox(height: 8),
                        TextButton(
                          onPressed: _busy
                              ? null
                              : () {
                                  setState(() {
                                    _createAccount = !_createAccount;
                                    _message = null;
                                    _messageIsError = false;
                                  });
                                },
                          child: Text(
                            _createAccount
                                ? 'Already have an account? Sign in'
                                : 'New to Mizzy? Create an account',
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class WorkspaceScreen extends StatefulWidget {
  const WorkspaceScreen({super.key, required this.repository});

  final AuthRepository repository;

  @override
  State<WorkspaceScreen> createState() => _WorkspaceScreenState();
}

class _WorkspaceScreenState extends State<WorkspaceScreen> {
  final _organizationController = TextEditingController();
  final _branchController = TextEditingController();
  List<OrganizationAccess> _organizations = const [];
  bool _loading = true;
  bool _creating = false;
  bool _showCreateForm = false;
  String? _error;
  String? _notice;

  @override
  void initState() {
    super.initState();
    _loadOrganizations();
  }

  @override
  void dispose() {
    _organizationController.dispose();
    _branchController.dispose();
    super.dispose();
  }

  Future<void> _loadOrganizations() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final organizations = await widget.repository.listMyOrganizations();
      if (!mounted) return;
      setState(() {
        _organizations = organizations;
        _showCreateForm = organizations.isEmpty;
      });
    } on Object {
      if (!mounted) return;
      setState(() {
        _error =
            'Unable to load your workspaces. Check the network and workspace '
            'access policies, then retry.';
      });
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _createOrganization() async {
    final organizationName = _organizationController.text.trim();
    final branchName = _branchController.text.trim();
    if (organizationName.isEmpty || branchName.isEmpty) {
      setState(() => _error = 'Enter both a restaurant name and first branch name.');
      return;
    }

    setState(() {
      _creating = true;
      _error = null;
      _notice = null;
    });
    try {
      await widget.repository.createOrganization(
        name: organizationName,
        firstBranchName: branchName,
      );
      if (!mounted) return;
      _organizationController.clear();
      _branchController.clear();
      setState(() {
        _notice = 'Restaurant workspace created.';
        _showCreateForm = false;
      });
      await _loadOrganizations();
    } on AuthException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } on ArgumentError catch (error) {
      if (mounted) {
        setState(() => _error = error.message?.toString() ?? 'Review the fields.');
      }
    } on Object {
      if (mounted) {
        setState(() {
          _error =
              'Mizzy could not create the workspace. Check your access and '
              'try again; no success is assumed without server confirmation.';
        });
      }
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  Future<void> _signOut() async {
    try {
      await widget.repository.signOut();
    } on Object {
      if (mounted) {
        setState(() => _error = 'Sign-out failed. Check the connection and retry.');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Your workspaces'),
        actions: [
          IconButton(
            tooltip: 'Sign out',
            onPressed: _signOut,
            icon: const Icon(Icons.logout),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            widget.repository.currentUserEmail ?? 'Signed-in account',
            style: theme.textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          const Text(
            'Choose a restaurant and branch. Your server-side membership and '
            'RLS policies control which workspaces appear here.',
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            _InlineNotice(message: _error!, isError: true),
          ],
          if (_notice != null) ...[
            const SizedBox(height: 12),
            _InlineNotice(message: _notice!, isError: false),
          ],
          const SizedBox(height: 16),
          if (_loading)
            const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: CircularProgressIndicator(),
              ),
            )
          else if (_organizations.isEmpty)
            const _EmptyWorkspaces()
          else
            for (final organization in _organizations)
              _OrganizationCard(organization: organization),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _creating || _loading
                ? null
                : () => setState(() => _showCreateForm = !_showCreateForm),
            icon: const Icon(Icons.add_business_outlined),
            label: Text(
              _showCreateForm ? 'Cancel new workspace' : 'Create a restaurant workspace',
            ),
          ),
          if (_showCreateForm) ...[
            const SizedBox(height: 12),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text('Restaurant setup', style: theme.textTheme.titleLarge),
                    const SizedBox(height: 12),
                    TextField(
                      key: const ValueKey('organization-name'),
                      controller: _organizationController,
                      maxLength: 120,
                      decoration: const InputDecoration(
                        labelText: 'Restaurant / business name',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      key: const ValueKey('branch-name'),
                      controller: _branchController,
                      maxLength: 120,
                      decoration: const InputDecoration(
                        labelText: 'First branch name',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 8),
                    FilledButton(
                      onPressed: _creating ? null : _createOrganization,
                      child: _creating
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Text('Create restaurant and branch'),
                    ),
                  ],
                ),
              ),
            ),
          ],
          const SizedBox(height: 24),
          const _InlineNotice(
            message:
                'Workspace access is active, but Counter, Orders, and Kitchen '
                'screens are still under implementation. Do not use this build '
                'to process real sales.',
            isError: false,
          ),
        ],
      ),
    );
  }
}

class _OrganizationCard extends StatelessWidget {
  const _OrganizationCard({required this.organization});

  final OrganizationAccess organization;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(organization.name, style: theme.textTheme.titleLarge),
            const SizedBox(height: 4),
            Text('Organization role: ${organization.role}'),
            const Divider(height: 24),
            if (organization.branches.isEmpty)
              const Text(
                'No active branch assignment is visible for this account. '
                'Ask an Owner to assign a branch.',
              )
            else
              for (final branch in organization.branches)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.store_outlined),
                  title: Text(branch.name),
                  subtitle: Text('Branch role: ${branch.role}'),
                  trailing: const Icon(Icons.lock_clock_outlined),
                ),
          ],
        ),
      ),
    );
  }
}

class _EmptyWorkspaces extends StatelessWidget {
  const _EmptyWorkspaces();

  @override
  Widget build(BuildContext context) {
    return const Card(
      child: Padding(
        padding: EdgeInsets.all(20),
        child: Column(
          children: [
            Icon(Icons.store_mall_directory_outlined, size: 40),
            SizedBox(height: 12),
            Text('No restaurant workspace yet'),
            SizedBox(height: 6),
            Text(
              'Create a restaurant and first branch. The server will assign '
              'the signed-in user as Owner in one database transaction.',
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

class _InlineNotice extends StatelessWidget {
  const _InlineNotice({required this.message, required this.isError});

  final String message;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isError ? colors.errorContainer : colors.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        message,
        style: TextStyle(
          color: isError ? colors.onErrorContainer : colors.onSurfaceVariant,
        ),
      ),
    );
  }
}

class _MessageScreen extends StatelessWidget {
  const _MessageScreen({required this.title, required this.message});

  final String title;
  final String message;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Mizzy POS')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.cloud_off_outlined, size: 44),
              const SizedBox(height: 16),
              Text(title, style: Theme.of(context).textTheme.headlineSmall),
              const SizedBox(height: 8),
              Text(message, textAlign: TextAlign.center),
            ],
          ),
        ),
      ),
    );
  }
}
