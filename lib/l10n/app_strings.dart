import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'app_strings_es.dart';

/// Manual localization layer (no codegen) so CI stays deterministic.
///
/// Two languages are supported:
/// * English — the default (`languageCode: 'en'`), always used on first run
///   regardless of the device locale.
/// * Bahasa Indonesia (`languageCode: 'id'`) — selectable in Settings.
///
/// [appStringsFor] also works without a [BuildContext] so controllers
/// (Riverpod notifiers) can produce localized error messages.

/// Locale codes the app can render.
const List<String> supportedLanguageCodes = <String>['en', 'id', 'es'];

/// Human-readable native names for the language picker.
const Map<String, String> languageNames = <String, String>{
  'en': 'English',
  'id': 'Bahasa Indonesia',
  'es': 'Español',
};

/// Default language used when no preference is stored.
const String defaultLanguageCode = 'en';

/// Resolves [languageCode] to a strings bundle; unknown codes fall back to
/// English.
AppStrings appStringsFor(String languageCode) {
  switch (languageCode.toLowerCase()) {
    case 'id':
      return AppStringsId();
    case 'es':
      return AppStringsEs();
    default:
      return AppStringsEn();
  }
}

/// Lookup wrapper registered through a [LocalizationsDelegate].
class ZLocalizations {
  const ZLocalizations(this.locale, this.strings);

  final Locale locale;
  final AppStrings strings;

  static ZLocalizations of(BuildContext context) =>
      Localizations.of<ZLocalizations>(context, ZLocalizations)!;
}

/// Convenience accessor for widgets.
AppStrings stringsOf(BuildContext context) =>
    Localizations.of<ZLocalizations>(context, ZLocalizations)!.strings;

const LocalizationsDelegate<ZLocalizations> zLocalizationsDelegate =
    _ZLocalizationsDelegate();

class _ZLocalizationsDelegate extends LocalizationsDelegate<ZLocalizations> {
  const _ZLocalizationsDelegate();

  @override
  bool isSupported(Locale locale) =>
      supportedLanguageCodes.contains(locale.languageCode);

  @override
  Future<ZLocalizations> load(Locale locale) =>
      SynchronousFuture<ZLocalizations>(
        ZLocalizations(locale, appStringsFor(locale.languageCode)),
      );

  @override
  bool shouldReload(_ZLocalizationsDelegate old) => false;
}

/// Every user-facing string in the app.
/// One bilingual help topic shown on the Help screen (v1.41.5).
class HelpEntry {
  const HelpEntry(this.title, this.body);
  final String title;
  final String body;
}

abstract class AppStrings {
  String get cronSectionTitle;
  String get cronTileTitle;
  String get cronTileSubtitle;
  String get cronJobsTitle;
  String get cronMasterTitle;
  String get cronMasterSubtitle;
  String get cronJobsEmptyTitle;
  String get cronJobsEmptyBody;
  String get cronAddJobTooltip;
  String get cronNewTitle;
  String get cronEditTitle;
  String get cronFieldName;
  String get cronFieldSchedule;
  String get cronScheduleEveryMinute;
  String get cronScheduleEvery5Minutes;
  String get cronScheduleHourly;
  String get cronScheduleDaily8;
  String get cronScheduleWeekdays9;
  String get cronScheduleWeekly;
  String get cronScheduleMonthly;
  String get cronScheduleCustom;
  String get cronFieldExpression;
  String get cronExpressionHint;
  String get cronNextRuns;
  String get cronFieldAction;
  String get cronActionNotification;
  String get cronActionTelegram;
  String get cronActionAgent;
  String get cronActionAgentHint;
  String get cronActionChat;
  String get cronActionChatHint;
  String get cronFieldChatTarget;
  String get cronChatNewEveryRun;
  String get cronChatOwnerDefault;
  String get cronFieldChatPrompt;
  String get cronChatPromptRequired;
  String get cronChatTargetMissing;
  String get cronFieldNotifTitle;
  String get cronFieldNotifText;
  String get cronFieldTelegramToken;
  String get cronFieldTelegramChat;
  String get cronFieldMessage;
  String get cronFieldAgentPrompt;
  String get cronAgentRelayHint;
  String get cronRunsWhileAppOpen;
  String get cronNever;
  String get cronNextRunLabel;
  String get cronLastRunLabel;
  String get cronDeleteTitle;
  String cronDeleteBody(String name);
  String get cronRunNowTooltip;
  String get cronNameRequired;
  String get cronExpressionInvalid;
  String get cronTelegramFieldsRequired;
  String get cronMessageRequired;
  String get cronNotifTextRequired;
  String get cronAgentPromptRequired;
  String get cronSaved;
  String get cronHistoryTitle;
  String get cronHistoryEmpty;
  String get cronDisabledBadge;
  String get cronPausedBadge;
  String cronLocalAiHint(String model);
  String get cronLocalAiNoModel;

  // -- Generic ---------------------------------------------------------
  String get menu;
  String get settings;
  String get cancel;
  String get delete;
  String get send;
  String get stop;
  String get result;
  String get resultError;
  String get screenshotUnavailable;
  String get thinking;
  String get readPageText;
  String get open;
  String get share;
  String get rename;
  String get copy;
  String get cut;
  String get paste;
  String get save;
  String get edit;
  String get add;
  String get confirm;
  String get operationFailed;

  // -- v1.44.0 image attachments & speech dictation --------------------
  String get speechListen;
  String get speechStop;
  String get speechListening;
  String get speechUnavailable;
  String get speechPermissionDenied;
  String get imageTooLarge;
  String get imageNotAnImage;

  // -- v1.44.0 update check --------------------------------------------
  String get updateBannerTitle;
  String get updateBannerBody;
  String get updateOpenRelease;
  String get updateDismiss;
  String get checkUpdatesOnStart;
  String get checkUpdatesNow;
  String get updateChecking;
  String get updateUpToDate;
  String get updateCheckFailed;

  // -- v1.48.0 chat-switch IP guard -------------------------------------
  String get ipSwitchWarnTitle;
  String get ipSwitchWarnSubtitle;
  String get ipSwitchWarnDialogTitle;
  String ipSwitchWarnDialogBody(String ip);
  String get ipSwitchWarnContinue;

  // -- v1.44.0 module catalog ------------------------------------------
  String get officialModulesTitle;
  String get officialModulesSubtitle;
  String get moduleUpdatedTo;

  // -- v1.44.0 accessibility leftovers ---------------------------------
  String get loading;
  String get refresh;
  String get parentFolder;
  String get todoCompleted;
  String get todoInProgress;
  String get todoPending;

  // -- v1.49.0 plan (blocked/deps) + skills manager + agentrouter ------
  String get todoBlocked;
  String get todoDependsOn;
  String get skillsTitle;
  String get skillsSubtitle;
  String get skillsManage;
  String get skillsInstallUrl;
  String get skillsUrlTitle;
  String get skillsUrlLabel;
  String get skillsInstallZip;
  String get skillsSearchHint;
  String get skillsEmptyTitle;
  String get skillsEmptyBody;
  String get skillBundledInstall;
  String get skillEnabled;
  String get skillDisabled;
  String get skillConfigure;
  String get skillConfigSave;
  String get skillConfigRequired;
  String get skillConfigSecret;
  String get skillInspect;
  String get skillInstructions;
  String get skillUpdate;
  String get skillRemove;
  String get skillRemoveTitle;
  String get skillRemoveBody;
  String get skillStatusChecking;
  String get skillFiles;
  String get skillSheetTitle;
  String get skillSheetHint;
  String get skillSheetUseGlobal;
  String get skillSheetClear;
  String get skillSheetApply;
  String get composerSkillsTooltip;
  String get drawerSkills;
  String get settingsSkillsManager;
  String get agentRouterHint;
  String get settingsEngineLabel;
  String get engineAuto;
  String get engineAnthropic;
  String get engineOpenai;
  String get engineOpenaiResponses;
  String get engineHint;

  // -- Home / chat -----------------------------------------------------
  String get askAnything;
  String get attachFile;
  String get newChat;
  String get historyTitle;
  String get historyLoadFailed;
  String get noChats;
  String get deleteChatTitle;
  String get deleteChatBody;
  String get renameChatTitle;
  String get nameHint;
  String get pickModel;
  String get customModelHint;
  String get searchModelsHint;
  String get filterAll;
  String get filterTools;
  String get filterFree;
  String get refreshCatalog;
  String get modelsRetry;
  String get modelsLoadError;
  String get modelsEmpty;
  String get modelsEmptyHint;
  String get modelsApiKeyHint;
  String get suggestedFallback;
  String get suggestedFallbackBody;
  String get toolsBadge;
  String get freeBadge;
  String get browseModels;
  String get browseModelsHint;
  String pageIndicator(int current, int total);
  String get searchProvidersHint;
  String get searchSessionsHint;
  String get searchFilesHint;
  String get searchContextHint;
  String get searchLibsHint;
  String get noResults;
  String get agentTagline;
  String get emptySubtitle;
  List<String> get suggestions;

  // -- Files manager ----------------------------------------------------
  String get filesTitle;
  String get filesEmpty;
  String get filesHint;

  /// v1.29.0: copies the ACTIVE chat's workspace folder to the device
  /// file manager (`Downloads/Noah/<chat>` via MediaStore).
  String get filesExportFolder;

  /// Progress dialog text while the folder export runs.
  String get filesExporting;

  /// Success after a MediaStore export.
  String filesExportDone(int count);

  /// Pre-Android-10 fallback: folder zipped, share sheet opened.
  String filesExportZipReady(int count);

  /// Files screen without an ACTIVE chat — no per-chat workspace exists.
  String get filesNoChatTitle;
  String get filesNoChatBody;
  String get newFolder;
  String get newFolderTitle;
  String get compress;
  String get extractHere;
  String get noPreview;
  String get filePreviewTitle;
  String get clipboardCopied;
  String get clipboardCut;
  String get pastedOk;
  String get zipCreatedOk;
  String get unzippedOk;
  String get unzipPasswordTitle;
  String unzipPasswordBody(String name);
  String get passwordFieldHint;
  String get unzipPasswordConfirm;
  String get wrongPassword;
  String get deleteEntryTitle;
  String get deleteEntryBody;

  // -- Context Manager ---------------------------------------------------
  String get contextSection;
  String get contextManagerTitle;
  String get contextManagerHint;
  String contextActiveCount(int n);
  String get addContext;
  String get editContext;
  String get contextNameLabel;
  String get contextContentLabel;
  String get contextEnabledLabel;
  String get deleteContextTitle;
  String get deleteContextBody;
  String get contextEmpty;

  // -- Node.js runtime ---------------------------------------------------
  String get nodeSection;
  String get nodeManagerTitle;
  String get nodeManagerHint;
  String nodeInstalledCount(int n);
  String get nodeAddHint;
  String get nodeAddButton;
  String get nodeVersionHint;
  String get nodeEmpty;
  String get nodeInstalling;
  String get nodeDescription;
  String get nodeRemoveTitle;
  String get nodeRemoveBody;

  // -- Appearance --------------------------------------------------------
  String get appearanceSection;
  String get themeLight;
  String get themeDark;
  String get themeSystem;

  // -- User Agent (browser identity) -------------------------------------
  String get uaSection;
  String get uaModeTitle;
  String get uaModeSubtitle;
  String get uaModeAuto;
  String get uaModeDesktop;
  String get uaModeAndroid;
  String get uaModeHint;
  String get uaCurrentLabel;
  String get uaRotateTooltip;
  String get uaAskRandomTitle;
  String get uaAskRandomSubtitle;
  String get randomUaDialogTitle;
  String get randomUaDialogBody;
  String get randomUaAccept;
  String get randomUaDecline;
  String createdBy(String name);

  // -- Settings --------------------------------------------------------
  String get providerSection;
  String get providerPreset;
  String get baseUrlLabel;
  String get apiKeyLabel;
  String get apiKeyStoredLocally;
  String get modelLabel;
  String get modelHint;
  String get presetsTitle;
  String get savePreset;
  String get savePresetTitle;
  String get presetNameLabel;
  String get editPreset;
  String get deletePresetTitle;
  String get deletePresetBody;
  String get presetHasKey;
  String get presetNoKey;

  // -- Providers management (v1.5.0) -----------------------------------
  String get providersTileSubtitle;
  String get providersTitle;
  String get providersHint;
  String get addProvider;
  String get newProviderTitle;
  String get activeBadge;
  String get useProviderTooltip;
  String providerActivatedSnack(String name);
  String get saveApiKey;
  String get apiKeySavedSnack;
  String get fetchModels;
  String get fetchingModels;
  String modelsFetchedSnack(int n);
  String get modelsCachedNote;
  String modelsCachedCount(int n);
  String get noModelsYet;
  String get nameRequiredError;
  String get urlRequiredError;
  String get duplicateNameError;
  String get providerSavedSnack;
  String get providerDeletedSnack;
  String get keyStatusSection;

  String get maxStepsTitle;
  String get maxStepsHint;
  String get runUntilDoneTitle;
  String get runUntilDoneSubtitle;
  String get runUntilDoneHint;
  String get planFirstTitle;
  String get planFirstSubtitle;
  String get planTitle;
  String planProgress(int done, int total);
  String get showPlanTooltip;
  String get hidePlanTooltip;
  String get confirmDialogTitle;
  String get confirmDialogPrompt;
  String get confirmApprove;
  String get confirmDeny;
  String get confirmDenied;
  String get confirmApproved;
  String get confirmTimeout;
  String get confirmUnavailable;
  String get skillInstallConfirmTitle;
  String skillInstallConfirmSource(String source);
  String get skillInstallConfirmBody;
  String get skillInstallDeclined;
  String get skillWalletConfirmTitle;
  String skillWalletConfirmAction(String skill, String script);
  String get skillWalletConfirmBody;
  String get skillWalletDeclined;
  String get copyMessage;
  String get copied;
  String get activateProviderTitle;
  String activateProviderBody(String name);
  String get activateProviderConfirm;
  String maxStepsReachedMarkdown(int steps);
  String get agentSection;
  String get agentModeTitle;
  String get agentModeSubtitle;
  String get automationTitle;
  String get automationSubtitle;
  String get runInBackgroundTitle;
  String get runInBackgroundSubtitle;
  String get languageSection;
  String get languageSubtitle;
  String get englishOption;
  String get indonesianOption;
  String get dataSection;
  String get exportSessions;
  String get importSessions;
  String exportDone(String path);
  String importDone(int count);
  String get importFailed;

  // -- Session import/export icon tooltips (v1.34.0) ---------------------
  String get importSessionsIconTip;
  String get exportSessionsIconTip;

  // -- Markdown export, token stats & encrypted backup (v1.17.0) ---------
  String get exportChatMarkdown;
  String get exportChatMarkdownEmpty;
  String exportChatMarkdownDone(String path);
  String get tokenStatsMenuItem;
  String get tokenStatsTitle;
  String get statsNoData;
  String get statsPromptTokens;
  String get statsCompletionTokens;
  String get statsTotalTokens;
  String get statsTurns;
  String get statsSessions;
  String get statsPerModel;
  String statsModelLine(
    String prompt,
    String completion,
    String total,
    int turns,
  );
  String get statsUsageHint;
  String get backupSectionTitle;
  String get backupCreate;
  String get backupCreateHint;
  String get backupPassphraseLabel;
  String get backupRestore;
  String get backupRestoreHint;
  String get backupConfirmTitle;
  String get backupConfirmBody;
  String backupRestoreDone(int sessions, bool settings, int contexts);
  String get backupWrongPassphrase;
  String get backupFailed;
  String get backupPassphraseShort;

  // -- App lock & done notifications (v1.18.0) ---------------------------
  String get appLockSection;
  String get appLockTitle;
  String get appLockEnableTitle;
  String get appLockEnableSubtitle;
  String get appLockSetPinTitle;
  String get appLockPinField;
  String get appLockPinTooShort;
  String get appLockPinMismatch;
  String get appLockConfirmPin;
  String get appLockDisableConfirm;
  String get appLockPinHint;
  String get appLockWrongPin;
  String get appLockUnlock;
  String get appLockUseBiometric;
  String get appLockBiometricReason;
  String get notifyOnDoneTitle;
  String get notifyOnDoneSubtitle;
  String get notifDoneTitle;
  String notifDoneBody(String sessionTitle, String? error);

  // -- Exit confirmation + battery optimization (v1.28.0) ---------------
  String get exitAppTitle;
  String get exitAppBody;
  String get exitAppConfirm;
  String get batteryTitle;
  String get batterySubtitle;
  String get batteryRestricted;
  String get batteryExempted;

  String get aboutSection;
  String get aboutBody;

  // -- Help & About screens (v1.41.5) ------------------------------------
  String get helpAboutSection;
  String get helpTileTitle;
  String get helpTileSubtitle;
  String get aboutTileTitle;
  String get aboutTileSubtitle;
  String get aboutTitle;
  String get aboutTagline;
  String get aboutCreatorLabel;
  String get aboutVersionLabel;
  String get aboutWhatsInside;
  String get aboutDisclaimer;
  String get helpTitle;
  String get helpIntro;
  List<HelpEntry> get helpTopics;

  // -- Message actions (v1.15.0) ----------------------------------------
  String get editMessageAction;
  String get editDialogTitle;
  String get regenerate;

  // -- Global chat search (v1.15.0) -------------------------------------
  String get searchChats;
  String get searchHint;
  String get noSearchResults;
  String get searchInitialHint;

  // -- Automatic conversation titles (v1.15.0) --------------------------
  String get autoTitleTitle;
  String get autoTitleSubtitle;

  // -- Prompt library (v1.15.0) -----------------------------------------
  String get promptLibrary;
  String get promptLibraryEmpty;
  String get newPrompt;
  String get editPrompt;
  String get promptTitleLabel;
  String get promptContentLabel;
  String get insertPrompt;
  String get deletePromptTitle;
  String get deletePromptBody;
  String get promptSaved;
  String get promptDeleted;

  // -- Chat modules / plugins (v1.21.0) ---------------------------------
  String get modulesTitle;
  String get modulesInstall;
  String get modulesEmpty;
  String get modulesEmptyHint;
  String get modulesManage;
  String get moduleSdkDocs;
  String get moduleStartNewChat;
  String get moduleActivate;
  String get moduleDeactivate;
  String get moduleActiveBadge;
  String moduleDeactivated(String name);
  String get moduleTerminated;
  String moduleRunFailed(String error);
  String moduleNotFound(String name);
  String get moduleSessionBusy;
  String modulePermissionTitle(String name);
  String get modulePermissionBody;
  String get moduleAllow;
  String moduleInstallSuccess(String name);
  String moduleInstallFailed(String error);
  String get moduleRemoveTitle;
  String moduleRemoveBody(String name);
  String moduleRemoved(String name);
  String get pluginMenuTitle;
  String get pluginMenuEmpty;
  String get startWithModule;

  // -- Module per-chat setup form (v1.24.0) ------------------------------
  String moduleSetupNeededTitle(String name);
  String get moduleSetupNeededBody;

  /// Shown when a module run failed with a setup-required signal but the
  /// installed manifest declares no setup form — i.e. a stale module zip
  /// from before the form feature. Names both concrete solutions.
  String moduleSetupLegacyHint(String name);
  String get moduleSetupBannerCta;
  String get moduleSetupSaveRun;
  String get moduleSetupPerChatHint;
  String get moduleSetupRequiredTag;

  /// v1.29.0: shown on the setup banner while a sent message is QUEUED
  /// behind the form — the agent does not process it until submission.
  String get moduleSetupWaitingHint;

