{
  description = "OmniWM developer tooling";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  outputs =
    { self, nixpkgs }:
    let
      inherit (nixpkgs) lib;
      forAllSystems = lib.genAttrs [
        "aarch64-darwin"
        "x86_64-darwin"
        "aarch64-linux"
        "x86_64-linux"
      ];

      pins = builtins.listToAttrs (
        map (
          line:
          let
            pair = builtins.match "([A-Z0-9_]+)=(.*)" line;
          in
          {
            name = builtins.elemAt pair 0;
            value = builtins.elemAt pair 1;
          }
        ) (builtins.filter (line: builtins.match "[A-Z0-9_]+=.*" line != null) (lib.splitString "\n" (builtins.readFile ./Scripts/dev-tools.env)))
      );

      unzipped =
        pkgs: name: version: url: sha256: installPhase:
        pkgs.stdenvNoCC.mkDerivation {
          pname = name;
          inherit version installPhase;
          src = pkgs.fetchurl { inherit url sha256; };
          nativeBuildInputs = [ pkgs.unzip ];
          sourceRoot = ".";
          dontConfigure = true;
          dontBuild = true;
          dontFixup = true;
          meta.platforms = lib.platforms.darwin;
        };

      releaseTool =
        pkgs: name: version: url: sha256:
        unzipped pkgs name version url sha256 "install -Dm755 ${name} $out/bin/${name}";

      ghosttykit =
        pkgs:
        unzipped pkgs "GhosttyKit.xcframework" pins.OMNIWM_GHOSTTY_SOURCE_COMMIT pins.OMNIWM_GHOSTTY_DOWNLOAD_URL
          pins.OMNIWM_GHOSTTY_ZIP_SHA256 "cp -R GhosttyKit.xcframework $out";

      tools =
        pkgs:
        [
          pkgs.python3
          pkgs.fish
          pkgs.nushell
          pkgs.gnumake
        ]
        ++ lib.optionals pkgs.stdenv.hostPlatform.isDarwin [
          (releaseTool pkgs "swiftformat" pins.SWIFTFORMAT_VERSION
            "https://github.com/nicklockwood/SwiftFormat/releases/download/${pins.SWIFTFORMAT_VERSION}/swiftformat.zip"
            pins.OMNIWM_SWIFTFORMAT_ZIP_SHA256
          )
          (releaseTool pkgs "swiftlint" pins.SWIFTLINT_VERSION
            "https://github.com/realm/SwiftLint/releases/download/${pins.SWIFTLINT_VERSION}/portable_swiftlint.zip"
            pins.OMNIWM_SWIFTLINT_ZIP_SHA256
          )
        ];
    in
    {
      packages = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          default = pkgs.buildEnv {
            name = "omniwm-dev-tools";
            paths = tools pkgs;
          };
          inherit (pkgs) gettext;
        }
        // lib.optionalAttrs pkgs.stdenv.hostPlatform.isDarwin {
          ghosttykit = ghosttykit pkgs;
        }
      );

      devShells = forAllSystems (
        system:
        let
          devTools = self.packages.${system}.default;
        in
        {
          default = nixpkgs.legacyPackages.${system}.mkShellNoCC {
            packages = [ devTools ];
            OMNIWM_DEV_TOOLS = "${devTools}";
          };
        }
      );

      checks = forAllSystems (system: {
        tools = self.packages.${system}.default;
      });
    };
}
