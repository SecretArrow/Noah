// Spanish (Español) strings bundle for Noah — v1.44.0.
//
// Full parity with `AppStringsEn` in `app_strings.dart`: same members,
// same order, everything translated. Language registration (language
// picker, `appStringsFor`, delegate) is wired separately — this file
// only provides the bundle class.
import 'app_strings.dart' show AppStrings, HelpEntry;

/// Spanish strings.
class AppStringsEs implements AppStrings {
  @override
  String get cronSectionTitle => 'Trabajos cron';
  @override
  String get cronTileTitle => 'Trabajos cron';
  @override
  String get cronTileSubtitle =>
      'Programa mensajes de Telegram, notificaciones o tareas de agente';
  @override
  String get cronJobsTitle => 'Trabajos cron';
  @override
  String get cronMasterTitle => 'Planificador activo';
  @override
  String get cronMasterSubtitle =>
      'Interruptor maestro: pausa todos los trabajos sin eliminarlos';
  @override
  String get cronJobsEmptyTitle => 'Aún no hay trabajos';
  @override
  String get cronJobsEmptyBody =>
      'Toca + para programar mensajes de Telegram, notificaciones o '
      'tareas de agente.';
  @override
  String get cronAddJobTooltip => 'Añadir trabajo';
  @override
  String get cronNewTitle => 'Nuevo trabajo';
  @override
  String get cronEditTitle => 'Editar trabajo';
  @override
  String get cronFieldName => 'Nombre del trabajo';
  @override
  String get cronFieldSchedule => 'Horario';
  @override
  String get cronScheduleEveryMinute => 'Cada minuto';
  @override
  String get cronScheduleEvery5Minutes => 'Cada 5 minutos';
  @override
  String get cronScheduleHourly => 'Cada hora (minuto 0)';
  @override
  String get cronScheduleDaily8 => 'Diario a las 08:00';
  @override
  String get cronScheduleWeekdays9 => 'Días laborables a las 09:00';
  @override
  String get cronScheduleWeekly => 'Domingos a las 09:00';
  @override
  String get cronScheduleMonthly => 'Día 1 del mes a las 08:00';
  @override
  String get cronScheduleCustom => 'Personalizado (expresión cron)';
  @override
  String get cronFieldExpression => 'Expresión cron';
  @override
  String get cronExpressionHint =>
      'minuto hora día mes día de semana — p. ej. 30 8 * * mon-fri';
  @override
  String get cronNextRuns => 'Próximas ejecuciones';
  @override
  String get cronFieldAction => 'Acción';
  @override
  String get cronActionNotification => 'Notificación';
  @override
  String get cronActionTelegram => 'Telegram';
  @override
  String get cronActionAgent => 'Tarea de agente';
  @override
  String get cronActionAgentHint =>
      'Ejecuta el prompt como un agente sin interfaz (workspace, '
      'navegador, web y herramientas node) y notifica el resultado.';
  @override
  String get cronActionChat => 'Ejecutar en chat';
  @override
  String get cronActionChatHint =>
      'Envía el comando al chat seleccionado como si fuera un mensaje '
      'escrito; el agente responde en esa misma conversación (se aplican '
      'su historial, módulos y skills).';
  @override
  String get cronFieldChatTarget => 'Chat de destino';
  @override
  String get cronChatNewEveryRun => 'Chat nuevo (cada ejecución)';
  @override
  String get cronChatOwnerDefault => 'Este chat (predeterminado)';
  @override
  String get cronFieldChatPrompt => 'Comando a ejecutar';
  @override
  String get cronChatPromptRequired => 'El texto del comando es obligatorio.';
  @override
  String get cronChatTargetMissing =>
      'Chat seleccionado no encontrado (¿borrado?)';
  @override
  String get cronFieldNotifTitle => 'Título de la notificación';
  @override
  String get cronFieldNotifText => 'Texto de la notificación';
  @override
  String get cronFieldTelegramToken => 'Token del bot';
  @override
  String get cronFieldTelegramChat => 'ID de chat';
  @override
  String get cronFieldMessage => 'Texto del mensaje';
  @override
  String get cronFieldAgentPrompt => 'Prompt del agente';
  @override
  String get cronAgentRelayHint =>
      'Rellena el token del bot + ID de chat para reenviar también la '
      'respuesta a Telegram (opcional).';
  @override
  String get cronRunsWhileAppOpen =>
      'Los trabajos se ejecutan mientras la app esté activa (primer '
      'plano o servicio en segundo plano). Las ejecuciones perdidas con '
      'la app cerrada se omiten, no se reproducen.';
  @override
  String get cronNever => 'nunca';
  @override
  String get cronNextRunLabel => 'Próxima';
  @override
  String get cronLastRunLabel => 'Última';
  @override
  String get cronDeleteTitle => '¿Eliminar el trabajo?';
  @override
  String cronDeleteBody(String name) =>
      'El trabajo "$name" y su historial de ejecuciones serán eliminados.';
  @override
  String get cronRunNowTooltip => 'Ejecutar ahora';
  @override
  String get cronNameRequired => 'El nombre es obligatorio.';
  @override
  String get cronExpressionInvalid => 'Expresión cron no válida.';
  @override
  String get cronTelegramFieldsRequired =>
      'El token del bot y el ID de chat son obligatorios.';
  @override
  String get cronMessageRequired => 'El texto del mensaje es obligatorio.';
  @override
  String get cronNotifTextRequired =>
      'El texto de la notificación es obligatorio.';
  @override
  String get cronAgentPromptRequired => 'El prompt del agente es obligatorio.';
  @override
  String get cronSaved => 'Trabajo guardado.';
  @override
  String get cronHistoryTitle => 'Ejecuciones recientes';
  @override
  String get cronHistoryEmpty => 'Aún no hay ejecuciones registradas.';
  @override
  String get cronDisabledBadge => 'desactivado';
  @override
  String get cronPausedBadge => 'planificador en pausa';
  @override
  String cronLocalAiHint(String model) =>
      'Se ejecuta en el modelo local “$model”: inicia primero el servidor '
      'de Local AI.';
  @override
  String get cronLocalAiNoModel =>
      'Se ejecuta en el modelo local: inicia primero el servidor de Local AI.';

  const AppStringsEs();

  // -- Generic ---------------------------------------------------------
  @override
  String get menu => 'Menú';
  @override
  String get settings => 'Ajustes';
  @override
  String get cancel => 'Cancelar';
  @override
  String get delete => 'Eliminar';
  @override
  String get send => 'Enviar';
  @override
  String get stop => 'Detener';
  @override
  String get result => 'resultado';
  @override
  String get resultError => 'resultado (error)';
  @override
  String get screenshotUnavailable => 'captura de pantalla no disponible';
  @override
  String get thinking => 'pensando…';
  @override
  String get readPageText => 'Leer texto de la página';
  @override
  String get open => 'Abrir';
  @override
  String get share => 'Compartir';
  @override
  String get rename => 'Renombrar';
  @override
  String get copy => 'Copiar';
  @override
  String get cut => 'Cortar';
  @override
  String get paste => 'Pegar';
  @override
  String get save => 'Guardar';
  @override
  String get edit => 'Editar';
  @override
  String get add => 'Añadir';
  @override
  String get confirm => 'OK';
  @override
  String get operationFailed => 'La operación falló.';

  // -- Home / chat -----------------------------------------------------
  @override
  String get askAnything => 'Pregunta lo que sea…';
  @override
  String get attachFile => 'Adjuntar archivo';

  @override
  String get speechListen => 'Dictar';

  @override
  String get speechStop => 'Detener dictado';

  @override
  String get speechListening => 'Escuchando…';

  @override
  String get speechUnavailable =>
      'El reconocimiento de voz no está disponible en este dispositivo.';

  @override
  String get speechPermissionDenied => 'Permiso del micrófono denegado.';

  @override
  String get imageTooLarge => 'La imagen supera los 20 MB.';

  @override
  String get imageNotAnImage => 'Ese archivo no es una imagen compatible.';

  @override
  String get updateBannerTitle => 'Actualización disponible';

  @override
  String get updateBannerBody => 'Hay una versión nueva de Noah.';

  @override
  String get updateOpenRelease => 'Ver release';

  @override
  String get updateDismiss => 'Descartar';

  @override
  String get checkUpdatesOnStart => 'Buscar actualizaciones al iniciar';

  @override
  String get checkUpdatesNow => 'Buscar actualizaciones ahora';

  @override
  String get updateChecking => 'Buscando…';

  @override
  String get updateUpToDate => 'Estás en la versión más reciente.';

  @override
  String get updateCheckFailed => 'No se pudo buscar actualizaciones.';

  @override
  String get ipSwitchWarnTitle => 'Avisar cuando la IP sea la misma';

  @override
  String get ipSwitchWarnSubtitle =>
      'Antes de cambiar de chat, compara la IP pública actual con la última '
      'usada en el chat de destino y pide confirmación antes de continuar.';

