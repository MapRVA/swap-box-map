import 'package:flutter/material.dart';

import '../models/amenity.dart';
import '../models/pending_edit.dart';
import '../services/edit_queue_service.dart';
import '../services/osm_auth_service.dart';
import '../services/recent_uploads_service.dart';
import '../services/settings_service.dart';
import '../services/upload_service.dart';

/// What the queue screen pops back with. `null` means the user simply backed
/// out; `EditQueueOpenEdit` means they tapped a tile to view that POI on the
/// map; `EditQueueUploaded` means an upload completed and the home map
/// should refetch.
sealed class EditQueueResult {
  const EditQueueResult();
}

class EditQueueOpenEdit extends EditQueueResult {
  const EditQueueOpenEdit(this.edit);
  final PendingEdit edit;
}

class EditQueueUploaded extends EditQueueResult {
  const EditQueueUploaded(this.count);
  final int count;
}

class EditQueueScreen extends StatefulWidget {
  const EditQueueScreen({
    super.key,
    required this.editQueueService,
    required this.authService,
    required this.recentUploadsService,
    required this.settingsService,
  });

  final EditQueueService editQueueService;
  final OsmAuthService authService;
  final RecentUploadsService recentUploadsService;
  final SettingsService settingsService;

  @override
  State<EditQueueScreen> createState() => _EditQueueScreenState();
}

class _EditQueueScreenState extends State<EditQueueScreen> {
  bool _uploading = false;

  Future<void> _onDelete(PendingEdit edit) async {
    final messenger = ScaffoldMessenger.of(context);
    await widget.editQueueService.remove(edit.localId);
    if (!mounted) return;
    messenger.showSnackBar(
      SnackBar(
        content: const Text('Removed from queue'),
        action: SnackBarAction(
          label: 'Undo',
          onPressed: () => widget.editQueueService.enqueue(edit),
        ),
      ),
    );
  }

  Future<void> _onUploadAll() async {
    if (_uploading) return;
    final edits = widget.editQueueService.pending;
    if (edits.isEmpty) return;
    final snapshot = edits.toList(growable: false);

    final confirmed = await _showConfirmDialog(snapshot);
    if (confirmed != true || !mounted) return;

    await _doUpload(snapshot);
  }

  Future<void> _doUpload(List<PendingEdit> edits) async {
    setState(() => _uploading = true);
    final outcome = await UploadService().uploadAll(
      edits: edits,
      authService: widget.authService,
      editQueueService: widget.editQueueService,
      recentUploadsService: widget.recentUploadsService,
      settingsService: widget.settingsService,
    );
    if (!mounted) return;
    setState(() => _uploading = false);

    switch (outcome) {
      case UploadSuccess(:final count):
        Navigator.of(context).pop(EditQueueUploaded(count));
      case UploadNotSignedIn():
        await _showSignInDialog();
      case UploadFailure(:final message, :final detail, :final retryable):
        final retry = await _showUploadError(message, detail, retryable);
        if (retry == true && mounted) {
          await _doUpload(edits);
        }
    }
  }

  Future<bool?> _showConfirmDialog(List<PendingEdit> edits) {
    final comment = buildChangesetComment(edits);
    final displayName = widget.authService.currentUser?.displayName;
    return showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        final theme = Theme.of(dialogContext);
        return AlertDialog(
          title: const Text('Upload to OpenStreetMap?'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (displayName != null) ...[
                Text(
                  'Signed in as $displayName',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 8),
              ],
              Text(
                '${edits.length} ${edits.length == 1 ? 'edit' : 'edits'} '
                'will be uploaded with this changeset comment:',
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: SelectableText(
                  comment,
                  style: theme.textTheme.bodyMedium,
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton.icon(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              icon: const Icon(Icons.cloud_upload_outlined),
              label: const Text('Upload'),
            ),
          ],
        );
      },
    );
  }