  /// v1.31.0: master switch for the module `device` capability
  /// (`zagents.device.shell`) — rooted phones only.
  String get deviceCommandsTitle;
  String get deviceCommandsSubtitle;

  // -- Auto retry & red stop button (v1.30.0) ------------------------------
  String get autoRetrySection;
  String get autoRetryTitle;
  String get autoRetrySubtitle;
  String get autoRetryAttemptsTitle;
  String get autoRetryDelayTitle;
  String get autoRetryHint;
  String autoRetryStreamNote(int attempt, int max);
  String autoRetryResumeNote(int attempt, int max);
  String autoRetryPlanNote(int attempt, int max);

  /// v1.32.0 — shown in the streaming placeholder while the retry loop
  /// HOLDS because airplane mode is ON (expected outage, no attempt is
  /// consumed until the radio comes back).
  String get autoRetryAirplaneNote;

  /// v1.32.0 — run-level note added before an airplane-mode hold.
  String get autoRetryAirplaneResumeNote;

  // -- Module doctor (v1.26.0) --------------------------------------------
  String moduleRepairCardTitle(String name, String version);
  String moduleRepairCardBody(String permissions);
  String get moduleRepairInstall;
  String get moduleRepairDiscard;
  String moduleRepairInstalled(String name);
  String moduleRepairInstallFailed(String error);
  String get moduleExportTooltip;

  // -- Module export dialog (v1.47.0) --------------------------------------
  String get moduleExportTitle;
  String get moduleExportHint;
  String get moduleExportAction;

  // -- Module update & remote install (v1.46.0) ---------------------------
  String get moduleInstallFromUrl;
  String get moduleUrlDialogTitle;
  String get moduleUrlDialogHint;
  String get moduleUrlDialogBody;
  String get moduleDownload;
  String get moduleUpdateTooltip;
  String get moduleUpdateTitle;
  String moduleUpdateBody(String name);
  String get moduleUpdateFromZip;
  String get moduleUpdateFromUrl;
  String get moduleDownloading;
  String get moduleSampleInstall;
  String get moduleSampleUpdate;
  String get moduleSampleInstalled;
  String get moduleSampleRepoHint;

  // -- Module builder (/make_plugins, v1.27.0) ----------------------------
  String moduleBuildCardTitle(String name, String version);
  String moduleBuildCardBody(String permissions);
  String moduleBuildInstalled(String name);

  // -- Controller messages (no BuildContext available) -----------------
  String get missingApiKey;
  String get modelNotSet;
  String get stoppedMarkdown;
  String get chatOpenError;
  String get chatDeleteError;
  String get chatRenameError;

  // -- Background service notification (no BuildContext available) -----
  String get notifTitle;
  String get notifProcessing;
  String notifStep(int step, String tool);

  // -- Stop / force stop (v1.42.0) ---------------------------------------
  /// Snack after the second Stop tap: one more tap offers the force-stop
  /// dialog.
  String get stopHintForce;
  String get forceStopTitle;
  String get forceStopBody;
  String get forceStopConfirm;
  String get forceStopCancel;

  /// Snack after a confirmed force stop.
  String get forceStopDone;

  // -- Local AI / Ollama (port Fase 2) --------------------------------
  String get ollamaSectionTitle;
  String get ollamaTileTitle;
  String get ollamaTileSubtitle;
  String get ollamaScreenTitle;
  String get ollamaTabServer;
  String get ollamaExternalServerLabel;
  String get ollamaProbe;
  String ollamaProbeOk(String version);
  String ollamaProbeFail(String error);
  String get ollamaUseAsProvider;
  String get ollamaOnDeviceTitle;
  String get ollamaOnDevicePending;

  String get cronOpenOllamaManage;
  String get ollamaActiveModelLabel;
  String ollamaAddedAt(String date);
  String ollamaBattery(int percent);
  String ollamaBatteryCharging(int percent);
  String ollamaBatteryLow(int percent);
  String get ollamaBenchmark;
  String ollamaBenchmarkFailed(String error);
  String get ollamaBenchmarkRunning;
  String ollamaBenchmarkSummary(String tokPerSec, int firstTokenMs, int tokens);
  String get ollamaCatalogRefresh;
  String ollamaCatalogRefreshDone(int count);
  String ollamaCatalogRefreshFailed(String error);
  String get ollamaCatalogReset;
  String get ollamaCatalogResetDone;
  String get ollamaClearFinished;
  String get ollamaClose;
  String get ollamaConfigInvalid;
  String get ollamaConfigSave;
  String get ollamaConfigSaved;
  String get ollamaContextLabel;
  String get ollamaCopyAll;
  String ollamaCtxTokens(String tokens);
  String get ollamaCustomUrlInvalid;
  String get ollamaCustomUrlLabel;
  String ollamaDeleteBody(String name);
  String get ollamaDeleteTitle;
  String ollamaDeviceRam(String size);
  String get ollamaDlCanceled;
  String get ollamaDlCompleted;
  String get ollamaDlFailed;
  String get ollamaDlPaused;
  String get ollamaDlQueued;
  String get ollamaDlRunning;
  String get ollamaDownload;
  String ollamaDownloadStarted(String name);
  String get ollamaDownloadingLabel;
  String get ollamaDownloadsEmpty;
  String get ollamaExport;
  String get ollamaExportDone;
  String get ollamaExportNone;
  String get ollamaExportSelected;
  String ollamaExportSelectedDone(int count);
  String get ollamaFitFilter;
  String get ollamaGoToCatalog;
  String get ollamaImportButton;
  String ollamaImportDone(String name);
  String get ollamaImportFailed;
  String get ollamaInstalledEmptyBody;
  String get ollamaInstalledEmptyTitle;
  String get ollamaInstalledLabel;
  String get ollamaLogTitle;
  String get ollamaModelEmptyHint;
  String get ollamaModelLabel;
  String get ollamaOomWarning;
  String get ollamaPause;
  String get ollamaPortLabel;
  String ollamaRamEst(String size);
  String get ollamaResume;
  String ollamaRiskBody(String ref);
  String get ollamaRiskTitle;
  String get ollamaRuntimeUnavailable;
  String get ollamaSelectMode;
  String ollamaSelectedCount(int count);
  String ollamaSizeProgress(int receivedMb, int totalMb);
  String get ollamaSizeUnknown;
  String get ollamaSourceCatalog;
  String get ollamaSourceCustomUrl;
  String get ollamaSourceImported;
  String get ollamaStart;
  String get ollamaStartFailedSnack;
  String get ollamaStartWith;
  String get ollamaStartedSnack;
  String get ollamaStatusFailed;
  String get ollamaStatusRunning;
  String get ollamaStatusStarting;
  String get ollamaStatusStopped;
  String get ollamaStatusStopping;
  String get ollamaStatusUnavailable;
  String get ollamaStop;
  String get ollamaStoppedSnack;
  String get ollamaTabCatalog;
  String get ollamaTabDownloads;
  String get ollamaTabInstalled;
  String get ollamaThreadsLabel;
  String get ollamaTierHeavy;
  String get ollamaTierLight;
  String get ollamaTierMedium;
  String get ollamaTooLarge;
  String get ollamaUseInChat;
  String ollamaUseInChatBody(String alias);
  String get ollamaUseInChatDone;
  String get ollamaUseInChatTitle;
  String get ollamaViewFullLog;
}

/// English strings (default).
class AppStringsEn implements AppStrings {
  @override
  String get cronSectionTitle => 'Cron jobs';
  @override
  String get cronTileTitle => 'Cron jobs';
  @override
  String get cronTileSubtitle =>
      'Schedule Telegram messages, notifications or agent tasks';
  @override
  String get cronJobsTitle => 'Cron jobs';
  @override
  String get cronMasterTitle => 'Scheduler enabled';
  @override
  String get cronMasterSubtitle =>
      'Master switch — pauses every job without deleting it';
  @override
  String get cronJobsEmptyTitle => 'No jobs yet';
  @override
  String get cronJobsEmptyBody =>
      'Tap + to schedule Telegram messages, notifications or agent tasks.';
  @override
  String get cronAddJobTooltip => 'Add job';
  @override
  String get cronNewTitle => 'New job';
  @override
  String get cronEditTitle => 'Edit job';
  @override
  String get cronFieldName => 'Job name';
  @override
  String get cronFieldSchedule => 'Schedule';
  @override
  String get cronScheduleEveryMinute => 'Every minute';
  @override
  String get cronScheduleEvery5Minutes => 'Every 5 minutes';
  @override
  String get cronScheduleHourly => 'Hourly (minute 0)';
  @override
  String get cronScheduleDaily8 => 'Daily at 08:00';
  @override
  String get cronScheduleWeekdays9 => 'Weekdays at 09:00';
  @override
  String get cronScheduleWeekly => 'Sundays at 09:00';
  @override
  String get cronScheduleMonthly => '1st of the month at 08:00';
  @override
  String get cronScheduleCustom => 'Custom (cron expression)';
  @override
  String get cronFieldExpression => 'Cron expression';
  @override
  String get cronExpressionHint =>
      'minute hour day month weekday — e.g. 30 8 * * mon-fri';
  @override
  String get cronNextRuns => 'Next runs';
  @override
  String get cronFieldAction => 'Action';
  @override
  String get cronActionNotification => 'Notification';
  @override
  String get cronActionTelegram => 'Telegram';
  @override
  String get cronActionAgent => 'Agent task';
  @override
  String get cronActionAgentHint =>
      'Runs the prompt as a headless agent (workspace, browser, web and '
      'node tools) and notifies the result.';
  @override
  String get cronActionChat => 'Run in chat';
  @override
  String get cronActionChatHint =>
      'Sends the command into the selected chat like a typed message; the '
      'agent answers right in that conversation (its history, modules and '
      'skills all apply).';
  @override
  String get cronFieldChatTarget => 'Target chat';
  @override
  String get cronChatNewEveryRun => 'New chat (each run)';
  @override
  String get cronChatOwnerDefault => 'This chat (default)';
  @override
  String get cronFieldChatPrompt => 'Command to run';
  @override
  String get cronChatPromptRequired => 'The command text is required.';
  @override
  String get cronChatTargetMissing => 'Selected chat not found (deleted?)';
  @override
  String get cronFieldNotifTitle => 'Notification title';
  @override
  String get cronFieldNotifText => 'Notification text';
  @override
  String get cronFieldTelegramToken => 'Bot token';
  @override
  String get cronFieldTelegramChat => 'Chat ID';
  @override
  String get cronFieldMessage => 'Message text';
  @override
  String get cronFieldAgentPrompt => 'Agent prompt';
  @override
  String get cronAgentRelayHint =>
      'Fill bot token + chat ID to also relay the answer to Telegram '
      '(optional).';
  @override
  String get cronRunsWhileAppOpen =>
      'Jobs run while the app is running (foreground or background hold). '
      'Runs missed while the app was closed are skipped, not replayed.';
  @override
  String get cronNever => 'never';
  @override
  String get cronNextRunLabel => 'Next';
  @override
  String get cronLastRunLabel => 'Last';
  @override
  String get cronDeleteTitle => 'Delete job?';
  @override
  String cronDeleteBody(String name) =>
      'The scheduled job "$name" and its run history will be removed.';
  @override
  String get cronRunNowTooltip => 'Run now';
  @override
  String get cronNameRequired => 'Name is required.';
  @override
  String get cronExpressionInvalid => 'Invalid cron expression.';
  @override
  String get cronTelegramFieldsRequired =>
      'Bot token and chat ID are required.';
  @override
  String get cronMessageRequired => 'Message text is required.';
  @override
  String get cronNotifTextRequired => 'Notification text is required.';
  @override
  String get cronAgentPromptRequired => 'Agent prompt is required.';
  @override
  String get cronSaved => 'Job saved.';
  @override
  String get cronHistoryTitle => 'Recent runs';
  @override
  String get cronHistoryEmpty => 'No runs recorded yet.';
  @override
  String get cronDisabledBadge => 'disabled';
  @override
  String get cronPausedBadge => 'scheduler paused';
  @override
  String cronLocalAiHint(String model) =>
      'Runs on the local model “$model” — start the Local AI server first.';
  @override
  String get cronLocalAiNoModel =>
      'Runs on the local model — start the Local AI server first.';

  const AppStringsEn();

  // -- Generic ---------------------------------------------------------
  @override
  String get menu => 'Menu';
  @override
  String get settings => 'Settings';
  @override
  String get cancel => 'Cancel';
  @override
  String get delete => 'Delete';
  @override
  String get send => 'Send';
  @override
  String get stop => 'Stop';
  @override
  String get result => 'result';
  @override
  String get resultError => 'result (error)';
  @override
  String get screenshotUnavailable => 'screenshot unavailable';
  @override
  String get thinking => 'thinking…';
  @override
  String get readPageText => 'Read page text';
  @override
  String get open => 'Open';
  @override
  String get share => 'Share';
  @override
  String get rename => 'Rename';
  @override
  String get copy => 'Copy';
  @override
  String get cut => 'Cut';
  @override
  String get paste => 'Paste';
  @override
  String get save => 'Save';
  @override
  String get edit => 'Edit';
  @override
  String get add => 'Add';
  @override
  String get confirm => 'OK';
  @override
  String get operationFailed => 'Operation failed.';

  // -- Home / chat -----------------------------------------------------
  @override
  String get askAnything => 'Ask anything…';
  @override
  String get attachFile => 'Attach file';

  @override
  String get speechListen => 'Dictate';

  @override
  String get speechStop => 'Stop dictation';

  @override
  String get speechListening => 'Listening…';

  @override
  String get speechUnavailable =>
      'Speech recognition is not available on this device.';

  @override
  String get speechPermissionDenied => 'Microphone permission was denied.';

  @override
  String get imageTooLarge => 'Image is larger than 20 MB.';

  @override
  String get imageNotAnImage => 'That file is not a supported image.';

  @override
  String get updateBannerTitle => 'Update available';

  @override
  String get updateBannerBody => 'A newer version of Noah is out.';

  @override
  String get updateOpenRelease => 'View release';

  @override
  String get updateDismiss => 'Dismiss';

  @override
  String get checkUpdatesOnStart => 'Check for updates on start';

  @override
  String get checkUpdatesNow => 'Check for updates now';

  @override
  String get updateChecking => 'Checking…';

  @override
  String get updateUpToDate => 'You are on the latest version.';

  @override
  String get updateCheckFailed => 'Could not check for updates.';

  @override
  String get ipSwitchWarnTitle => 'Warn when the IP is the same';

  @override
  String get ipSwitchWarnSubtitle =>
      'Before switching chats, compare the current public IP with the last '
      'one used in the target chat and ask before continuing.';

  @override
  String get ipSwitchWarnDialogTitle => 'Same IP as last session';

  @override
  String ipSwitchWarnDialogBody(String ip) =>
      'The current public IP ($ip) is the same as the last IP recorded for '
      'this chat. Continue anyway?';

  @override
  String get ipSwitchWarnContinue => 'Continue';

  @override
  String get officialModulesTitle => 'Official sample modules';

  @override
  String get officialModulesSubtitle =>
      'Install from the samples folder zips (samples/<name>.zip in the repo), then manage them here.';

  @override
  String get moduleUpdatedTo => 'Module updated to version';

  @override
  String get loading => 'Loading';

  @override
  String get refresh => 'Refresh';

  @override
  String get parentFolder => 'Parent folder';

  @override
  String get todoCompleted => 'Completed';

  @override
  String get todoInProgress => 'In progress';

  @override
  String get todoPending => 'Pending';

  @override
  String get todoBlocked => 'Blocked';

  @override
  String get todoDependsOn => 'Depends on';

  @override
  String get skillsTitle => 'Skills';

  @override
  String get skillsSubtitle => 'Install once, use in every chat';

  @override
  String get skillsManage => 'Manage skills';

  @override
  String get skillsInstallUrl => 'Install from URL';

  @override
  String get skillsUrlTitle => 'Install from URL';

  @override
  String get skillsUrlLabel => 'Git URL or skill source';

  @override
  String get skillsInstallZip => 'Install from ZIP';

  @override
  String get skillsSearchHint => 'Search skills';

  @override
  String get skillsEmptyTitle => 'No skills yet';

  @override
  String get skillsEmptyBody =>
      'Install a skill from a URL, ZIP or a bundled pack to extend the '
      'agent.';

  @override
  String get skillBundledInstall => 'Install';

  @override
  String get skillEnabled => 'Enabled';

  @override
  String get skillDisabled => 'Disabled';

  @override
  String get skillConfigure => 'Configure';

  @override
  String get skillConfigSave => 'Save config';

  @override
  String get skillConfigRequired => 'Required';

  @override
  String get skillConfigSecret => 'Stored encrypted on this device';

  @override
  String get skillInspect => 'Inspect';

  @override
  String get skillInstructions => 'Instructions';

  @override
  String get skillUpdate => 'Update';

  @override
  String get skillRemove => 'Remove';

  @override
  String get skillRemoveTitle => 'Remove skill?';

  @override
  String get skillRemoveBody =>
      'Its stored config is kept so you can roll back safely.';

  @override
  String get skillStatusChecking => 'Checking…';

  @override
  String get skillFiles => 'Files';

  @override
  String get skillSheetTitle => 'Attach skills';

  @override
  String get skillSheetHint => 'Selected skills guide this chat only.';

  @override
  String get skillSheetUseGlobal => 'Use global default';

  @override
  String get skillSheetClear => 'Clear selection';

  @override
  String get skillSheetApply => 'Apply';

  @override
  String get composerSkillsTooltip => 'Skills for this chat';

  @override
  String get drawerSkills => 'Skills';

  @override
  String get settingsSkillsManager => 'Skills manager';

  @override
  String get agentRouterHint =>
      'agentrouter.org gateway: every request carries the claude-cli '
      'identity the gateway requires. Claude models speak Anthropic '
      'Messages; GPT and other models speak OpenAI-compatible. If the '
      'gateway bot-challenges the connection, switch to mobile data and '
      'retry.';

  @override
  String get settingsEngineLabel => 'Engine';

  @override
  String get engineAuto => 'Auto — detect per model';

  @override
  String get engineAnthropic => 'Anthropic Messages';

  @override
  String get engineOpenai => 'OpenAI Chat Completions';

  @override
  String get engineOpenaiResponses => 'OpenAI Responses';

  @override
  String get engineHint =>
      'Wire protocol used to reach this provider. Auto picks per model '
      '(Claude models → Anthropic Messages, the rest → OpenAI Chat '
      'Completions) and retries through the OpenAI Responses API when a '
      'model requires it. Pin an engine when a provider only serves one '
      'protocol.';