  @override
  String get ipSwitchWarnDialogTitle => 'Misma IP que la última sesión';

  @override
  String ipSwitchWarnDialogBody(String ip) =>
      'La IP pública actual ($ip) es la misma que la última registrada en '
      'este chat. ¿Continuar de todos modos?';

  @override
  String get ipSwitchWarnContinue => 'Continuar';

  @override
  String get officialModulesTitle => 'Módulos oficiales de ejemplo';

  @override
  String get officialModulesSubtitle =>
      'Instala desde los ZIP de la carpeta samples (samples/<name>.zip en '
      'el repo) y luego gestionalos aquí.';

  @override
  String get moduleUpdatedTo => 'Módulo actualizado a la versión';

  @override
  String get loading => 'Cargando';

  @override
  String get refresh => 'Actualizar';

  @override
  String get parentFolder => 'Carpeta padre';

  @override
  String get todoCompleted => 'Completado';

  @override
  String get todoInProgress => 'En curso';

  @override
  String get todoPending => 'Pendiente';

  @override
  String get todoBlocked => 'Bloqueado';

  @override
  String get todoDependsOn => 'Depende de';

  @override
  String get skillsTitle => 'Habilidades';

  @override
  String get skillsSubtitle => 'Instala una vez, usa en todos los chats';

  @override
  String get skillsManage => 'Administrar skills';

  @override
  String get skillsInstallUrl => 'Instalar desde URL';

  @override
  String get skillsUrlTitle => 'Instalar desde URL';

  @override
  String get skillsUrlLabel => 'URL de Git o fuente de la habilidad';

  @override
  String get skillsInstallZip => 'Instalar desde ZIP';

  @override
  String get skillsSearchHint => 'Buscar habilidades';

  @override
  String get skillsEmptyTitle => 'Aún no hay habilidades';

  @override
  String get skillsEmptyBody =>
      'Instala una habilidad desde URL, ZIP o un paquete incluido para '
      'ampliar el agente.';

  @override
  String get skillBundledInstall => 'Instalar';

  @override
  String get skillEnabled => 'Activado';

  @override
  String get skillDisabled => 'Desactivado';

  @override
  String get skillConfigure => 'Configurar';

  @override
  String get skillConfigSave => 'Guardar configuración';

  @override
  String get skillConfigRequired => 'Obligatorio';

  @override
  String get skillConfigSecret => 'Se guarda cifrado en este dispositivo';

  @override
  String get skillInspect => 'Inspeccionar';

  @override
  String get skillInstructions => 'Instrucciones';

  @override
  String get skillUpdate => 'Actualizar';

  @override
  String get skillRemove => 'Eliminar';

  @override
  String get skillRemoveTitle => '¿Eliminar habilidad?';

  @override
  String get skillRemoveBody =>
      'Su configuración se conserva para que puedas revertir con '
      'seguridad.';

  @override
  String get skillStatusChecking => 'Comprobando…';

  @override
  String get skillFiles => 'Archivos';

  @override
  String get skillSheetTitle => 'Adjuntar habilidades';

  @override
  String get skillSheetHint =>
      'Las habilidades seleccionadas aplican solo a este chat.';

  @override
  String get skillSheetUseGlobal => 'Usar predeterminado global';

  @override
  String get skillSheetClear => 'Quitar selección';

  @override
  String get skillSheetApply => 'Aplicar';

  @override
  String get composerSkillsTooltip => 'Habilidades para este chat';

  @override
  String get drawerSkills => 'Habilidades';

  @override
  String get settingsSkillsManager => 'Gestor de habilidades';

  @override
  String get agentRouterHint =>
      'Gateway agentrouter.org: las peticiones llevan la identidad '
      'claude-cli que exige el gateway. Los modelos Claude hablan '
      'Anthropic Messages; GPT y demás modelos hablan OpenAI-compatible. '
      'Si el gateway desafía el bot (WAF), cambia a datos móviles y '
      'reintenta.';

  @override
  String get settingsEngineLabel => 'Motor';

  @override
  String get engineAuto => 'Automático — detectar por modelo';

  @override
  String get engineAnthropic => 'Anthropic Messages';

  @override
  String get engineOpenai => 'OpenAI Chat Completions';

  @override
  String get engineOpenaiResponses => 'OpenAI Responses';

  @override
  String get engineHint =>
      'Protocolo usado para contactar este proveedor. Automático elige '
      'por modelo (Claude → Anthropic Messages, el resto → OpenAI Chat '
      'Completions) y reintenta vía la API de Responses de OpenAI cuando '
      'el modelo lo exige. Fija un motor si el proveedor solo sirve un '
      'protocolo.';

  @override
  String get newChat => 'Nuevo chat';
  @override
  String get historyTitle => 'Historial';
  @override
  String get historyLoadFailed => 'No se pudo cargar el historial.';
  @override
  String get noChats => 'Aún no hay conversaciones.';
  @override
  String get deleteChatTitle => '¿Eliminar conversación?';
  @override
  String get deleteChatBody =>
      'Esta conversación se eliminará permanentemente.';
  @override
  String get renameChatTitle => 'Renombrar conversación';
  @override
  String get nameHint => 'Nombre';
  @override
  String get pickModel => 'Elige un modelo';
  @override
  String get customModelHint =>
      'Modelo personalizado (p. ej. openai/gpt-4o-mini)';
  @override
  String get searchModelsHint => 'Buscar modelos…';
  @override
  String get filterAll => 'Todos';
  @override
  String get filterTools => 'Herramientas';
  @override
  String get filterFree => 'Gratis';
  @override
  String get refreshCatalog => 'Actualizar catálogo';
  @override
  String get modelsRetry => 'Reintentar';
  @override
  String get modelsLoadError => 'No se pudo cargar la lista de modelos.';
  @override
  String get modelsEmpty => 'Ningún modelo coincide';
  @override
  String get modelsEmptyHint =>
      'Prueba otra palabra clave o filtro — algunos proveedores no anuncian '
      'compatibilidad con herramientas.';
  @override
  String get modelsApiKeyHint =>
      'Introduce tu API key en Ajustes para explorar el catálogo completo '
      'de modelos de tu proveedor.';
  @override
  String get suggestedFallback => 'MODELOS SUGERIDOS';
  @override
  String get suggestedFallbackBody =>
      'Se muestran modelos sugeridos en su lugar. Revisa tu conexión o la '
      'Base URL y reintenta.';
  @override
  String get toolsBadge => 'herramientas';
  @override
  String get freeBadge => 'GRATIS';
  @override
  String get browseModels => 'Explorar modelos';
  @override
  String get browseModelsHint =>
      'Toca el icono de búsqueda para explorar el catálogo de modelos en '
      'vivo.';
  @override
  String pageIndicator(int current, int total) => 'Página $current de $total';
  @override
  String get searchProvidersHint => 'Buscar proveedores…';
  @override
  String get searchSessionsHint => 'Buscar chats…';
  @override
  String get searchFilesHint => 'Buscar archivos…';
  @override
  String get searchContextHint => 'Buscar contextos…';
  @override
  String get searchLibsHint => 'Buscar librerías…';
  @override
  String get noResults => 'Sin resultados';
  @override
  String get agentTagline => 'AI Agent · Flutter';
  @override
  String get emptySubtitle =>
      'Tu agente de IA en el dispositivo — navega, toma capturas,\n'
      'ejecuta código y gestiona archivos directamente desde el chat.';
  @override
  List<String> get suggestions => const <String>[
    'Abre wikipedia.org y resume su página principal',
    'Busca el precio de Bitcoin de hoy y toma una captura',
    'Crea un archivo notes.txt con mi plan del día',
    'Ejecuta JavaScript para parsear este JSON que adjunté',
  ];

  // -- Files manager ----------------------------------------------------
  @override
  String get filesTitle => 'Archivos';
  @override
  String get filesEmpty => 'Aún no hay archivos.';
  @override
  String get filesHint =>
      'Este workspace es privado del chat actual — los archivos de otros '
      'chats nunca se mezclan. Copia, pega, comprime en ZIP y comparte.';
  @override
  String get filesExportFolder => 'Exportar carpeta del chat al dispositivo';
  @override
  String get filesExporting => 'Exportando la carpeta de este chat…';
  @override
  String filesExportDone(int count) =>
      'Carpeta del chat guardada en Downloads/Noah ($count archivos).';
  @override
  String filesExportZipReady(int count) =>
      'Carpeta del chat comprimida en ZIP ($count archivos) — elige dónde '
      'guardarla o enviarla.';
  @override
  String get filesNoChatTitle => 'Ningún chat abierto';
  @override
  String get filesNoChatBody =>
      'Abre o inicia un chat primero — cada chat tiene aquí su propia '
      'carpeta de workspace privada, así que los archivos nunca se mezclan '
      'entre chats.';
  @override
  String get newFolder => 'Nueva carpeta';
  @override
  String get newFolderTitle => 'Nueva carpeta';
  @override
  String get compress => 'Comprimir a ZIP';
  @override
  String get extractHere => 'Extraer';
  @override
  String get noPreview => 'No hay vista previa para este tipo de archivo.';
  @override
  String get filePreviewTitle => 'Vista previa';
  @override
  String get clipboardCopied => 'Copiado.';
  @override
  String get clipboardCut => 'Cortado. Pégalo en otra carpeta.';
  @override
  String get pastedOk => 'Pegado.';
  @override
  String get zipCreatedOk => 'ZIP creado.';
  @override
  String get unzippedOk => 'Extraído.';
  @override
  String get unzipPasswordTitle => 'Se requiere contraseña';
  @override
  String unzipPasswordBody(String name) =>
      '"$name" está cifrado. Introduce la contraseña para extraerlo.';
  @override
  String get passwordFieldHint => 'Contraseña';
  @override
  String get unzipPasswordConfirm => 'Extraer';
  @override
  String get wrongPassword => 'Contraseña incorrecta.';
  @override
  String get deleteEntryTitle => '¿Eliminar?';
  @override
  String get deleteEntryBody => 'Este elemento se eliminará permanentemente.';

