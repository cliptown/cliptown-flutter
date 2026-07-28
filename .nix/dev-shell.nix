{ pkgs, agentCheck }:
let
  linuxPackages = pkgs.lib.optionals pkgs.stdenv.hostPlatform.isLinux (
    with pkgs;
    [
      clang
      cmake
      glib
      gtk3
      libGL
      libsecret
      ninja
      pkg-config
    ]
  );
  linuxLibraries = with pkgs; [
    glib
    gtk3
    libGL
    libsecret
  ];
  shellPackages =
    (with pkgs; [
      actionlint
      cacert
      flutter
      git
      jdk17
      jq
      nixfmt-rfc-style
      rsync
      shellcheck
      shfmt
    ])
    ++ linuxPackages
    ++ [ agentCheck ];
in
pkgs.mkShell {
  packages = shellPackages;

  JAVA_HOME = "${pkgs.jdk17.home}";
  LANG = if pkgs.stdenv.hostPlatform.isDarwin then "en_US.UTF-8" else "C.UTF-8";
  LC_ALL = if pkgs.stdenv.hostPlatform.isDarwin then "en_US.UTF-8" else "C.UTF-8";
  LD_LIBRARY_PATH = pkgs.lib.optionalString pkgs.stdenv.hostPlatform.isLinux (
    pkgs.lib.makeLibraryPath linuxLibraries
  );

  shellHook = ''
    repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
    cache_root="''${NIX_AGENT_CACHE_ROOT:-$repo_root/.cache/nix-agent}"
    export NIX_AGENT_CACHE_ROOT="$cache_root"
    export PUB_CACHE="''${PUB_CACHE:-$cache_root/dart-pub}"
    export GRADLE_USER_HOME="''${GRADLE_USER_HOME:-$cache_root/gradle}"
    export XDG_CACHE_HOME="''${XDG_CACHE_HOME:-$cache_root/xdg-cache}"
    export XDG_CONFIG_HOME="''${XDG_CONFIG_HOME:-$cache_root/xdg-config}"
    export XDG_DATA_HOME="''${XDG_DATA_HOME:-$cache_root/xdg-data}"
    export FLUTTER_SUPPRESS_ANALYTICS="''${FLUTTER_SUPPRESS_ANALYTICS:-true}"
    export DART_SUPPRESS_ANALYTICS="''${DART_SUPPRESS_ANALYTICS:-true}"
    mkdir -p \
      "$PUB_CACHE" \
      "$GRADLE_USER_HOME" \
      "$XDG_CACHE_HOME" \
      "$XDG_CONFIG_HOME" \
      "$XDG_DATA_HOME"
  '';
}