  @override
  String get newChat => 'New chat';
  @override
  String get historyTitle => 'History';
  @override
  String get historyLoadFailed => 'Failed to load history.';
  @override
  String get noChats => 'No conversations yet.';
  @override
  String get deleteChatTitle => 'Delete conversation?';
  @override
  String get deleteChatBody => 'This conversation will be permanently deleted.';
  @override
  String get renameChatTitle => 'Rename conversation';
  @override
  String get nameHint => 'Name';
  @override
  String get pickModel => 'Pick a model';
  @override
  String get customModelHint => 'Custom model (e.g. openai/gpt-4o-mini)';
  @override
  String get searchModelsHint => 'Search models…';
  @override
  String get filterAll => 'All';
  @override
  String get filterTools => 'Tools';
  @override
  String get filterFree => 'Free';
  @override
  String get refreshCatalog => 'Refresh catalog';
  @override
  String get modelsRetry => 'Retry';
  @override
  String get modelsLoadError => 'Failed to load the model list.';
  @override
  String get modelsEmpty => 'No models match';
  @override
  String get modelsEmptyHint =>
      'Try another keyword or filter — some providers do not advertise '
      'tool support.';
  @override
  String get modelsApiKeyHint =>
      'Enter your API key in Settings to browse the full model catalog '
      'of your provider.';
  @override
  String get suggestedFallback => 'SUGGESTED MODELS';
  @override
  String get suggestedFallbackBody =>
      'Showing suggested models instead. Check your connection or the '
      'Base URL, then retry.';
  @override
  String get toolsBadge => 'tools';
  @override
  String get freeBadge => 'FREE';
  @override
  String get browseModels => 'Browse models';
  @override
  String get browseModelsHint =>
      'Tap the search icon to browse the live model catalog.';
  @override
  String pageIndicator(int current, int total) => 'Page $current of $total';
  @override
  String get searchProvidersHint => 'Search providers…';
  @override
  String get searchSessionsHint => 'Search chats…';
  @override
  String get searchFilesHint => 'Search files…';
  @override
  String get searchContextHint => 'Search contexts…';
  @override
  String get searchLibsHint => 'Search libraries…';
  @override
  String get noResults => 'No results';
  @override
  String get agentTagline => 'AI Agent · Flutter';
  @override
  String get emptySubtitle =>
      'Your on-device AI agent — browse, take screenshots,\n'
      'run code, and manage files right from chat.';
  @override
  List<String> get suggestions => const <String>[
    'Open wikipedia.org and summarize its main page',
    "Search today's Bitcoin price and take a screenshot",
    'Create a notes.txt file with my daily plan',
    'Run JavaScript to parse this JSON I attached',
  ];

  // -- Files manager ----------------------------------------------------
  @override
  String get filesTitle => 'Files';
  @override
  String get filesEmpty => 'No files yet.';
  @override
  String get filesHint =>
      'This workspace is private to the current chat — files from other '
      'chats never mix in. Copy, paste, zip and share them.';
  @override
  String get filesExportFolder => 'Export chat folder to device';
  @override
  String get filesExporting => 'Exporting this chat\'s folder…';
  @override
  String filesExportDone(int count) =>
      'Chat folder saved to Downloads/Noah ($count files).';
  @override
  String filesExportZipReady(int count) =>
      'Chat folder zipped ($count files) — choose where to save or send it.';
  @override
  String get filesNoChatTitle => 'No chat open';
  @override
  String get filesNoChatBody =>
      'Open or start a chat first — every chat has its own private '
      'workspace folder here, so files never mix between chats.';
  @override
  String get newFolder => 'New folder';
  @override
  String get newFolderTitle => 'New folder';
  @override
  String get compress => 'Compress to ZIP';
  @override
  String get extractHere => 'Extract';
  @override
  String get noPreview => 'No preview available for this file type.';
  @override
  String get filePreviewTitle => 'Preview';
  @override
  String get clipboardCopied => 'Copied.';
  @override
  String get clipboardCut => 'Cut. Paste it in another folder.';
  @override
  String get pastedOk => 'Pasted.';
  @override
  String get zipCreatedOk => 'ZIP created.';
  @override
  String get unzippedOk => 'Extracted.';
  @override
  String get unzipPasswordTitle => 'Password required';
  @override
  String unzipPasswordBody(String name) =>
      '"$name" is encrypted. Enter the password to extract it.';
  @override
  String get passwordFieldHint => 'Password';
  @override
  String get unzipPasswordConfirm => 'Extract';
  @override
  String get wrongPassword => 'Wrong password.';
  @override
  String get deleteEntryTitle => 'Delete?';
  @override
  String get deleteEntryBody => 'This item will be permanently deleted.';

  // -- Context Manager ---------------------------------------------------
  @override
  String get contextSection => 'Context';
  @override
  String get contextManagerTitle => 'Context manager';
  @override
  String get contextManagerHint =>
      'Reusable prompt blocks. Enabled entries are sent with every request '
      'so the agent always follows your rules.';
  @override
  String contextActiveCount(int n) => '$n active';
  @override
  String get addContext => 'Add context';
  @override
  String get editContext => 'Edit context';
  @override
  String get contextNameLabel => 'Name';
  @override
  String get contextContentLabel => 'Content (sent as prompt context)';
  @override
  String get contextEnabledLabel => 'Use this context';
  @override
  String get deleteContextTitle => 'Delete context?';
  @override
  String get deleteContextBody =>
      'This context entry will be permanently deleted.';
  @override
  String get contextEmpty =>
      'No context entries yet. Add rules the agent should always follow.';

  // -- Node.js runtime ---------------------------------------------------
  @override
  String get nodeSection => 'Node.js runtime';
  @override
  String get nodeManagerTitle => 'Node.js runtime & modules';
  @override
  String get nodeManagerHint =>
      'An embedded JavaScript runtime the agent can use to process data. '
      'Install npm packages it needs and remove them when done.';
  @override
  String nodeInstalledCount(int n) => '$n package(s) installed';
  @override
  String get nodeAddHint => 'Package name, e.g. lodash';
  @override
  String get nodeAddButton => 'Install';
  @override
  String get nodeVersionHint => 'Version (optional)';
  @override
  String get nodeEmpty => 'No packages installed yet.';
  @override
  String get nodeInstalling => 'Installing…';
  @override
  String get nodeDescription =>
      'node_run lets the agent execute JavaScript with require(), fs and '
      'fetch. Packages are downloaded from the npm registry and stored in '
      'the app sandbox.';
  @override
  String get nodeRemoveTitle => 'Remove package?';
  @override
  String get nodeRemoveBody => 'The package files will be deleted.';

  // -- Appearance --------------------------------------------------------
  @override
  String get appearanceSection => 'Appearance';
  @override
  String get themeLight => 'Light';
  @override
  String get themeDark => 'Dark';
  @override
  String get themeSystem => 'System';

  // -- User Agent ---------------------------------------------------------
  @override
  String get uaSection => 'User Agent';
  @override
  String get uaModeTitle => 'User-Agent Mode';
  @override
  String get uaModeSubtitle =>
      'Applied to the embedded browser the agent browses with.';
  @override
  String get uaModeAuto => 'Auto (device default)';
  @override
  String get uaModeDesktop => 'PC/Desktop';
  @override
  String get uaModeAndroid => 'Android Mobile';
  @override
  String get uaModeHint =>
      'Auto uses an Android identity that matches this device and stays '
      'stable for the whole session. PC/Desktop also switches page layout '
      'to desktop rendering.';
  @override
  String get uaCurrentLabel => 'Active User-Agent';
  @override
  String get uaRotateTooltip => 'Use another User-Agent';
  @override
  String get uaAskRandomTitle => 'Offer random User-Agent on new chat';
  @override
  String get uaAskRandomSubtitle =>
      'Every new chat asks whether the embedded browser should switch to a '
      'different, randomly picked User-Agent. You can decline to keep the '
      'current one.';
  @override
  String get randomUaDialogTitle => 'Random User-Agent';
  @override
  String get randomUaDialogBody =>
      'Use a different, randomly picked User-Agent for the embedded browser '
      'in this new chat? The choice is remembered until you change it again.';
  @override
  String get randomUaAccept => 'Yes, randomize';
  @override
  String get randomUaDecline => 'Keep current';

  // -- Settings --------------------------------------------------------
  @override
  String get providerSection => 'AI provider';
  @override
  String get providerPreset => 'Provider preset';
  @override
  String get baseUrlLabel => 'Base URL (OpenAI-compatible)';
  @override
  String get apiKeyLabel => 'API key';
  @override
  String get apiKeyStoredLocally =>
      'Each preset keeps its own key, stored only on this device. '
      'InferHub keys look like sk-airo-…';
  @override
  String get modelLabel => 'Model';
  @override
  String get modelHint => 'e.g. z-ai/glm-4.6 or anthropic/claude-sonnet-4.5';
  @override
  String get presetsTitle => 'Presets (each keeps its own API key)';
  @override
  String get savePreset => 'Save current as preset';
  @override
  String get savePresetTitle => 'Save preset';
  @override
  String get presetNameLabel => 'Preset name';
  @override
  String get editPreset => 'Edit preset';
  @override
  String get deletePresetTitle => 'Delete preset?';
  @override
  String get deletePresetBody => 'The preset and its stored key are removed.';
  @override
  String get presetHasKey => 'key saved';
  @override
  String get presetNoKey => 'no key';

  // -- Providers management (v1.5.0) -----------------------------------
  @override
  String get providersTileSubtitle => 'Manage providers, API keys and models';
  @override
  String get providersTitle => 'Providers';
  @override
  String get providersHint =>
      'Tap a provider to edit it, long-press to activate it with a '
      'confirmation. Each provider stores its own API key and model list.';
  @override
  String get addProvider => 'Add provider';
  @override
  String get newProviderTitle => 'New provider';
  @override
  String get activeBadge => 'ACTIVE';
  @override
  String get useProviderTooltip => 'Use this provider';
  @override
  String providerActivatedSnack(String name) => 'Connected to $name';
  @override
  String get saveApiKey => 'Save API key';
  @override
  String get apiKeySavedSnack => 'API key saved for this provider';
  @override
  String get fetchModels => 'Fetch models';
  @override
  String get fetchingModels => 'Fetching…';
  @override
  String modelsFetchedSnack(int n) => '$n models available';
  @override
  String get modelsCachedNote =>
      'Showing the last fetched list for this provider.';
  @override
  String modelsCachedCount(int n) => '$n models cached';
  @override
  String get noModelsYet =>
      'No models fetched yet — tap “Fetch models” to load the list from '
      'this provider.';
  @override
  String get nameRequiredError => 'Name is required.';
  @override
  String get urlRequiredError => 'Base URL is required.';
  @override
  String get duplicateNameError => 'A provider with this name already exists.';
  @override
  String get providerSavedSnack => 'Provider saved';
  @override
  String get providerDeletedSnack => 'Provider deleted';
  @override
  String get keyStatusSection => 'Key status';

  @override
  String get maxStepsTitle => 'Max agent steps';
  @override
  String get maxStepsHint =>
      'How many tool-call rounds the agent may take (1-100). Type a custom '
      'value or use the slider.';
  @override
  String get runUntilDoneTitle => 'Run until done';
  @override
  String get runUntilDoneSubtitle =>
      'The agent keeps working until the task is really finished instead of '
      'stopping at the steps cap (recommended). Turn off to enforce the '
      'limit below.';
  @override
  String maxStepsReachedMarkdown(int steps) =>
      '*Paused: reached the max agent steps limit ($steps). The task may not '
      'be finished — raise the limit in Settings or keep “Run until done” '
      'enabled.*';
  @override
  String get runUntilDoneHint =>
      'Bypassed while “Run until done” is on — the agent works until the '
      'task is finished.';
  @override
  String get planFirstTitle => 'Plan first (Todos)';
  @override
  String get planFirstSubtitle =>
      'The agent starts every task with a todo plan and keeps working '
      'until all todos are completed (recommended).';
  @override
  String get planTitle => 'Plan';
  @override
  String planProgress(int done, int total) => '$done of $total done';
  @override
  String get showPlanTooltip => 'Show plan';
  @override
  String get hidePlanTooltip => 'Hide plan';
  @override
  String get confirmDialogTitle => 'Approval required';
  @override
  String get confirmDialogPrompt =>
      'The agent asks for your explicit approval before performing this '
      'action. Review every line before deciding.';
  @override
  String get confirmApprove => 'Approve';
  @override
  String get confirmDeny => 'Deny';
  @override
  String get confirmDenied =>
      'DENIED by the user. Do not perform this action and do not retry '
      'it in this conversation.';
  @override
  String get confirmApproved =>
      'APPROVED by the user. You may perform exactly the action described '
      '— nothing more.';
  @override
  String get confirmTimeout =>
      'No answer within 10 minutes — treated as DENIED. Do not perform '
      'the action.';
  @override
  String get confirmUnavailable =>
      'This chat is not on screen, so the user cannot see the approval '
      'prompt. Bring this chat to the foreground and ask again.';
  @override
  String get skillInstallConfirmTitle => 'Install external skill?';
  @override
  String skillInstallConfirmSource(String source) => 'Source: $source';
  @override
  String get skillInstallConfirmBody =>
      'This downloads third-party code that will run on this device with '
      'network and file access. Continue only if you trust the source.';
  @override
  String get skillInstallDeclined =>
      'The user declined to install this skill. Do not install it and do '
      'not retry it in this conversation.';
  @override
  String get skillWalletConfirmTitle => 'Approve wallet action?';
  @override
  String skillWalletConfirmAction(String skill, String script) =>
      'Skill: $skill — script: $script';
  @override
  String get skillWalletConfirmBody =>
      'This skill moves value on a blockchain (transfer, swap, approval, '
      'NFT sale or similar). Approve only if the amount, network and '
      'destination match what you expect. A denial is final for this run.';
  @override
  String get skillWalletDeclined =>
      'The user DENIED this wallet action. Do not perform it and do not '
      'retry it in this conversation. Report the denial to the user and '
      'stop; no transaction was sent.';
  @override
  String get copyMessage => 'Copy';
  @override
  String get copied => 'Copied';
  @override
  String get activateProviderTitle => 'Activate provider';
  @override
  String activateProviderBody(String name) =>
      'Use “$name” as the active provider? Its stored API key and model '
      'will be applied to the connection.';
  @override
  String get activateProviderConfirm => 'Activate';
  @override
  String get agentSection => 'Agent';
  @override
  String get agentModeTitle => 'Agent mode';
  @override
  String get agentModeSubtitle =>
      'Enable tool calling: browsing, screenshots, files, code. '
      'Turn off for plain chat.';
  @override
  String get automationTitle => 'Browser automation';
  @override
  String get automationSubtitle =>
      'Let the agent control the embedded browser.';
  @override
  String get runInBackgroundTitle => 'Run in background';
  @override
  String get runInBackgroundSubtitle =>
      'Keep the agent working when you leave the app '
      '(shows a progress notification).';
  @override
  String get languageSection => 'Language';
  @override
  String get languageSubtitle => 'App interface language. Default: English.';
  @override
  String get englishOption => 'English (default)';
  @override
  String get indonesianOption => 'Bahasa Indonesia';
  @override
  String get dataSection => 'Data';
  @override
  String get exportSessions => 'Export sessions';
  @override
  String get importSessions => 'Import sessions';
  @override
  String exportDone(String path) => 'Exported to $path';
  @override
  String importDone(int count) => '$count session(s) imported.';
  @override
  String get importFailed => 'Import failed: not a valid export file.';

  // -- Session import/export icon tooltips (v1.34.0) ---------------------
  @override
  String get importSessionsIconTip => 'Import sessions (JSON)';
  @override
  String get exportSessionsIconTip => 'Export sessions (JSON)';

  // -- Markdown export, token stats & encrypted backup (v1.17.0) ---------
  @override
  String get exportChatMarkdown => 'Export chat (Markdown)';
  @override
  String get exportChatMarkdownEmpty =>
      'Nothing to export yet — this chat has no messages.';
  @override
  String exportChatMarkdownDone(String path) => 'Chat exported to $path';
  @override
  String get tokenStatsMenuItem => 'Token stats';
  @override
  String get tokenStatsTitle => 'Token stats';
  @override
  String get statsNoData =>
      'No token usage recorded yet. Providers report usage per request; '
      'stats appear here after your next conversation.';
  @override
  String get statsPromptTokens => 'Prompt tokens';
  @override
  String get statsCompletionTokens => 'Completion tokens';
  @override
  String get statsTotalTokens => 'Total tokens';
  @override
  String get statsTurns => 'Assistant turns';
  @override
  String get statsSessions => 'Sessions';
  @override
  String get statsPerModel => 'PER MODEL';
  @override
  String statsModelLine(
    String prompt,
    String completion,
    String total,
    int turns,
  ) => '$total tokens across $turns turns ($prompt in / $completion out)';
  @override
  String get statsUsageHint =>
      'Usage is counted only when the provider reports it per request. '
      'Older conversations (before v1.17.0) are not included.';
  @override
  String get backupSectionTitle => 'Backup & restore';
  @override
  String get backupCreate => 'Create encrypted backup';
  @override
  String get backupCreateHint =>
      'Saves every chat, all settings (including API keys) and the Context '
      'Manager into one AES-256 encrypted .zabak file under exports/.';
  @override
  String get backupPassphraseLabel => 'Passphrase (min. 8 characters)';
  @override
  String get backupRestore => 'Restore from backup';
  @override
  String get backupRestoreHint =>
      'Restoring REPLACES all current chats, settings and context entries '
      'with the backup contents.';
  @override
  String get backupConfirmTitle => 'Restore this backup?';
  @override
  String get backupConfirmBody =>
      'Your current chats, provider settings and context entries will be '
      'REPLACED by the backup contents. This cannot be undone.';
  @override
  String backupRestoreDone(int sessions, bool settings, int contexts) =>
      'Restored $sessions sessions, $contexts context entries'
      '${settings ? ' and settings' : ''}.';
  @override
  String get backupWrongPassphrase =>
      'Wrong passphrase or the file was tampered with.';
  @override
  String get backupFailed => 'Backup failed.';
  @override
  String get backupPassphraseShort =>
      'Use a passphrase of at least 8 characters.';

  // -- App lock & done notifications (v1.18.0) ---------------------------
  @override
  String get appLockSection => 'App lock';
  @override
  String get appLockTitle => 'Noah is locked';
  @override
  String get appLockEnableTitle => 'Lock the app';
  @override
  String get appLockEnableSubtitle =>
      'Ask for your fingerprint or PIN on app start and when returning '
      'from the background. Set a PIN as the fallback first.';
  @override
  String get appLockSetPinTitle => 'Set fallback PIN';
  @override
  String get appLockPinField => 'PIN (4-8 digits)';
  @override
  String get appLockPinTooShort => 'The PIN needs 4-8 digits.';
  @override
  String get appLockPinMismatch => 'The two PINs do not match.';
  @override
  String get appLockConfirmPin => 'Confirm PIN';
  @override
  String get appLockDisableConfirm =>
      'Turning the lock off removes the stored PIN. Continue?';
  @override
  String get appLockPinHint => 'PIN';
  @override
  String get appLockWrongPin => 'Wrong PIN';
  @override
  String get appLockUnlock => 'Unlock';
  @override
  String get appLockUseBiometric => 'Use biometrics';
  @override
  String get appLockBiometricReason => 'Unlock Noah';
  @override
  String get notifyOnDoneTitle => 'Notify when a task finishes';
  @override
  String get notifyOnDoneSubtitle =>
      'Shows a local notification when an agent run ends while you are '
      'away; tapping it reopens that conversation.';
  @override
  String get notifDoneTitle => 'Agent task finished';
  @override
  String notifDoneBody(String sessionTitle, String? error) => error == null
      ? '\u201C$sessionTitle\u201D is done — tap to open it.'
      : '\u201C$sessionTitle\u201D stopped with an error — tap to open it.';

  @override
  String get exitAppTitle => 'Exit Noah?';
  @override
  String get exitAppBody =>
      'Agent tasks keep running in the background while the app is closed.';
  @override
  String get exitAppConfirm => 'Exit';
  @override
  String get batteryTitle => 'Background reliability';
  @override
  String get batterySubtitle =>
      'Ask Android to exempt Noah from battery optimization so long '
      'agent runs are never paused in the background.';
  @override
  String get batteryRestricted => 'Optimized (may pause runs) — tap to exempt';
  @override
  String get batteryExempted => 'Exempted — background runs protected';