  // -- Context Manager ---------------------------------------------------
  @override
  String get contextSection => 'Contexto';
  @override
  String get contextManagerTitle => 'Gestor de contexto';
  @override
  String get contextManagerHint =>
      'Bloques de prompt reutilizables. Las entradas activadas se envían '
      'con cada solicitud para que el agente siempre siga tus reglas.';
  @override
  String contextActiveCount(int n) => '$n activos';
  @override
  String get addContext => 'Añadir contexto';
  @override
  String get editContext => 'Editar contexto';
  @override
  String get contextNameLabel => 'Nombre';
  @override
  String get contextContentLabel =>
      'Contenido (se envía como contexto del prompt)';
  @override
  String get contextEnabledLabel => 'Usar este contexto';
  @override
  String get deleteContextTitle => '¿Eliminar contexto?';
  @override
  String get deleteContextBody =>
      'Esta entrada de contexto se eliminará permanentemente.';
  @override
  String get contextEmpty =>
      'Aún no hay entradas de contexto. Añade reglas que el agente deba '
      'seguir siempre.';

  // -- Node.js runtime ---------------------------------------------------
  @override
  String get nodeSection => 'Runtime de Node.js';
  @override
  String get nodeManagerTitle => 'Runtime de Node.js y módulos';
  @override
  String get nodeManagerHint =>
      'Un runtime de JavaScript integrado que el agente puede usar para '
      'procesar datos. Instala los paquetes npm que necesite y elimínalos '
      'al terminar.';
  @override
  String nodeInstalledCount(int n) => '$n paquete(s) instalado(s)';
  @override
  String get nodeAddHint => 'Nombre del paquete, p. ej. lodash';
  @override
  String get nodeAddButton => 'Instalar';
  @override
  String get nodeVersionHint => 'Versión (opcional)';
  @override
  String get nodeEmpty => 'Aún no hay paquetes instalados.';
  @override
  String get nodeInstalling => 'Instalando…';
  @override
  String get nodeDescription =>
      'node_run permite al agente ejecutar JavaScript con require(), fs y '
      'fetch. Los paquetes se descargan del registro npm y se guardan en '
      'el sandbox de la app.';
  @override
  String get nodeRemoveTitle => '¿Eliminar paquete?';
  @override
  String get nodeRemoveBody => 'Los archivos del paquete se eliminarán.';

  // -- Appearance --------------------------------------------------------
  @override
  String get appearanceSection => 'Apariencia';
  @override
  String get themeLight => 'Claro';
  @override
  String get themeDark => 'Oscuro';
  @override
  String get themeSystem => 'Sistema';

  // -- User Agent ---------------------------------------------------------
  @override
  String get uaSection => 'User Agent';
  @override
  String get uaModeTitle => 'Modo User-Agent';
  @override
  String get uaModeSubtitle =>
      'Se aplica al navegador integrado con el que navega el agente.';
  @override
  String get uaModeAuto => 'Auto (predeterminado del dispositivo)';
  @override
  String get uaModeDesktop => 'PC/Escritorio';
  @override
  String get uaModeAndroid => 'Android móvil';
  @override
  String get uaModeHint =>
      'Auto usa una identidad Android que coincide con este dispositivo y '
      'se mantiene estable durante toda la sesión. PC/Escritorio también '
      'cambia el diseño de la página a renderizado de escritorio.';
  @override
  String get uaCurrentLabel => 'User-Agent activo';
  @override
  String get uaRotateTooltip => 'Usar otro User-Agent';
  @override
  String get uaAskRandomTitle => 'Ofrecer User-Agent aleatorio en chat nuevo';
  @override
  String get uaAskRandomSubtitle =>
      'Cada chat nuevo pregunta si el navegador integrado debe cambiar a '
      'un User-Agent diferente elegido al azar. Puedes rechazar y '
      'mantener el actual.';
  @override
  String get randomUaDialogTitle => 'User-Agent aleatorio';
  @override
  String get randomUaDialogBody =>
      '¿Usar un User-Agent diferente elegido al azar para el navegador '
      'integrado en este chat nuevo? La elección se recuerda hasta que la '
      'cambies de nuevo.';
  @override
  String get randomUaAccept => 'Sí, aleatorizar';
  @override
  String get randomUaDecline => 'Mantener actual';

  // -- Settings --------------------------------------------------------
  @override
  String get providerSection => 'Proveedor de IA';
  @override
  String get providerPreset => 'Preset de proveedor';
  @override
  String get baseUrlLabel => 'Base URL (compatible con OpenAI)';
  @override
  String get apiKeyLabel => 'API key';
  @override
  String get apiKeyStoredLocally =>
      'Cada preset guarda su propia clave, almacenada solo en este '
      'dispositivo. Las claves de InferHub se ven así: sk-airo-…';
  @override
  String get modelLabel => 'Modelo';
  @override
  String get modelHint => 'p. ej. z-ai/glm-4.6 o anthropic/claude-sonnet-4.5';
  @override
  String get presetsTitle => 'Presets (cada uno guarda su propia API key)';
  @override
  String get savePreset => 'Guardar actual como preset';
  @override
  String get savePresetTitle => 'Guardar preset';
  @override
  String get presetNameLabel => 'Nombre del preset';
  @override
  String get editPreset => 'Editar preset';
  @override
  String get deletePresetTitle => '¿Eliminar preset?';
  @override
  String get deletePresetBody => 'Se eliminan el preset y su clave guardada.';
  @override
  String get presetHasKey => 'clave guardada';
  @override
  String get presetNoKey => 'sin clave';

  // -- Providers management (v1.5.0) -----------------------------------
  @override
  String get providersTileSubtitle =>
      'Gestiona proveedores, API keys y modelos';
  @override
  String get providersTitle => 'Proveedores';
  @override
  String get providersHint =>
      'Toca un proveedor para editarlo; mantén pulsado para activarlo con '
      'confirmación. Cada proveedor guarda su propia API key y lista de '
      'modelos.';
  @override
  String get addProvider => 'Añadir proveedor';
  @override
  String get newProviderTitle => 'Nuevo proveedor';
  @override
  String get activeBadge => 'ACTIVO';
  @override
  String get useProviderTooltip => 'Usar este proveedor';
  @override
  String providerActivatedSnack(String name) => 'Conectado a $name';
  @override
  String get saveApiKey => 'Guardar API key';
  @override
  String get apiKeySavedSnack => 'API key guardada para este proveedor';
  @override
  String get fetchModels => 'Obtener modelos';
  @override
  String get fetchingModels => 'Obteniendo…';
  @override
  String modelsFetchedSnack(int n) => '$n modelos disponibles';
  @override
  String get modelsCachedNote =>
      'Se muestra la última lista obtenida para este proveedor.';
  @override
  String modelsCachedCount(int n) => '$n modelos en caché';
  @override
  String get noModelsYet =>
      'Aún no se han obtenido modelos — toca \u201cObtener modelos\u201d para '
      'cargar la lista de este proveedor.';
  @override
  String get nameRequiredError => 'El nombre es obligatorio.';
  @override
  String get urlRequiredError => 'La Base URL es obligatoria.';
  @override
  String get duplicateNameError => 'Ya existe un proveedor con este nombre.';
  @override
  String get providerSavedSnack => 'Proveedor guardado';
  @override
  String get providerDeletedSnack => 'Proveedor eliminado';
  @override
  String get keyStatusSection => 'Estado de la clave';

