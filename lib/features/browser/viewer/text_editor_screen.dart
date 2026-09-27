import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/rendering.dart' show AxisDirection;
import 'package:flutter/scheduler.dart' show SchedulerBinding, SchedulerPhase;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:re_editor/re_editor.dart';
import 'package:vaultexplorer/core/extensions/l10n_extension.dart';
import 'package:vaultexplorer/core/providers/vault_engine_providers.dart';
import 'package:vaultexplorer/core/theme/app_theme.dart';
import 'package:vaultexplorer/core/utils/raw_entry.dart';
import 'package:vaultexplorer/core/widgets/common_widgets.dart';
import 'package:vaultexplorer/data/models/mounted_container.dart';
import 'package:vaultexplorer/data/services/text_editor_appearance_service.dart';
import 'package:vaultexplorer/features/browser/viewer/markdown/markdown_body_view.dart';
import 'package:vaultexplorer/features/browser/viewer/text_editor_appearance_provider.dart';
import 'package:vaultexplorer/features/browser/viewer/text_editor_formatters.dart';
import 'package:vaultexplorer/features/browser/viewer/text_editor_language.dart';
import 'package:vaultexplorer/features/browser/viewer/widgets/editor_accessory_key_bar.dart';
import 'package:vaultexplorer/features/browser/viewer/widgets/editor_appearance_sheet.dart';
import 'package:vaultexplorer/features/browser/controllers/file_browser_navigation_controller.dart' show PathSegment;
import 'package:vaultexplorer/features/browser/widgets/breadcrumb_bar.dart';
import 'package:vaultexplorer/features/browser/viewer/widgets/editor_find_panel.dart';

class EditorTab {
  String filePath;
  final CodeLineEditingController codeController;
  late final CodeFindController findController;
  bool isLoading = true;
  bool hasError = false;
  String errorMessage = '';
  bool isDirty = false;
  bool isSaving = false;
  bool isAutosaving = false;
  int lineCount = 0;
  int charCount = 0;
  DateTime? lastSavedAt;
  bool lastSaveWasAutosave = false;
  bool appliedInitialText = false;
  String lastKnownText = '';
  Object? lastCodeLines;
  int editsSinceHistoryClear = 0;
  bool showMarkdownPreview;
  final ScrollController previewScrollController = ScrollController();

  EditorTab({
    required this.filePath,
    String initialText = '',
    bool isMarkdown = false,
  })  : codeController = CodeLineEditingController.fromText(initialText),
        showMarkdownPreview = isMarkdown {
    findController = CodeFindController(codeController);
  }

  String get fileName => filePath.contains('/') ? filePath.split('/').last : filePath;

  bool get isMarkdownFile =>
      filePath.toLowerCase().endsWith('.md') ||
      filePath.toLowerCase().endsWith('.markdown');

  void dispose() {
    findController.dispose();
    codeController.dispose();
    previewScrollController.dispose();
  }
}

class TextEditorScreen extends ConsumerStatefulWidget {
  final MountedContainer container;
  final String filePath;

  const TextEditorScreen({
    super.key,
    required this.container,
    required this.filePath,
  });

  @override
  ConsumerState<TextEditorScreen> createState() => _TextEditorScreenState();
}

class _TextEditorScreenState extends ConsumerState<TextEditorScreen> {
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  final List<EditorTab> _tabs = [];
  int _activeTabIndex = 0;

  static const _kMaxUndoHistoryOperations = 200;

  bool _readOnly = false;
  bool _wordWrap = true;
  Timer? _autosaveTimer;
  final EditorFocusNode _focusNode = EditorFocusNode();

  late String _projectDirPath;

  EditorTab get _activeTab => _tabs[_activeTabIndex];

  @override
  void initState() {
    super.initState();
    final slash = widget.filePath.lastIndexOf('/');
    _projectDirPath = slash >= 0 ? widget.filePath.substring(0, slash) : '';

    final initialTab = EditorTab(
      filePath: widget.filePath,
      isMarkdown: widget.filePath.toLowerCase().endsWith('.md') ||
          widget.filePath.toLowerCase().endsWith('.markdown'),
    );
    _tabs.add(initialTab);
    _bindTabController(initialTab);

    Future.microtask(() => _loadFileForTab(initialTab));
  }

  void _bindTabController(EditorTab tab) {
    tab.codeController.addListener(_onTextChanged);
    tab.findController.addListener(_onFindChanged);
  }

  void _unbindTabController(EditorTab tab) {
    tab.codeController.removeListener(_onTextChanged);
    tab.findController.removeListener(_onFindChanged);
  }