  @override
  String get aboutSection => 'About';
  @override
  String get aboutBody =>
      'Noah is an Android agent-chat app styled after the chat.z.ai '
      'agent mode: bring your own OpenAI-compatible provider (OpenRouter, '
      'InferHub, Z.AI, OpenAI, DeepSeek, Groq, and more), run many chats '
      'in parallel with real background execution, plan-first Todos with '
      'a live Plan panel, a real skills system (install external skills '
      'by CLI-style command or plain language, manage and run them '
      'across every chat), Web3 wallet workflows with explicit '
      'confirmation cards, per-chat isolated file sandboxes and browser '
      'sessions, git and web_fetch tools, a Node.js-style runtime with '
      'npm packages, Markdown export, encrypted whole-app backup, token '
      'statistics, and an optional biometric/PIN app lock. Your API keys '
      'and skill secrets stay on this device. See Help for the complete '
      'guide.';

  // -- Help & About screens (v1.41.5) ------------------------------------
  @override
  String get helpAboutSection => 'Help & About';
  @override
  String get helpTileTitle => 'Help & user guide';
  @override
  String get helpTileSubtitle =>
      'Complete how-to for every feature, in plain language';
  @override
  String get aboutTileTitle => 'About Noah';
  @override
  String get aboutTileSubtitle => 'Version, creator, and what this app can do';
  @override
  String get aboutTitle => 'About';
  @override
  String get aboutTagline =>
      'Your own AI agent team on Android — plan, browse, run, deliver.';
  @override
  String get aboutCreatorLabel => 'Creator';
  @override
  String get aboutVersionLabel => 'Version';
  @override
  String get aboutWhatsInside => 'What\'s inside';
  @override
  String get aboutDisclaimer =>
      'Noah is an independent app by Maragung, styled after the '
      'chat.z.ai agent mode UI, and is not affiliated with Z.AI. Skills '
      'and modules run locally on this device; the app never asks for '
      'seed phrases or private keys, and every wallet action that moves '
      'value needs your explicit confirmation first.';
  @override
  String get helpTitle => 'Help';
  @override
  String get helpIntro =>
      'Everything Noah can do, and how to use it. Sections follow the '
      'order you will meet them in the app.';
  @override
  List<HelpEntry> get helpTopics => const [
    HelpEntry(
      '1. Get started: connect a provider',
      'Open Settings → Providers, add your provider (OpenRouter, '
          'InferHub, Z.AI, OpenAI, DeepSeek, Groq, or any OpenAI-compatible '
          'endpoint), paste its API key and pick a model from the live '
          'catalog (search and filters included). Keys are stored only on '
          'this device. Without a working key the chat cannot answer, so '
          'start here.',
    ),
    HelpEntry(
      '2. Chats and background tasks',
      'Create as many chats as you like from the side drawer — they run '
          'in parallel. A task keeps running when you switch chats or leave '
          'the app; a notification tells you when it finishes. Every chat '
          'is fully isolated: its transcript, state, processes, output and '
          'files never leak into another chat, and Stop only affects the '
          'chat you pressed it in.',
    ),
    HelpEntry(
      '3. Plans (Todos) and the Plan panel',
      'Every task starts with a plan: the agent lists the steps, then '
          'works through them. Open the live Plan panel from the plan icon '
          '— it stays open until YOU close it, survives chat switches, and '
          'updates in real time when a step completes or fails. Plans are '
          'saved to disk continuously, so even an app crash or dead '
          'battery keeps your plan and progress.',
    ),
    HelpEntry(
      '4. Skills: install, configure, run',
      'Skills are reusable instruction + script packages the agent can '
          'discover, install and use. Install by asking in plain language '
          '(\u201cinstall the X skill\u201d) or paste a CLI-style command '
          'like \u201cnpx skills add owner/repo/path/to/skill\u201d — the '
          'agent checks dependencies, reads the skill\'s instructions and '
          'verifies the install honestly. Bundled Web3 wallet skills are '
          'ready to use. Manage them in chat: skill_list, skill_info, '
          'skill_config (API keys and settings, stored on-device and never '
          'echoed), skill_update, and skill_run. Installed skills persist '
          'across ALL chats — install once, use everywhere.',
    ),
    HelpEntry(
      '5. Web3 wallet workflows and safety',
      'Use the bundled wallet skills (Binance Agentic Wallet, Web3 '
          'basics) or install compatible ones to check balances, read '
          'transactions and interact with Web3 apps. Login always uses the '
          'provider\'s official page — the agent shows you the link, you '
          'connect yourself. The app NEVER asks for seed phrases or '
          'private keys. Before anything irreversible (transfer, swap, '
          'NFT listing, token approval) the agent must show a confirmation '
          'card with network, asset, amount, destination and fee — nothing '
          'moves until you approve. Logging in is never permission to '
          'trade.',
    ),
    HelpEntry(
      '6. Browser automation and User-Agent',
      'The agent can browse, fill forms and fetch pages with a real '
          'embedded browser. Each chat gets its own isolated browser '
          'context — cookies and logins from one chat never leak into '
          'another. In Settings → User Agent you choose the browser '
          'identity: Auto uses the truthful Android identity; Desktop/Android '
          'pools rotate through current-generation fingerprints — Chromium '
          'browsers (Chrome, Edge, Opera, Samsung Internet, Vivaldi) all on '
          'Chromium 153+, Firefox on the newest trains (150+ and live ESR), '
          'Safari 26/27. Rotate manually or let new chats pick a random '
          'identity.',
    ),
    HelpEntry(
      '7. Modules (plugins)',
      'Modules are zip-packaged JavaScript add-ons with the official '
          'zagents SDK — upload one from the Modules screen and it runs in '
          'each chat\'s own sandbox with per-chat setup forms, storage, '
          'state and permissions. The agent sees each module\'s setup '
          'state (secrets masked) — strictly per chat: a form in one chat '
          'never shows values typed in another chat. The Node screen '
          'manages the embedded '
          'runtime and its npm packages; Device commands stay off unless '
          'you explicitly enable them (rooted phones only).',
    ),
    HelpEntry(
      '8. Files and per-chat sandbox',
      'Every chat has a private workspace folder — uploads, generated '
          'files and module state live there, invisible to other chats. '
          'Export a workspace to your device file manager '
          '(Downloads/Noah/<chat>) with one tap, and deleting a chat '
          'removes its whole workspace. File uploads support zip '
          'extraction, including password-protected archives.',
    ),
    HelpEntry(
      '9. Search, export and backup',
      'Global search (magnifier icon) finds titles and full message '
          'text across every chat. Export any chat as Markdown from the '
          'drawer. Settings → Data makes an encrypted whole-app backup '
          '(chats, settings, skills config) you can restore after a '
          'reinstall or move to a new phone.',
    ),
    HelpEntry(
      '10. Stats, app lock and notifications',
      'Stats shows token usage per model and per chat. The optional '
          'app lock (biometric or PIN) protects the app on launch. '
          'Background tasks post a completion notification; long runs can '
          'be exempted from battery optimization so Android never pauses '
          'them.',
    ),
    HelpEntry(
      '11. Per-chat notifications and Stop / Force stop',
      'Every RUNNING chat posts its own notification — the chat title '
          'plus the step it is on (which tool is executing right now). '
          'Tap it to jump straight into that chat, even after hours in '
          'the background: the foreground service and wake lock keep '
          'Android from pausing the work, and Android 13+ asks once for '
          'the notification permission — allowing it is what makes these '
          'visible. Need to end a run? The red Stop button stops the '
          'process with ONE tap. If it will not die, tap Stop again (a '
          'hint appears) and the third tap offers Force stop — it '
          'immediately tears down the connection and ends the run; '
          'partial progress stays saved in the transcript.',
    ),
    HelpEntry(
      '12. Tips and troubleshooting',
      'Provider error? Re-check the API key and the model\'s quota in '
          'the provider dashboard. A module misbehaving? Use its repair '
          'card or re-upload the zip. Unstable network? Auto-retry with '
          'the airplane-mode guard resumes safely. Streaming text looks '
          'stuck? Wait or press Stop — the transcript is saved after '
          'every step. Found a bug or want a feature? Open an issue on '
          'the project repository.',
    ),
  ];

  @override
  String createdBy(String name) => 'Created by $name';

  // -- Message actions (v1.15.0) ----------------------------------------
  @override
  String get editMessageAction => 'Edit message';
  @override
  String get editDialogTitle => 'Edit message';
  @override
  String get regenerate => 'Regenerate';

  // -- Global chat search (v1.15.0) -------------------------------------
  @override
  String get searchChats => 'Search chats';
  @override
  String get searchHint => 'Search all conversations…';
  @override
  String get noSearchResults => 'No conversations found.';
  @override
  String get searchInitialHint =>
      'Type to search your conversation titles and messages.';

  // -- Automatic conversation titles (v1.15.0) --------------------------
  @override
  String get autoTitleTitle => 'Automatic titles';
  @override
  String get autoTitleSubtitle =>
      'Name new conversations automatically with a short model-generated '
      'title after the first answer.';

  // -- Prompt library (v1.15.0) -----------------------------------------
  @override
  String get promptLibrary => 'Prompt library';
  @override
  String get promptLibraryEmpty => 'No prompts yet.';
  @override
  String get newPrompt => 'New prompt';
  @override
  String get editPrompt => 'Edit prompt';
  @override
  String get promptTitleLabel => 'Title';
  @override
  String get promptContentLabel => 'Prompt content';
  @override
  String get insertPrompt => 'Insert from prompt library';
  @override
  String get deletePromptTitle => 'Delete prompt?';
  @override
  String get deletePromptBody => 'This prompt will be permanently removed.';
  @override
  String get promptSaved => 'Prompt saved.';
  @override
  String get promptDeleted => 'Prompt deleted.';

  // -- Chat modules / plugins (v1.21.0) ---------------------------------
  @override
  String get modulesTitle => 'Modules';
  @override
  String get modulesInstall => 'Install module (ZIP)';
  @override
  String get modulesEmpty => 'No modules installed yet.';
  @override
  String get modulesEmptyHint =>
      'Install a module ZIP to run native JavaScript capabilities inside '
      'any chat — isolated per chat like a private window.';
  @override
  String get modulesManage => 'Manage modules';
  @override
  String get moduleSdkDocs => 'SDK documentation';
  @override
  String get moduleStartNewChat => 'Start in new chat';
  @override
  String get moduleActivate => 'Activate in this chat';
  @override
  String get moduleDeactivate => 'Deactivate';
  @override
  String get moduleActiveBadge => 'active';
  @override
  String moduleDeactivated(String name) =>
      'Module \u201c$name\u201d deactivated — its execution was stopped safely and '
      'its per-chat data stays inside this chat.';
  @override
  String get moduleTerminated => 'Module execution was terminated by the user.';
  @override
  String moduleRunFailed(String error) => 'Module run failed: $error';
  @override
  String moduleNotFound(String name) => 'Module not installed: $name';
  @override
  String get moduleSessionBusy =>
      'Wait for the current task to finish before activating a module.';
  @override
  String modulePermissionTitle(String name) => 'Allow \u201c$name\u201d to:';
  @override
  String get modulePermissionBody =>
      'These capabilities run isolated inside THIS chat only — nothing '
      'leaks into other chats.';
  @override
  String get moduleAllow => 'Allow and run';
  @override
  String moduleInstallSuccess(String name) => '$name installed.';
  @override
  String moduleInstallFailed(String error) => 'Install failed: $error';
  @override
  String get moduleRemoveTitle => 'Remove module?';
  @override
  String moduleRemoveBody(String name) =>
      '\u201c$name\u201d and its program files will be removed. Data already stored '
      'inside individual chats stays in each chat sandbox.';
  @override
  String moduleRemoved(String name) => 'Module removed: $name';
  @override
  String get pluginMenuTitle => 'Modules for this chat';
  @override
  String get pluginMenuEmpty =>
      'No modules installed yet. Install one from the Modules screen.';
  @override
  String get startWithModule => 'Start with a module';

  // -- Module per-chat setup form (v1.24.0) ------------------------------
  @override
  String moduleSetupNeededTitle(String name) =>
      '$name needs setup before it can run in this chat.';
  @override
  String get moduleSetupNeededBody =>
      'Fill in the required information in the form — once submitted, the '
      'module is allowed and runs automatically.';
  @override
  String moduleSetupLegacyHint(String name) =>
      '\u201c$name\u201d was installed from an older ZIP that has no setup '
      'form (installed modules keep their version across app updates). '
      'Solutions: 1) install the latest \u201c$name\u201d module ZIP — its new '
      'version ships a setup form the app shows before the first run; '
      '2) or send the module\u2019s own setup command as the first message '
      'of a new chat (for example \u201csetup your-email your-password\u201d), '
      'then activate the module again.';
  @override
  String get moduleSetupBannerCta => 'Set up';
  @override
  String get moduleSetupSaveRun => 'Save and run';
  @override
  String get moduleSetupPerChatHint =>
      'Stored for THIS chat only — other chats ask again.';
  @override
  String get moduleSetupRequiredTag => 'required';
  @override
  String get moduleSetupWaitingHint =>
      'Your message is queued — the agent processes it right after this '
      'setup is submitted.';

  // -- Module device commands (v1.31.0) -----------------------------------
  @override
  String get deviceCommandsTitle => 'Device commands (root)';
  @override
  String get deviceCommandsSubtitle =>
      'Let approved modules run shell commands on this device via '
      'zagents.device.shell — airplane mode toggles and similar '
      'automation. Needs a rooted phone; every activation still asks for '
      'your consent.';

  // -- Auto retry & red stop button (v1.30.0) ------------------------------
  @override
  String get autoRetrySection => 'Auto retry';
  @override
  String get autoRetryTitle => 'Retry automatically on failures';
  @override
  String get autoRetrySubtitle =>
      'Network errors, weak connection, dropped streams or transient '
      'provider errors no longer kill the task: the agent waits and tries '
      'again, and unfinished work is resumed.';
  @override
  String get autoRetryAttemptsTitle => 'Max retry attempts';
  @override
  String get autoRetryDelayTitle => 'Wait between retries (seconds)';
  @override
  String get autoRetryHint =>
      'The wait grows with each attempt (delay x attempt). When a task '
      'stops with an unfinished plan, it is also picked back up '
      'automatically. Stop always wins — nothing retries after you press '
      'it.';
  @override
  String autoRetryStreamNote(int attempt, int max) =>
      '*Auto retry $attempt/$max — reconnecting to the provider…*';
  @override
  String autoRetryResumeNote(int attempt, int max) =>
      '*Auto retry $attempt/$max — the run was interrupted (network '
      'error). Resuming the task…*';
  @override
  String autoRetryPlanNote(int attempt, int max) =>
      '*Auto resume $attempt/$max — the plan is not finished yet. '
      'Continuing the task…*';
  @override
  String get autoRetryAirplaneNote =>
      '*Airplane mode is ON — holding retries until it is turned off. '
      'No attempt is consumed; the task continues automatically as soon '
      'as the connection returns.*';
  @override
  String get autoRetryAirplaneResumeNote =>
      '*Airplane mode is ON — the task auto-resumes as soon as it is '
      'turned off (no retry budget is used while offline).*';

  // -- Module doctor (v1.26.0) --------------------------------------------
  @override
  String moduleRepairCardTitle(String name, String version) =>
      'Module repair ready: $name v$version';
  @override
  String moduleRepairCardBody(String permissions) =>
      'The agent prepared a repaired module and it passed validation. '
      'Installing replaces the installed copy — its per-chat data in THIS '
      'chat is kept. Review the permissions before installing: '
      '$permissions';
  @override
  String get moduleRepairInstall => 'Install';
  @override
  String get moduleRepairDiscard => 'Discard';
  @override
  String moduleRepairInstalled(String name) =>
      'Module “$name” installed from the agent’s repair. If it needs '
      'setup in this chat, the form appears before the next run.';
  @override
  String moduleRepairInstallFailed(String error) =>
      'The repaired module could not be installed: $error';
  @override
  String get moduleExportTooltip => 'Export ZIP';

  // -- Module export dialog (v1.47.0) --------------------------------------
  @override
  String get moduleExportTitle => 'Export module';
  @override
  String get moduleExportHint =>
      'Saved as a fresh, installable ZIP — no accounts, sessions or chat '
      'data are included. File name:';
  @override
  String get moduleExportAction => 'Export';

  // -- Module update & remote install (v1.46.0) ---------------------------
  @override
  String get moduleInstallFromUrl => 'Install from URL';
  @override
  String get moduleUrlDialogTitle => 'Install module from URL';
  @override
  String get moduleUrlDialogHint => 'https://example.com/module.zip';
  @override
  String get moduleUrlDialogBody =>
      'The module ZIP is downloaded over HTTPS and unpacked with the same '
      'validation as a local file. Only install modules from sources you '
      'trust.';
  @override
  String get moduleDownload => 'Download & install';
  @override
  String get moduleUpdateTooltip => 'Update module';
  @override
  String get moduleUpdateTitle => 'Update module';
  @override
  String moduleUpdateBody(String name) =>
      'Choose the update source for \u201c$name\u201d. Installing replaces '
      'the module files; per-chat module data is kept.';
  @override
  String get moduleUpdateFromZip => 'From ZIP file';
  @override
  String get moduleUpdateFromUrl => 'From URL';
  @override
  String get moduleDownloading => 'Downloading\u2026';
  @override
  String get moduleSampleInstall => 'Install';
  @override
  String get moduleSampleUpdate => 'Update';
  @override
  String get moduleSampleInstalled => 'Installed';
  @override
  String get moduleSampleRepoHint =>
      'One tap installs or updates a module straight from the official '
      'samples repository.';

  // -- Module builder (/make_plugins) -------------------------------------
  @override
  String moduleBuildCardTitle(String name, String version) =>
      'New plugin ready: $name v$version';
  @override
  String moduleBuildCardBody(String permissions) =>
      'The agent built this plugin in this chat and it passed validation. '
      'Review the permissions before installing: $permissions. After '
      'installing, start it with /plugins (menu) or /plugins <name>.';
  @override
  String moduleBuildInstalled(String name) =>
      'Plugin “$name” installed. Start it with /plugins (menu) or '
      '/plugins <name> — this chat or any new chat; every chat gets its '
      'own isolated storage and setup form.';
  @override
  String get missingApiKey =>
      'API key is not set. Open Settings to configure your provider.';
  @override
  String get modelNotSet =>
      'No model selected. Pick one in Settings or from the model menu.';
  @override
  String get stoppedMarkdown => '_(stopped)_';
  @override
  String get chatOpenError => 'Could not open this conversation.';
  @override
  String get chatDeleteError => 'Could not delete this conversation.';
  @override
  String get chatRenameError => 'Could not rename this conversation.';

  // -- Background service notification ----------------------------------
  @override
  String get notifTitle => 'Noah agent is running';
  @override
  String get notifProcessing => 'Processing your request…';
  @override
  String notifStep(int step, String tool) => 'Step $step · $tool';

  // -- Stop / force stop (v1.42.0) ---------------------------------------
  @override
  String get stopHintForce =>
      'Stop requested — tap Stop once more to offer a force stop.';
  @override
  String get forceStopTitle => 'Force stop this process?';
  @override
  String get forceStopBody =>
      'The process is still running after repeated Stop taps. A force stop '
      'immediately tears down the connection and ends this run — partial '
      'progress is kept in the transcript.';
  @override
  String get forceStopConfirm => 'Force stop';
  @override
  String get forceStopCancel => 'Cancel';
  @override
  String get forceStopDone => 'Force stop executed.';