  @override
  String get maxStepsTitle => 'Pasos máximos del agente';
  @override
  String get maxStepsHint =>
      'Cuántas rondas de llamadas a herramientas puede hacer el agente '
      '(1-100). Escribe un valor personalizado o usa el deslizador.';
  @override
  String get runUntilDoneTitle => 'Ejecutar hasta terminar';
  @override
  String get runUntilDoneSubtitle =>
      'El agente sigue trabajando hasta que la tarea esté realmente '
      'terminada en lugar de detenerse en el límite de pasos '
      '(recomendado). Desactívalo para aplicar el límite de abajo.';
  @override
  String maxStepsReachedMarkdown(int steps) =>
      '*Pausado: se alcanzó el límite de pasos máximos del agente ($steps). '
      'Puede que la tarea no esté terminada — sube el límite en Ajustes o '
      'mantén \u201cEjecutar hasta terminar\u201d activado.*';
  @override
  String get runUntilDoneHint =>
      'Se omite mientras \u201cEjecutar hasta terminar\u201d esté activado — '
      'el agente trabaja hasta terminar la tarea.';
  @override
  String get planFirstTitle => 'Planificar primero (Todos)';
  @override
  String get planFirstSubtitle =>
      'El agente empieza cada tarea con un plan de todos y sigue '
      'trabajando hasta completarlos todos (recomendado).';
  @override
  String get planTitle => 'Plan';
  @override
  String planProgress(int done, int total) => '$done de $total completadas';
  @override
  String get showPlanTooltip => 'Mostrar plan';
  @override
  String get hidePlanTooltip => 'Ocultar plan';
  @override
  String get confirmDialogTitle => 'Se requiere aprobación';
  @override
  String get confirmDialogPrompt =>
      'El agente solicita tu aprobación explícita antes de realizar esta '
      'acción. Revisa cada línea antes de decidir.';
  @override
  String get confirmApprove => 'Aprobar';
  @override
  String get confirmDeny => 'Denegar';
  @override
  String get confirmDenied =>
      'DENEGADO por el usuario. No realices esta acción ni la reintentes '
      'en esta conversación.';
  @override
  String get confirmApproved =>
      'APROBADO por el usuario. Puedes realizar exactamente la acción '
      'descrita — nada más.';
  @override
  String get confirmTimeout =>
      'Sin respuesta en 10 minutos — se trata como DENEGADO. No realices '
      'la acción.';
  @override
  String get confirmUnavailable =>
      'Este chat no está en pantalla, así que el usuario no puede ver la '
      'solicitud de aprobación. Trae este chat al primer plano y pregunta '
      'de nuevo.';
  @override
  String get skillInstallConfirmTitle => '¿Instalar skill externa?';
  @override
  String skillInstallConfirmSource(String source) => 'Origen: $source';
  @override
  String get skillInstallConfirmBody =>
      'Esto descarga código de terceros que se ejecutará en este '
      'dispositivo con acceso a la red y a archivos. Continúa solo si '
      'confías en el origen.';
  @override
  String get skillInstallDeclined =>
      'El usuario rechazó instalar esta skill. No la instales ni la '
      'reintentes en esta conversación.';
  @override
  String get skillWalletConfirmTitle => '¿Aprobar acción de wallet?';
  @override
  String skillWalletConfirmAction(String skill, String script) =>
      'Skill: $skill — script: $script';
  @override
  String get skillWalletConfirmBody =>
      'Esta skill mueve valor en una blockchain (transferencia, swap, '
      'aprobación, venta de NFT o similar). Aprueba solo si el importe, '
      'la red y el destino coinciden con lo que esperas. Un rechazo es '
      'definitivo para esta ejecución.';
  @override
  String get skillWalletDeclined =>
      'El usuario DENEGÓ esta acción de wallet. No la realices ni la '
      'reintentes en esta conversación. Informa del rechazo al usuario y '
      'detente; no se envió ninguna transacción.';
  @override
  String get copyMessage => 'Copiar';
  @override
  String get copied => 'Copiado';
  @override
  String get activateProviderTitle => 'Activar proveedor';
  @override
  String activateProviderBody(String name) =>
      '¿Usar \u201c$name\u201d como proveedor activo? Su API key y su modelo '
      'guardados se aplicarán a la conexión.';
  @override
  String get activateProviderConfirm => 'Activar';
  @override
  String get agentSection => 'Agente';
  @override
  String get agentModeTitle => 'Modo agente';
  @override
  String get agentModeSubtitle =>
      'Activa el uso de herramientas: navegación, capturas, archivos, '
      'código. Desactívalo para chat simple.';
  @override
  String get automationTitle => 'Automatización del navegador';
  @override
  String get automationSubtitle =>
      'Permite al agente controlar el navegador integrado.';
  @override
  String get runInBackgroundTitle => 'Ejecutar en segundo plano';
  @override
  String get runInBackgroundSubtitle =>
      'Mantiene al agente trabajando cuando sales de la app '
      '(muestra una notificación de progreso).';
  @override
  String get languageSection => 'Idioma';
  @override
  String get languageSubtitle =>
      'Idioma de la interfaz de la app. Predeterminado: English.';
  @override
  String get englishOption => 'English (predeterminado)';
  @override
  String get indonesianOption => 'Bahasa Indonesia';
  @override
  String get dataSection => 'Datos';
  @override
  String get exportSessions => 'Exportar sesiones';
  @override
  String get importSessions => 'Importar sesiones';
  @override
  String exportDone(String path) => 'Exportado a $path';
  @override
  String importDone(int count) => '$count sesión(es) importada(s).';
  @override
  String get importFailed =>
      'Importación fallida: no es un archivo de exportación válido.';

  // -- Session import/export icon tooltips (v1.34.0) ---------------------
  @override
  String get importSessionsIconTip => 'Importar sesiones (JSON)';
  @override
  String get exportSessionsIconTip => 'Exportar sesiones (JSON)';

  // -- Markdown export, token stats & encrypted backup (v1.17.0) ---------
  @override
  String get exportChatMarkdown => 'Exportar chat (Markdown)';
  @override
  String get exportChatMarkdownEmpty =>
      'Nada que exportar todavía — este chat no tiene mensajes.';
  @override
  String exportChatMarkdownDone(String path) => 'Chat exportado a $path';
  @override
  String get tokenStatsMenuItem => 'Estadísticas de tokens';
  @override
  String get tokenStatsTitle => 'Estadísticas de tokens';
  @override
  String get statsNoData =>
      'Aún no hay uso de tokens registrado. Los proveedores informan del '
      'uso por solicitud; las estadísticas aparecerán aquí tras tu '
      'próxima conversación.';
  @override
  String get statsPromptTokens => 'Tokens de prompt';
  @override
  String get statsCompletionTokens => 'Tokens de completion';
  @override
  String get statsTotalTokens => 'Tokens totales';
  @override
  String get statsTurns => 'Turnos del asistente';
  @override
  String get statsSessions => 'Sesiones';
  @override
  String get statsPerModel => 'POR MODELO';
  @override
  String statsModelLine(
    String prompt,
    String completion,
    String total,
    int turns,
  ) => '$total tokens en $turns turnos ($prompt entrada / $completion salida)';
  @override
  String get statsUsageHint =>
      'El uso solo se cuenta cuando el proveedor lo informa por solicitud. '
      'Las conversaciones anteriores (antes de v1.17.0) no se incluyen.';
  @override
  String get backupSectionTitle => 'Copia de seguridad y restauración';
  @override
  String get backupCreate => 'Crear copia de seguridad cifrada';
  @override
  String get backupCreateHint =>
      'Guarda todos los chats, todos los ajustes (incluidas las API keys) '
      'y el Gestor de contexto en un solo archivo .zabak cifrado con '
      'AES-256 bajo exports/.';
  @override
  String get backupPassphraseLabel => 'Frase de contraseña (mín. 8 caracteres)';
  @override
  String get backupRestore => 'Restaurar desde copia de seguridad';
  @override
  String get backupRestoreHint =>
      'Restaurar REEMPLAZA todos los chats, ajustes y entradas de contexto '
      'actuales con el contenido de la copia.';
  @override
  String get backupConfirmTitle => '¿Restaurar esta copia de seguridad?';
  @override
  String get backupConfirmBody =>
      'Tus chats, ajustes de proveedor y entradas de contexto actuales '
      'serán REEMPLAZADOS por el contenido de la copia. Esto no se puede '
      'deshacer.';
  @override
  String backupRestoreDone(int sessions, bool settings, int contexts) =>
      'Restauradas $sessions sesiones, $contexts entradas de contexto'
      '${settings ? ' y los ajustes' : ''}.';
  @override
  String get backupWrongPassphrase =>
      'Frase de contraseña incorrecta o el archivo fue manipulado.';
  @override
  String get backupFailed => 'La copia de seguridad falló.';
  @override
  String get backupPassphraseShort =>
      'Usa una frase de contraseña de al menos 8 caracteres.';

