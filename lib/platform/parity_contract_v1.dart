/// Shared feature-parity contract with `cliptown/cliptown-desktop-app.rs`.
/// Platform-specific behavior belongs only in [AppPlatformAdapter].
const int crossPlatformParityContractVersion = 1;
const String rustDesktopCounterpart = 'cliptown/cliptown-desktop-app.rs';
enum AppSurface { mobile, flutterDesktop, rustDesktop }
enum AppCapability {
  authentication, deepLinks, secureStorage, notifications, fileImportExport,
  offlineCache, backgroundSync, telemetry, accessibility, applicationUpdates,
}
const Set<AppCapability> requiredParityCapabilities = <AppCapability>{
  AppCapability.authentication, AppCapability.deepLinks,
  AppCapability.secureStorage, AppCapability.notifications,
  AppCapability.fileImportExport, AppCapability.offlineCache,
  AppCapability.backgroundSync, AppCapability.telemetry,
  AppCapability.accessibility, AppCapability.applicationUpdates,
};
abstract class AppPlatformAdapter {
  const AppPlatformAdapter();
  AppSurface get surface;
  bool supports(AppCapability capability);
}
void verifyRequiredParityCapabilities(AppPlatformAdapter adapter) {
  final missing = requiredParityCapabilities
      .where((capability) => !adapter.supports(capability)).toList();
  if (missing.isNotEmpty) {
    throw StateError('Parity gate failed for ${adapter.surface}: $missing');
  }
}
