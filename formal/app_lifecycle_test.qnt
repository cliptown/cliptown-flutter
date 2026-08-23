module app_lifecycle_test {
  import app_lifecycle.* from "./app_lifecycle"

  run mobileBackgroundLocksAndStopsSyncTest =
    init_mobile
      .then(boot_authenticated)
      .then(unlock_succeeded)
      .then(network_connected)
      .then(sync_requested)
      .then(background_requested)
      .expect(and {
        s.lifecycle == LIFECYCLE_BACKGROUND,
        s.vault == VAULT_LOCKED,
        s.sync == SYNC_DISABLED,
        not(s.window_visible),
        app_lifecycle_safety,
      })

  run desktopTrayBackgroundRetainsReviewedWorkStateTest =
    init_desktop
      .then(boot_authenticated)
      .then(unlock_succeeded)
      .then(network_connected)
      .then(sync_requested)
      .then(background_requested)
      .expect(and {
        s.lifecycle == LIFECYCLE_BACKGROUND,
        s.vault == VAULT_UNLOCKED,
        s.sync == SYNC_RUNNING,
        desktop_background_unlocked_reached,
        app_lifecycle_safety,
      })

  run syncNeedsAuthenticationTrustUnlockAndNetworkTest =
    init_mobile.then(boot_authenticated).then(sync_requested).fail()

  run offlineUnlockedClientCannotStartSyncTest =
    init_mobile
      .then(boot_authenticated)
      .then(unlock_succeeded)
      .then(sync_requested)
      .fail()

  run authenticationExpiryFailsClosedTest =
    init_desktop
      .then(boot_authenticated)
      .then(unlock_succeeded)
      .then(network_connected)
      .then(sync_requested)
      .then(authentication_expired)
      .expect(and {
        s.authentication == AUTH_REAUTHENTICATION_REQUIRED,
        s.vault == VAULT_LOCKED,
        s.sync == SYNC_DISABLED,
        app_lifecycle_safety,
      })

  run disconnectMovesRunningSyncToBackoffTest =
    init_desktop
      .then(boot_authenticated)
      .then(unlock_succeeded)
      .then(network_connected)
      .then(sync_requested)
      .then(network_disconnected)
      .expect(and {
        not(s.online),
        s.sync == SYNC_BACKOFF,
        retry_backoff_reached,
        app_lifecycle_safety,
      })

  run retryRequiresOnlineStateTest =
    init_desktop
      .then(boot_authenticated)
      .then(unlock_succeeded)
      .then(network_connected)
      .then(sync_requested)
      .then(sync_failed)
      .then(retry_requested)
      .expect(and {
        s.sync == SYNC_RUNNING,
        app_lifecycle_safety,
      })

  run deviceRevocationIsTerminalTest =
    init_desktop
      .then(boot_authenticated)
      .then(unlock_succeeded)
      .then(device_revoked)
      .then(sign_in_succeeded)
      .fail()

  run revokedDeviceCanOnlyProgressTowardShutdownTest =
    init_desktop
      .then(boot_authenticated)
      .then(device_revoked)
      .then(shutdown_requested)
      .then(shutdown_completed)
      .expect(and {
        s.local_device == DEVICE_REVOKED,
        s.authentication == AUTH_REVOKED,
        s.vault == VAULT_DESTROYED,
        s.lifecycle == LIFECYCLE_STOPPED,
        app_lifecycle_safety,
      })

  run nativeFailureContainsSensitiveWorkTest =
    init_desktop
      .then(boot_authenticated)
      .then(unlock_succeeded)
      .then(network_connected)
      .then(sync_requested)
      .then(native_failure)
      .expect(and {
        s.lifecycle == LIFECYCLE_FAULTED,
        s.vault == VAULT_LOCKED,
        s.sync == SYNC_DISABLED,
        not(s.window_visible),
        controlled_fault_reached,
        app_lifecycle_safety,
      })

  run controlledFaultCanCompleteShutdownTest =
    init_desktop
      .then(boot_authenticated)
      .then(unlock_succeeded)
      .then(native_failure)
      .then(shutdown_requested)
      .then(shutdown_completed)
      .expect(and {
        s.lifecycle == LIFECYCLE_STOPPED,
        s.vault == VAULT_LOCKED,
        s.sync == SYNC_DISABLED,
        app_lifecycle_safety,
      })
}
