// Bounded executable specification for the shared ClipTown Flutter control
// plane. The production refinement is lib/state/app_state_machine.dart.
module app_lifecycle {
  type State = {
    runtime: int,
    lifecycle: int,
    authentication: int,
    local_device: int,
    vault: int,
    sync: int,
    online: bool,
    window_visible: bool,
    revocation_observed: bool,
    revision: int,
  }

  pure val RUNTIME_MOBILE = 0
  pure val RUNTIME_DESKTOP = 1
  pure val RUNTIMES: Set[int] = Set(RUNTIME_MOBILE, RUNTIME_DESKTOP)

  pure val LIFECYCLE_STARTING = 0
  pure val LIFECYCLE_FOREGROUND = 1
  pure val LIFECYCLE_BACKGROUND = 2
  pure val LIFECYCLE_STOPPING = 3
  pure val LIFECYCLE_STOPPED = 4
  pure val LIFECYCLE_FAULTED = 5

  pure val AUTH_SIGNED_OUT = 0
  pure val AUTH_AUTHENTICATED = 1
  pure val AUTH_REAUTHENTICATION_REQUIRED = 2
  pure val AUTH_REVOKED = 3

  pure val DEVICE_PENDING = 0
  pure val DEVICE_ACTIVE = 1
  pure val DEVICE_SUSPENDED = 2
  pure val DEVICE_REVOKED = 3

  pure val VAULT_UNAVAILABLE = 0
  pure val VAULT_LOCKED = 1
  pure val VAULT_UNLOCKED = 2
  pure val VAULT_DESTROYED = 3

  pure val SYNC_DISABLED = 0
  pure val SYNC_IDLE = 1
  pure val SYNC_RUNNING = 2
  pure val SYNC_BACKOFF = 3

  pure val LIFECYCLES: Set[int] = Set(
    LIFECYCLE_STARTING,
    LIFECYCLE_FOREGROUND,
    LIFECYCLE_BACKGROUND,
    LIFECYCLE_STOPPING,
    LIFECYCLE_STOPPED,
    LIFECYCLE_FAULTED
  )
  pure val AUTH_STATES: Set[int] = Set(
    AUTH_SIGNED_OUT,
    AUTH_AUTHENTICATED,
    AUTH_REAUTHENTICATION_REQUIRED,
    AUTH_REVOKED
  )
  pure val DEVICE_STATES: Set[int] = Set(
    DEVICE_PENDING,
    DEVICE_ACTIVE,
    DEVICE_SUSPENDED,
    DEVICE_REVOKED
  )
  pure val VAULT_STATES: Set[int] = Set(
    VAULT_UNAVAILABLE,
    VAULT_LOCKED,
    VAULT_UNLOCKED,
    VAULT_DESTROYED
  )
  pure val SYNC_STATES: Set[int] = Set(
    SYNC_DISABLED,
    SYNC_IDLE,
    SYNC_RUNNING,
    SYNC_BACKOFF
  )

  var s: State

  pure def initial_state(runtime: int): State = {
    runtime: runtime,
    lifecycle: LIFECYCLE_STARTING,
    authentication: AUTH_SIGNED_OUT,
    local_device: DEVICE_PENDING,
    vault: VAULT_UNAVAILABLE,
    sync: SYNC_DISABLED,
    online: false,
    window_visible: false,
    revocation_observed: false,
    revision: 0,
  }

  pure def operational(snapshot: State): bool =
    Set(LIFECYCLE_FOREGROUND, LIFECYCLE_BACKGROUND).contains(
      snapshot.lifecycle
    )

  pure def sensitive_work_allowed(snapshot: State): bool = and {
    snapshot.authentication == AUTH_AUTHENTICATED,
    snapshot.local_device == DEVICE_ACTIVE,
    snapshot.vault == VAULT_UNLOCKED,
    or {
      snapshot.lifecycle == LIFECYCLE_FOREGROUND,
      and {
        snapshot.runtime == RUNTIME_DESKTOP,
        snapshot.lifecycle == LIFECYCLE_BACKGROUND,
      },
    },
  }