  @override
  String get ollamaSectionTitle => 'Local AI';
  @override
  String get ollamaTileTitle => 'Ollama Manage';
  @override
  String get ollamaTileSubtitle => 'Local AI runtime compatible with Ollama';
  @override
  String get ollamaScreenTitle => 'Ollama Manage';
  @override
  String get ollamaTabServer => 'Server';
  @override
  String get ollamaExternalServerLabel => 'External Ollama server';
  @override
  String get ollamaProbe => 'Probe';
  @override
  String ollamaProbeOk(String version) => 'Ollama $version is reachable.';
  @override
  String ollamaProbeFail(String error) => 'No Ollama server found: $error';
  @override
  String get ollamaUseAsProvider => 'Use as provider';
  @override
  String get ollamaOnDeviceTitle => 'On-device runtime';
  @override
  String get ollamaOnDevicePending =>
      'The bundled on-device LLM runtime is not available in this build '
      'yet. You can still point Noah at an external Ollama server '
      'below.';

  @override
  String get cronOpenOllamaManage => 'Open Ollama Manage';
  @override
  String get ollamaActiveModelLabel => 'Active model';
  @override
  String ollamaAddedAt(String date) => 'Added $date';
  @override
  String ollamaBattery(int percent) => 'Battery $percent%';
  @override
  String ollamaBatteryCharging(int percent) => 'Battery $percent% · charging';
  @override
  String ollamaBatteryLow(int percent) => 'Battery $percent% — low';
  @override
  String get ollamaBenchmark => 'Benchmark';
  @override
  String ollamaBenchmarkFailed(String error) => 'Benchmark failed: $error';
  @override
  String get ollamaBenchmarkRunning => 'Benchmarking…';
  @override
  String ollamaBenchmarkSummary(
    String tokPerSec,
    int firstTokenMs,
    int tokens,
  ) => '$tokPerSec tok/s · first token ${firstTokenMs}ms · $tokens tokens';
  @override
  String get ollamaCatalogRefresh => 'Refresh catalog';
  @override
  String ollamaCatalogRefreshDone(int count) =>
      'Catalog updated: $count models.';
  @override
  String ollamaCatalogRefreshFailed(String error) =>
      'Catalog refresh failed: $error';
  @override
  String get ollamaCatalogReset => 'Reset';
  @override
  String get ollamaCatalogResetDone => 'Back to the built-in catalog.';
  @override
  String get ollamaClearFinished => 'Clear finished';
  @override
  String get ollamaClose => 'Close';
  @override
  String get ollamaConfigInvalid =>
      'Port must be 1024–65535, context 512–32768, threads 0–8.';
  @override
  String get ollamaConfigSave => 'Save configuration';
  @override
  String get ollamaConfigSaved => 'Server configuration saved.';
  @override
  String get ollamaContextLabel => 'Context size';
  @override
  String get ollamaCopyAll => 'Copy all';
  @override
  String ollamaCtxTokens(String tokens) => '$tokens ctx';
  @override
  String get ollamaCustomUrlInvalid =>
      'Enter an http(s) URL that ends with .gguf';
  @override
  String get ollamaCustomUrlLabel => 'Custom URL (.gguf)';
  @override
  String ollamaDeleteBody(String name) =>
      '“$name” and its file will be removed from this device.';
  @override
  String get ollamaDeleteTitle => 'Delete this model?';
  @override
  String ollamaDeviceRam(String size) => 'Device RAM $size';
  @override
  String get ollamaDlCanceled => 'Canceled';
  @override
  String get ollamaDlCompleted => 'Completed';
  @override
  String get ollamaDlFailed => 'Failed';
  @override
  String get ollamaDlPaused => 'Paused';
  @override
  String get ollamaDlQueued => 'Queued';
  @override
  String get ollamaDlRunning => 'Downloading';
  @override
  String get ollamaDownload => 'Download';
  @override
  String ollamaDownloadStarted(String name) =>
      '“$name” added to the download queue.';
  @override
  String get ollamaDownloadingLabel => 'Downloading…';
  @override
  String get ollamaDownloadsEmpty => 'No downloads yet.';
  @override
  String get ollamaExport => 'Export';
  @override
  String get ollamaExportDone => 'Model exported.';
  @override
  String get ollamaExportNone => 'No models exported.';
  @override
  String get ollamaExportSelected => 'Export selected';
  @override
  String ollamaExportSelectedDone(int count) => 'Exported $count models.';
  @override
  String get ollamaFitFilter => 'Only models that fit';
  @override
  String get ollamaGoToCatalog => 'Go to Catalog';
  @override
  String get ollamaImportButton => 'Import .gguf file';
  @override
  String ollamaImportDone(String name) => '“$name” imported.';
  @override
  String get ollamaImportFailed => 'Import failed.';
  @override
  String get ollamaInstalledEmptyBody =>
      'Download a model from the Catalog or import a .gguf file.';
  @override
  String get ollamaInstalledEmptyTitle => 'No models installed';
  @override
  String get ollamaInstalledLabel => 'Installed';
  @override
  String get ollamaLogTitle => 'Server log';
  @override
  String get ollamaModelEmptyHint =>
      'No models installed yet — download one from the Catalog.';
  @override
  String get ollamaModelLabel => 'Model';
  @override
  String get ollamaOomWarning =>
      'Heavy model: high risk of running out of memory on this device.';
  @override
  String get ollamaPause => 'Pause';
  @override
  String get ollamaPortLabel => 'Port';
  @override
  String ollamaRamEst(String size) => '~$size RAM';
  @override
  String get ollamaResume => 'Resume';
  @override
  String ollamaRiskBody(String ref) =>
      '“$ref” may exceed this device’s memory and fail to load. Download it '
      'anyway?';
  @override
  String get ollamaRiskTitle => 'Download this heavy model?';
  @override
  String get ollamaRuntimeUnavailable =>
      'This build or device has no local AI runtime (armeabi-v7a is not '
      'supported). You can still connect to an external Ollama server below.';
  @override
  String get ollamaSelectMode => 'Select models';
  @override
  String ollamaSelectedCount(int count) => '$count selected';
  @override
  String ollamaSizeProgress(int receivedMb, int totalMb) =>
      '$receivedMb of $totalMb MB';
  @override
  String get ollamaSizeUnknown => 'unknown size';
  @override
  String get ollamaSourceCatalog => 'Catalog';
  @override
  String get ollamaSourceCustomUrl => 'Custom URL';
  @override
  String get ollamaSourceImported => 'Imported';
  @override
  String get ollamaStart => 'Start';
  @override
  String get ollamaStartFailedSnack => 'The server could not start.';
  @override
  String get ollamaStartWith => 'Start with this model';
  @override
  String get ollamaStartedSnack => 'Server started.';
  @override
  String get ollamaStatusFailed => 'Failed';
  @override
  String get ollamaStatusRunning => 'Running';
  @override
  String get ollamaStatusStarting => 'Starting…';
  @override
  String get ollamaStatusStopped => 'Stopped';
  @override
  String get ollamaStatusStopping => 'Stopping…';
  @override
  String get ollamaStatusUnavailable => 'Unavailable';
  @override
  String get ollamaStop => 'Stop';
  @override
  String get ollamaStoppedSnack => 'Server stopped.';
  @override
  String get ollamaTabCatalog => 'Catalog';
  @override
  String get ollamaTabDownloads => 'Downloads';
  @override
  String get ollamaTabInstalled => 'Installed';
  @override
  String get ollamaThreadsLabel => 'Threads (0 = auto)';
  @override
  String get ollamaTierHeavy => 'Heavy';
  @override
  String get ollamaTierLight => 'Light';
  @override
  String get ollamaTierMedium => 'Medium';
  @override
  String get ollamaTooLarge => 'Too large for this device';
  @override
  String get ollamaUseInChat => 'Use in chat';
  @override
  String ollamaUseInChatBody(String alias) =>
      'Your active provider switches to Local AI with the model “$alias”.';
  @override
  String get ollamaUseInChatDone => 'Local AI is now active for chat.';
  @override
  String get ollamaUseInChatTitle => 'Use this model in chat?';
  @override
  String get ollamaViewFullLog => 'View full log';
}

/// Bahasa Indonesia strings.
class AppStringsId implements AppStrings {
  @override
  String get cronSectionTitle => 'Cron jobs';
  @override
  String get cronTileTitle => 'Cron jobs';
  @override
  String get cronTileSubtitle =>
      'Jadwalkan pesan Telegram, notifikasi, atau tugas agent';
  @override
  String get cronJobsTitle => 'Cron jobs';
  @override
  String get cronMasterTitle => 'Scheduler aktif';
  @override
  String get cronMasterSubtitle =>
      'Saklar utama — menjeda semua job tanpa menghapusnya';
  @override
  String get cronJobsEmptyTitle => 'Belum ada job';
  @override
  String get cronJobsEmptyBody =>
      'Ketuk + untuk menjadwalkan pesan Telegram, notifikasi, atau tugas '
      'agent.';
  @override
  String get cronAddJobTooltip => 'Tambah job';
  @override
  String get cronNewTitle => 'Job baru';
  @override
  String get cronEditTitle => 'Edit job';
  @override
  String get cronFieldName => 'Nama job';
  @override
  String get cronFieldSchedule => 'Jadwal';
  @override
  String get cronScheduleEveryMinute => 'Setiap menit';
  @override
  String get cronScheduleEvery5Minutes => 'Setiap 5 menit';
  @override
  String get cronScheduleHourly => 'Setiap jam (menit 0)';
  @override
  String get cronScheduleDaily8 => 'Harian pukul 08:00';
  @override
  String get cronScheduleWeekdays9 => 'Hari kerja pukul 09:00';
  @override
  String get cronScheduleWeekly => 'Minggu pukul 09:00';
  @override
  String get cronScheduleMonthly => 'Tanggal 1 pukul 08:00';
  @override
  String get cronScheduleCustom => 'Kustom (ekspresi cron)';
  @override
  String get cronFieldExpression => 'Ekspresi cron';
  @override
  String get cronExpressionHint =>
      'menit jam tanggal bulan hari — contoh: 30 8 * * mon-fri';
  @override
  String get cronNextRuns => 'Jadwal berikutnya';
  @override
  String get cronFieldAction => 'Aksi';
  @override
  String get cronActionNotification => 'Notifikasi';
  @override
  String get cronActionTelegram => 'Telegram';
  @override
  String get cronActionAgent => 'Tugas agent';
  @override
  String get cronActionAgentHint =>
      'Menjalankan prompt sebagai agent tanpa UI (workspace, browser, web, '
      'dan tool node) lalu memberi tahu hasilnya.';
  @override
  String get cronActionChat => 'Jalankan di chat';
  @override
  String get cronActionChatHint =>
      'Mengirim perintah ke chat terpilih seperti pesan yang diketik; '
      'agent menjawab langsung di percakapan itu (histori, modul, dan '
      'skill-nya tetap berlaku).';
  @override
  String get cronFieldChatTarget => 'Chat tujuan';
  @override
  String get cronChatNewEveryRun => 'Chat baru (tiap eksekusi)';
  @override
  String get cronChatOwnerDefault => 'Chat ini (bawaan)';
  @override
  String get cronFieldChatPrompt => 'Perintah yang dijalankan';
  @override
  String get cronChatPromptRequired => 'Teks perintah wajib diisi.';
  @override
  String get cronChatTargetMissing =>
      'Chat terpilih tidak ditemukan (terhapus?)';
  @override
  String get cronFieldNotifTitle => 'Judul notifikasi';
  @override
  String get cronFieldNotifText => 'Isi notifikasi';
  @override
  String get cronFieldTelegramToken => 'Token bot';
  @override
  String get cronFieldTelegramChat => 'Chat ID';
  @override
  String get cronFieldMessage => 'Isi pesan';
  @override
  String get cronFieldAgentPrompt => 'Prompt agent';
  @override
  String get cronAgentRelayHint =>
      'Isi token bot + chat ID untuk meneruskan jawaban ke Telegram juga '
      '(opsional).';
  @override
  String get cronRunsWhileAppOpen =>
      'Job berjalan selama aplikasi aktif (foreground atau background '
      'hold). Eksekusi yang terlewat saat aplikasi tertutup dilewati, '
      'bukan diputar ulang.';
  @override
  String get cronNever => 'tidak pernah';
  @override
  String get cronNextRunLabel => 'Berikutnya';
  @override
  String get cronLastRunLabel => 'Terakhir';
  @override
  String get cronDeleteTitle => 'Hapus job?';
  @override
  String cronDeleteBody(String name) =>
      'Job "$name" beserta riwayat eksekusinya akan dihapus.';
  @override
  String get cronRunNowTooltip => 'Jalankan sekarang';
  @override
  String get cronNameRequired => 'Nama wajib diisi.';
  @override
  String get cronExpressionInvalid => 'Ekspresi cron tidak valid.';
  @override
  String get cronTelegramFieldsRequired => 'Token bot dan chat ID wajib diisi.';
  @override
  String get cronMessageRequired => 'Isi pesan wajib diisi.';
  @override
  String get cronNotifTextRequired => 'Isi notifikasi wajib diisi.';
  @override
  String get cronAgentPromptRequired => 'Prompt agent wajib diisi.';
  @override
  String get cronSaved => 'Job tersimpan.';
  @override
  String get cronHistoryTitle => 'Eksekusi terakhir';
  @override
  String get cronHistoryEmpty => 'Belum ada riwayat eksekusi.';
  @override
  String get cronDisabledBadge => 'nonaktif';
  @override
  String get cronPausedBadge => 'scheduler dijeda';
  @override
  String cronLocalAiHint(String model) =>
      'Berjalan di model lokal “$model” — nyalakan dulu server Local AI.';
  @override
  String get cronLocalAiNoModel =>
      'Berjalan di model lokal — nyalakan dulu server Local AI.';

  const AppStringsId();

  // -- Generic ---------------------------------------------------------
  @override
  String get menu => 'Menu';
  @override
  String get settings => 'Pengaturan';
  @override
  String get cancel => 'Batal';
  @override
  String get delete => 'Hapus';
  @override
  String get send => 'Kirim';
  @override
  String get stop => 'Hentikan';
  @override
  String get result => 'hasil';
  @override
  String get resultError => 'hasil (error)';
  @override
  String get screenshotUnavailable => 'screenshot tidak tersedia';
  @override
  String get thinking => 'berpikir…';
  @override
  String get readPageText => 'Baca teks halaman';
  @override
  String get open => 'Buka';
  @override
  String get share => 'Bagikan';
  @override
  String get rename => 'Ganti nama';
  @override
  String get copy => 'Salin';
  @override
  String get cut => 'Potong';
  @override
  String get paste => 'Tempel';
  @override
  String get save => 'Simpan';
  @override
  String get edit => 'Ubah';
  @override
  String get add => 'Tambah';
  @override
  String get confirm => 'OK';
  @override
  String get operationFailed => 'Operasi gagal.';

  // -- Home / chat -----------------------------------------------------
  @override
  String get askAnything => 'Tanya apa saja…';
  @override
  String get attachFile => 'Lampirkan file';

  @override
  String get speechListen => 'Dikte suara';

  @override
  String get speechStop => 'Hentikan dikte';

  @override
  String get speechListening => 'Mendengarkan…';

  @override
  String get speechUnavailable =>
      'Pengenalan suara tidak tersedia di perangkat ini.';

  @override
  String get speechPermissionDenied => 'Izin mikrofon ditolak.';

  @override
  String get imageTooLarge => 'Gambar lebih besar dari 20 MB.';

  @override
  String get imageNotAnImage => 'File tersebut bukan gambar yang didukung.';

  @override
  String get updateBannerTitle => 'Pembaruan tersedia';

  @override
  String get updateBannerBody =>
      'Versi Noah yang lebih baru sudah tersedia.';

  @override
  String get updateOpenRelease => 'Lihat rilis';

  @override
  String get updateDismiss => 'Tutup';

  @override
  String get checkUpdatesOnStart => 'Periksa pembaruan saat mulai';

  @override
  String get checkUpdatesNow => 'Periksa pembaruan sekarang';

  @override
  String get updateChecking => 'Memeriksa…';

  @override
  String get updateUpToDate => 'Anda sudah memakai versi terbaru.';

  @override
  String get updateCheckFailed => 'Gagal memeriksa pembaruan.';

  @override
  String get ipSwitchWarnTitle => 'Peringatkan saat IP sama';

  @override
  String get ipSwitchWarnSubtitle =>
      'Sebelum berpindah chat, bandingkan IP publik saat ini dengan IP '
      'terakhir yang dipakai di chat tujuan, lalu minta konfirmasi sebelum '
      'lanjut.';

  @override
  String get ipSwitchWarnDialogTitle => 'IP sama dengan sesi terakhir';

  @override
  String ipSwitchWarnDialogBody(String ip) =>
      'IP publik saat ini ($ip) sama dengan IP terakhir yang tercatat untuk '
      'chat ini. Tetap lanjutkan?';

  @override
  String get ipSwitchWarnContinue => 'Lanjutkan';

  @override
  String get officialModulesTitle => 'Modul contoh resmi';

  @override
  String get officialModulesSubtitle =>
      'Install dari zip di folder samples (samples/<nama>.zip di repo), lalu kelola di sini.';

  @override
  String get moduleUpdatedTo => 'Modul diperbarui ke versi';

  @override
  String get loading => 'Memuat';

  @override
  String get refresh => 'Muat ulang';

  @override
  String get parentFolder => 'Folder induk';

  @override
  String get todoCompleted => 'Selesai';

  @override
  String get todoInProgress => 'Sedang berjalan';

  @override
  String get todoPending => 'Menunggu';

  @override
  String get todoBlocked => 'Terblokir';

  @override
  String get todoDependsOn => 'Bergantung pada';

  @override
  String get skillsTitle => 'Skills';

  @override
  String get skillsSubtitle => 'Pasang sekali, pakai di semua chat';

  @override
  String get skillsManage => 'Kelola skills';

  @override
  String get skillsInstallUrl => 'Pasang dari URL';

  @override
  String get skillsUrlTitle => 'Pasang dari URL';

  @override
  String get skillsUrlLabel => 'URL Git atau sumber skill';

  @override
  String get skillsInstallZip => 'Pasang dari ZIP';

  @override
  String get skillsSearchHint => 'Cari skill';

  @override
  String get skillsEmptyTitle => 'Belum ada skill';

  @override
  String get skillsEmptyBody =>
      'Pasang skill dari URL, ZIP atau paket bawaan untuk memperluas '
      'kemampuan agent.';

  @override
  String get skillBundledInstall => 'Pasang';

  @override
  String get skillEnabled => 'Aktif';

  @override
  String get skillDisabled => 'Nonaktif';

  @override
  String get skillConfigure => 'Konfigurasi';

  @override
  String get skillConfigSave => 'Simpan konfigurasi';

  @override
  String get skillConfigRequired => 'Wajib';

  @override
  String get skillConfigSecret => 'Disimpan terenkripsi di perangkat ini';

  @override
  String get skillInspect => 'Inspeksi';

  @override
  String get skillInstructions => 'Instruksi';

  @override
  String get skillUpdate => 'Perbarui';

  @override
  String get skillRemove => 'Hapus';

  @override
  String get skillRemoveTitle => 'Hapus skill?';

  @override
  String get skillRemoveBody =>
      'Konfigurasi tersimpan dipertahankan agar rollback tetap aman.';

  @override
  String get skillStatusChecking => 'Memeriksa…';

  @override
  String get skillFiles => 'File';

  @override
  String get skillSheetTitle => 'Lampirkan skill';

  @override
  String get skillSheetHint => 'Skill terpilih hanya berlaku di chat ini.';

  @override
  String get skillSheetUseGlobal => 'Pakai bawaan global';

  @override
  String get skillSheetClear => 'Kosongkan pilihan';

  @override
  String get skillSheetApply => 'Terapkan';

  @override
  String get composerSkillsTooltip => 'Skill untuk chat ini';

