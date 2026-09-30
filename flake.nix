{
  # The Rust app for Linux lives at the root; the macOS app in macos/ is built
  # with Xcode's Swift toolchain instead (see the Makefile).
  description = "Procmon: a small native system monitor";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
      rust-overlay,
    }:
    flake-utils.lib.eachSystem
      [
        "aarch64-darwin"
        "x86_64-linux"
        "aarch64-linux"
      ]
      (
        system:
        let
          pkgs = import nixpkgs {
            inherit system;
            overlays = [ rust-overlay.overlays.default ];
          };
          inherit (pkgs) lib stdenv;

          toolchain = pkgs.rust-bin.fromRustupToolchainFile ./rust-toolchain.toml;
          rustPlatform = pkgs.makeRustPlatform {
            cargo = toolchain;
            rustc = toolchain;
          };

          # Libraries GPUI links against or loads at runtime on Linux.
          linuxLibs = with pkgs; [
            fontconfig
            freetype
            libxkbcommon
            wayland
            vulkan-loader
            libx11
            libxcb
          ];

          manifest = (lib.importTOML ./Cargo.toml).package;

          procmon = rustPlatform.buildRustPackage {
            pname = manifest.name;
            inherit (manifest) version;
            src = lib.cleanSource ./.;
            cargoLock.lockFile = ./Cargo.lock;

            nativeBuildInputs = [
              pkgs.pkg-config
              pkgs.patchelf
            ];
            buildInputs = linuxLibs;

            # Tests read the live system, which the build sandbox hides.
            doCheck = false;

            # nixpkgs disables cargo's own stripping and by default only strips
            # debug info, which leaves the full symbol table in the binary.
            stripAllList = [ "bin" ];

            postInstall = ''
              install -Dm644 packaging/linux/procmon.desktop $out/share/applications/procmon.desktop
              install -Dm644 assets/icon/procmon-512.png $out/share/icons/hicolor/512x512/apps/procmon.png
            '';

            # Vulkan, Wayland and xkbcommon are opened with dlopen at runtime.
            postFixup = ''
              patchelf --add-rpath ${lib.makeLibraryPath linuxLibs} $out/bin/procmon
            '';

            meta = {
              description = "Memory, CPU, storage and device monitor";
              homepage = "https://github.com/Yuvraj-cyborg/procmon";
              mainProgram = "procmon";
              platforms = lib.platforms.linux;
            };
          };
        in
        {
          # The package is the Linux app; on macOS the dev shell is still useful
          # for working on the Rust code.
          packages = lib.optionalAttrs stdenv.hostPlatform.isLinux { default = procmon; };

          apps = lib.optionalAttrs stdenv.hostPlatform.isLinux { default = flake-utils.lib.mkApp { drv = procmon; }; };

          devShells.default = pkgs.mkShell {
            packages =
              [
                toolchain
                pkgs.cargo-bloat
              ]
              ++ lib.optionals stdenv.hostPlatform.isLinux ([ pkgs.pkg-config ] ++ linuxLibs);

            LD_LIBRARY_PATH = lib.optionalString stdenv.hostPlatform.isLinux (lib.makeLibraryPath linuxLibs);
            LIBCLANG_PATH = "${pkgs.llvmPackages.libclang.lib}/lib";
          };
        }
      );
}
