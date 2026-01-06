{
  quickshell,
  nixfmt,
  statix,
  deadnix,
  shfmt,
  shellcheck,
  jsonfmt,
  lefthook,
  kdePackages,
  mkShellNoCC,
}:
mkShellNoCC {
  #it's faster than mkDerivation / mkShell
  packages = [
    quickshell

    # nix
    nixfmt # formatter
    statix # linter
    deadnix # linter

    # shell
    shfmt # formatter
    shellcheck # linter

    # json
    jsonfmt # formatter

    # CoC
    lefthook # githooks
    kdePackages.qtdeclarative # qmlfmt, qmllint, qmlls and etc; Qt6
  ];

  shellHook = ''
    # Generate .qmlls.ini for qmlls language server support
    # Quickshell creates a VFS with qmldir files and populates .qmlls.ini
    if [ -f shell.qml ]; then
      touch .qmlls.ini
      timeout 2 quickshell -p . >/dev/null 2>&1 &
    fi
  '';
}