  @override
  String get drawerSkills => 'Skills';

  @override
  String get settingsSkillsManager => 'Pengelola skill';

  @override
  String get agentRouterHint =>
      'Gateway agentrouter.org: setiap request membawa identitas claude-cli '
      'yang diwajibkan gateway. Model Claude memakai Anthropic Messages; '
      'GPT dan model lain memakai OpenAI-compatible. Jika gateway '
      'menantang bot (WAF), pindah ke data seluler lalu coba lagi.';

  @override
  String get settingsEngineLabel => 'Mesin';

  @override
  String get engineAuto => 'Otomatis — deteksi per model';

  @override
  String get engineAnthropic => 'Anthropic Messages';

  @override
  String get engineOpenai => 'OpenAI Chat Completions';

  @override
  String get engineOpenaiResponses => 'OpenAI Responses';

  @override
  String get engineHint =>
      'Protokol yang dipakai untuk menghubungi provider ini. Otomatis '
      'memilih per model (model Claude → Anthropic Messages, lainnya → '
      'OpenAI Chat Completions) dan mencoba ulang lewat OpenAI Responses '
      'API saat model menuntutnya. Kunci mesin bila provider hanya '
      'melayani satu protokol.';

  @override
  String get newChat => 'Percakapan baru';
  @override
  String get historyTitle => 'Riwayat';
  @override
  String get historyLoadFailed => 'Gagal memuat riwayat.';
  @override
  String get noChats => 'Belum ada percakapan.';
  @override
  String get deleteChatTitle => 'Hapus percakapan?';
  @override
  String get deleteChatBody => 'Percakapan ini akan dihapus permanen.';
  @override
  String get renameChatTitle => 'Ganti nama percakapan';
  @override
  String get nameHint => 'Nama';
  @override
  String get pickModel => 'Pilih model';
  @override
  String get customModelHint => 'Model kustom (mis. openai/gpt-4o-mini)';
  @override
  String get searchModelsHint => 'Cari model…';
  @override
  String get filterAll => 'Semua';
  @override
  String get filterTools => 'Tools';
  @override
  String get filterFree => 'Gratis';
  @override
  String get refreshCatalog => 'Segarkan katalog';
  @override
  String get modelsRetry => 'Coba lagi';
  @override
  String get modelsLoadError => 'Gagal memuat daftar model.';
  @override
  String get modelsEmpty => 'Tidak ada model yang cocok';
  @override
  String get modelsEmptyHint =>
      'Coba kata kunci atau filter lain — sebagian provider tidak '
      'mengiklankan dukungan tools.';
  @override
  String get modelsApiKeyHint =>
      'Masukkan API key di Pengaturan untuk melihat katalog model '
      'lengkap dari provider Anda.';
  @override
  String get suggestedFallback => 'MODEL YANG DISARANKAN';
  @override
  String get suggestedFallbackBody =>
      'Menampilkan model yang disarankan. Periksa koneksi atau Base URL, '
      'lalu coba lagi.';
  @override
  String get toolsBadge => 'tools';
  @override
  String get freeBadge => 'GRATIS';
  @override
  String get browseModels => 'Lihat daftar model';
  @override
  String get browseModelsHint =>
      'Ketuk ikon pencarian untuk melihat katalog model langsung.';
  @override
  String pageIndicator(int current, int total) =>
      'Halaman $current dari $total';
  @override
  String get searchProvidersHint => 'Cari provider…';
  @override
  String get searchSessionsHint => 'Cari chat…';
  @override
  String get searchFilesHint => 'Cari file…';
  @override
  String get searchContextHint => 'Cari context…';
  @override
  String get searchLibsHint => 'Cari pustaka…';
  @override
  String get noResults => 'Tidak ada hasil';
  @override
  String get agentTagline => 'AI Agent · Flutter';
  @override
  String get emptySubtitle =>
      'Agent AI di perangkat Anda — browsing, screenshot,\n'
      'jalankan kode, dan kelola file langsung dari chat.';
  @override
  List<String> get suggestions => const <String>[
    'Buka wikipedia.org lalu rangkum halaman utamanya',
    'Cari harga Bitcoin hari ini dan ambil screenshot',
    'Buat file catatan.txt berisi rencana harian',
    'Jalankan JavaScript untuk memproses JSON yang saya lampirkan',
  ];

  // -- Files manager ----------------------------------------------------
  @override
  String get filesTitle => 'File';
  @override
  String get filesEmpty => 'Belum ada file.';
  @override
  String get filesHint =>
      'Ruang kerja ini khusus untuk chat saat ini — file dari chat lain '
      'tidak akan tercampur. Salin, tempel, zip, dan bagikan.';
  @override
  String get filesExportFolder => 'Ekspor folder chat ke perangkat';
  @override
  String get filesExporting => 'Mengekspor folder chat ini…';
  @override
  String filesExportDone(int count) =>
      'Folder chat tersimpan di Downloads/Noah ($count berkas).';
  @override
  String filesExportZipReady(int count) =>
      'Folder chat dikemas menjadi ZIP ($count berkas) — pilih tempat '
      'menyimpan atau mengirimnya.';
  @override
  String get filesNoChatTitle => 'Tidak ada chat aktif';
  @override
  String get filesNoChatBody =>
      'Buka atau mulai sebuah chat dulu — setiap chat punya folder ruang '
      'kerja pribadinya di sini, jadi file tidak pernah tercampur antar '
      'chat.';
  @override
  String get newFolder => 'Folder baru';
  @override
  String get newFolderTitle => 'Folder baru';
  @override
  String get compress => 'Kompres ke ZIP';
  @override
  String get extractHere => 'Ekstrak';
  @override
  String get noPreview => 'Pratinjau tidak tersedia untuk tipe file ini.';
  @override
  String get filePreviewTitle => 'Pratinjau';
  @override
  String get clipboardCopied => 'Disalin.';
  @override
  String get clipboardCut => 'Dipotong. Tempel di folder lain.';
  @override
  String get pastedOk => 'Ditempel.';
  @override
  String get zipCreatedOk => 'ZIP dibuat.';
  @override
  String get unzippedOk => 'Diekstrak.';
  @override
  String get unzipPasswordTitle => 'Kata sandi diperlukan';
  @override
  String unzipPasswordBody(String name) =>
      '"$name" terenkripsi. Masukkan kata sandi untuk mengekstraknya.';
  @override
  String get passwordFieldHint => 'Kata sandi';
  @override
  String get unzipPasswordConfirm => 'Ekstrak';
  @override
  String get wrongPassword => 'Kata sandi salah.';
  @override
  String get deleteEntryTitle => 'Hapus?';
  @override
  String get deleteEntryBody => 'Item ini akan dihapus permanen.';

  // -- Context Manager ---------------------------------------------------
  @override
  String get contextSection => 'Konteks';
  @override
  String get contextManagerTitle => 'Manajer konteks';
  @override
  String get contextManagerHint =>
      'Blok prompt yang bisa dipakai ulang. Entri yang aktif dikirim dengan '
      'setiap permintaan agar agent selalu mengikuti aturan Anda.';
  @override
  String contextActiveCount(int n) => '$n aktif';
  @override
  String get addContext => 'Tambah konteks';
  @override
  String get editContext => 'Ubah konteks';
  @override
  String get contextNameLabel => 'Nama';
  @override
  String get contextContentLabel => 'Isi (dikirim sebagai konteks prompt)';
  @override
  String get contextEnabledLabel => 'Pakai konteks ini';
  @override
  String get deleteContextTitle => 'Hapus konteks?';
  @override
  String get deleteContextBody => 'Entri konteks ini akan dihapus permanen.';
  @override
  String get contextEmpty =>
      'Belum ada entri konteks. Tambahkan aturan yang harus selalu '
      'diikuti agent.';

  // -- Node.js runtime ---------------------------------------------------
  @override
  String get nodeSection => 'Runtime Node.js';
  @override
  String get nodeManagerTitle => 'Runtime & modul Node.js';
  @override
  String get nodeManagerHint =>
      'Runtime JavaScript tersemat yang bisa dipakai agent untuk memproses '
      'data. Instal package npm yang dibutuhkan dan hapus saat selesai.';
  @override
  String nodeInstalledCount(int n) => '$n package terpasang';
  @override
  String get nodeAddHint => 'Nama package, mis. lodash';
  @override
  String get nodeAddButton => 'Instal';
  @override
  String get nodeVersionHint => 'Versi (opsional)';
  @override
  String get nodeEmpty => 'Belum ada package terpasang.';
  @override
  String get nodeInstalling => 'Menginstal…';
  @override
  String get nodeDescription =>
      'node_run memungkinkan agent menjalankan JavaScript dengan require(), '
      'fs, dan fetch. Package diunduh dari registry npm dan disimpan di '
      'sandbox aplikasi.';
  @override
  String get nodeRemoveTitle => 'Hapus package?';
  @override
  String get nodeRemoveBody => 'File package akan dihapus.';

  // -- Appearance --------------------------------------------------------
  @override
  String get appearanceSection => 'Tampilan';
  @override
  String get themeLight => 'Terang';
  @override
  String get themeDark => 'Gelap';
  @override
  String get themeSystem => 'Sistem';

  // -- User Agent ---------------------------------------------------------
  @override
  String get uaSection => 'User Agent';
  @override
  String get uaModeTitle => 'Mode User-Agent';
  @override
  String get uaModeSubtitle =>
      'Berlaku untuk browser tersemat yang dipakai agent untuk browsing.';
  @override
  String get uaModeAuto => 'Otomatis (ikut perangkat)';
  @override
  String get uaModeDesktop => 'PC/Desktop';
  @override
  String get uaModeAndroid => 'Android Mobile';
  @override
  String get uaModeHint =>
      'Otomatis memakai identitas Android yang sesuai dengan perangkat ini '
      'dan tetap stabil selama sesi. Mode PC/Desktop juga mengubah tata '
      'letak halaman menjadi rendering desktop.';
  @override
  String get uaCurrentLabel => 'User-Agent aktif';
  @override
  String get uaRotateTooltip => 'Pakai User-Agent lain';
  @override
  String get uaAskRandomTitle => 'Tawarkan User-Agent acak saat chat baru';
  @override
  String get uaAskRandomSubtitle =>
      'Setiap chat baru menanyakan apakah browser tersemat harus beralih ke '
      'User-Agent lain yang dipilih acak. Anda bisa menolak agar '
      'User-Agent sekarang tetap dipakai.';
  @override
  String get randomUaDialogTitle => 'User-Agent acak';
  @override
  String get randomUaDialogBody =>
      'Pakai User-Agent lain yang dipilih acak untuk browser tersemat di '
      'chat baru ini? Pilihan ini diingat sampai Anda mengubahnya lagi.';
  @override
  String get randomUaAccept => 'Ya, acak';
  @override
  String get randomUaDecline => 'Pertahankan';

  // -- Settings --------------------------------------------------------
  @override
  String get providerSection => 'Provider AI';
  @override
  String get providerPreset => 'Preset provider';
  @override
  String get baseUrlLabel => 'Base URL (OpenAI-compatible)';
  @override
  String get apiKeyLabel => 'API key';
  @override
  String get apiKeyStoredLocally =>
      'Setiap preset menyimpan key-nya sendiri, hanya di perangkat ini. '
      'Key InferHub berformat sk-airo-…';
  @override
  String get modelLabel => 'Model';
  @override
  String get modelHint => 'mis. z-ai/glm-4.6 atau anthropic/claude-sonnet-4.5';
  @override
  String get presetsTitle => 'Preset (masing-masing punya API key sendiri)';
  @override
  String get savePreset => 'Simpan sebagai preset';
  @override
  String get savePresetTitle => 'Simpan preset';
  @override
  String get presetNameLabel => 'Nama preset';
  @override
  String get editPreset => 'Ubah preset';
  @override
  String get deletePresetTitle => 'Hapus preset?';
  @override
  String get deletePresetBody => 'Preset beserta key tersimpannya dihapus.';
  @override
  String get presetHasKey => 'key tersimpan';
  @override
  String get presetNoKey => 'tanpa key';

  // -- Providers management (v1.5.0) -----------------------------------
  @override
  String get providersTileSubtitle =>
      'Kelola provider, API key, dan daftar model';
  @override
  String get providersTitle => 'Provider';
  @override
  String get providersHint =>
      'Ketuk provider untuk mengubahnya, tahan (long-press) untuk '
      'mengaktifkannya dengan konfirmasi. Setiap provider menyimpan API key '
      'dan daftar modelnya sendiri.';
  @override
  String get addProvider => 'Tambah provider';
  @override
  String get newProviderTitle => 'Provider baru';
  @override
  String get activeBadge => 'AKTIF';
  @override
  String get useProviderTooltip => 'Gunakan provider ini';
  @override
  String providerActivatedSnack(String name) => 'Terhubung ke $name';
  @override
  String get saveApiKey => 'Simpan API key';
  @override
  String get apiKeySavedSnack => 'API key tersimpan untuk provider ini';
  @override
  String get fetchModels => 'Ambil daftar model';
  @override
  String get fetchingModels => 'Mengambil…';
  @override
  String modelsFetchedSnack(int n) => '$n model tersedia';
  @override
  String get modelsCachedNote =>
      'Menampilkan daftar terakhir yang berhasil diambil dari provider ini.';
  @override
  String modelsCachedCount(int n) => '$n model tersimpan';
  @override
  String get noModelsYet =>
      'Belum ada model — ketuk “Ambil daftar model” untuk memuat daftar '
      'dari provider ini.';
  @override
  String get nameRequiredError => 'Nama wajib diisi.';
  @override
  String get urlRequiredError => 'Base URL wajib diisi.';
  @override
  String get duplicateNameError => 'Provider dengan nama ini sudah ada.';
  @override
  String get providerSavedSnack => 'Provider tersimpan';
  @override
  String get providerDeletedSnack => 'Provider dihapus';
  @override
  String get keyStatusSection => 'Status key';

  @override
  String get maxStepsTitle => 'Maks. langkah agent';
  @override
  String get maxStepsHint =>
      'Jumlah maksimum putaran tool-call agent (1-100). Isi angka kustom '
      'atau gunakan slider.';
  @override
  String get runUntilDoneTitle => 'Jalankan sampai selesai';
  @override
  String get runUntilDoneSubtitle =>
      'Agent terus bekerja sampai tugas benar-benar selesai alih-alih '
      'berhenti di batas langkah (disarankan). Matikan untuk menerapkan '
      'batas di bawah.';
  @override
  String maxStepsReachedMarkdown(int steps) =>
      '*Berhenti sementara: batas maks. langkah agent ($steps) tercapai. '
      'Tugas mungkin belum selesai — naikkan batas di Pengaturan atau '
      'biarkan “Jalankan sampai selesai” aktif.*';
  @override
  String get runUntilDoneHint =>
      'Dinonaktifkan selama “Jalankan sampai selesai” aktif — agent bekerja '
      'sampai tugas selesai.';
  @override
  String get planFirstTitle => 'Buat rencana dulu (Todos)';
  @override
  String get planFirstSubtitle =>
      'Agent selalu memulai tugas dengan rencana todo dan terus bekerja '
      'sampai semua todo selesai (disarankan).';
  @override
  String get planTitle => 'Rencana';
  @override
  String planProgress(int done, int total) => '$done dari $total selesai';
  @override
  String get showPlanTooltip => 'Tampilkan rencana';
  @override
  String get hidePlanTooltip => 'Sembunyikan rencana';
  @override
  String get confirmDialogTitle => 'Perlu persetujuan';
  @override
  String get confirmDialogPrompt =>
      'Agen meminta persetujuan eksplisit Anda sebelum melakukan aksi '
      'ini. Periksa setiap baris sebelum memutuskan.';
  @override
  String get confirmApprove => 'Setujui';
  @override
  String get confirmDeny => 'Tolak';
  @override
  String get confirmDenied =>
      'DITOLAK oleh pengguna. Jangan lakukan aksi ini dan jangan mencoba '
      'lagi di percakapan ini.';
  @override
  String get confirmApproved =>
      'DISETUJUI oleh pengguna. Anda boleh melakukan persis aksi yang '
      'dijelaskan — tidak lebih.';
  @override
  String get confirmTimeout =>
      'Tidak ada jawaban dalam 10 menit — dianggap DITOLAK. Jangan '
      'lakukan aksi ini.';
  @override
  String get confirmUnavailable =>
      'Chat ini tidak berada di layar sehingga pengguna tidak dapat '
      'melihat permintaan persetujuan. Buka chat ini lalu minta lagi.';
  @override
  String get skillInstallConfirmTitle => 'Pasang skill eksternal?';
  @override
  String skillInstallConfirmSource(String source) => 'Sumber: $source';
  @override
  String get skillInstallConfirmBody =>
      'Ini mengunduh kode pihak ketiga yang akan berjalan di perangkat ini '
      'dengan akses jaringan dan file. Lanjutkan hanya jika Anda percaya '
      'sumbernya.';
  @override
  String get skillInstallDeclined =>
      'Pengguna menolak memasang skill ini. Jangan pasang dan jangan coba '
      'lagi di percakapan ini.';
  @override
  String get skillWalletConfirmTitle => 'Setujui aksi wallet?';
  @override
  String skillWalletConfirmAction(String skill, String script) =>
      'Skill: $skill — skrip: $script';
  @override
  String get skillWalletConfirmBody =>
      'Skill ini memindahkan nilai di blockchain (transfer, swap, '
      'approval, penjualan NFT, atau sejenisnya). Setujui hanya jika '
      'jumlah, jaringan, dan tujuan sesuai dengan yang Anda harapkan. '
      'Penolakan bersifat final untuk proses ini.';
  @override
  String get skillWalletDeclined =>
      'Pengguna MENOLAK aksi wallet ini. Jangan lakukan dan jangan coba '
      'lagi di percakapan ini. Laporkan penolakan kepada pengguna lalu '
      'berhenti; tidak ada transaksi yang dikirim.';
  @override
  String get copyMessage => 'Salin';
  @override
  String get copied => 'Tersalin';
  @override
  String get activateProviderTitle => 'Aktifkan provider';
  @override
  String activateProviderBody(String name) =>
      'Gunakan “$name” sebagai provider aktif? API key dan model yang '
      'tersimpan akan diterapkan ke koneksi.';
  @override
  String get activateProviderConfirm => 'Aktifkan';
  @override
  String get agentSection => 'Agent';
  @override
  String get agentModeTitle => 'Mode Agent';
  @override
  String get agentModeSubtitle =>
      'Aktifkan tool calling: browsing, screenshot, file, kode. '
      'Matikan untuk chat biasa.';
  @override
  String get automationTitle => 'Otomasi browser';
  @override
  String get automationSubtitle =>
      'Izinkan agent mengendalikan browser tersemat.';
  @override
  String get runInBackgroundTitle => 'Jalankan di latar belakang';
  @override
  String get runInBackgroundSubtitle =>
      'Agent tetap bekerja saat keluar dari aplikasi '
      '(menampilkan notifikasi progres).';
  @override
  String get languageSection => 'Bahasa';
  @override
  String get languageSubtitle => 'Bahasa antarmuka aplikasi. Bawaan: English.';
  @override
  String get englishOption => 'English (bawaan)';
  @override
  String get indonesianOption => 'Bahasa Indonesia';
  @override
  String get dataSection => 'Data';
  @override
  String get exportSessions => 'Ekspor sesi';
  @override
  String get importSessions => 'Impor sesi';
  @override
  String exportDone(String path) => 'Diekspor ke $path';
  @override
  String importDone(int count) => '$count sesi diimpor.';
  @override
  String get importFailed => 'Impor gagal: file ekspor tidak valid.';

