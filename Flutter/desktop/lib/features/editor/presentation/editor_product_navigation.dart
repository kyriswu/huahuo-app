part of 'editor_workspace.dart';

extension _EditorProductNavigation on _EditorWorkspaceState {
  String _locationForSection(_WorkspaceSection section) => switch (section) {
    _WorkspaceSection.brain => '/brain',
    _WorkspaceSection.creation => '/creation',
    _WorkspaceSection.chat => '/chat',
    _WorkspaceSection.capture => '/capture/text',
    _WorkspaceSection.tools => '/chat/agent',
    _WorkspaceSection.externalKnowledge => '/knowledge/subscriptions',
    _WorkspaceSection.assets => '/assets',
    _WorkspaceSection.notifications => '/notifications',
    _WorkspaceSection.account => '/account/profile',
    _WorkspaceSection.settings => '/settings',
  };

  Future<void> _showCommandPalette() async {
    final location = await showDesktopFeatureCommandPalette(
      context: context,
      entries: widget.featureEntries,
    );
    if (!mounted || location == null) return;
    if (location == '/creation/proposals') _proposalCreation = null;
    final navigate = widget.onNavigateLocation;
    if (navigate == null) {
      _applyProductLocation(location);
    } else {
      navigate(location);
    }
  }

  void _openCreationWorkspace() =>
      _openFeatureTab(_WorkspaceSection.creation, title: '云端创作');

  void _openRecordingsWorkspace() => _openFeatureTab(
    _WorkspaceSection.assets,
    id: 'recording-library',
    title: '录音文件库',
  );

  void _openSupportWorkspace() =>
      _openAccountProductTab(id: 'support-center', title: '帮助中心');

  void _openDigitalTwinWorkspace() =>
      _openAccountProductTab(id: 'digital-twin-workspace', title: '数字分身');

  void _openAccountProductTab({required String id, required String title}) {
    _openFeatureTab(_WorkspaceSection.account, id: id, title: title);
  }

  void _openProposalWorkspace([ProductCreationDocument? creation]) {
    _proposalCreation = creation;
    _openFeatureTab(
      _WorkspaceSection.tools,
      id: 'proposal-workspace',
      title: '文档提案',
    );
  }

  void _openProposalForCreation(ProductCreationDocument creation) {
    _proposalCreation = creation;
    final navigate = widget.onNavigateLocation;
    if (!_applyingExternalLocation && navigate != null) {
      navigate('/creation/proposals');
    }
    _openProposalWorkspace(creation);
  }
}
