import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/api_exception.dart';
import '../core/app_theme.dart';
import '../core/formatters.dart';
import '../models/user_profile.dart';
import '../repositories/report_repository.dart';
import '../routing/app_router.dart';
import '../routing/app_routes.dart';
import '../widgets/empty_view.dart';
import '../widgets/error_view.dart';
import '../widgets/loading_view.dart';
import '../widgets/user_whatsapp_button.dart';
import '../widgets/whatsapp_number_dialog.dart';

/// All of this admin's casino users (the bonus recipients from the weekly
/// reports): their saved WhatsApp number, the balance carried forward, and
/// the full calculation history behind each. Casino users never log in.
class UsersScreen extends StatefulWidget {
  const UsersScreen({super.key});

  @override
  State<UsersScreen> createState() => _UsersScreenState();
}

class _UsersScreenState extends State<UsersScreen> {
  bool _loading = true;
  String? _errorMessage;
  List<UserProfile> _users = [];
  String _query = '';
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  Future<void> _load({bool silent = false}) async {
    if (!silent) {
      setState(() {
        _loading = true;
        _errorMessage = null;
      });
    }
    try {
      final users = await context.read<ReportRepository>().listUsers(query: _query);
      if (!mounted) return;
      setState(() {
        _users = users;
        _loading = false;
        _errorMessage = null;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage = e.userMessage;
        _loading = false;
      });
    }
  }

  void _onQueryChanged(String value) {
    _query = value;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () {
      if (mounted) _load(silent: true);
    });
  }

  Future<void> _editNumber(UserProfile user) async {
    final repo = context.read<ReportRepository>();
    final saved = await showWhatsAppNumberDialog(
      context,
      userName: user.name,
      currentNumber: user.whatsappNumber,
      onSave: (number) async {
        final updated = await repo.saveWhatsAppNumber(user.userId, number);
        return updated.whatsappNumber;
      },
    );
    if (saved == null || !mounted) return;
    _load(silent: true);
  }

  void _open(UserProfile user) {
    Navigator.of(context).pushNamed(
      AppRoutes.userDetail,
      arguments: UserDetailArgs(userId: user.userId, userName: user.name),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Casino users')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(AppSpacing.md),
            child: TextField(
              decoration: const InputDecoration(
                hintText: 'Search by User ID / Name',
                prefixIcon: Icon(Icons.search),
                isDense: true,
              ),
              onChanged: _onQueryChanged,
            ),
          ),
          Expanded(child: _buildList(context)),
        ],
      ),
    );
  }

  Widget _buildList(BuildContext context) {
    if (_loading) return const LoadingView();
    if (_errorMessage != null) return ErrorView(message: _errorMessage!, onRetry: _load);
    if (_users.isEmpty) {
      return EmptyView(
        icon: Icons.groups_outlined,
        message: _query.trim().isEmpty
            ? 'No users yet.\nUsers appear here after you upload a report.'
            : 'No users match your search.',
      );
    }

    return RefreshIndicator(
      onRefresh: _load,
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 820),
          child: ListView.separated(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(AppSpacing.md, 0, AppSpacing.md, AppSpacing.lg),
            itemCount: _users.length,
            separatorBuilder: (_, __) => const SizedBox(height: AppSpacing.sm),
            itemBuilder: (context, index) {
              final user = _users[index];
              final carry = user.carryForwardBalance;
              return Card(
                child: InkWell(
                  borderRadius: BorderRadius.circular(16),
                  onTap: () => _open(user),
                  child: Padding(
                    padding: const EdgeInsets.all(AppSpacing.md),
                    child: Row(
                      children: [
                        CircleAvatar(
                          backgroundColor: AppTheme.surfaceMuted,
                          child: Text(
                            user.name.isNotEmpty ? user.name[0].toUpperCase() : '?',
                            style: const TextStyle(color: AppTheme.navy, fontWeight: FontWeight.w800),
                          ),
                        ),
                        const SizedBox(width: AppSpacing.sm),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                user.name,
                                style: Theme.of(context).textTheme.titleSmall,
                                overflow: TextOverflow.ellipsis,
                              ),
                              const SizedBox(height: 2),
                              Text(
                                user.hasWhatsAppNumber ? user.whatsappNumber! : 'No WhatsApp number',
                                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                      color: user.hasWhatsAppNumber ? Colors.black54 : AppTheme.warning,
                                    ),
                              ),
                              if (carry != null && carry < 0)
                                Text(
                                  'Carried forward: ${Formatters.rupees(carry)}',
                                  style: Theme.of(context)
                                      .textTheme
                                      .bodySmall
                                      ?.copyWith(color: AppTheme.danger, fontWeight: FontWeight.w600),
                                ),
                              const SizedBox(height: AppSpacing.sm),
                              UserWhatsAppButton(user: user, onChanged: () => _load(silent: true)),
                            ],
                          ),
                        ),
                        IconButton(
                          tooltip: user.hasWhatsAppNumber ? 'Edit WhatsApp number' : 'Add WhatsApp number',
                          icon: Icon(
                            user.hasWhatsAppNumber ? Icons.edit_outlined : Icons.add_ic_call_outlined,
                            color: AppTheme.blue,
                          ),
                          onPressed: () => _editNumber(user),
                        ),
                        const Icon(Icons.chevron_right, color: Colors.black26),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}