  // -- Tooltip ikon impor/ekspor sesi (v1.34.0) --------------------------
  @override
  String get importSessionsIconTip => 'Impor sesi (JSON)';
  @override
  String get exportSessionsIconTip => 'Ekspor sesi (JSON)';

  // -- Ekspor Markdown, statistik token & backup terenkripsi (v1.17.0) ---
  @override
  String get exportChatMarkdown => 'Ekspor chat (Markdown)';
  @override
  String get exportChatMarkdownEmpty =>
      'Belum ada yang bisa diekspor — chat ini masih kosong.';
  @override
  String exportChatMarkdownDone(String path) => 'Chat diekspor ke $path';
  @override
  String get tokenStatsMenuItem => 'Statistik token';
  @override
  String get tokenStatsTitle => 'Statistik token';
  @override
  String get statsNoData =>
      'Belum ada pemakaian token tercatat. Provider melaporkan pemakaian '
      'per permintaan; statistik muncul di sini setelah percakapan '
      'berikutnya.';
  @override
  String get statsPromptTokens => 'Token prompt';
  @override
  String get statsCompletionTokens => 'Token jawaban';
  @override
  String get statsTotalTokens => 'Total token';
  @override
  String get statsTurns => 'Giliran asisten';
  @override
  String get statsSessions => 'Sesi';
  @override
  String get statsPerModel => 'PER MODEL';
  @override
  String statsModelLine(
    String prompt,
    String completion,
    String total,
    int turns,
  ) => '$total token dalam $turns giliran ($prompt masuk / $completion keluar)';
  @override
  String get statsUsageHint =>
      'Pemakaian hanya dihitung saat provider melapkannya per permintaan. '
      'Percakapan lama (sebelum v1.17.0) tidak ikut dihitung.';
  @override
  String get backupSectionTitle => 'Backup & pulihkan';
  @override
  String get backupCreate => 'Buat backup terenkripsi';
  @override
  String get backupCreateHint =>
      'Menyimpan semua chat, seluruh pengaturan (termasuk API key) dan '
      'Manajer Konteks ke satu file .zabak terenkripsi AES-256 di '
      'folder exports/.';
  @override
  String get backupPassphraseLabel => 'Kata sandi (min. 8 karakter)';
  @override
  String get backupRestore => 'Pulihkan dari backup';
  @override
  String get backupRestoreHint =>
      'Memulihkan akan MENGGANTI semua chat, pengaturan, dan entri konteks '
      'saat ini dengan isi backup.';
  @override
  String get backupConfirmTitle => 'Pulihkan backup ini?';
  @override
  String get backupConfirmBody =>
      'Chat, pengaturan provider, dan entri konteks Anda saat ini akan '
      'DIGANTI dengan isi backup. Tindakan ini tidak bisa dibatalkan.';
  @override
  String backupRestoreDone(int sessions, bool settings, int contexts) =>
      'Dipulihkan: $sessions sesi, $contexts entri konteks'
      '${settings ? ' dan pengaturan' : ''}.';
  @override
  String get backupWrongPassphrase =>
      'Kata sandi salah atau file pernah diubah.';
  @override
  String get backupFailed => 'Backup gagal.';
  @override
  String get backupPassphraseShort => 'Gunakan kata sandi minimal 8 karakter.';

  // -- Kunci aplikasi & notifikasi selesai (v1.18.0) ---------------------
  @override
  String get appLockSection => 'Kunci aplikasi';
  @override
  String get appLockTitle => 'Noah terkunci';
  @override
  String get appLockEnableTitle => 'Kunci aplikasi';
  @override
  String get appLockEnableSubtitle =>
      'Minta sidik jari atau PIN saat aplikasi dibuka dan kembali dari '
      'latar belakang. Atur PIN sebagai cadangan terlebih dahulu.';
  @override
  String get appLockSetPinTitle => 'Atur PIN cadangan';
  @override
  String get appLockPinField => 'PIN (4-8 digit)';
  @override
  String get appLockPinTooShort => 'PIN perlu 4-8 digit.';
  @override
  String get appLockPinMismatch => 'Kedua PIN tidak sama.';
  @override
  String get appLockConfirmPin => 'Konfirmasi PIN';
  @override
  String get appLockDisableConfirm =>
      'Mematikan kunci akan menghapus PIN tersimpan. Lanjutkan?';
  @override
  String get appLockPinHint => 'PIN';
  @override
  String get appLockWrongPin => 'PIN salah';
  @override
  String get appLockUnlock => 'Buka kunci';
  @override
  String get appLockUseBiometric => 'Gunakan biometrik';
  @override
  String get appLockBiometricReason => 'Buka kunci Noah';
  @override
  String get notifyOnDoneTitle => 'Beri tahu saat tugas selesai';
  @override
  String get notifyOnDoneSubtitle =>
      'Menampilkan notifikasi lokal saat proses agent selesai saat Anda '
      'di luar aplikasi; ketuk untuk membuka kembali percakapan itu.';
  @override
  String get notifDoneTitle => 'Tugas agent selesai';
  @override
  String notifDoneBody(String sessionTitle, String? error) => error == null
      ? '\u201C$sessionTitle\u201D selesai — ketuk untuk membuka.'
      : '\u201C$sessionTitle\u201D berhenti karena error — ketuk untuk membuka.';

  @override
  String get exitAppTitle => 'Keluar dari Noah?';
  @override
  String get exitAppBody =>
      'Tugas agent tetap berjalan di latar belakang selama aplikasi ditutup.';
  @override
  String get exitAppConfirm => 'Keluar';
  @override
  String get batteryTitle => 'Keandalan latar belakang';
  @override
  String get batterySubtitle =>
      'Minta Android mengecualikan Noah dari optimisasi baterai agar '
      'proses agent yang lama tidak pernah dijeda di latar belakang.';
  @override
  String get batteryRestricted =>
      'Dioptimalkan (bisa dijeda) — ketuk untuk pengecualian';
  @override
  String get batteryExempted =>
      'Dikecualikan — proses latar belakang dilindungi';

  @override
  String get aboutSection => 'Tentang';
  @override
  String get aboutBody =>
      'Noah adalah aplikasi chat agen Android bergaya agent mode '
      'chat.z.ai: bawa provider OpenAI-compatible Anda sendiri '
      '(OpenRouter, InferHub, Z.AI, OpenAI, DeepSeek, Groq, dan '
      'lainnya), jalankan banyak chat paralel dengan proses latar '
      'belakang sungguhan, Todos perencanaan dengan panel Plan live, '
      'sistem skills nyata (pasang skill eksternal lewat perintah gaya '
      'CLI atau bahasa biasa, kelola dan jalankan di semua chat), alur '
      'kerja dompet Web3 dengan kartu konfirmasi eksplisit, sandbox '
      'file dan sesi browser terisolasi per chat, tool git dan '
      'web_fetch, runtime bergaya Node.js dengan paket npm, ekspor '
      'Markdown, backup terenkripsi seluruh aplikasi, statistik token, '
      'dan kunci aplikasi biometrik/PIN opsional. API key dan rahasia '
      'skill Anda tetap di perangkat ini. Lihat Bantuan untuk panduan '
      'lengkap.';

  // -- Help & About screens (v1.41.5) ------------------------------------
  @override
  String get helpAboutSection => 'Bantuan & Tentang';
  @override
  String get helpTileTitle => 'Bantuan & panduan pakai';
  @override
  String get helpTileSubtitle =>
      'Panduan lengkap semua fitur, dengan bahasa yang mudah';
  @override
  String get aboutTileTitle => 'Tentang Noah';
  @override
  String get aboutTileSubtitle => 'Versi, pembuat, dan kemampuan aplikasi ini';
  @override
  String get aboutTitle => 'Tentang';
  @override
  String get aboutTagline =>
      'Tim agen AI Anda sendiri di Android — rencanakan, telusuri, '
      'jalankan, selesaikan.';
  @override
  String get aboutCreatorLabel => 'Pembuat';
  @override
  String get aboutVersionLabel => 'Versi';
  @override
  String get aboutWhatsInside => 'Isi aplikasi';
  @override
  String get aboutDisclaimer =>
      'Noah adalah aplikasi independen karya Maragung yang bergaya '
      'antarmuka agent mode chat.z.ai dan tidak berafiliasi dengan '
      'Z.AI. Skill dan modul berjalan lokal di perangkat ini; aplikasi '
      'tidak pernah meminta seed phrase atau private key, dan setiap '
      'aksi dompet yang memindahkan nilai butuh konfirmasi eksplisit '
      'Anda terlebih dahulu.';
  @override
  String get helpTitle => 'Bantuan';
  @override
  String get helpIntro =>
      'Semua yang bisa dilakukan Noah, dan cara memakainya. Bagian '
      'diurutkan sesuai urutan Anda menemuinya di aplikasi.';
  @override
  List<HelpEntry> get helpTopics => const [
    HelpEntry(
      '1. Mulai: hubungkan provider',
      'Buka Pengaturan → Providers, tambahkan provider Anda '
          '(OpenRouter, InferHub, Z.AI, OpenAI, DeepSeek, Groq, atau '
          'endpoint OpenAI-compatible apa pun), tempel API key-nya dan '
          'pilih model dari katalog live (lengkap dengan pencarian dan '
          'filter). Key hanya tersimpan di perangkat ini. Tanpa key yang '
          'berfungsi chat tidak bisa menjawab, jadi mulai dari sini.',
    ),
    HelpEntry(
      '2. Chat dan tugas latar belakang',
      'Buat chat sebanyak yang Anda mau dari drawer samping — semuanya '
          'berjalan paralel. Tugas tetap berjalan saat Anda pindah chat '
          'atau keluar dari aplikasi; notifikasi memberi tahu saat ia '
          'selesai. Setiap chat terisolasi penuh: transkrip, state, '
          'proses, output, dan filenya tidak pernah bocor ke chat lain, '
          'dan Stop hanya memengaruhi chat tempat Anda menekannya.',
    ),
    HelpEntry(
      '3. Rencana (Todos) dan panel Plan',
      'Setiap tugas dimulai dengan rencana: agent mendaftar langkahnya, '
          'lalu mengerjakannya satu per satu. Buka panel Plan live dari '
          'ikon rencana — panel tetap terbuka sampai ANDA menutupnya, '
          'bertahan saat pindah chat, dan terbarui real-time saat langkah '
          'selesai atau gagal. Rencana tersimpan terus-menerus ke disk, '
          'jadi aplikasi crash atau baterai habis pun rencana dan progres '
          'Anda tetap aman.',
    ),
    HelpEntry(
      '4. Skills: pasang, atur, jalankan',
      'Skill adalah paket instruksi + skrip yang bisa ditemukan, '
          'dipasang, dan dipakai agent. Pasang dengan bahasa biasa '
          '(\u201cpasang skill X\u201d) atau tempel perintah gaya CLI '
          'seperti \u201cnpx skills add owner/repo/path/to/skill\u201d — '
          'agent memeriksa dependensi, membaca instruksi skill, dan '
          'memverifikasi hasil pemasangan secara jujur. Skill dompet Web3 '
          'bawaan siap dipakai. Kelola lewat chat: skill_list, skill_info, '
          'skill_config (API key dan pengaturan, tersimpan di perangkat '
          'dan tidak pernah diecho), skill_update, dan skill_run. Skill '
          'yang terpasang bertahan di SEMUA chat — pasang sekali, pakai '
          'di mana saja.',
    ),
    HelpEntry(
      '5. Alur kerja dompet Web3 dan keamanannya',
      'Pakai skill dompet bawaan (Binance Agentic Wallet, Web3 basics) '
          'atau pasang yang kompatibel untuk cek saldo, baca transaksi, '
          'dan berinteraksi dengan aplikasi Web3. Login selalu memakai '
          'halaman resmi penyedia — agent menampilkan tautannya, Anda '
          'yang menghubungkan sendiri. Aplikasi TIDAK PERNAH meminta seed '
          'phrase atau private key. Sebelum aksi tak bisa dibatalkan '
          '(transfer, swap, listing NFT, token approval), agent wajib '
          'menampilkan kartu konfirmasi berisi jaringan, aset, jumlah, '
          'tujuan, dan biaya — tidak ada yang bergerak sebelum Anda '
          'setujui. Login bukan izin untuk bertransaksi.',
    ),
    HelpEntry(
      '6. Otomasi browser dan User-Agent',
      'Agent bisa menjelajah, mengisi form, dan mengambil halaman '
          'dengan browser tersemat sungguhan. Setiap chat punya konteks '
          'browser terisolasi sendiri — cookie dan login satu chat tidak '
          'pernah bocor ke chat lain. Di Pengaturan → User Agent Anda '
          'memilih identitas browser: Auto memakai identitas Android yang '
          'jujur; pool Desktop/Android memutar sidik jari generasi '
          'terkini — browser Chromium (Chrome, Edge, Opera, Samsung '
          'Internet, Vivaldi) semuanya di Chromium 153+, Firefox di rilis '
          'terbaru (150+ dan ESR aktif), Safari 26/27. Putar manual atau '
          'biarkan chat baru memilih identitas acak.',
    ),
    HelpEntry(
      '7. Modul (plugin)',
      'Modul adalah addon JavaScript terpaket zip dengan SDK resmi '
          'zagents — unggah dari layar Modules dan ia berjalan di sandbox '
          'masing-masing chat dengan form setup, storage, state, dan '
          'izin per chat. Agent melihat status setup tiap modul (rahasia '
          'selalu disamarkan) — ketat per chat: form di satu chat tidak '
          'pernah menampilkan nilai yang diketik di chat lain. Layar '
          'Node mengelola runtime tersemat beserta '
          'paket npm; perintah Device tetap mati kecuali Anda '
          'mengaktifkannya eksplisit (khusus HP rooted).',
    ),
    HelpEntry(
      '8. File dan sandbox per chat',
      'Setiap chat punya folder ruang kerja pribadi — unggahan, file '
          'hasil, dan state modul tinggal di sana, tak terlihat chat '
          'lain. Ekspor ruang kerja ke file manager perangkat '
          '(Downloads/Noah/<chat>) dengan satu ketukan, dan menghapus '
          'chat ikut menghapus seluruh ruang kerjanya. Unggahan file '
          'mendukung ekstraksi zip, termasuk arsip berpassword.',
    ),
    HelpEntry(
      '9. Pencarian, ekspor, dan backup',
      'Pencarian global (ikon kaca pembesar) menemukan judul dan isi '
          'lengkap pesan di semua chat. Ekspor chat apa pun sebagai '
          'Markdown dari drawer. Pengaturan → Data membuat backup '
          'terenkripsi seluruh aplikasi (chat, pengaturan, konfigurasi '
          'skill) yang bisa dipulihkan setelah instal ulang atau pindah '
          'HP.',
    ),
    HelpEntry(
      '10. Statistik, kunci aplikasi, dan notifikasi',
      'Statistik menampilkan pemakaian token per model dan per chat. '
          'Kunci aplikasi opsional (biometrik atau PIN) melindungi '
          'aplikasi saat dibuka. Tugas latar belakang mengirim notifikasi '
          'selesai; proses panjang bisa dikecualikan dari optimasi '
          'baterai agar Android tidak pernah menjedanya.',
    ),
    HelpEntry(
      '11. Notifikasi per chat dan Stop / Force stop',
      'Setiap chat yang SEDANG BERJALAN memasang notifikasinya sendiri '
          '— judul chat plus langkah yang sedang dikerjakan (tool apa '
          'yang berjalan saat ini). Ketuk untuk langsung membuka chat '
          'tersebut, bahkan setelah berjam-jam di background: foreground '
          'service dan wake lock menjaga Android tidak menjeda '
          'pekerjaan, dan Android 13+ bertanya sekali tentang izin '
          'notifikasi — izinkan agar notifikasinya tampil. Ingin '
          'menghentikan run? Tombol Stop merah menghentikan proses '
          'dengan SATU ketukan. Jika tidak kunjung berhenti, ketuk Stop '
          'lagi (muncul petunjuk) dan ketukan ketiga menawarkan Force '
          'stop — koneksi langsung diputus dan run diakhiri; progres '
          'parsial tetap tersimpan di transkrip.',
    ),
    HelpEntry(
      '12. Tips dan pemecahan masalah',
      'Provider error? Periksa ulang API key dan kuota model di '
          'dashboard penyedia. Modul bermasalah? Pakai kartu perbaikannya '
          'atau unggah ulang zip. Jaringan tidak stabil? Auto-retry '
          'dengan penjaga mode pesawat melanjutkan dengan aman. Teks '
          'streaming terasa macet? Tunggu atau tekan Stop — transkrip '
          'tersimpan setelah setiap langkah. Menemukan bug atau ingin '
          'fitur? Buka issue di repositori proyek.',
    ),
  ];

  @override
  String createdBy(String name) => 'Dibuat oleh $name';

  // -- Message actions (v1.15.0) ----------------------------------------
  @override
  String get editMessageAction => 'Edit pesan';
  @override
  String get editDialogTitle => 'Edit pesan';
  @override
  String get regenerate => 'Buat ulang';

  // -- Global chat search (v1.15.0) -------------------------------------
  @override
  String get searchChats => 'Cari chat';
  @override
  String get searchHint => 'Cari semua percakapan…';
  @override
  String get noSearchResults => 'Tidak ada percakapan yang cocok.';
  @override
  String get searchInitialHint =>
      'Ketik untuk mencari judul dan isi percakapan Anda.';

  // -- Automatic conversation titles (v1.15.0) --------------------------
  @override
  String get autoTitleTitle => 'Judul otomatis';
  @override
  String get autoTitleSubtitle =>
      'Beri nama percakapan baru secara otomatis dengan judul singkat '
      'buatan model setelah jawaban pertama.';

  // -- Prompt library (v1.15.0) -----------------------------------------
  @override
  String get promptLibrary => 'Pustaka prompt';
  @override
  String get promptLibraryEmpty => 'Belum ada prompt.';
  @override
  String get newPrompt => 'Prompt baru';
  @override
  String get editPrompt => 'Edit prompt';
  @override
  String get promptTitleLabel => 'Judul';
  @override
  String get promptContentLabel => 'Isi prompt';
  @override
  String get insertPrompt => 'Sisipkan dari pustaka prompt';
  @override
  String get deletePromptTitle => 'Hapus prompt?';
  @override
  String get deletePromptBody => 'Prompt ini akan dihapus permanen.';
  @override
  String get promptSaved => 'Prompt tersimpan.';
  @override
  String get promptDeleted => 'Prompt terhapus.';