  // -- App lock & done notifications (v1.18.0) ---------------------------
  @override
  String get appLockSection => 'Bloqueo de la app';
  @override
  String get appLockTitle => 'Noah está bloqueado';
  @override
  String get appLockEnableTitle => 'Bloquear la app';
  @override
  String get appLockEnableSubtitle =>
      'Pide tu huella o PIN al iniciar la app y al volver del segundo '
      'plano. Configura primero un PIN como respaldo.';
  @override
  String get appLockSetPinTitle => 'Configurar PIN de respaldo';
  @override
  String get appLockPinField => 'PIN (4-8 dígitos)';
  @override
  String get appLockPinTooShort => 'El PIN necesita 4-8 dígitos.';
  @override
  String get appLockPinMismatch => 'Los dos PIN no coinciden.';
  @override
  String get appLockConfirmPin => 'Confirmar PIN';
  @override
  String get appLockDisableConfirm =>
      'Desactivar el bloqueo elimina el PIN guardado. ¿Continuar?';
  @override
  String get appLockPinHint => 'PIN';
  @override
  String get appLockWrongPin => 'PIN incorrecto';
  @override
  String get appLockUnlock => 'Desbloquear';
  @override
  String get appLockUseBiometric => 'Usar biometría';
  @override
  String get appLockBiometricReason => 'Desbloquear Noah';
  @override
  String get notifyOnDoneTitle => 'Notificar cuando termine una tarea';
  @override
  String get notifyOnDoneSubtitle =>
      'Muestra una notificación local cuando una ejecución del agente '
      'termina mientras no estás; al tocarla se reabre esa conversación.';
  @override
  String get notifDoneTitle => 'Tarea del agente finalizada';
  @override
  String notifDoneBody(String sessionTitle, String? error) => error == null
      ? '\u201C$sessionTitle\u201D terminó — toca para abrirla.'
      : '\u201C$sessionTitle\u201D se detuvo con un error — toca para abrirla.';

  @override
  String get exitAppTitle => '¿Salir de Noah?';
  @override
  String get exitAppBody =>
      'Las tareas del agente siguen en ejecución en segundo plano mientras '
      'la app está cerrada.';
  @override
  String get exitAppConfirm => 'Salir';
  @override
  String get batteryTitle => 'Fiabilidad en segundo plano';
  @override
  String get batterySubtitle =>
      'Pide a Android eximir a Noah de la optimización de batería para '
      'que las ejecuciones largas del agente nunca se pause en segundo '
      'plano.';
  @override
  String get batteryRestricted =>
      'Optimizado (puede pausar ejecuciones) — toca para eximir';
  @override
  String get batteryExempted =>
      'Exento — ejecuciones en segundo plano protegidas';

  @override
  String get aboutSection => 'Acerca de';
  @override
  String get aboutBody =>
      'Noah es una app de chat con agente para Android inspirada en el '
      'modo agente de chat.z.ai: trae tu propio proveedor compatible con '
      'OpenAI (OpenRouter, InferHub, Z.AI, OpenAI, DeepSeek, Groq y más), '
      'ejecuta muchos chats en paralelo con ejecución real en segundo '
      'plano, Todos con planificación previa y un panel de Plan en vivo, '
      'un sistema de skills real (instala skills externas por comando '
      'estilo CLI o lenguaje natural, gestionalas y ejecútalas en todos '
      'los chats), flujos Web3 wallet con tarjetas de confirmación '
      'explícitas, sandboxes de archivos y sesiones de navegador aisladas '
      'por chat, herramientas git y web_fetch, un runtime estilo Node.js '
      'con paquetes npm, exportación a Markdown, copia de seguridad '
      'cifrada de toda la app, estadísticas de tokens y un bloqueo '
      'opcional con biometría/PIN. Tus API keys y los secretos de tus '
      'skills permanecen en este dispositivo. Consulta Ayuda para la '
      'guía completa.';

  // -- Help & About screens (v1.41.5) ------------------------------------
  @override
  String get helpAboutSection => 'Ayuda y acerca de';
  @override
  String get helpTileTitle => 'Ayuda y guía de usuario';
  @override
  String get helpTileSubtitle =>
      'Cómo usar cada función, explicado en lenguaje sencillo';
  @override
  String get aboutTileTitle => 'Acerca de Noah';
  @override
  String get aboutTileSubtitle => 'Versión, creador y qué puede hacer esta app';
  @override
  String get aboutTitle => 'Acerca de';
  @override
  String get aboutTagline =>
      'Tu propio equipo de agentes de IA en Android — planifica, navega, '
      'ejecuta, entrega.';
  @override
  String get aboutCreatorLabel => 'Creador';
  @override
  String get aboutVersionLabel => 'Versión';
  @override
  String get aboutWhatsInside => 'Qué hay dentro';
  @override
  String get aboutDisclaimer =>
      'Noah es una app independiente de Maragung, inspirada en la '
      'interfaz del modo agente de chat.z.ai, y no está afiliada a Z.AI. '
      'Las skills y los módulos se ejecutan localmente en este '
      'dispositivo; la app nunca pide seed phrases ni claves privadas, y '
      'toda acción de wallet que mueva valor requiere primero tu '
      'confirmación explícita.';
  @override
  String get helpTitle => 'Ayuda';
  @override
  String get helpIntro =>
      'Todo lo que Noah puede hacer y cómo usarlo. Las secciones '
      'siguen el orden en que las encontrarás en la app.';
  @override
  List<HelpEntry> get helpTopics => const [
    HelpEntry(
      '1. Empezar: conectar un proveedor',
      'Abre Ajustes → Proveedores, añade tu proveedor (OpenRouter, '
          'InferHub, Z.AI, OpenAI, DeepSeek, Groq o cualquier endpoint '
          'compatible con OpenAI), pega su API key y elige un modelo del '
          'catálogo en vivo (con búsqueda y filtros incluidos). Las keys '
          'se guardan solo en este dispositivo. Sin una key que funcione '
          'el chat no puede responder, así que empieza aquí.',
    ),
    HelpEntry(
      '2. Chats y tareas en segundo plano',
      'Crea todos los chats que quieras desde el menú lateral — se '
          'ejecutan en paralelo. Una tarea sigue en ejecución cuando '
          'cambias de chat o sales de la app; una notificación te avisa '
          'al terminar. Cada chat está totalmente aislado: su '
          'transcripción, estado, procesos, salida y archivos nunca se '
          'filtran a otro chat, y Detener solo afecta al chat donde lo '
          'pulsaste.',
    ),
    HelpEntry(
      '3. Planes (Todos) y el panel Plan',
      'Cada tarea empieza con un plan: el agente lista los pasos y luego '
          'los va completando. Abre el panel Plan en vivo desde el icono '
          'de plan — permanece abierto hasta que TÚ lo cierres, sobrevive '
          'a los cambios de chat y se actualiza en tiempo real cuando un '
          'paso se completa o falla. Los planes se guardan en disco '
          'continuamente, así que incluso un cierre inesperado de la app '
          'o una batería agotada conserva tu plan y tu progreso.',
    ),
    HelpEntry(
      '4. Skills: instalar, configurar, ejecutar',
      'Las skills son paquetes reutilizables de instrucciones + scripts '
          'que el agente puede descubrir, instalar y usar. Instálalas '
          'pidiéndolo en lenguaje natural (\u201cinstala la skill X\u201d) o '
          'pegando un comando estilo CLI como \u201cnpx skills add '
          'owner/repo/path/to/skill\u201d — el agente comprueba las '
          'dependencias, lee las instrucciones de la skill y verifica la '
          'instalación con honestidad. Las skills Web3 wallet incluidas '
          'están listas para usar. Gestiónalas en el chat: skill_list, '
          'skill_info, skill_config (API keys y ajustes, guardados en el '
          'dispositivo y nunca mostrados), skill_update y skill_run. Las '
          'skills instaladas persisten en TODOS los chats — instala una '
          'vez, úsalas en todas partes.',
    ),
    HelpEntry(
      '5. Flujos Web3 wallet y seguridad',
      'Usa las skills de wallet incluidas (Binance Agentic Wallet, Web3 '
          'basics) o instala otras compatibles para consultar saldos, '
          'leer transacciones e interactuar con apps Web3. El login '
          'siempre usa la página oficial del proveedor — el agente te '
          'muestra el enlace y tú te conectas. La app NUNCA pide seed '
          'phrases ni claves privadas. Antes de nada irreversible '
          '(transferencia, swap, listado de NFT, aprobación de token) el '
          'agente debe mostrar una tarjeta de confirmación con red, '
          'activo, importe, destino y comisión — nada se mueve hasta que '
          'apruebes. Iniciar sesión nunca es permiso para operar.',
    ),
    HelpEntry(
      '6. Automatización del navegador y User-Agent',
      'El agente puede navegar, rellenar formularios y obtener páginas '
          'con un navegador integrado real. Cada chat tiene su propio '
          'contexto de navegador aislado — las cookies y los logins de '
          'un chat nunca se filtran a otro. En Ajustes → User Agent '
          'eliges la identidad del navegador: Auto usa la identidad '
          'Android real; los pools Desktop/Android rotan entre huellas '
          'de generación actual — navegadores Chromium (Chrome, Edge, '
          'Opera, Samsung Internet, Vivaldi) todos en Chromium 153+, '
          'Firefox en las ramas más recientes (150+ y ESR en vigor), '
          'Safari 26/27. Rota manualmente o deja que los chats nuevos '
          'elijan una identidad aleatoria.',
    ),
    HelpEntry(
      '7. Módulos (plugins)',
      'Los módulos son add-ons de JavaScript empaquetados en ZIP con el '
          'SDK oficial de zagents — sube uno desde la pantalla Módulos y '
          'se ejecuta en el sandbox propio de cada chat, con formularios '
          'de configuración, almacenamiento, estado y permisos por chat. '
          'El agente ve el estado de configuración de cada módulo '
          '(secretos enmascarados) — estrictamente por chat: un '
          'formulario en un chat nunca muestra valores escritos en otro. '
          'La pantalla Node gestiona el runtime integrado y sus paquetes '
          'npm; los comandos de dispositivo permanecen desactivados '
          'salvo que los actives explícitamente (solo teléfonos '
          'rooteados).',
    ),
    HelpEntry(
      '8. Archivos y sandbox por chat',
      'Cada chat tiene una carpeta de workspace privada — las subidas, '
          'los archivos generados y el estado de los módulos viven ahí, '
          'invisibles para otros chats. Exporta un workspace al gestor '
          'de archivos de tu dispositivo (Downloads/Noah/<chat>) con '
          'un toque, y al eliminar un chat se borra todo su workspace. '
          'Las subidas de archivos admiten la extracción ZIP, incluidos '
          'los archivos protegidos con contraseña.',
    ),
    HelpEntry(
      '9. Búsqueda, exportación y copia de seguridad',
      'La búsqueda global (icono de lupa) encuentra títulos y texto '
          'completo de mensajes en todos los chats. Exporta cualquier '
          'chat como Markdown desde el menú lateral. Ajustes → Datos '
          'crea una copia de seguridad cifrada de toda la app (chats, '
          'ajustes, configuración de skills) que puedes restaurar tras '
          'reinstalar o al pasar a un teléfono nuevo.',
    ),
    HelpEntry(
      '10. Estadísticas, bloqueo de la app y notificaciones',
      'Estadísticas muestra el uso de tokens por modelo y por chat. El '
          'bloqueo opcional de la app (biometría o PIN) protege la app '
          'al iniciarla. Las tareas en segundo plano publican una '
          'notificación al terminar; las ejecuciones largas pueden '
          'eximirse de la optimización de batería para que Android nunca '
          'las pause.',
    ),
    HelpEntry(
      '11. Notificaciones por chat y Detener / Force stop',
      'Cada chat EN EJECUCIÓN publica su propia notificación — el título '
          'del chat más el paso en el que va (qué herramienta se está '
          'ejecutando ahora). Tócala para ir directo a ese chat, incluso '
          'tras horas en segundo plano: el servicio en primer plano y el '
          'wake lock impiden que Android pause el trabajo, y Android 13+ '
          'pide una vez el permiso de notificaciones — concederlo es lo '
          'que hace visibles estos avisos. ¿Necesitas terminar una '
          'ejecución? El botón rojo Detener detiene el proceso con UN '
          'toque. Si no se detiene, toca Detener otra vez (aparece una '
          'pista) y el tercer toque ofrece Force stop — corta la '
          'conexión al instante y termina la ejecución; el progreso '
          'parcial queda guardado en la transcripción.',
    ),
    HelpEntry(
      '12. Consejos y solución de problemas',
      '¿Error del proveedor? Revisa la API key y la cuota del modelo en '
          'el panel del proveedor. ¿Un módulo falla? Usa su tarjeta de '
          'reparación o vuelve a subir el ZIP. ¿Red inestable? El '
          'reintento automático con la guarda de modo avión se reanuda '
          'con seguridad. ¿El texto en streaming parece atascado? Espera '
          'o pulsa Detener — la transcripción se guarda tras cada paso. '
          '¿Encontraste un bug o quieres una función? Abre un issue en '
          'el repositorio del proyecto.',
    ),
  ];

