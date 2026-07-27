# ClipTown Flutter application

Shared Flutter product surface for ClipTown desktop and mobile clients.

## Current foundation

The application provides a testable local ClipTown shell with search, pinning, clip-kind previews, and a clear disconnected-sync state. It does not claim cloud synchronization or production encryption until the authentication, key-management, and SDK contracts are integrated.

The sibling `cliptown-interfaces` checkout is required at `../cliptown-interfaces` for the generated Dart wire package.

## Validation

```sh
flutter pub get
dart format lib test integration_test
flutter analyze --fatal-infos --fatal-warnings
flutter test --coverage
```

GitHub Actions additionally builds Linux, macOS, Windows, Android, and iOS simulator targets and executes the integration flow on Android and iOS emulators.

## Platform boundaries

- Desktop clipboard monitoring, menu-bar/tray integration, and global shortcuts require native plugins and explicit permission onboarding.
- iOS and Android use user-initiated share, keyboard, or foreground capture flows; background clipboard access is not assumed.
- Production sessions and key material must use platform secure storage and the reviewed ClipTown auth/encryption architecture.