  void _onFindChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _loadFileForTab(EditorTab tab) async {
    setState(() {
      tab.isLoading = true;
      tab.hasError = false;
      tab.errorMessage = '';
    });

    try {
      final bytes = await ref.read(vaultFileIoApiProvider).readWholeFile(widget.container, tab.filePath);
      if (bytes == null) {
        throw Exception(context.l10n.textEditorDecryptFailedMessage);
      }
      String text;
      try {
        text = utf8.decode(bytes);
      } on FormatException {
        throw FormatException(context.l10n.textEditorInvalidTextFileMessage);
      }

      if (!mounted) return;
      tab.appliedInitialText = true;
      tab.lastKnownText = text;
      tab.codeController.text = text;
      tab.lastCodeLines = tab.codeController.value.codeLines;
      tab.codeController.clearHistory();
      tab.editsSinceHistoryClear = 0;
      tab.lineCount = tab.codeController.lineCount;
      tab.charCount = text.length;
      tab.isLoading = false;
      if (mounted) setState(() {});
    } catch (e) {
      if (!mounted) return;
      setState(() {
        tab.isLoading = false;
        tab.hasError = true;
        tab.errorMessage = e.toString();
      });
    }
  }

  @override
  void dispose() {
    _autosaveTimer?.cancel();
    for (final tab in _tabs) {
      _unbindTabController(tab);
      tab.dispose();
    }
    _focusNode.dispose();
    super.dispose();
  }