  Future<bool?> _showUploadError(
    String message,
    String? detail,
    bool retryable,
  ) {
    return showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        final theme = Theme.of(dialogContext);
        return AlertDialog(
          title: const Text("Couldn't upload"),
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 400),
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(message),
                  if (detail != null) ...[
                    const SizedBox(height: 12),
                    SelectableText(
                      detail,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Close'),
            ),
            if (retryable)
              FilledButton.icon(
                onPressed: () => Navigator.of(dialogContext).pop(true),
                icon: const Icon(Icons.refresh),
                label: const Text('Retry'),
              ),
          ],
        );
      },
    );
  }

  Future<void> _showSignInDialog() async {
    final shouldSignIn = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Sign in required'),
        content: const Text('Sign in with OpenStreetMap to upload your edits.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            icon: const Icon(Icons.login),
            label: const Text('Sign in'),
          ),
        ],
      ),
    );
    if (shouldSignIn != true || !mounted) return;
    try {
      await widget.authService.signIn();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Sign-in failed: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // Block back gesture/button during upload so the user can't navigate
      // away while a changeset is open server-side.
      canPop: !_uploading,
      child: ListenableBuilder(
        listenable: widget.editQueueService,
        builder: (context, _) {
          final edits = widget.editQueueService.pending;
          return Scaffold(
            appBar: AppBar(title: const Text('Pending Edits')),
            bottomNavigationBar: edits.isEmpty
                ? null
                : SafeArea(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                      child: SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          icon: _uploading
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.cloud_upload_outlined),
                          label: Text(
                            _uploading
                                ? 'Uploading…'
                                : 'Upload All (${edits.length})',
                          ),
                          onPressed: _uploading ? null : _onUploadAll,
                        ),
                      ),
                    ),
                  ),
            body: edits.isEmpty
                ? Builder(
                    builder: (context) {
                      final theme = Theme.of(context);
                      return Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Text(
                            'No pending edits.',
                            textAlign: TextAlign.center,
                            style: theme.textTheme.bodyLarge?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      );
                    },
                  )
                : ListView.separated(
                    itemCount: edits.length,
                    separatorBuilder: (_, _) => const Divider(height: 0),
                    itemBuilder: (context, i) => _PendingEditTile(
                      edit: edits[i],
                      // Disable tile actions during upload — taps would
                      // otherwise be silently swallowed by PopScope.
                      onDelete: _uploading ? null : () => _onDelete(edits[i]),
                      onTap: _uploading
                          ? null
                          : () => Navigator.of(
                              context,
                            ).pop(EditQueueOpenEdit(edits[i])),
                    ),
                  ),
          );
        },
      ),
    );
  }
}

class _PendingEditTile extends StatelessWidget {
  const _PendingEditTile({
    required this.edit,
    required this.onDelete,
    required this.onTap,
  });

  final PendingEdit edit;
  final VoidCallback? onDelete;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      onTap: onTap,
      leading: _OpIcon(op: edit.op),
      title: Text(_titleFor(edit)),
      subtitle: _Subtitle(edit: edit),
      trailing: IconButton(
        icon: const Icon(Icons.delete_outline),
        tooltip: 'Remove from queue',
        onPressed: onDelete,
      ),
    );
  }

  static String _titleFor(PendingEdit edit) {
    final tags = edit.op == PendingEditOp.delete
        ? edit.originalTags
        : (edit.newTags ?? edit.originalTags);
    final name = tags?['name'];
    if (name != null && name.trim().isNotEmpty) return name;
    if (edit.osmId != null) return 'Node #${edit.osmId}';
    return 'New node';
  }
}

class _OpIcon extends StatelessWidget {
  const _OpIcon({required this.op});

  final PendingEditOp op;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (icon, color) = switch (op) {
      PendingEditOp.create => (
        Icons.add_location_alt_outlined,
        Colors.green.shade700,
      ),
      PendingEditOp.modify => (Icons.edit_outlined, theme.colorScheme.primary),
      PendingEditOp.delete => (Icons.delete_outline, theme.colorScheme.error),
    };
    return Icon(icon, color: color);
  }
}

class _Subtitle extends StatelessWidget {
  const _Subtitle({required this.edit});

  final PendingEdit edit;

  @override
  Widget build(BuildContext context) {
    switch (edit.op) {
      case PendingEditOp.create:
        return Text(_typeLabel(edit) ?? 'Created');
      case PendingEditOp.delete:
        return const Text('Will be deleted');
      case PendingEditOp.modify:
        final k = edit.modifyKind;
        final labels = <String>[
          if (k.checked) 'Checked',
          if (k.moved) 'Moved',
          if (k.editedMetadata) 'Edited',
        ];
        if (labels.isEmpty) return const Text('No changes');
        return Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Wrap(
            spacing: 6,
            runSpacing: 4,
            children: [for (final l in labels) _KindChip(label: l)],
          ),
        );
    }
  }

  static String? _typeLabel(PendingEdit edit) {
    final amenityTag = (edit.newTags ?? edit.originalTags)?['amenity'];
    final type = AmenityType.fromOsmValue(amenityTag);
    if (type == null) return null;
    switch (type) {
      case AmenityType.foodSharing:
        return 'Food Sharing';
      case AmenityType.publicBookcase:
        return 'Public Bookcase';
      case AmenityType.giveBox:
        return 'Give Box';
    }
  }
}

class _KindChip extends StatelessWidget {
  const _KindChip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: theme.colorScheme.secondaryContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        label,
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.onSecondaryContainer,
        ),
      ),
    );
  }
}