  @override
  String createdBy(String name) => 'Creado por $name';

  // -- Message actions (v1.15.0) ----------------------------------------
  @override
  String get editMessageAction => 'Editar mensaje';
  @override
  String get editDialogTitle => 'Editar mensaje';
  @override
  String get regenerate => 'Regenerar';

  // -- Global chat search (v1.15.0) -------------------------------------
  @override
  String get searchChats => 'Buscar chats';
  @override
  String get searchHint => 'Buscar en todas las conversaciones…';
  @override
  String get noSearchResults => 'No se encontraron conversaciones.';
  @override
  String get searchInitialHint =>
      'Escribe para buscar en los títulos y mensajes de tus conversaciones.';

  // -- Automatic conversation titles (v1.15.0) --------------------------
  @override
  String get autoTitleTitle => 'Títulos automáticos';
  @override
  String get autoTitleSubtitle =>
      'Nombra automáticamente las conversaciones nuevas con un título '
      'corto generado por el modelo tras la primera respuesta.';

  // -- Prompt library (v1.15.0) -----------------------------------------
  @override
  String get promptLibrary => 'Biblioteca de prompts';
  @override
  String get promptLibraryEmpty => 'Aún no hay prompts.';
  @override
  String get newPrompt => 'Nuevo prompt';
  @override
  String get editPrompt => 'Editar prompt';
  @override
  String get promptTitleLabel => 'Título';
  @override
  String get promptContentLabel => 'Contenido del prompt';
  @override
  String get insertPrompt => 'Insertar desde la biblioteca de prompts';
  @override
  String get deletePromptTitle => '¿Eliminar prompt?';
  @override
  String get deletePromptBody => 'Este prompt se eliminará permanentemente.';
  @override
  String get promptSaved => 'Prompt guardado.';
  @override
  String get promptDeleted => 'Prompt eliminado.';

  // -- Chat modules / plugins (v1.21.0) ---------------------------------
  @override
  String get modulesTitle => 'Módulos';
  @override
  String get modulesInstall => 'Instalar módulo (ZIP)';
  @override
  String get modulesEmpty => 'Aún no hay módulos instalados.';
  @override
  String get modulesEmptyHint =>
      'Instala un ZIP de módulo para ejecutar capacidades nativas de '
      'JavaScript dentro de cualquier chat — aislado por chat como una '
      'ventana privada.';
  @override
  String get modulesManage => 'Gestionar módulos';
  @override
  String get moduleSdkDocs => 'Documentación del SDK';
  @override
  String get moduleStartNewChat => 'Iniciar en un chat nuevo';
  @override
  String get moduleActivate => 'Activar en este chat';
  @override
  String get moduleDeactivate => 'Desactivar';
  @override
  String get moduleActiveBadge => 'activo';
  @override
  String moduleDeactivated(String name) =>
      'Módulo \u201c$name\u201d desactivado — su ejecución se detuvo de forma '
      'segura y sus datos por chat permanecen dentro de este chat.';
  @override
  String get moduleTerminated =>
      'La ejecución del módulo fue terminada por el usuario.';
  @override
  String moduleRunFailed(String error) =>
      'Error en la ejecución del módulo: $error';
  @override
  String moduleNotFound(String name) => 'Módulo no instalado: $name';
  @override
  String get moduleSessionBusy =>
      'Espera a que termine la tarea actual antes de activar un módulo.';
  @override
  String modulePermissionTitle(String name) =>
      'Permitir que \u201c$name\u201d:';
  @override
  String get modulePermissionBody =>
      'Estas capacidades se ejecutan aisladas solo dentro de ESTE chat — '
      'nada se filtra a otros chats.';
  @override
  String get moduleAllow => 'Permitir y ejecutar';
  @override
  String moduleInstallSuccess(String name) => '$name instalado.';
  @override
  String moduleInstallFailed(String error) => 'Error de instalación: $error';
  @override
  String get moduleRemoveTitle => '¿Eliminar módulo?';
  @override
  String moduleRemoveBody(String name) =>
      '\u201c$name\u201d y sus archivos de programa se eliminarán. Los datos '
      'ya guardados dentro de chats individuales permanecen en el sandbox '
      'de cada chat.';
  @override
  String moduleRemoved(String name) => 'Módulo eliminado: $name';
  @override
  String get pluginMenuTitle => 'Módulos para este chat';
  @override
  String get pluginMenuEmpty =>
      'Aún no hay módulos instalados. Instala uno desde la pantalla '
      'Módulos.';
  @override
  String get startWithModule => 'Iniciar con un módulo';

