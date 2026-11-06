import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/build_record.dart';
import '../services/memory_service.dart';
import '../services/plan_version_service.dart';
import '../services/project_package.dart';

class ProjectPackageActions {
  static Future<void> export(BuildContext context, BuildRecord record) async {
    final memory = context.read<MemoryService>();
    final includePkt = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Export project package'),
        content: const Text(
          'Includes the design, saved checks, configuration and report. Credentials are omitted. You can also rebuild a portable .pkt from this sanitized design; review its credentials before use.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Design and reports'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Include rebuilt .pkt'),
          ),
        ],
      ),
    );
    if (includePkt == null || !context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(
      const SnackBar(content: Text('Preparing project package…')),
    );
    try {
      final bytes = await ProjectPackage.export(
        record,
        memory,
        includePkt: includePkt,
      );
      final path = await FilePicker.platform.saveFile(
        dialogTitle: 'Save project package',
        fileName: 'network.nbproject',
        type: FileType.any,
        bytes: bytes,
      );
      if (path == null) return;
      // Desktop pickers choose a path; Android writes the supplied bytes via SAF.
      if (!Platform.isAndroid && !Platform.isIOS) {
        await File(path).writeAsBytes(bytes, flush: true);
      }
      messenger.showSnackBar(
        SnackBar(content: Text('Project package saved to $path')),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Could not export project: $e')),
      );
    }
  }

  static Future<BuildRecord?> import(BuildContext context) async {
    final memory = context.read<MemoryService>();
    final messenger = ScaffoldMessenger.of(context);
    try {
      final selection = await FilePicker.platform.pickFiles(
        dialogTitle: 'Open project package',
        type: FileType.any,
        withData: false,
      );
      if (selection == null || selection.files.isEmpty || !context.mounted) {
        return null;
      }
      final file = selection.files.single;
      if (file.size > ProjectPackage.maxBytes) {
        throw const FormatException(
          'Project packages must be 20 MB or smaller.',
        );
      }
      final bytes =
          file.bytes ??
          (file.path == null ? null : await File(file.path!).readAsBytes());
      if (bytes == null) {
        throw const FormatException('The selected file could not be read.');
      }
      final preview = ProjectPackage.inspect(bytes);
      if (!context.mounted) return null;
      final accepted = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: Text('Import ${preview.plan.projectName}?'),
          content: SizedBox(
            width: 480,
            child: SingleChildScrollView(
              child: Text(
                '${preview.plan.nodes.length} devices · ${preview.plan.links.length} cables\n${preview.checks.length} saved checks\nAttachments: ${preview.artifacts.keys.join(', ')}\n\nCreates a separate project. Check results start unverified. Credentials must be supplied again.',
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(c, true),
              child: const Text('Import as new project'),
            ),
          ],
        ),
      );
      if (accepted != true) return null;
      return await ProjectPackage.import(bytes, memory);
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Could not import project: $e')),
      );
      return null;
    }
  }

  static Future<void> attachments(
    BuildContext context,
    BuildRecord record,
  ) async {
    final memory = context.read<MemoryService>();
    final messenger = ScaffoldMessenger.of(context);
    try {
      final entries = await ProjectPackage.savedArtifacts(
        memory,
        PlanVersionService.projectKeyOf(record),
      );
      if (!context.mounted) return;
      if (entries.isEmpty) {
        messenger.showSnackBar(
          const SnackBar(
            content: Text('This project has no imported attachments.'),
          ),
        );
        return;
      }
      final name = await showDialog<String>(
        context: context,
        builder: (c) => SimpleDialog(
          title: const Text('Save an imported attachment'),
          children: [
            for (final e in entries.entries)
              ListTile(
                title: Text(e.key),
                subtitle: Text('${e.value.length} bytes'),
                onTap: () => Navigator.pop(c, e.key),
              ),
          ],
        ),
      );
      if (name == null) return;
      final path = await FilePicker.platform.saveFile(
        fileName: name,
        type: FileType.any,
        bytes: entries[name],
      );
      if (path == null) return;
      if (!Platform.isAndroid && !Platform.isIOS) {
        await File(path).writeAsBytes(entries[name]!, flush: true);
      }
      messenger.showSnackBar(SnackBar(content: Text('Saved $name')));
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Could not save attachment: $e')),
      );
    }
  }
}