  // -- Modul chat / plugin (v1.21.0) ------------------------------------
  @override
  String get modulesTitle => 'Modul';
  @override
  String get modulesInstall => 'Pasang modul (ZIP)';
  @override
  String get modulesEmpty => 'Belum ada modul terpasang.';
  @override
  String get modulesEmptyHint =>
      'Pasang ZIP modul untuk menjalankan kemampuan JavaScript native di '
      'dalam chat mana pun — terisolasi per chat seperti jendela privat.';
  @override
  String get modulesManage => 'Kelola modul';
  @override
  String get moduleSdkDocs => 'Dokumentasi SDK';
  @override
  String get moduleStartNewChat => 'Mulai di chat baru';
  @override
  String get moduleActivate => 'Aktifkan di chat ini';
  @override
  String get moduleDeactivate => 'Nonaktifkan';
  @override
  String get moduleActiveBadge => 'aktif';
  @override
  String moduleDeactivated(String name) =>
      'Modul \u201c$name\u201d dinonaktifkan — eksekusinya dihentikan dengan aman dan '
      'data per-chatnya tetap di dalam chat ini.';
  @override
  String get moduleTerminated => 'Eksekusi modul dihentikan oleh pengguna.';
  @override
  String moduleRunFailed(String error) => 'Modul gagal berjalan: $error';
  @override
  String moduleNotFound(String name) => 'Modul tidak terpasang: $name';
  @override
  String get moduleSessionBusy =>
      'Tunggu tugas saat ini selesai sebelum mengaktifkan modul.';
  @override
  String modulePermissionTitle(String name) =>
      'Izinkan \u201c$name\u201d untuk:';
  @override
  String get modulePermissionBody =>
      'Kemampuan ini berjalan terisolasi di dalam chat INI saja — tidak ada '
      'yang bocor ke chat lain.';
  @override
  String get moduleAllow => 'Izinkan dan jalankan';
  @override
  String moduleInstallSuccess(String name) => '$name terpasang.';
  @override
  String moduleInstallFailed(String error) => 'Gagal memasang: $error';
  @override
  String get moduleRemoveTitle => 'Hapus modul?';
  @override
  String moduleRemoveBody(String name) =>
      '\u201c$name\u201d beserta file programnya akan dihapus. Data yang sudah '
      'tersimpan di dalam chat masing-masing tetap berada di sandbox chat '
      'tersebut.';
  @override
  String moduleRemoved(String name) => 'Modul dihapus: $name';
  @override
  String get pluginMenuTitle => 'Modul untuk chat ini';
  @override
  String get pluginMenuEmpty =>
      'Belum ada modul terpasang. Pasang dari layar Modul.';
  @override
  String get startWithModule => 'Mulai dengan modul';

  // -- Module per-chat setup form (v1.24.0) ------------------------------
  @override
  String moduleSetupNeededTitle(String name) =>
      '$name butuh setup sebelum bisa berjalan di chat ini.';
  @override
  String get moduleSetupNeededBody =>
      'Isi informasi yang diminta pada formulir — setelah dikirim, modul '
      'diizinkan dan otomatis dijalankan.';
  @override
  String moduleSetupLegacyHint(String name) =>
      '\u201c$name\u201d terpasang dari ZIP lama yang belum punya formulir '
      'setup (modul terpasang mempertahankan versinya walau aplikasi '
      'diperbarui). Solusinya: 1) instal ZIP modul \u201c$name\u201d terbaru — '
      'versi barunya menyertakan formulir setup yang ditampilkan aplikasi '
      'sebelum run pertama; 2) atau kirim perintah setup milik modulnya '
      'sebagai pesan pertama di chat baru (misalnya \u201csetup email-kamu '
      'password-kamu\u201d), lalu aktifkan kembali modulnya.';
  @override
  String get moduleSetupBannerCta => 'Isi data';
  @override
  String get moduleSetupSaveRun => 'Simpan dan jalankan';
  @override
  String get moduleSetupPerChatHint =>
      'Disimpan hanya untuk chat INI — chat lain akan bertanya lagi.';
  @override
  String get moduleSetupRequiredTag => 'wajib';
  @override
  String get moduleSetupWaitingHint =>
      'Pesan Anda menunggu — agent mengerjakannya tepat setelah setup ini '
      'dikirim.';

  // -- Perintah perangkat modul (v1.31.0) ----------------------------------
  @override
  String get deviceCommandsTitle => 'Perintah perangkat (root)';
  @override
  String get deviceCommandsSubtitle =>
      'Izinkan modul yang disetujui menjalankan perintah shell di '
      'perangkat ini lewat zagents.device.shell — misal mode pesawat. '
      'Hanya untuk ponsel yang di-root; aktivasi modul tetap meminta '
      'persetujuan Anda.';

  // -- Auto retry & tombol stop merah (v1.30.0) -----------------------------
  @override
  String get autoRetrySection => 'Coba-ulang otomatis';
  @override
  String get autoRetryTitle => 'Coba ulang otomatis saat gagal';
  @override
  String get autoRetrySubtitle =>
      'Error jaringan, koneksi lemah, aliran terputus, atau error '
      'sementara dari provider tidak lagi mematikan tugas: agent '
      'menunggu lalu mencoba lagi, dan pekerjaan yang belum selesai '
      'dilanjutkan.';
  @override
  String get autoRetryAttemptsTitle => 'Maks. percobaan ulang';
  @override
  String get autoRetryDelayTitle => 'Jeda antar percobaan (detik)';
  @override
  String get autoRetryHint =>
      'Jeda membesar tiap percobaan (jeda x percobaan). Saat tugas berhenti '
      'dengan rencana yang belum selesai, ia juga dilanjutkan otomatis. '
      'Stop selalu menang — tidak ada percobaan ulang setelah tombolnya '
      'ditekan.';
  @override
  String autoRetryStreamNote(int attempt, int max) =>
      '*Coba-ulang $attempt/$max — menyambung ulang ke provider…*';
  @override
  String autoRetryResumeNote(int attempt, int max) =>
      '*Coba-ulang $attempt/$max — run terputus (error jaringan). '
      'Melanjutkan tugas…*';
  @override
  String autoRetryPlanNote(int attempt, int max) =>
      '*Lanjut otomatis $attempt/$max — rencana belum selesai. '
      'Melanjutkan tugas…*';
  @override
  String get autoRetryAirplaneNote =>
      '*Mode pesawat AKTIF — percobaan ulang ditahan sampai dimatikan. '
      'Kuota retry tidak terpakai; tugas lanjut otomatis begitu '
      'koneksi kembali.*';
  @override
  String get autoRetryAirplaneResumeNote =>
      '*Mode pesawat AKTIF — tugas lanjut otomatis begitu dimatikan '
      '(kuota retry tidak terpakai selama offline).*';

  // -- Module doctor (v1.26.0) --------------------------------------------
  @override
  String moduleRepairCardTitle(String name, String version) =>
      'Perbaikan modul siap: $name v$version';
  @override
  String moduleRepairCardBody(String permissions) =>
      'Agent menyiapkan modul hasil perbaikan dan lolos validasi. '
      'Menginstall akan menggantikan salinan terpasang — data per-chat di '
      'chat INI tetap disimpan. Periksa izinnya sebelum menginstall: '
      '$permissions';
  @override
  String get moduleRepairInstall => 'Install';
  @override
  String get moduleRepairDiscard => 'Buang';
  @override
  String moduleRepairInstalled(String name) =>
      'Modul “$name” terpasang dari hasil perbaikan agent. Bila butuh '
      'setup di chat ini, formulirnya muncul sebelum run berikutnya.';
  @override
  String moduleRepairInstallFailed(String error) =>
      'Modul hasil perbaikan gagal terpasang: $error';
  @override
  String get moduleExportTooltip => 'Ekspor ZIP';

  // -- Module export dialog (v1.47.0) --------------------------------------
  @override
  String get moduleExportTitle => 'Ekspor modul';
  @override
  String get moduleExportHint =>
      'Disimpan sebagai ZIP baru yang siap dipasang — tanpa akun, sesi, '
      'atau data chat apa pun. Nama file:';
  @override
  String get moduleExportAction => 'Ekspor';

  // -- Module update & remote install (v1.46.0) ---------------------------
  @override
  String get moduleInstallFromUrl => 'Install dari URL';
  @override
  String get moduleUrlDialogTitle => 'Install modul dari URL';
  @override
  String get moduleUrlDialogHint => 'https://contoh.com/modul.zip';
  @override
  String get moduleUrlDialogBody =>
      'ZIP modul diunduh lewat HTTPS dan dibongkar dengan validasi yang '
      'sama seperti file lokal. Hanya install modul dari sumber yang '
      'Anda percaya.';
  @override
  String get moduleDownload => 'Unduh & install';
  @override
  String get moduleUpdateTooltip => 'Update modul';
  @override
  String get moduleUpdateTitle => 'Update modul';
  @override
  String moduleUpdateBody(String name) =>
      'Pilih sumber update untuk \u201c$name\u201d. Menginstall menggantikan '
      'file modul; data modul per-chat tetap tersimpan.';
  @override
  String get moduleUpdateFromZip => 'Dari file ZIP';
  @override
  String get moduleUpdateFromUrl => 'Dari URL';
  @override
  String get moduleDownloading => 'Mengunduh\u2026';
  @override
  String get moduleSampleInstall => 'Install';
  @override
  String get moduleSampleUpdate => 'Update';
  @override
  String get moduleSampleInstalled => 'Terpasang';
  @override
  String get moduleSampleRepoHint =>
      'Sekali tap langsung menginstall atau mengupdate modul dari '
      'repositori contoh resmi.';

  // -- Module builder (/make_plugins) -------------------------------------
  @override
  String moduleBuildCardTitle(String name, String version) =>
      'Plugin baru siap: $name v$version';
  @override
  String moduleBuildCardBody(String permissions) =>
      'Agent membuat plugin ini di chat dan lolos validasi. Periksa '
      'izinnya sebelum menginstall: $permissions. Setelah terpasang, '
      'jalankan dengan /plugins (menu) atau /plugins <nama>.';
  @override
  String moduleBuildInstalled(String name) =>
      'Plugin “$name” terpasang. Jalankan dengan /plugins (menu) atau '
      '/plugins <nama> — di chat ini atau chat baru; tiap chat punya '
      'storage terisolasi dan formulir setup sendiri.';

  // -- Controller messages ----------------------------------------------
  @override
  String get missingApiKey =>
      'API key belum diisi. Buka Pengaturan untuk mengatur provider.';
  @override
  String get modelNotSet =>
      'Model belum dipilih. Pilih di Pengaturan atau dari menu model.';
  @override
  String get stoppedMarkdown => '_(dihentikan)_';
  @override
  String get chatOpenError => 'Gagal membuka percakapan ini.';
  @override
  String get chatDeleteError => 'Gagal menghapus percakapan ini.';
  @override
  String get chatRenameError => 'Gagal mengganti nama percakapan ini.';

  // -- Background service notification ----------------------------------
  @override
  String get notifTitle => 'Agent Noah sedang berjalan';
  @override
  String get notifProcessing => 'Memproses permintaan Anda…';
  @override
  String notifStep(int step, String tool) => 'Langkah $step · $tool';

  // -- Stop / force stop (v1.42.0) ---------------------------------------
  @override
  String get stopHintForce =>
      'Stop diminta — ketuk Stop sekali lagi untuk menawarkan force stop.';
  @override
  String get forceStopTitle => 'Force stop proses ini?';
  @override
  String get forceStopBody =>
      'Proses masih berjalan setelah Stop ditap berulang. Force stop akan '
      'langsung memutus koneksi dan mengakhiri run ini — progres parsial '
      'tetap tersimpan di transkrip.';
  @override
  String get forceStopConfirm => 'Force stop';
  @override
  String get forceStopCancel => 'Batal';
  @override
  String get forceStopDone => 'Force stop dijalankan.';

  @override
  String get ollamaSectionTitle => 'Local AI';
  @override
  String get ollamaTileTitle => 'Kelola Ollama';
  @override
  String get ollamaTileSubtitle =>
      'Runtime AI lokal yang kompatibel dengan Ollama';
  @override
  String get ollamaScreenTitle => 'Kelola Ollama';
  @override
  String get ollamaTabServer => 'Server';
  @override
  String get ollamaExternalServerLabel => 'Server Ollama eksternal';
  @override
  String get ollamaProbe => 'Periksa';
  @override
  String ollamaProbeOk(String version) => 'Ollama $version terjangkau.';
  @override
  String ollamaProbeFail(String error) =>
      'Server Ollama tidak ditemukan: $error';
  @override
  String get ollamaUseAsProvider => 'Pakai sebagai provider';
  @override
  String get ollamaOnDeviceTitle => 'Runtime di perangkat';
  @override
  String get ollamaOnDevicePending =>
      'Runtime LLM bawaan di perangkat belum tersedia di build ini. '
      'Kamu tetap bisa mengarahkan Noah ke server Ollama eksternal '
      'di bawah.';

  @override
  String get cronOpenOllamaManage => 'Buka Kelola Ollama';
  @override
  String get ollamaActiveModelLabel => 'Model aktif';
  @override
  String ollamaAddedAt(String date) => 'Ditambahkan $date';
  @override
  String ollamaBattery(int percent) => 'Baterai $percent%';
  @override
  String ollamaBatteryCharging(int percent) => 'Baterai $percent% · mengisi';
  @override
  String ollamaBatteryLow(int percent) => 'Baterai $percent% — lemah';
  @override
  String get ollamaBenchmark => 'Benchmark';
  @override
  String ollamaBenchmarkFailed(String error) => 'Benchmark gagal: $error';
  @override
  String get ollamaBenchmarkRunning => 'Mengukur…';
  @override
  String ollamaBenchmarkSummary(
    String tokPerSec,
    int firstTokenMs,
    int tokens,
  ) => '$tokPerSec tok/dtk · token pertama ${firstTokenMs}ms · $tokens token';
  @override
  String get ollamaCatalogRefresh => 'Muat ulang katalog';
  @override
  String ollamaCatalogRefreshDone(int count) =>
      'Katalog diperbarui: $count model.';
  @override
  String ollamaCatalogRefreshFailed(String error) =>
      'Gagal memuat ulang katalog: $error';
  @override
  String get ollamaCatalogReset => 'Atur ulang';
  @override
  String get ollamaCatalogResetDone => 'Kembali ke katalog bawaan.';
  @override
  String get ollamaClearFinished => 'Bersihkan yang selesai';
  @override
  String get ollamaClose => 'Tutup';
  @override
  String get ollamaConfigInvalid =>
      'Port harus 1024–65535, konteks 512–32768, thread 0–8.';
  @override
  String get ollamaConfigSave => 'Simpan konfigurasi';
  @override
  String get ollamaConfigSaved => 'Konfigurasi server disimpan.';
  @override
  String get ollamaContextLabel => 'Ukuran konteks';
  @override
  String get ollamaCopyAll => 'Salin semua';
  @override
  String ollamaCtxTokens(String tokens) => '$tokens ctx';
  @override
  String get ollamaCustomUrlInvalid =>
      'Masukkan URL http(s) yang berakhiran .gguf';
  @override
  String get ollamaCustomUrlLabel => 'URL kustom (.gguf)';
  @override
  String ollamaDeleteBody(String name) =>
      '“$name” dan filenya akan dihapus dari perangkat ini.';
  @override
  String get ollamaDeleteTitle => 'Hapus model ini?';
  @override
  String ollamaDeviceRam(String size) => 'RAM perangkat $size';
  @override
  String get ollamaDlCanceled => 'Dibatalkan';
  @override
  String get ollamaDlCompleted => 'Selesai';
  @override
  String get ollamaDlFailed => 'Gagal';
  @override
  String get ollamaDlPaused => 'Dijeda';
  @override
  String get ollamaDlQueued => 'Dalam antrean';
  @override
  String get ollamaDlRunning => 'Mengunduh';
  @override
  String get ollamaDownload => 'Unduh';
  @override
  String ollamaDownloadStarted(String name) => '“$name” masuk antrean unduhan.';
  @override
  String get ollamaDownloadingLabel => 'Mengunduh…';
  @override
  String get ollamaDownloadsEmpty => 'Belum ada unduhan.';
  @override
  String get ollamaExport => 'Ekspor';
  @override
  String get ollamaExportDone => 'Model diekspor.';
  @override
  String get ollamaExportNone => 'Tidak ada model yang diekspor.';
  @override
  String get ollamaExportSelected => 'Ekspor terpilih';
  @override
  String ollamaExportSelectedDone(int count) => '$count model diekspor.';
  @override
  String get ollamaFitFilter => 'Hanya model yang muat';
  @override
  String get ollamaGoToCatalog => 'Buka Katalog';
  @override
  String get ollamaImportButton => 'Impor file .gguf';
  @override
  String ollamaImportDone(String name) => '“$name” diimpor.';
  @override
  String get ollamaImportFailed => 'Impor gagal.';
  @override
  String get ollamaInstalledEmptyBody =>
      'Unduh model dari Katalog atau impor file .gguf.';
  @override
  String get ollamaInstalledEmptyTitle => 'Belum ada model terpasang';
  @override
  String get ollamaInstalledLabel => 'Terpasang';
  @override
  String get ollamaLogTitle => 'Log server';
  @override
  String get ollamaModelEmptyHint =>
      'Belum ada model terpasang — unduh satu dari Katalog.';
  @override
  String get ollamaModelLabel => 'Model';
  @override
  String get ollamaOomWarning =>
      'Model berat: risiko tinggi kehabisan memori di perangkat ini.';
  @override
  String get ollamaPause => 'Jeda';
  @override
  String get ollamaPortLabel => 'Port';
  @override
  String ollamaRamEst(String size) => 'RAM ~$size';
  @override
  String get ollamaResume => 'Lanjutkan';
  @override
  String ollamaRiskBody(String ref) =>
      '“$ref” berisiko melebihi memori perangkat ini dan gagal dimuat. Tetap '
      'unduh?';
  @override
  String get ollamaRiskTitle => 'Unduh model berat ini?';
  @override
  String get ollamaRuntimeUnavailable =>
      'Build atau perangkat ini tidak memiliki runtime AI lokal '
      '(armeabi-v7a tidak didukung). Anda masih bisa terhubung ke server '
      'Ollama eksternal di bawah.';
  @override
  String get ollamaSelectMode => 'Pilih model';
  @override
  String ollamaSelectedCount(int count) => '$count dipilih';
  @override
  String ollamaSizeProgress(int receivedMb, int totalMb) =>
      '$receivedMb dari $totalMb MB';
  @override
  String get ollamaSizeUnknown => 'ukuran tidak diketahui';
  @override
  String get ollamaSourceCatalog => 'Katalog';
  @override
  String get ollamaSourceCustomUrl => 'URL kustom';
  @override
  String get ollamaSourceImported => 'Impor';
  @override
  String get ollamaStart => 'Mulai';
  @override
  String get ollamaStartFailedSnack => 'Server gagal dinyalakan.';
  @override
  String get ollamaStartWith => 'Mulai dengan model ini';
  @override
  String get ollamaStartedSnack => 'Server dinyalakan.';
  @override
  String get ollamaStatusFailed => 'Gagal';
  @override
  String get ollamaStatusRunning => 'Berjalan';
  @override
  String get ollamaStatusStarting => 'Menyalakan…';
  @override
  String get ollamaStatusStopped => 'Berhenti';
  @override
  String get ollamaStatusStopping => 'Menghentikan…';
  @override
  String get ollamaStatusUnavailable => 'Tidak tersedia';
  @override
  String get ollamaStop => 'Stop';
  @override
  String get ollamaStoppedSnack => 'Server dihentikan.';
  @override
  String get ollamaTabCatalog => 'Katalog';
  @override
  String get ollamaTabDownloads => 'Unduhan';
  @override
  String get ollamaTabInstalled => 'Terpasang';
  @override
  String get ollamaThreadsLabel => 'Thread (0 = otomatis)';
  @override
  String get ollamaTierHeavy => 'Berat';
  @override
  String get ollamaTierLight => 'Ringan';
  @override
  String get ollamaTierMedium => 'Sedang';
  @override
  String get ollamaTooLarge => 'Terlalu besar untuk perangkat ini';
  @override
  String get ollamaUseInChat => 'Gunakan di chat';
  @override
  String ollamaUseInChatBody(String alias) =>
      'Provider aktif Anda beralih ke Local AI dengan model “$alias”.';
  @override
  String get ollamaUseInChatDone => 'Local AI kini aktif untuk chat.';
  @override
  String get ollamaUseInChatTitle => 'Gunakan model ini di chat?';
  @override
  String get ollamaViewFullLog => 'Lihat log lengkap';
}