  // -- Module per-chat setup form (v1.24.0) ------------------------------
  @override
  String moduleSetupNeededTitle(String name) =>
      '$name necesita configuración antes de ejecutarse en este chat.';
  @override
  String get moduleSetupNeededBody =>
      'Rellena la información requerida en el formulario — una vez '
      'enviado, el módulo se permite y se ejecuta automáticamente.';
  @override
  String moduleSetupLegacyHint(String name) =>
      '\u201c$name\u201d se instaló desde un ZIP más antiguo que no tiene '
      'formulario de configuración (los módulos instalados conservan su '
      'versión entre actualizaciones de la app). Soluciones: 1) instala '
      'el ZIP del módulo \u201c$name\u201d más reciente — su nueva versión '
      'incluye un formulario de configuración que la app muestra antes '
      'de la primera ejecución; 2) o envía el comando de configuración '
      'del propio módulo como primer mensaje de un chat nuevo (por '
      'ejemplo \u201csetup tu-correo tu-contraseña\u201d), y luego activa '
      'el módulo de nuevo.';
  @override
  String get moduleSetupBannerCta => 'Configurar';
  @override
  String get moduleSetupSaveRun => 'Guardar y ejecutar';
  @override
  String get moduleSetupPerChatHint =>
      'Guardado solo para ESTE chat — otros chats lo preguntan de nuevo.';
  @override
  String get moduleSetupRequiredTag => 'obligatorio';
  @override
  String get moduleSetupWaitingHint =>
      'Tu mensaje está en cola — el agente lo procesa justo después de '
      'enviar esta configuración.';

  // -- Module device commands (v1.31.0) -----------------------------------
  @override
  String get deviceCommandsTitle => 'Comandos de dispositivo (root)';
  @override
  String get deviceCommandsSubtitle =>
      'Permite que los módulos aprobados ejecuten comandos shell en este '
      'dispositivo vía zagents.device.shell — alternar el modo avión y '
      'automatizaciones similares. Requiere un teléfono rooteado; cada '
      'activación sigue pidiendo tu consentimiento.';

  // -- Auto retry & red stop button (v1.30.0) ------------------------------
  @override
  String get autoRetrySection => 'Reintento automático';
  @override
  String get autoRetryTitle => 'Reintentar automáticamente ante fallos';
  @override
  String get autoRetrySubtitle =>
      'Los errores de red, conexión débil, streams cortados o errores '
      'transitorios del proveedor ya no matan la tarea: el agente espera '
      'y lo intenta de nuevo, y el trabajo sin terminar se reanuda.';
  @override
  String get autoRetryAttemptsTitle => 'Intentos máximos de reintento';
  @override
  String get autoRetryDelayTitle => 'Espera entre reintentos (segundos)';
  @override
  String get autoRetryHint =>
      'La espera crece con cada intento (retraso x intento). Cuando una '
      'tarea se detiene con un plan sin terminar, también se retoma '
      'automáticamente. Detener siempre gana — nada se reintenta después '
      'de pulsarlo.';
  @override
  String autoRetryStreamNote(int attempt, int max) =>
      '*Reintento automático $attempt/$max — reconectando con el '
      'proveedor…*';
  @override
  String autoRetryResumeNote(int attempt, int max) =>
      '*Reintento automático $attempt/$max — la ejecución se interrumpió '
      '(error de red). Reanudando la tarea…*';
  @override
  String autoRetryPlanNote(int attempt, int max) =>
      '*Reanudación automática $attempt/$max — el plan aún no está '
      'terminado. Continuando la tarea…*';
  @override
  String get autoRetryAirplaneNote =>
      '*El modo avión está ACTIVADO — los reintentos quedan en espera '
      'hasta desactivarlo. No se consume ningún intento; la tarea '
      'continúa automáticamente en cuanto vuelva la conexión.*';
  @override
  String get autoRetryAirplaneResumeNote =>
      '*El modo avión está ACTIVADO — la tarea se reanuda automáticamente '
      'en cuanto se desactive (sin gastar reintentos mientras esté sin '
      'conexión).*';

  // -- Module doctor (v1.26.0) --------------------------------------------
  @override
  String moduleRepairCardTitle(String name, String version) =>
      'Reparación de módulo lista: $name v$version';
  @override
  String moduleRepairCardBody(String permissions) =>
      'El agente preparó un módulo reparado y pasó la validación. '
      'Instalarlo reemplaza la copia instalada — sus datos por chat en '
      'ESTE chat se conservan. Revisa los permisos antes de instalar: '
      '$permissions';
  @override
  String get moduleRepairInstall => 'Instalar';
  @override
  String get moduleRepairDiscard => 'Descartar';
  @override
  String moduleRepairInstalled(String name) =>
      'Módulo \u201c$name\u201d instalado desde la reparación del agente. Si '
      'necesita configuración en este chat, el formulario aparece antes '
      'de la siguiente ejecución.';
  @override
  String moduleRepairInstallFailed(String error) =>
      'No se pudo instalar el módulo reparado: $error';
  @override
  String get moduleExportTooltip => 'Exportar ZIP';

  // -- Module export dialog (v1.47.0) --------------------------------------
  @override
  String get moduleExportTitle => 'Exportar módulo';
  @override
  String get moduleExportHint =>
      'Se guarda como un ZIP nuevo instalable — sin cuentas, sesiones ni '
      'datos de chat. Nombre del archivo:';
  @override
  String get moduleExportAction => 'Exportar';

  // -- Module update & remote install (v1.46.0) ---------------------------
  @override
  String get moduleInstallFromUrl => 'Instalar desde URL';
  @override
  String get moduleUrlDialogTitle => 'Instalar módulo desde URL';
  @override
  String get moduleUrlDialogHint => 'https://ejemplo.com/modulo.zip';
  @override
  String get moduleUrlDialogBody =>
      'El ZIP del módulo se descarga por HTTPS y se desempaqueta con la '
      'misma validación que un archivo local. Instala solo módulos de '
      'fuentes confiables.';
  @override
  String get moduleDownload => 'Descargar e instalar';
  @override
  String get moduleUpdateTooltip => 'Actualizar módulo';
  @override
  String get moduleUpdateTitle => 'Actualizar módulo';
  @override
  String moduleUpdateBody(String name) =>
      'Elige la fuente de actualización para \u201c$name\u201d. Instalar '
      'reemplaza los archivos del módulo; los datos por chat se conservan.';
  @override
  String get moduleUpdateFromZip => 'Desde archivo ZIP';
  @override
  String get moduleUpdateFromUrl => 'Desde URL';
  @override
  String get moduleDownloading => 'Descargando\u2026';
  @override
  String get moduleSampleInstall => 'Instalar';
  @override
  String get moduleSampleUpdate => 'Actualizar';
  @override
  String get moduleSampleInstalled => 'Instalado';
  @override
  String get moduleSampleRepoHint =>
      'Un toque instala o actualiza el módulo directamente desde el '
      'repositorio oficial de ejemplos.';

  // -- Module builder (/make_plugins) -------------------------------------
  @override
  String moduleBuildCardTitle(String name, String version) =>
      'Nuevo plugin listo: $name v$version';
  @override
  String moduleBuildCardBody(String permissions) =>
      'El agente construyó este plugin en este chat y pasó la validación. '
      'Revisa los permisos antes de instalarlo: $permissions. Tras '
      'instalarlo, inícialo con /plugins (menú) o /plugins <name>.';
  @override
  String moduleBuildInstalled(String name) =>
      'Plugin \u201c$name\u201d instalado. Inícialo con /plugins (menú) o '
      '/plugins <name> — en este chat o en cualquier chat nuevo; cada '
      'chat obtiene su propio almacenamiento aislado y su formulario de '
      'configuración.';
  @override
  String get missingApiKey =>
      'API key sin configurar. Abre Ajustes para configurar tu proveedor.';
  @override
  String get modelNotSet =>
      'Ningún modelo seleccionado. Elige uno en Ajustes o en el menú de '
      'modelos.';
  @override
  String get stoppedMarkdown => '_(detenido)_';
  @override
  String get chatOpenError => 'No se pudo abrir esta conversación.';
  @override
  String get chatDeleteError => 'No se pudo eliminar esta conversación.';
  @override
  String get chatRenameError => 'No se pudo renombrar esta conversación.';

  // -- Background service notification ----------------------------------
  @override
  String get notifTitle => 'El agente de Noah está en ejecución';
  @override
  String get notifProcessing => 'Procesando tu solicitud…';
  @override
  String notifStep(int step, String tool) => 'Paso $step · $tool';

  // -- Stop / force stop (v1.42.0) ---------------------------------------
  @override
  String get stopHintForce =>
      'Detención solicitada — toca Detener una vez más para ofrecer un '
      'force stop.';
  @override
  String get forceStopTitle => '¿Forzar la detención de este proceso?';
  @override
  String get forceStopBody =>
      'El proceso sigue en ejecución tras tocar Detener repetidamente. '
      'Un force stop corta la conexión al instante y termina esta '
      'ejecución — el progreso parcial se conserva en la transcripción.';
  @override
  String get forceStopConfirm => 'Force stop';
  @override
  String get forceStopCancel => 'Cancelar';
  @override
  String get forceStopDone => 'Force stop ejecutado.';

