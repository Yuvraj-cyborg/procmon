{
  description = "Procmon: a small native system monitor built with GPUI";

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
        "x86_64-darwin"
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
            xorg.libX11
            xorg.libxcb
          ];

          manifest = (lib.importTOML ./Cargo.toml).package;

          procmon = rustPlatform.buildRustPackage {
            pname = manifest.name;
            inherit (manifest) version;
            src = lib.cleanSource ./.;
            cargoLock.lockFile = ./Cargo.lock;

            # libproc generates its bindings with bindgen on macOS.
            nativeBuildInputs =
              [ rustPlatform.bindgenHook ]
              ++ lib.optionals stdenv.isLinux [
                pkgs.pkg-config
                pkgs.patchelf
              ];
            buildInputs = lib.optionals stdenv.isLinux linuxLibs ++ lib.optionals stdenv.isDarwin [ pkgs.apple-sdk_15 ];

            # Tests read the live system, which the build sandbox hides.
            doCheck = false;

            # nixpkgs disables cargo's own stripping and by default only strips
            # debug info, which leaves the full symbol table in the binary.
            # llvm-strip (used for Mach-O) needs -x instead of the GNU default.
            stripAllList = [ "bin" ] ++ lib.optional stdenv.isDarwin "Applications";
            stripAllFlags = lib.optionals stdenv.isDarwin [ "-x" ];

            postInstall =
              if stdenv.isDarwin then
                ''
                  app=$out/Applications/Procmon.app
                  mkdir -p $app/Contents/MacOS $app/Contents/Resources
                  mv $out/bin/procmon $app/Contents/MacOS/procmon
                  ln -s $app/Contents/MacOS/procmon $out/bin/procmon
                  cp assets/icon/Procmon.icns $app/Contents/Resources/
                  sed "s/@VERSION@/${manifest.version}/g" packaging/macos/Info.plist > $app/Contents/Info.plist
                ''
              else
                ''
                  install -Dm644 packaging/linux/procmon.desktop $out/share/applications/procmon.desktop
                  install -Dm644 assets/icon/procmon-512.png $out/share/icons/hicolor/512x512/apps/procmon.png
                '';

            # Vulkan, Wayland and xkbcommon are opened with dlopen at runtime.
            postFixup = lib.optionalString stdenv.isLinux ''
              patchelf --add-rpath ${lib.makeLibraryPath linuxLibs} $out/bin/procmon
            '';

            meta = {
              description = "Memory, CPU, storage and device monitor";
              homepage = "https://github.com/Yuvraj-cyborg/procmon";
              mainProgram = "procmon";
              platforms = lib.platforms.darwin ++ lib.platforms.linux;
            };
          };
        in
        {
          packages.default = procmon;

          apps.default = flake-utils.lib.mkApp { drv = procmon; };

          devShells.default = pkgs.mkShell {
            packages =
              [
                toolchain
                pkgs.cargo-bloat
                pkgs.nodejs
                pkgs.oxipng
                pkgs.pngquant
                pkgs.resvg
              ]
              ++ lib.optionals stdenv.isLinux ([ pkgs.pkg-config ] ++ linuxLibs);

            LD_LIBRARY_PATH = lib.optionalString stdenv.isLinux (lib.makeLibraryPath linuxLibs);
            LIBCLANG_PATH = "${pkgs.llvmPackages.libclang.lib}/lib";
          };
        }
      );
}