  void _onTextChanged() {
    if (_tabs.isEmpty) return;
    final tab = _activeTab;
    final codeLines = tab.codeController.value.codeLines;
    if (identical(codeLines, tab.lastCodeLines)) return;

    final currentText = tab.codeController.text;
    if (currentText == tab.lastKnownText) {
      tab.lastCodeLines = codeLines;
      return;
    }
    tab.lastCodeLines = codeLines;
    tab.lastKnownText = currentText;

    tab.editsSinceHistoryClear++;
    if (tab.editsSinceHistoryClear >= _kMaxUndoHistoryOperations) {
      tab.codeController.clearHistory();
      tab.editsSinceHistoryClear = 0;
    }

    void updateState() {
      if (!mounted) return;
      setState(() {
        tab.isDirty = true;
        tab.lineCount = tab.codeController.lineCount;
        tab.charCount = currentText.length;
      });
    }

    if (SchedulerBinding.instance.schedulerPhase == SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) => updateState());
    } else {
      updateState();
    }

    _autosaveTimer?.cancel();
    final appearance = ref.read(textEditorAppearanceProvider);

    if (appearance.autoSave && !tab.isLoading && !tab.hasError) {
      _autosaveTimer = Timer(const Duration(milliseconds: 2500), () {
        final currentAppearance = ref.read(textEditorAppearanceProvider);
        if (mounted && currentAppearance.autoSave && tab.isDirty && !tab.isSaving && !tab.isAutosaving) {
          _saveFile(tab, isAutosave: true);
        }
      });
    }
  }

  Future<bool> _saveFile(EditorTab tab, {bool isAutosave = false}) async {
    _autosaveTimer?.cancel();

    setState(() {
      if (isAutosave) {
        tab.isAutosaving = true;
      } else {
        tab.isSaving = true;
      }
    });

    final content = tab.codeController.text;
    final ok = await ref.read(vaultFileIoApiProvider).writeWholeFile(
          widget.container,
          tab.filePath,
          Uint8List.fromList(utf8.encode(content)),
        );

    if (ok) {
      if (mounted) {
        tab.lastKnownText = content;
        tab.lastCodeLines = tab.codeController.value.codeLines;
        setState(() {
          tab.isSaving = false;
          tab.isAutosaving = false;
          tab.isDirty = false;
          tab.lastSavedAt = DateTime.now();
          tab.lastSaveWasAutosave = isAutosave;
        });

        if (!isAutosave) {
          showAppSnackBar(
            context,
            message: context.l10n.changesSavedSuccessfully,
            tone: AppBannerTone.success,
          );
        }
      }
      return true;
    } else {
      if (mounted) {
        setState(() {
          tab.isSaving = false;
          tab.isAutosaving = false;
        });

        if (!isAutosave) {
          showAppSnackBar(
            context,
            message: context.l10n.saveFailedWithError(context.l10n.textEditorWriteBackFailedMessage),
            tone: AppBannerTone.error,
          );
        }
      }
      return false;
    }
  }

  Future<bool> _onWillPop() async {
    final anyDirty = _tabs.any((t) => t.isDirty);
    if (!anyDirty) return true;

    final appearance = ref.read(textEditorAppearanceProvider);
    if (appearance.autoSave) {
      for (final tab in _tabs.where((t) => t.isDirty)) {
        await _saveFile(tab, isAutosave: true);
      }
      return true;
    }

    if (!mounted) return true;
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.l10n.unsavedChangesTitle),
        content: Text(context.l10n.unsavedChangesMessage),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop('discard'),
            child: Text(
              context.l10n.discardButton,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop('cancel'),
            child: Text(context.l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop('save'),
            child: Text(context.l10n.save),
          ),
        ],
      ),
    );

    if (result == 'save') {
      for (final tab in _tabs.where((t) => t.isDirty)) {
        await _saveFile(tab);
      }
      return true;
    } else if (result == 'discard') {
      return true;
    }
    return false;
  }

  void _openFileInTab(String filePath) {
    final existingIndex = _tabs.indexWhere((t) => t.filePath == filePath);
    if (existingIndex != -1) {
      setState(() => _activeTabIndex = existingIndex);
      return;
    }

    final newTab = EditorTab(
      filePath: filePath,
      isMarkdown: filePath.toLowerCase().endsWith('.md') ||
          filePath.toLowerCase().endsWith('.markdown'),
    );
    _bindTabController(newTab);
    setState(() {
      _tabs.add(newTab);
      _activeTabIndex = _tabs.length - 1;
    });

    _loadFileForTab(newTab);
  }

  Future<void> _closeTab(int index) async {
    final tab = _tabs[index];
    if (tab.isDirty) {
      final shouldClose = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(ctx.l10n.unsavedChangesTitle),
          content: Text(ctx.l10n.unsavedChangesMessage),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: Text(ctx.l10n.discardButton, style: TextStyle(color: Theme.of(ctx).colorScheme.error)),
            ),
            FilledButton(
              onPressed: () async {
                final saved = await _saveFile(tab);
                if (ctx.mounted) Navigator.of(ctx).pop(saved);
              },
              child: Text(ctx.l10n.save),
            ),
          ],
        ),
      );

      if (shouldClose != true) return;
    }

    if (_tabs.length == 1) {
      if (mounted) Navigator.of(context).pop();
      return;
    }

    _unbindTabController(tab);
    tab.dispose();

    setState(() {
      _tabs.removeAt(index);
      _activeTabIndex = _activeTabIndex.clamp(0, _tabs.length - 1);
    });
  }

  Future<void> _showSaveAsDialog() async {
    final currentTab = _activeTab;
    final lastSlash = currentTab.filePath.lastIndexOf('/');
    final parentDir = lastSlash >= 0 ? currentTab.filePath.substring(0, lastSlash) : '';
    final fileName = currentTab.fileName;
    final controller = TextEditingController(text: fileName);
    final formKey = GlobalKey<FormState>();

    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(ctx.l10n.textEditorSaveAsDialogTitle),
        content: Form(
          key: formKey,
          child: TextFormField(
            controller: controller,
            autofocus: true,
            decoration: InputDecoration(
              labelText: ctx.l10n.textEditorSaveAsFileNameLabel,
            ),
            validator: (val) {
              final text = val?.trim() ?? '';
              if (text.isEmpty) return ctx.l10n.validationEmptyName;
              if (text.contains('/') || text.contains('\\')) {
                return ctx.l10n.validationIllegalChar('/', 0, 'vault');
              }
              return null;
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(ctx.l10n.cancel),
          ),
          FilledButton(
            onPressed: () {
              if (formKey.currentState?.validate() ?? false) {
                Navigator.of(ctx).pop(controller.text.trim());
              }
            },
            child: Text(ctx.l10n.textEditorSaveAsButton),
          ),
        ],
      ),
    );

    if (result == null || result == fileName) return;

    final newFilePath = parentDir.isEmpty ? result : '$parentDir/$result';

    final rawList = await ref.read(vaultFileIoApiProvider).listDirectory(
          widget.container,
          parentDir,
        );
    final existingNames = RawEntry.parseAll(rawList ?? const [])
        .map((e) => e.name.toLowerCase())
        .toSet();

    if (existingNames.contains(result.toLowerCase()) && mounted) {
      final overwrite = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(ctx.l10n.conflictResolutionTitle),
          content: Text(ctx.l10n.textEditorFileAlreadyExistsError),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text(ctx.l10n.cancel),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: Text(ctx.l10n.replaceExistingFile),
            ),
          ],
        ),
      );

      if (overwrite != true) return;
    }

    final content = currentTab.codeController.text;
    final ok = await ref.read(vaultFileIoApiProvider).writeWholeFile(
          widget.container,
          newFilePath,
          Uint8List.fromList(utf8.encode(content)),
        );

    if (ok && mounted) {
      setState(() {
        currentTab.filePath = newFilePath;
        currentTab.isDirty = false;
        currentTab.lastSavedAt = DateTime.now();
      });
      showAppSnackBar(
        context,
        message: context.l10n.changesSavedSuccessfully,
        tone: AppBannerTone.success,
      );
    }
  }

  Future<void> _handleLinkTap(String url) async {
    try {
      final ok = await ref.read(vaultFileIoApiProvider).launchUrl(url);
      if (!ok && mounted) {
        showAppSnackBar(context, message: context.l10n.couldNotOpenLinkMessage, tone: AppBannerTone.error);
      }
    } catch (_) {
      if (mounted) {
        showAppSnackBar(context, message: context.l10n.couldNotOpenLinkMessage, tone: AppBannerTone.error);
      }
    }
  }

  void _toggleReadOnly() {
    setState(() => _readOnly = !_readOnly);
    if (_readOnly) {
      _focusNode.unfocus();
    }
  }

  void _toggleWordWrap() => setState(() => _wordWrap = !_wordWrap);

 Future<void> _insertImageTemplate() async {
    final imageExts = {'png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp', 'svg'};
    final currentTab = _activeTab;
    final lastSlash = currentTab.filePath.lastIndexOf('/');
    final parentDir = lastSlash >= 0 ? currentTab.filePath.substring(0, lastSlash) : '';
    
    final rawList = await ref.read(vaultFileIoApiProvider).listDirectory(
          widget.container,
          parentDir,
        );
        
    final images = rawList == null 
        ? <RawEntry>[] 
        : RawEntry.parseAll(rawList).where((e) {
            if (e.isDir) return false;
            final dot = e.name.lastIndexOf('.');
            if (dot < 0) return false;
            return imageExts.contains(e.name.substring(dot + 1).toLowerCase());
          }).toList();

    if (!mounted) return;

    final selectedImage = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(ctx.l10n.selectImageTitle),
        content: SizedBox(
          width: double.maxFinite,
          child: images.isEmpty
              ? Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Text(ctx.l10n.noImagesFoundMessage),
                )
              : ListView.builder(
                  shrinkWrap: true,
                  itemCount: images.length,
                  itemBuilder: (context, index) {
                    final img = images[index];
                    return ListTile(
                      leading: const Icon(Icons.image_outlined),
                      title: Text(img.name),
                      onTap: () => Navigator.of(ctx).pop(img.name),
                    );
                  },
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(ctx.l10n.cancel),
          ),
        ],
      ),
    );

    if (selectedImage == null) return;

    final template = '![$selectedImage]($selectedImage)';
    currentTab.codeController.replaceSelection(template);
    _focusNode.requestFocus();
  }

  void _goToLineIndex(int lineIndex) {
    final target = lineIndex.clamp(0, _activeTab.codeController.lineCount - 1);
    _activeTab.codeController.selection = CodeLineSelection.collapsed(index: target, offset: 0);
    _activeTab.codeController.makeCursorCenterIfInvisible();
  }

  void _goToStart() => _goToLineIndex(0);

  void _goToEnd() => _goToLineIndex(_activeTab.codeController.lineCount - 1);

  Future<void> _showGoToLineDialog() async {
    final result = await showDialog<int>(
      context: context,
      builder: (dialogContext) => _GoToLineDialog(maxLine: _activeTab.codeController.lineCount),
    );

    if (result != null) {
      _goToLineIndex(result - 1);
    }
  }

  String? Function(String)? get _formatter => formatterFor(_activeTab.filePath);

  bool get _isJsonFile => _activeTab.filePath.toLowerCase().endsWith('.json');

  void _runFormatter(String? Function(String) formatter) {
    final input = _activeTab.codeController.text;
    String? result;
    try {
      result = formatter(input);
    } catch (_) {
      result = null;
    }
    if (result == null) {
      showAppSnackBar(
        context,
        message: context.l10n.textEditorFormatFailedMessage,
        tone: AppBannerTone.error,
      );
      return;
    }
    if (result == input) return;
    _activeTab.codeController.text = result;
  }

  @override
  Widget build(BuildContext context) {
    if (_tabs.isEmpty) {
      return const Scaffold(body: SizedBox.shrink());
    }

    final cs = Theme.of(context).colorScheme;
    final activeTab = _activeTab;

    ref.listen<TextEditorAppearancePrefs>(textEditorAppearanceProvider, (previous, next) {
      if (!next.autoSave) {
        _autosaveTimer?.cancel();
        _autosaveTimer = null;
      }
    });

    final anyDirty = _tabs.any((t) => t.isDirty);
    final isSearching = activeTab.findController.value != null;
    final isReplaceMode = activeTab.findController.value?.replaceMode ?? false;
    final findBarHeight = (isReplaceMode && !_readOnly) ? 88.0 : 48.0;

    return PopScope(
      canPop: !anyDirty,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        final shouldPop = await _onWillPop();
        if (shouldPop && context.mounted) {
          Navigator.of(context).pop();
        }
      },
      child: Scaffold(
        key: _scaffoldKey,
        drawer: _buildProjectDrawer(cs),
        appBar: isSearching
            ? AppBar(
                automaticallyImplyLeading: false,
                toolbarHeight: findBarHeight,
                titleSpacing: 0,
                title: EditorFindPanel(
                  controller: activeTab.findController,
                  readOnly: _readOnly,
                ),
                bottom: PreferredSize(
                  preferredSize: const Size.fromHeight(42),
                  child: _buildTabBar(cs),
                ),
              )
            : AppBar(
                leading: IconButton(
                  icon: const Icon(Icons.menu_rounded),
                  tooltip: context.l10n.textEditorProjectFilesTitle,
                  onPressed: () => _scaffoldKey.currentState?.openDrawer(),
                ),
                title: Text(activeTab.fileName),
                actions: [
                  if (!activeTab.isLoading && !activeTab.hasError) ...[
                    if (activeTab.isMarkdownFile) ...[
                      if (!activeTab.showMarkdownPreview && !_readOnly)
                        IconButton(
                          icon: const Icon(Icons.add_photo_alternate_outlined),
                          tooltip: context.l10n.addFile,
                          onPressed: _insertImageTemplate,
                        ),
                      IconButton(
                        icon: Icon(activeTab.showMarkdownPreview ? Icons.edit_note_rounded : Icons.visibility_outlined),
                        tooltip: activeTab.showMarkdownPreview
                            ? context.l10n.markdownViewerEditTooltip
                            : context.l10n.markdownViewerPreviewTooltip,
                        onPressed: () => setState(() => activeTab.showMarkdownPreview = !activeTab.showMarkdownPreview),
                      ),
                    ],
                    IconButton(
                      icon: const Icon(Icons.search_rounded),
                      tooltip: context.l10n.textEditorFindTooltip,
                      onPressed: () {
                        if (activeTab.showMarkdownPreview) {
                          setState(() => activeTab.showMarkdownPreview = false);
                        }
                        activeTab.findController.findMode();
                      },
                    ),
                    PopupMenuButton<String>(
                      tooltip: context.l10n.textEditorMoreActionsTooltip,
                      icon: const Icon(Icons.more_vert_rounded),
                      onSelected: (value) {
                        switch (value) {
                          case 'save':
                            _saveFile(activeTab);
                            break;
                          case 'saveAs':
                            _showSaveAsDialog();
                            break;
                          case 'readOnly':
                            _toggleReadOnly();
                            break;
                          case 'wordWrap':
                            _toggleWordWrap();
                            break;
                          case 'goToLine':
                            _showGoToLineDialog();
                            break;
                          case 'goToStart':
                            _goToStart();
                            break;
                          case 'goToEnd':
                            _goToEnd();
                            break;
                          case 'format':
                            final formatter = _formatter;
                            if (formatter != null) _runFormatter(formatter);
                            break;
                          case 'minify':
                            _runFormatter(minifyJson);
                            break;
                          case 'appearance':
                            showEditorAppearanceSheet(context);
                            break;
                        }
                      },
                      itemBuilder: (context) => [
                        PopupMenuItem(
                          value: 'save',
                          enabled: activeTab.isDirty && !activeTab.isSaving && !activeTab.isAutosaving,
                          child: Row(
                            children: [
                              Icon(
                                Icons.save_rounded,
                                size: 20,
                                color: (activeTab.isDirty && !activeTab.isSaving && !activeTab.isAutosaving)
                                    ? cs.primary
                                    : cs.onSurface.withValues(alpha: 0.38),
                              ),
                              const SizedBox(width: 12),
                              Text(context.l10n.save),
                            ],
                          ),
                        ),
                        PopupMenuItem(
                          value: 'saveAs',
                          child: Row(
                            children: [
                              const Icon(Icons.save_as_rounded, size: 20),
                              const SizedBox(width: 12),
                              Text(context.l10n.textEditorSaveAsMenuItem),
                            ],
                          ),
                        ),
                        const PopupMenuDivider(),
                        PopupMenuItem(
                          value: 'wordWrap',
                          child: Row(
                            children: [
                              const Icon(Icons.wrap_text_rounded, size: 20),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Text(context.l10n.textEditorWordWrap),
                              ),
                              if (_wordWrap)
                                Icon(Icons.check_rounded, size: 18, color: cs.primary),
                            ],
                          ),
                        ),
                        PopupMenuItem(
                          value: 'readOnly',
                          child: Row(
                            children: [
                              Icon(_readOnly ? Icons.lock_rounded : Icons.lock_open_rounded, size: 20),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Text(context.l10n.textEditorReadOnly),
                              ),
                              if (_readOnly)
                                Icon(Icons.check_rounded, size: 18, color: cs.primary),
                            ],
                          ),
                        ),
                        const PopupMenuDivider(),
                        PopupMenuItem(
                          value: 'goToLine',
                          child: Row(
                            children: [
                              const Icon(Icons.redo_rounded, size: 20),
                              const SizedBox(width: 12),
                              Text(context.l10n.textEditorGoToLineMenuItem),
                            ],
                          ),
                        ),
                        PopupMenuItem(
                          value: 'goToStart',
                          child: Row(
                            children: [
                              const Icon(Icons.vertical_align_top_rounded, size: 20),
                              const SizedBox(width: 12),
                              Text(context.l10n.textEditorGoToStartMenuItem),
                            ],
                          ),
                        ),
                        PopupMenuItem(
                          value: 'goToEnd',
                          child: Row(
                            children: [
                              const Icon(Icons.vertical_align_bottom_rounded, size: 20),
                              const SizedBox(width: 12),
                              Text(context.l10n.textEditorGoToEndMenuItem),
                            ],
                          ),
                        ),
                        if (_formatter != null && !_readOnly) ...[
                          const PopupMenuDivider(),
                          PopupMenuItem(
                            value: 'format',
                            child: Row(
                              children: [
                                const Icon(Icons.auto_fix_high_rounded, size: 20),
                                const SizedBox(width: 12),
                                Text(context.l10n.textEditorFormatDocumentMenuItem),
                              ],
                            ),
                          ),
                          if (_isJsonFile)
                            PopupMenuItem(
                              value: 'minify',
                              child: Row(
                                children: [
                                  const Icon(Icons.compress_rounded, size: 20),
                                  const SizedBox(width: 12),
                                  Text(context.l10n.textEditorMinifyJsonMenuItem),
                                ],
                              ),
                            ),
                        ],
                        const PopupMenuDivider(),
                        PopupMenuItem(
                          value: 'appearance',
                          child: Row(
                            children: [
                              const Icon(Icons.palette_outlined, size: 20),
                              const SizedBox(width: 12),
                              Text(context.l10n.textEditorThemeMenuItem),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
                bottom: PreferredSize(
                  preferredSize: const Size.fromHeight(42),
                  child: _buildTabBar(cs),
                ),
              ),
        body: _buildBody(cs, Theme.of(context).textTheme),
        bottomNavigationBar:
            activeTab.isLoading || activeTab.hasError ? null : _buildBottomBar(cs),
      ),
    );
  }

  Widget _buildTabBar(ColorScheme cs) {
    return Container(
      height: 42,
      decoration: BoxDecoration(
        color: cs.surfaceContainer,
        border: Border(bottom: BorderSide(color: cs.outlineVariant, width: 0.5)),
      ),
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
        itemCount: _tabs.length,
        itemBuilder: (context, index) {
          final tab = _tabs[index];
          final isActive = index == _activeTabIndex;

          return Material(
            color: isActive ? cs.surfaceContainerHighest : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
            child: InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: () => setState(() => _activeTabIndex = index),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: isActive ? cs.primary.withValues(alpha: 0.5) : Colors.transparent,
                    width: 1,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (tab.isDirty)
                      Container(
                        width: 6,
                        height: 6,
                        margin: const EdgeInsets.only(right: 6),
                        decoration: BoxDecoration(color: cs.primary, shape: BoxShape.circle),
                      ),
                    Text(
                      tab.fileName,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: isActive ? FontWeight.bold : FontWeight.normal,
                        color: isActive ? cs.onSurface : cs.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(width: 6),
                    InkWell(
                      borderRadius: BorderRadius.circular(12),
                      onTap: () => _closeTab(index),
                      child: Padding(
                        padding: const EdgeInsets.all(2.0),
                        child: Icon(
                          Icons.close_rounded,
                          size: 14,
                          color: isActive ? cs.onSurfaceVariant : cs.outline,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

List<PathSegment> get _drawerPathStack {
    final rootLabel = context.l10n.rootFolderLabel;
    final stack = <PathSegment>[
      PathSegment(rootLabel, ''),
    ];
    if (_projectDirPath.isEmpty) return stack;

    final segments = _projectDirPath.split('/');
    String accumulated = '';
    for (final seg in segments) {
      if (seg.isEmpty) continue;
      accumulated = accumulated.isEmpty ? seg : '$accumulated/$seg';
      stack.add(PathSegment(seg, accumulated));
    }
    return stack;
  }

  IconData _fileIconFor(String fileName) {
    final lower = fileName.toLowerCase();
    if (lower.endsWith('.md') || lower.endsWith('.markdown')) {
      return Icons.article_outlined;
    }
    if (lower.endsWith('.json') ||
        lower.endsWith('.xml') ||
        lower.endsWith('.html') ||
        lower.endsWith('.yaml') ||
        lower.endsWith('.yml')) {
      return Icons.data_object_rounded;
    }
    if (lower.endsWith('.dart') ||
        lower.endsWith('.js') ||
        lower.endsWith('.ts') ||
        lower.endsWith('.py') ||
        lower.endsWith('.c') ||
        lower.endsWith('.cpp') ||
        lower.endsWith('.java') ||
        lower.endsWith('.kt') ||
        lower.endsWith('.go') ||
        lower.endsWith('.rs') ||
        lower.endsWith('.sh')) {
      return Icons.code_rounded;
    }
    return Icons.insert_drive_file_outlined;
  }

  Widget _buildProjectDrawer(ColorScheme cs) {
    return Drawer(
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Drawer Header
            Container(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
              decoration: BoxDecoration(
                color: cs.surfaceContainerHigh,
               
              ),
              child: Row(
                children: [
                  Icon(Icons.inventory_2_outlined, size: 20, color: cs.primary),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.container.displayName,
                          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close_rounded, size: 20),
                    tooltip: context.l10n.close,
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            // Reused BreadcrumbBar
            Container(
              decoration: BoxDecoration(
                color: cs.surfaceContainer,
               
              ),
              child: BreadcrumbBar(
                stack: _drawerPathStack,
                backgroundColor: Colors.transparent,
                onTap: (index) {
                  final target = _drawerPathStack[index];
                  setState(() => _projectDirPath = target.fatPath);
                },
              ),
            ),
            // File & Directory List
            Expanded(
              child: FutureBuilder<List<String>?>(
                future: ref.read(vaultFileIoApiProvider).listDirectory(
                      widget.container,
                      _projectDirPath,
                    ),
                builder: (context, snapshot) {
                  if (snapshot.connectionState == ConnectionState.waiting) {
                    return const Center(child: CircularProgressIndicator());
                  }

                  final rawEntries = snapshot.data ?? [];
                  final entries = RawEntry.parseAll(rawEntries)
                    ..sort((a, b) {
                      if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
                      return a.name.compareTo(b.name);
                    });

                  if (entries.isEmpty) {
                    return Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.folder_open_rounded, size: 40, color: cs.onSurfaceVariant.withValues(alpha: 0.5)),
                          const SizedBox(height: 8),
                          Text(
                            context.l10n.filesEmptyMessage,
                            style: TextStyle(color: cs.onSurfaceVariant),
                          ),
                        ],
                      ),
                    );
                  }

                  return ListView.builder(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                    itemCount: entries.length,
                    itemBuilder: (context, index) {
                      final entry = entries[index];
                      final fullPath = _projectDirPath.isEmpty
                          ? entry.name
                          : '$_projectDirPath/${entry.name}';
                      final isOpen = _tabs.any((t) => t.filePath == fullPath);
                      final isCurrentActive = fullPath == _activeTab.filePath;

                      return Padding(
                        padding: const EdgeInsets.only(bottom: 2),
                        child: Material(
                          color: isCurrentActive
                              ? cs.secondaryContainer.withValues(alpha: 0.6)
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(8),
                          child: ListTile(
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                            contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 0),
                            visualDensity: VisualDensity.compact,
                            dense: true,
                            leading: Icon(
                              entry.isDir ? Icons.folder_rounded : _fileIconFor(entry.name),
                              color: entry.isDir
                                  ? cs.primary
                                  : (isCurrentActive ? cs.primary : cs.onSurfaceVariant),
                              size: 20,
                            ),
                            title: Text(
                              entry.name,
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: (isCurrentActive || isOpen) ? FontWeight.w600 : FontWeight.normal,
                                color: isCurrentActive ? cs.onSecondaryContainer : cs.onSurface,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            trailing: entry.isDir
                                ? Icon(Icons.chevron_right_rounded, size: 18, color: cs.onSurfaceVariant)
                                : (isCurrentActive
                                    ? Icon(Icons.edit_note_rounded, size: 18, color: cs.primary)
                                    : (isOpen
                                        ? Container(
                                            width: 6,
                                            height: 6,
                                            decoration: BoxDecoration(color: cs.primary, shape: BoxShape.circle),
                                          )
                                        : null)),
                            onTap: () {
                              if (entry.isDir) {
                                setState(() => _projectDirPath = fullPath);
                              } else {
                                Navigator.of(context).pop();
                                _openFileInTab(fullPath);
                              }
                            },
                          ),
                        ),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(ColorScheme cs, TextTheme textTheme) {
    final activeTab = _activeTab;

    if (activeTab.isLoading) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const CircularProgressIndicator(strokeWidth: 2.5),
            const SizedBox(height: 16),
            Text(context.l10n.decryptingFileContent),
          ],
        ),
      );
    }
    if (activeTab.hasError) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.error_outline_rounded, color: cs.error, size: 48),
              const SizedBox(height: 16),
              Text(
                context.l10n.cannotOpenFile,
                style: textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              Text(
                activeTab.errorMessage,
                textAlign: TextAlign.center,
                style: textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
              ),
              const SizedBox(height: 24),
              OutlinedButton.icon(
                onPressed: () => _loadFileForTab(activeTab),
                icon: const Icon(Icons.refresh_rounded),
                label: Text(context.l10n.retryButton),
              ),
            ],
          ),
        ),
      );
    }

    if (activeTab.isMarkdownFile && activeTab.showMarkdownPreview) {
      return SelectionArea(
        child: MarkdownBodyView(
          source: activeTab.codeController.text,
          container: widget.container,
          currentFilePath: activeTab.filePath,
          onLinkTap: _handleLinkTap,
          scrollController: activeTab.previewScrollController,
        ),
      );
    }

    final appearance = ref.watch(textEditorAppearanceProvider);
    final syntaxStyle = resolveEditorSyntaxStyle(
      activeTab.filePath,
      Theme.of(context).brightness,
      cs,
      background: appearance.background,
      syntaxTheme: appearance.syntaxTheme,
    );
    final softKeyboardVisible = MediaQuery.of(context).viewInsets.bottom > 0;

    return Column(
      children: [
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
       child: CodeEditor(
              key: ValueKey(
                '${activeTab.filePath}_${appearance.background.name}_${appearance.syntaxTheme.name}_${appearance.fontSize}_${appearance.showLineNumbers}_${appearance.relativeLineNumbers}_${Theme.of(context).brightness.name}',
              ),
              controller: activeTab.codeController,
              focusNode: _focusNode,
              readOnly: _readOnly,
              showCursorWhenReadOnly: true,
              wordWrap: _wordWrap,
              autofocus: false,
             findController: activeTab.findController,
              findBuilder: null,
              chunkAnalyzer: const NonCodeChunkAnalyzer(),
              style: CodeEditorStyle(
                fontFamily: 'JetBrains Mono',
                fontFamilyFallback: const ['monospace'],
                fontSize: appearance.fontSize,
                fontHeight: 1.5,
                backgroundColor: syntaxStyle.backgroundColor,
                textColor: syntaxStyle.textColor,
                cursorColor: cs.primary,
                cursorLineColor: cs.primary.withValues(alpha: 0.35),
                selectionColor: cs.primary.withValues(alpha: 0.28),
                codeTheme: syntaxStyle.codeTheme,
              ),
             indicatorBuilder: appearance.showLineNumbers
                  ? (context, editingController, chunkController, notifier) {
                      return DefaultCodeLineNumber(
                        controller: editingController,
                        notifier: notifier,
                        textStyle: TextStyle(
                          color: syntaxStyle.textColor.withValues(alpha: 0.45),
                          fontFamily: 'JetBrains Mono',
                          fontFamilyFallback: const ['monospace'],
                          fontSize: appearance.fontSize,
                          height: 1.5,
                        ),
                        focusedTextStyle: TextStyle(
                          color: cs.primary,
                          fontFamily: 'JetBrains Mono',
                          fontFamilyFallback: const ['monospace'],
                          fontSize: appearance.fontSize,
                          fontWeight: FontWeight.w700,
                          height: 1.5,
                        ),
                        customLineIndex2Text: appearance.relativeLineNumbers
                            ? (lineIndex) {
                                final current = editingController.selection.extentIndex;
                                return lineIndex == current
                                    ? '${lineIndex + 1}'
                                    : '${(lineIndex - current).abs()}';
                              }
                            : null,
                      );
                    }
                  : null,
            ),
          ),
        ),
        if (!_readOnly &&
            softKeyboardVisible &&
            appearance.showAccessoryBar &&
            (appearance.showAccessorySymbols || appearance.showAccessoryActions))
          EditorAccessoryKeyBar(
            controller: activeTab.codeController,
            editorFocusNode: _focusNode,
            symbols: appearance.accessorySymbols,
            actions: appearance.accessoryActions,
            showSymbols: appearance.showAccessorySymbols,
            showActions: appearance.showAccessoryActions,
            isWordWrap: _wordWrap,
            isReadOnly: _readOnly,
            onSearch: () {
              if (activeTab.showMarkdownPreview) {
                setState(() => activeTab.showMarkdownPreview = false);
              }
              activeTab.findController.findMode();
            },
            onToggleWordWrap: _toggleWordWrap,
            onGoToLine: _showGoToLineDialog,
            onGoToStart: _goToStart,
            onGoToEnd: _goToEnd,
            onFormat: _formatter != null ? () => _runFormatter(_formatter!) : null,
            onToggleReadOnly: _toggleReadOnly,
          ),
      ],
    );
  }

  Widget _buildBottomBar(ColorScheme cs) {
    final activeTab = _activeTab;
    final appearance = ref.watch(textEditorAppearanceProvider);
    final timeStr = activeTab.lastSavedAt != null
        ? '${activeTab.lastSavedAt!.hour.toString().padLeft(2, '0')}:${activeTab.lastSavedAt!.minute.toString().padLeft(2, '0')}'
        : null;

    return Container(
      decoration: BoxDecoration(
        color: cs.surfaceContainerLow,
        border: Border(top: BorderSide(color: cs.outlineVariant, width: 0.5)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          Text(
            '${context.l10n.linesCount(activeTab.lineCount)}  |  ${context.l10n.charsCount(activeTab.charCount)}',
            style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12),
          ),
          const Spacer(),
          if (_readOnly && !activeTab.showMarkdownPreview) ...[
            Icon(Icons.lock_outline_rounded, size: 14, color: cs.onSurfaceVariant),
            const SizedBox(width: 4),
            Text(
              context.l10n.textEditorReadOnlyIndicatorLabel,
              style: TextStyle(
                color: cs.onSurfaceVariant,
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
          ] else if (activeTab.isAutosaving) ...[
            SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(
                strokeWidth: 1.8,
                color: cs.primary,
              ),
            ),
            const SizedBox(width: 6),
            Text(
              context.l10n.autosavingLabel,
              style: TextStyle(
                color: cs.primary,
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
          ] else if (activeTab.isSaving) ...[
            Text(
              context.l10n.savingLabel,
              style: TextStyle(
                color: cs.primary,
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
          ] else if (activeTab.isDirty) ...[
            Text(
              context.l10n.unsavedChangesLabel,
              style: TextStyle(
                color: context.semanticColors.warning,
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
          ] else ...[
            Icon(
              Icons.check_circle_outline_rounded,
              size: 14,
              color: context.semanticColors.success,
            ),
            const SizedBox(width: 4),
            Text(
              (activeTab.lastSaveWasAutosave && appearance.autoSave && timeStr != null)
                  ? context.l10n.autosavedAtLabel(timeStr)
                  : context.l10n.savedToVault,
              style: TextStyle(
                color: context.semanticColors.success,
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _GoToLineDialog extends StatefulWidget {
  final int maxLine;

  const _GoToLineDialog({required this.maxLine});

  @override
  State<_GoToLineDialog> createState() => _GoToLineDialogState();
}

class _GoToLineDialogState extends State<_GoToLineDialog> {
  late final TextEditingController _controller = TextEditingController();
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    if (_formKey.currentState?.validate() ?? false) {
      Navigator.of(context).pop(int.parse(_controller.text.trim()));
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(context.l10n.textEditorGoToLineDialogTitle),
      content: Form(
        key: _formKey,
        child: TextFormField(
          controller: _controller,
          autofocus: true,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(
            labelText: context.l10n.textEditorGoToLineFieldLabel,
            helperText: context.l10n.textEditorGoToLineHelperText(widget.maxLine),
          ),
          validator: (value) {
            final line = int.tryParse(value?.trim() ?? '');
            if (line == null || line < 1 || line > widget.maxLine) {
              return context.l10n.textEditorGoToLineInvalidNumber(widget.maxLine);
            }
            return null;
          },
          onFieldSubmitted: (_) => _submit(),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(context.l10n.cancel),
        ),
        FilledButton(
          onPressed: _submit,
          child: Text(context.l10n.goToLineButton),
        ),
      ],
    );
  }
}