  @override
  String get ollamaSectionTitle => 'IA local';
  @override
  String get ollamaTileTitle => 'Gestionar Ollama';
  @override
  String get ollamaTileSubtitle => 'Runtime de IA local compatible con Ollama';
  @override
  String get ollamaScreenTitle => 'Gestionar Ollama';
  @override
  String get ollamaTabServer => 'Servidor';
  @override
  String get ollamaExternalServerLabel => 'Servidor Ollama externo';
  @override
  String get ollamaProbe => 'Probar';
  @override
  String ollamaProbeOk(String version) => 'Ollama $version es accesible.';
  @override
  String ollamaProbeFail(String error) =>
      'No se encontró ningún servidor Ollama: $error';
  @override
  String get ollamaUseAsProvider => 'Usar como proveedor';
  @override
  String get ollamaOnDeviceTitle => 'Runtime en el dispositivo';
  @override
  String get ollamaOnDevicePending =>
      'El runtime LLM integrado en el dispositivo aún no está '
      'disponible en esta compilación. Aun así puedes apuntar Noah '
      'a un servidor Ollama externo abajo.';

  @override
  String get cronOpenOllamaManage => 'Abrir Gestionar Ollama';
  @override
  String get ollamaActiveModelLabel => 'Modelo activo';
  @override
  String ollamaAddedAt(String date) => 'Añadido el $date';
  @override
  String ollamaBattery(int percent) => 'Batería $percent%';
  @override
  String ollamaBatteryCharging(int percent) => 'Batería $percent% · cargando';
  @override
  String ollamaBatteryLow(int percent) => 'Batería $percent% — baja';
  @override
  String get ollamaBenchmark => 'Benchmark';
  @override
  String ollamaBenchmarkFailed(String error) => 'Error de benchmark: $error';
  @override
  String get ollamaBenchmarkRunning => 'Midiendo…';
  @override
  String ollamaBenchmarkSummary(
    String tokPerSec,
    int firstTokenMs,
    int tokens,
  ) => '$tokPerSec tok/s · primer token ${firstTokenMs}ms · $tokens tokens';
  @override
  String get ollamaCatalogRefresh => 'Actualizar catálogo';
  @override
  String ollamaCatalogRefreshDone(int count) =>
      'Catálogo actualizado: $count modelos.';
  @override
  String ollamaCatalogRefreshFailed(String error) =>
      'Error al actualizar el catálogo: $error';
  @override
  String get ollamaCatalogReset => 'Restablecer';
  @override
  String get ollamaCatalogResetDone => 'De vuelta al catálogo integrado.';
  @override
  String get ollamaClearFinished => 'Limpiar terminadas';
  @override
  String get ollamaClose => 'Cerrar';
  @override
  String get ollamaConfigInvalid =>
      'El puerto debe ser 1024–65535, el contexto 512–32768 y los hilos 0–8.';
  @override
  String get ollamaConfigSave => 'Guardar configuración';
  @override
  String get ollamaConfigSaved => 'Configuración del servidor guardada.';
  @override
  String get ollamaContextLabel => 'Tamaño de contexto';
  @override
  String get ollamaCopyAll => 'Copiar todo';
  @override
  String ollamaCtxTokens(String tokens) => '$tokens ctx';
  @override
  String get ollamaCustomUrlInvalid =>
      'Introduce una URL http(s) que termine en .gguf';
  @override
  String get ollamaCustomUrlLabel => 'URL personalizada (.gguf)';
  @override
  String ollamaDeleteBody(String name) =>
      '“$name” y su archivo se eliminarán de este dispositivo.';
  @override
  String get ollamaDeleteTitle => '¿Eliminar este modelo?';
  @override
  String ollamaDeviceRam(String size) => 'RAM del dispositivo $size';
  @override
  String get ollamaDlCanceled => 'Cancelada';
  @override
  String get ollamaDlCompleted => 'Completada';
  @override
  String get ollamaDlFailed => 'Error';
  @override
  String get ollamaDlPaused => 'En pausa';
  @override
  String get ollamaDlQueued => 'En cola';
  @override
  String get ollamaDlRunning => 'Descargando';
  @override
  String get ollamaDownload => 'Descargar';
  @override
  String ollamaDownloadStarted(String name) =>
      '“$name” añadido a la cola de descargas.';
  @override
  String get ollamaDownloadingLabel => 'Descargando…';
  @override
  String get ollamaDownloadsEmpty => 'Aún no hay descargas.';
  @override
  String get ollamaExport => 'Exportar';
  @override
  String get ollamaExportDone => 'Modelo exportado.';
  @override
  String get ollamaExportNone => 'No se exportó ningún modelo.';
  @override
  String get ollamaExportSelected => 'Exportar seleccionados';
  @override
  String ollamaExportSelectedDone(int count) => '$count modelos exportados.';
  @override
  String get ollamaFitFilter => 'Solo modelos que caben';
  @override
  String get ollamaGoToCatalog => 'Ir al Catálogo';
  @override
  String get ollamaImportButton => 'Importar archivo .gguf';
  @override
  String ollamaImportDone(String name) => '“$name” importado.';
  @override
  String get ollamaImportFailed => 'Error al importar.';
  @override
  String get ollamaInstalledEmptyBody =>
      'Descarga un modelo del Catálogo o importa un archivo .gguf.';
  @override
  String get ollamaInstalledEmptyTitle => 'Ningún modelo instalado';
  @override
  String get ollamaInstalledLabel => 'Instalado';
  @override
  String get ollamaLogTitle => 'Registro del servidor';
  @override
  String get ollamaModelEmptyHint =>
      'Aún no hay modelos instalados: descarga uno del Catálogo.';
  @override
  String get ollamaModelLabel => 'Modelo';
  @override
  String get ollamaOomWarning =>
      'Modelo pesado: alto riesgo de quedarse sin memoria en este '
      'dispositivo.';
  @override
  String get ollamaPause => 'Pausar';
  @override
  String get ollamaPortLabel => 'Puerto';
  @override
  String ollamaRamEst(String size) => 'RAM ~$size';
  @override
  String get ollamaResume => 'Reanudar';
  @override
  String ollamaRiskBody(String ref) =>
      '“$ref” puede superar la memoria de este dispositivo y no cargar. '
      '¿Descargarlo de todos modos?';
  @override
  String get ollamaRiskTitle => '¿Descargar este modelo pesado?';
  @override
  String get ollamaRuntimeUnavailable =>
      'Esta compilación o dispositivo no incluye el runtime de IA local '
      '(armeabi-v7a no es compatible). Aún puedes conectarte a un servidor '
      'Ollama externo más abajo.';
  @override
  String get ollamaSelectMode => 'Seleccionar modelos';
  @override
  String ollamaSelectedCount(int count) => '$count seleccionados';
  @override
  String ollamaSizeProgress(int receivedMb, int totalMb) =>
      '$receivedMb de $totalMb MB';
  @override
  String get ollamaSizeUnknown => 'tamaño desconocido';
  @override
  String get ollamaSourceCatalog => 'Catálogo';
  @override
  String get ollamaSourceCustomUrl => 'URL personalizada';
  @override
  String get ollamaSourceImported => 'Importado';
  @override
  String get ollamaStart => 'Iniciar';
  @override
  String get ollamaStartFailedSnack => 'El servidor no pudo iniciarse.';
  @override
  String get ollamaStartWith => 'Iniciar con este modelo';
  @override
  String get ollamaStartedSnack => 'Servidor iniciado.';
  @override
  String get ollamaStatusFailed => 'Error';
  @override
  String get ollamaStatusRunning => 'En ejecución';
  @override
  String get ollamaStatusStarting => 'Iniciando…';
  @override
  String get ollamaStatusStopped => 'Detenido';
  @override
  String get ollamaStatusStopping => 'Deteniendo…';
  @override
  String get ollamaStatusUnavailable => 'No disponible';
  @override
  String get ollamaStop => 'Detener';
  @override
  String get ollamaStoppedSnack => 'Servidor detenido.';
  @override
  String get ollamaTabCatalog => 'Catálogo';
  @override
  String get ollamaTabDownloads => 'Descargas';
  @override
  String get ollamaTabInstalled => 'Instalados';
  @override
  String get ollamaThreadsLabel => 'Hilos (0 = automático)';
  @override
  String get ollamaTierHeavy => 'Pesado';
  @override
  String get ollamaTierLight => 'Ligero';
  @override
  String get ollamaTierMedium => 'Medio';
  @override
  String get ollamaTooLarge => 'Demasiado grande para este dispositivo';
  @override
  String get ollamaUseInChat => 'Usar en el chat';
  @override
  String ollamaUseInChatBody(String alias) =>
      'Tu proveedor activo cambia a Local AI con el modelo “$alias”.';
  @override
  String get ollamaUseInChatDone => 'Local AI ya está activo para el chat.';
  @override
  String get ollamaUseInChatTitle => '¿Usar este modelo en el chat?';
  @override
  String get ollamaViewFullLog => 'Ver registro completo';
}
