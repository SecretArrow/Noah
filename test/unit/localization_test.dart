import 'package:flutter_test/flutter_test.dart';
import 'package:noah/l10n/app_strings.dart';
import 'package:noah/models/models.dart';

void main() {
  group('AppStrings resolution', () {
    test('default language is English', () {
      expect(defaultLanguageCode, 'en');
      expect(defaultLanguageCode, AppSettings().languageCode);
    });

    test('unknown / empty codes fall back to English', () {
      expect(appStringsFor('xx'), isA<AppStringsEn>());
      expect(appStringsFor(''), isA<AppStringsEn>());
      expect(appStringsFor('ID'), isA<AppStringsId>()); // case-insensitive
    });

    test('English bundle exposes default wording', () {
      final AppStrings en = appStringsFor('en');
      expect(en.settings, 'Settings');
      expect(en.askAnything, 'Ask anything…');
      expect(en.englishOption, 'English (default)');
      expect(en.missingApiKey, contains('API key is not set'));
      expect(en.suggestions, isNotEmpty);
    });

    test('Indonesian bundle exposes translated wording', () {
      final AppStrings id = appStringsFor('id');
      expect(id.settings, 'Pengaturan');
      expect(id.askAnything, 'Tanya apa saja…');
      expect(id.indonesianOption, 'Bahasa Indonesia');
      expect(id.missingApiKey, contains('API key belum diisi'));
      expect(id.suggestions.length, appStringsFor('en').suggestions.length);
    });

    test('plan-first strings are localized in all three bundles', () {
      final AppStrings en = appStringsFor('en');
      final AppStrings id = appStringsFor('id');
      final AppStrings es = appStringsFor('es');
      expect(en.planFirstTitle, contains('Plan first'));
      expect(en.planTitle, 'Plan');
      expect(en.planProgress(2, 5), '2 of 5 done');
      expect(id.planFirstTitle, contains('rencana'));
      expect(id.planTitle, 'Rencana');
      expect(id.planProgress(2, 5), '2 dari 5 selesai');
      expect(es.planFirstTitle, contains('Planificar'));
      expect(es.planTitle, 'Plan');
      expect(es.planProgress(2, 5), '2 de 5 completadas');
    });

    test('live plan toggle + provider activation strings are localized', () {
      final AppStrings en = appStringsFor('en');
      final AppStrings id = appStringsFor('id');
      expect(en.showPlanTooltip, 'Show plan');
      expect(en.hidePlanTooltip, 'Hide plan');
      expect(en.activateProviderTitle, 'Activate provider');
      expect(en.activateProviderBody('X'), contains('X'));
      expect(en.activateProviderConfirm, 'Activate');
      expect(id.showPlanTooltip, 'Tampilkan rencana');
      expect(id.hidePlanTooltip, 'Sembunyikan rencana');
      expect(id.activateProviderTitle, 'Aktifkan provider');
      expect(id.activateProviderBody('X'), contains('X'));
      expect(id.activateProviderConfirm, 'Aktifkan');
      expect(en.providersHint, contains('long-press'));
      expect(id.providersHint, contains('long-press'));
    });

    test('encrypted zip password strings are localized', () {
      final AppStrings en = appStringsFor('en');
      final AppStrings id = appStringsFor('id');
      expect(en.unzipPasswordTitle, 'Password required');
      expect(en.unzipPasswordBody('a.zip'), contains('a.zip'));
      expect(en.passwordFieldHint, 'Password');
      expect(en.unzipPasswordConfirm, 'Extract');
      expect(en.wrongPassword, 'Wrong password.');
      expect(id.unzipPasswordTitle, 'Kata sandi diperlukan');
      expect(id.unzipPasswordBody('a.zip'), contains('a.zip'));
      expect(id.passwordFieldHint, 'Kata sandi');
      expect(id.unzipPasswordConfirm, 'Ekstrak');
      expect(id.wrongPassword, 'Kata sandi salah.');
    });
  });

  group('AppSettings language persistence', () {
    test('languageCode round-trips through JSON', () {
      final AppSettings original = AppSettings(apiKey: 'k', languageCode: 'id');
      final Map<String, dynamic> json = original.toJson();
      final AppSettings restored = AppSettings.fromJson(json);
      expect(restored.languageCode, 'id');
    });

    test('missing languageCode in JSON defaults to English', () {
      final AppSettings restored = AppSettings.fromJson(<String, dynamic>{});
      expect(restored.languageCode, 'en');
    });

    test('copyWith only changes languageCode', () {
      final AppSettings base = AppSettings(apiKey: 'k', model: 'm');
      final AppSettings updated = base.copyWith(languageCode: 'id');
      expect(updated.languageCode, 'id');
      expect(updated.apiKey, 'k');
      expect(updated.model, 'm');
      expect(updated.baseUrl, base.baseUrl);
    });
  });

  test('copy-message strings are localized in both bundles', () {
    final AppStrings en = appStringsFor('en');
    final AppStrings id = appStringsFor('id');
    expect(en.copyMessage, 'Copy');
    expect(en.copied, 'Copied');
    expect(id.copyMessage, 'Salin');
    expect(id.copied, 'Tersalin');
  });

  test('edit/regenerate message strings are localized in both bundles', () {
    final AppStrings en = appStringsFor('en');
    final AppStrings id = appStringsFor('id');
    expect(en.editMessageAction, 'Edit message');
    expect(en.editDialogTitle, 'Edit message');
    expect(en.regenerate, 'Regenerate');
    expect(id.editMessageAction, 'Edit pesan');
    expect(id.editDialogTitle, 'Edit pesan');
    expect(id.regenerate, 'Buat ulang');
  });

  test('global search strings are localized in both bundles', () {
    final AppStrings en = appStringsFor('en');
    final AppStrings id = appStringsFor('id');
    expect(en.searchChats, 'Search chats');
    expect(en.searchHint, 'Search all conversations…');
    expect(en.noSearchResults, contains('conversations'));
    expect(id.searchChats, 'Cari chat');
    expect(id.searchHint, 'Cari semua percakapan…');
    expect(id.noSearchResults, contains('percakapan'));
  });

  test('auto-title + prompt library strings are localized in both bundles', () {
    final AppStrings en = appStringsFor('en');
    final AppStrings id = appStringsFor('id');
    expect(en.autoTitleTitle, 'Automatic titles');
    expect(en.promptLibrary, 'Prompt library');
    expect(en.newPrompt, 'New prompt');
    expect(en.insertPrompt, contains('prompt library'));
    expect(id.autoTitleTitle, 'Judul otomatis');
    expect(id.promptLibrary, 'Pustaka prompt');
    expect(id.newPrompt, 'Prompt baru');
    expect(id.insertPrompt, contains('pustaka prompt'));
  });

  test('random UA prompt + creator strings are localized in both bundles', () {
    final AppStrings en = appStringsFor('en');
    final AppStrings id = appStringsFor('id');
    expect(en.uaAskRandomTitle, contains('random User-Agent'));
    expect(en.randomUaDialogTitle, 'Random User-Agent');
    expect(en.randomUaAccept, 'Yes, randomize');
    expect(en.randomUaDecline, 'Keep current');
    expect(en.createdBy('Maragung'), 'Created by Maragung');
    expect(id.uaAskRandomTitle, contains('acak'));
    expect(id.randomUaDialogTitle, 'User-Agent acak');
    expect(id.randomUaAccept, 'Ya, acak');
    expect(id.randomUaDecline, 'Pertahankan');
    expect(id.createdBy('Maragung'), 'Dibuat oleh Maragung');
    expect(en.aboutBody, contains('OpenAI-compatible'));
    expect(id.aboutBody, contains('OpenAI-compatible'));
    // v1.41.5 — Help & About screen strings are localized end to end.
    expect(en.helpAboutSection, 'Help & About');
    expect(id.helpAboutSection, 'Bantuan & Tentang');
    expect(en.helpTileTitle, contains('Help'));
    expect(id.helpTileTitle, contains('Bantuan'));
    expect(en.helpTopics.length, 12);
    expect(id.helpTopics.length, 12);
    for (final HelpEntry t in en.helpTopics) {
      expect(t.title, isNotEmpty);
      expect(t.body.length, greaterThan(80));
    }
    for (final HelpEntry t in id.helpTopics) {
      expect(t.title, isNotEmpty);
      expect(t.body.length, greaterThan(80));
    }
    expect(en.aboutDisclaimer, contains('Maragung'));
    expect(id.aboutDisclaimer, contains('Maragung'));
    expect(en.aboutTagline, isNotEmpty);
    expect(id.aboutTagline, isNotEmpty);
    expect(en.autoRetryAirplaneNote, contains('Airplane mode'));
    expect(id.autoRetryAirplaneNote, contains('Mode pesawat'));
    expect(en.autoRetryAirplaneResumeNote, isNotEmpty);
    expect(id.autoRetryAirplaneResumeNote, isNotEmpty);
  });

  test('module doctor strings are localized in both bundles', () {
    final AppStrings en = appStringsFor('en');
    final AppStrings id = appStringsFor('id');
    expect(en.moduleRepairCardTitle('m', '1'), contains('Module repair'));
    expect(en.moduleRepairCardBody('storage'), contains('storage'));
    expect(en.moduleRepairInstall, 'Install');
    expect(en.moduleRepairDiscard, 'Discard');
    expect(en.moduleRepairInstalled('m'), contains('m'));
    expect(en.moduleRepairInstallFailed('x'), contains('x'));
    expect(en.moduleExportTooltip, 'Export ZIP');
    expect(id.moduleRepairCardTitle('m', '1'), contains('Perbaikan modul'));
    expect(id.moduleRepairCardBody('storage'), contains('izin'));
    expect(id.moduleRepairInstall, 'Install');
    expect(id.moduleRepairDiscard, 'Buang');
    expect(id.moduleRepairInstalled('m'), contains('m'));
    expect(id.moduleRepairInstallFailed('x'), contains('x'));
    expect(id.moduleExportTooltip, 'Ekspor ZIP');
  });

  test('module builder strings are localized in both bundles', () {
    final AppStrings en = appStringsFor('en');
    final AppStrings id = appStringsFor('id');
    expect(en.moduleBuildCardTitle('p', '1'), contains('New plugin ready'));
    expect(en.moduleBuildCardTitle('p', '1'), contains('p'));
    expect(en.moduleBuildCardBody('storage'), contains('storage'));
    expect(en.moduleBuildCardBody('storage'), contains('/plugins'));
    expect(en.moduleBuildInstalled('p'), contains('p'));
    expect(en.moduleBuildInstalled('p'), contains('/plugins'));
    expect(id.moduleBuildCardTitle('p', '1'), contains('Plugin baru siap'));
    expect(id.moduleBuildCardBody('storage'), contains('izin'));
    expect(id.moduleBuildCardBody('storage'), contains('/plugins'));
    expect(id.moduleBuildInstalled('p'), contains('p'));
    expect(id.moduleBuildInstalled('p'), contains('/plugins'));
  });

  test('v1.49 blocked/depends plan strings are localized in all bundles', () {
    final AppStrings en = appStringsFor('en');
    final AppStrings id = appStringsFor('id');
    final AppStrings es = appStringsFor('es');
    expect(en.todoBlocked, 'Blocked');
    expect(id.todoBlocked, 'Terblokir');
    expect(es.todoBlocked, 'Bloqueado');
    expect(en.todoDependsOn, 'Depends on');
    expect(id.todoDependsOn, 'Bergantung pada');
    expect(es.todoDependsOn, 'Depende de');
  });

  test('v1.49 skills manager strings are localized in all bundles', () {
    final AppStrings en = appStringsFor('en');
    final AppStrings id = appStringsFor('id');
    final AppStrings es = appStringsFor('es');
    for (final AppStrings s in <AppStrings>[en, id, es]) {
      expect(s.skillsTitle, isNotEmpty);
      expect(s.skillsSubtitle, isNotEmpty);
      expect(s.skillsInstallUrl, isNotEmpty);
      expect(s.skillsUrlTitle, isNotEmpty);
      expect(s.skillsUrlLabel, isNotEmpty);
      expect(s.skillsInstallZip, isNotEmpty);
      expect(s.skillsSearchHint, isNotEmpty);
      expect(s.skillsEmptyTitle, isNotEmpty);
      expect(s.skillsEmptyBody, isNotEmpty);
      expect(s.skillBundledInstall, isNotEmpty);
      expect(s.skillEnabled, isNotEmpty);
      expect(s.skillDisabled, isNotEmpty);
      expect(s.skillConfigure, isNotEmpty);
      expect(s.skillConfigSave, isNotEmpty);
      expect(s.skillConfigRequired, isNotEmpty);
      expect(s.skillConfigSecret, isNotEmpty);
      expect(s.skillInspect, isNotEmpty);
      expect(s.skillInstructions, isNotEmpty);
      expect(s.skillUpdate, isNotEmpty);
      expect(s.skillRemove, isNotEmpty);
      expect(s.skillRemoveTitle, isNotEmpty);
      expect(s.skillRemoveBody, isNotEmpty);
      expect(s.skillStatusChecking, isNotEmpty);
      expect(s.skillFiles, isNotEmpty);
      expect(s.skillSheetTitle, isNotEmpty);
      expect(s.skillSheetHint, isNotEmpty);
      expect(s.skillSheetUseGlobal, isNotEmpty);
      expect(s.skillSheetClear, isNotEmpty);
      expect(s.skillSheetApply, isNotEmpty);
      expect(s.drawerSkills, isNotEmpty);
      expect(s.settingsSkillsManager, isNotEmpty);
      expect(s.agentRouterHint, isNotEmpty);
    }
    expect(en.skillsTitle, 'Skills');
    expect(id.drawerSkills, 'Skills');
    expect(es.drawerSkills, 'Habilidades');
    expect(en.settingsSkillsManager, 'Skills manager');
    expect(id.settingsSkillsManager, 'Pengelola skill');
    expect(es.agentRouterHint, contains('Anthropic'));
  });
}