  pure def locked_vault(vault: int): int =
    if (vault == VAULT_UNAVAILABLE)
      VAULT_UNAVAILABLE
    else if (vault == VAULT_DESTROYED)
      VAULT_DESTROYED
    else
      VAULT_LOCKED

  action init = {
    nondet runtime = RUNTIMES.oneOf()
    s' = initial_state(runtime)
  }

  action init_mobile = s' = initial_state(RUNTIME_MOBILE)
  action init_desktop = s' = initial_state(RUNTIME_DESKTOP)

  action boot_signed_out = all {
    s.lifecycle == LIFECYCLE_STARTING,
    s' = {
      ...s,
      lifecycle: LIFECYCLE_FOREGROUND,
      authentication: AUTH_SIGNED_OUT,
      local_device: DEVICE_PENDING,
      vault: VAULT_UNAVAILABLE,
      sync: SYNC_DISABLED,
      window_visible: true,
      revision: s.revision + 1,
    },
  }

  action boot_authenticated = all {
    s.lifecycle == LIFECYCLE_STARTING,
    s' = {
      ...s,
      lifecycle: LIFECYCLE_FOREGROUND,
      authentication: AUTH_AUTHENTICATED,
      local_device: DEVICE_ACTIVE,
      vault: VAULT_LOCKED,
      sync: SYNC_DISABLED,
      window_visible: true,
      revision: s.revision + 1,
    },
  }

  action sign_in_succeeded = all {
    operational(s),
    s.local_device != DEVICE_REVOKED,
    Set(AUTH_SIGNED_OUT, AUTH_REAUTHENTICATION_REQUIRED).contains(
      s.authentication
    ),
    s' = {
      ...s,
      authentication: AUTH_AUTHENTICATED,
      vault: VAULT_LOCKED,
      sync: SYNC_DISABLED,
      revision: s.revision + 1,
    },
  }

  action device_approved = all {
    operational(s),
    s.authentication == AUTH_AUTHENTICATED,
    s.local_device == DEVICE_PENDING,
    s' = {
      ...s,
      local_device: DEVICE_ACTIVE,
      vault: VAULT_LOCKED,
      sync: SYNC_DISABLED,
      revision: s.revision + 1,
    },
  }

  action device_resumed = all {
    operational(s),
    s.authentication == AUTH_AUTHENTICATED,
    s.local_device == DEVICE_SUSPENDED,
    s' = {
      ...s,
      local_device: DEVICE_ACTIVE,
      vault: VAULT_LOCKED,
      sync: SYNC_DISABLED,
      revision: s.revision + 1,
    },
  }

  action unlock_succeeded = all {
    operational(s),
    s.authentication == AUTH_AUTHENTICATED,
    s.local_device == DEVICE_ACTIVE,
    s.vault == VAULT_LOCKED,
    not(and {
      s.runtime == RUNTIME_MOBILE,
      s.lifecycle == LIFECYCLE_BACKGROUND,
    }),
    s' = {
      ...s,
      vault: VAULT_UNLOCKED,
      sync: SYNC_IDLE,
      revision: s.revision + 1,
    },
  }

  action lock_requested = all {
    s.vault == VAULT_UNLOCKED,
    s' = {
      ...s,
      vault: VAULT_LOCKED,
      sync: SYNC_DISABLED,
      revision: s.revision + 1,
    },
  }

  action authentication_expired = all {
    operational(s),
    s.authentication == AUTH_AUTHENTICATED,
    s.local_device != DEVICE_REVOKED,
    s' = {
      ...s,
      authentication: AUTH_REAUTHENTICATION_REQUIRED,
      vault: locked_vault(s.vault),
      sync: SYNC_DISABLED,
      revision: s.revision + 1,
    },
  }

  action sign_out_requested = all {
    operational(s),
    s.authentication != AUTH_REVOKED,
    s.local_device != DEVICE_REVOKED,
    s' = {
      ...s,
      authentication: AUTH_SIGNED_OUT,
      vault: locked_vault(s.vault),
      sync: SYNC_DISABLED,
      revision: s.revision + 1,
    },
  }

  action device_suspended = all {
    operational(s),
    s.local_device == DEVICE_ACTIVE,
    s' = {
      ...s,
      authentication: AUTH_REAUTHENTICATION_REQUIRED,
      local_device: DEVICE_SUSPENDED,
      vault: locked_vault(s.vault),
      sync: SYNC_DISABLED,
      revision: s.revision + 1,
    },
  }

  action device_revoked = all {
    operational(s),
    s.local_device != DEVICE_REVOKED,
    s' = {
      ...s,
      authentication: AUTH_REVOKED,
      local_device: DEVICE_REVOKED,
      vault: VAULT_DESTROYED,
      sync: SYNC_DISABLED,
      revocation_observed: true,
      revision: s.revision + 1,
    },
  }

  action network_connected = all {
    operational(s),
    not(s.online),
    s' = { ...s, online: true, revision: s.revision + 1 },
  }

  action network_disconnected = all {
    operational(s),
    s.online,
    s' = {
      ...s,
      online: false,
      sync: if (s.sync == SYNC_RUNNING) SYNC_BACKOFF else s.sync,
      revision: s.revision + 1,
    },
  }

  action sync_requested = all {
    sensitive_work_allowed(s),
    s.online,
    Set(SYNC_IDLE, SYNC_BACKOFF).contains(s.sync),
    s' = { ...s, sync: SYNC_RUNNING, revision: s.revision + 1 },
  }

  action sync_succeeded = all {
    s.sync == SYNC_RUNNING,
    s' = { ...s, sync: SYNC_IDLE, revision: s.revision + 1 },
  }

  action sync_failed = all {
    s.sync == SYNC_RUNNING,
    s' = { ...s, sync: SYNC_BACKOFF, revision: s.revision + 1 },
  }

  action retry_requested = all {
    sensitive_work_allowed(s),
    s.online,
    s.sync == SYNC_BACKOFF,
    s' = { ...s, sync: SYNC_RUNNING, revision: s.revision + 1 },
  }

  action foreground_requested = all {
    operational(s),
    s' = {
      ...s,
      lifecycle: LIFECYCLE_FOREGROUND,
      window_visible: true,
      revision: s.revision + 1,
    },
  }

  action background_requested = all {
    operational(s),
    s' = {
      ...s,
      lifecycle: LIFECYCLE_BACKGROUND,
      window_visible: false,
      vault: if (s.runtime == RUNTIME_MOBILE)
        locked_vault(s.vault)
      else
        s.vault,
      sync: if (s.runtime == RUNTIME_MOBILE) SYNC_DISABLED else s.sync,
      revision: s.revision + 1,
    },
  }

  action shutdown_requested = all {
    Set(
      LIFECYCLE_STARTING,
      LIFECYCLE_FOREGROUND,
      LIFECYCLE_BACKGROUND,
      LIFECYCLE_FAULTED
    ).contains(s.lifecycle),
    s' = {
      ...s,
      lifecycle: LIFECYCLE_STOPPING,
      window_visible: false,
      vault: locked_vault(s.vault),
      sync: SYNC_DISABLED,
      revision: s.revision + 1,
    },
  }

  action shutdown_completed = all {
    s.lifecycle == LIFECYCLE_STOPPING,
    s' = {
      ...s,
      lifecycle: LIFECYCLE_STOPPED,
      window_visible: false,
      vault: locked_vault(s.vault),
      sync: SYNC_DISABLED,
      revision: s.revision + 1,
    },
  }

  action native_failure = all {
    Set(
      LIFECYCLE_STARTING,
      LIFECYCLE_FOREGROUND,
      LIFECYCLE_BACKGROUND,
      LIFECYCLE_STOPPING
    ).contains(s.lifecycle),
    s' = {
      ...s,
      lifecycle: LIFECYCLE_FAULTED,
      window_visible: false,
      vault: locked_vault(s.vault),
      sync: SYNC_DISABLED,
      revision: s.revision + 1,
    },
  }

  action idle = s' = s

  action step = any {
    boot_signed_out,
    boot_authenticated,
    sign_in_succeeded,
    device_approved,
    device_resumed,
    unlock_succeeded,
    lock_requested,
    authentication_expired,
    sign_out_requested,
    device_suspended,
    device_revoked,
    network_connected,
    network_disconnected,
    sync_requested,
    sync_succeeded,
    sync_failed,
    retry_requested,
    foreground_requested,
    background_requested,
    shutdown_requested,
    shutdown_completed,
    native_failure,
    idle,
  }

  val domain_bounds = and {
    RUNTIMES.contains(s.runtime),
    LIFECYCLES.contains(s.lifecycle),
    AUTH_STATES.contains(s.authentication),
    DEVICE_STATES.contains(s.local_device),
    VAULT_STATES.contains(s.vault),
    SYNC_STATES.contains(s.sync),
    s.revision >= 0,
  }

  val window_coherence =
    s.window_visible == (s.lifecycle == LIFECYCLE_FOREGROUND)

  val authentication_gate = or {
    s.authentication == AUTH_AUTHENTICATED,
    and {
      s.vault != VAULT_UNLOCKED,
      s.sync == SYNC_DISABLED,
    },
  }

  val device_gate = or {
    s.local_device == DEVICE_ACTIVE,
    and {
      s.vault != VAULT_UNLOCKED,
      s.sync == SYNC_DISABLED,
    },
  }

  val vault_gate =
    s.vault == VAULT_UNLOCKED or s.sync == SYNC_DISABLED

  val running_sync_gate = or {
    s.sync != SYNC_RUNNING,
    and { s.online, sensitive_work_allowed(s) },
  }

  val mobile_background_gate = or {
    s.runtime != RUNTIME_MOBILE,
    s.lifecycle != LIFECYCLE_BACKGROUND,
    and {
      s.vault != VAULT_UNLOCKED,
      s.sync == SYNC_DISABLED,
    },
  }

  val non_operational_gate = or {
    not(Set(
      LIFECYCLE_STARTING,
      LIFECYCLE_STOPPING,
      LIFECYCLE_STOPPED,
      LIFECYCLE_FAULTED
    ).contains(s.lifecycle)),
    and {
      s.vault != VAULT_UNLOCKED,
      s.sync == SYNC_DISABLED,
    },
  }

  val revocation_monotonicity = and {
    s.revocation_observed == (s.local_device == DEVICE_REVOKED),
    or {
      s.local_device != DEVICE_REVOKED,
      and {
        s.authentication == AUTH_REVOKED,
        s.vault == VAULT_DESTROYED,
        s.sync == SYNC_DISABLED,
      },
    },
    s.vault != VAULT_DESTROYED or s.local_device == DEVICE_REVOKED,
  }

  val app_lifecycle_safety = and {
    domain_bounds,
    window_coherence,
    authentication_gate,
    device_gate,
    vault_gate,
    running_sync_gate,
    mobile_background_gate,
    non_operational_gate,
    revocation_monotonicity,
  }

  val unlocked_reached = s.vault == VAULT_UNLOCKED
  val running_sync_reached = s.sync == SYNC_RUNNING
  val retry_backoff_reached = s.sync == SYNC_BACKOFF
  val mobile_background_locked_reached = and {
    s.runtime == RUNTIME_MOBILE,
    s.lifecycle == LIFECYCLE_BACKGROUND,
    s.vault != VAULT_UNLOCKED,
  }
  val desktop_background_unlocked_reached = and {
    s.runtime == RUNTIME_DESKTOP,
    s.lifecycle == LIFECYCLE_BACKGROUND,
    s.vault == VAULT_UNLOCKED,
  }
  val revocation_reached = s.local_device == DEVICE_REVOKED
  val controlled_fault_reached = s.lifecycle == LIFECYCLE_FAULTED
  val stopped_reached = s.lifecycle == LIFECYCLE_STOPPED
}
