{
  inputs = {
    nixpkgs.url = "nixpkgs/nixos-unstable";

    crane = {
      url = "github:ipetkov/crane";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    rust = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    flake-utils.url = "github:numtide/flake-utils";

    gitignore = {
      url = "github:hercules-ci/gitignore";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      flake-utils,
      rust,
      crane,
      nixpkgs,
      ...
    }@inputs:

    flake-utils.lib.eachDefaultSystem (
      system:
      let
        overlays = [ (import rust) ];
        pkgs = import nixpkgs {
          inherit system overlays;
        };

        lib = pkgs.lib;

        rustToolchain = pkgs.rust-bin.stable.latest.minimal;
        craneLib = (crane.mkLib pkgs).overrideToolchain rustToolchain;
      in
      {
        packages.cargo-pgrx = craneLib.buildPackage {
          src = inputs.gitignore.lib.gitignoreSource ./.;
          inherit (craneLib.crateNameFromCargoToml { cargoToml = ./cargo-pgrx/Cargo.toml; }) pname version;
          cargoExtraArgs = "--package cargo-pgrx";
          nativeBuildInputs = [ pkgs.pkg-config ];
          buildInputs =
            [ pkgs.openssl ]
            ++ lib.optionals pkgs.stdenv.isDarwin [
              pkgs.darwin.apple_sdk.frameworks.Security
              pkgs.libiconv
            ];
          # fixes to enable running pgrx tests
          preCheck = ''
            export PGRX_HOME=$(mktemp -d)
          '';
          # skip tests that require pgrx to be initialized using `cargo pgrx init`
          cargoTestExtraArgs = "-- --skip=command::schema::tests::test_parse_managed_postmasters";
        };

        checks.cargo-pgrx = self.packages.${system}.cargo-pgrx;

        devShells.default =
          with pkgs;
          mkShell {
            inputsFrom = [ self.packages.${system}.cargo-pgrx ];
            nativeBuildInputs = with pkgs; [
              rustToolchain
              pkg-config
            ];
            buildInputs =
              with pkgs;
              [ openssl ]
              ++ lib.optionals stdenv.isDarwin [
                darwin.apple_sdk.frameworks.Security
                libiconv
              ];

            shellHook = ''
              export PGRX_HOME=$(mktemp -d)
            '';
          };

        lib.buildPgrxExtension =
          {
            toolchain ? inputs.fenix.packages.minimal.toolchain,
            system,
            src,
            postgresql,
            additionalFeatures ? [ ],
          }:
          let
            cargo-pgrx = self.packages.${system}.cargo-pgrx;
            pkgs = nixpkgs.legacyPackages.${system};
            craneLib = crane.lib.${system}.overrideToolchain toolchain;

            postgresMajor = inputs.nixpkgs.lib.versions.major postgresql.version;
            cargoToml = builtins.fromTOML (builtins.readFile "${src}/Cargo.toml");
            name = cargoToml.package.name;
            pgrxFeatures = builtins.toString additionalFeatures;

            preBuildAndTest = ''
              export PGRX_HOME=$(mktemp -d)
              mkdir -p $PGRX_HOME/${postgresMajor}

              cp -r -L ${postgresql}/. $PGRX_HOME/${postgresMajor}/
              chmod -R ugo+w $PGRX_HOME/${postgresMajor}
              cp -r -L ${postgresql.lib}/lib/. $PGRX_HOME/${postgresMajor}/lib/

              ${cargo-pgrx}/bin/cargo-pgrx pgrx init \
                --pg${postgresMajor} $PGRX_HOME/${postgresMajor}/bin/pg_config \
            '';

            craneCommonBuildArgs = {
              inherit src;
              pname = "${name}-pg${postgresMajor}";
              nativeBuildInputs = [
                pkgs.pkg-config
                pkgs.rustPlatform.bindgenHook
                postgresql.lib
                postgresql
              ];
              cargoExtraArgs = "--no-default-features --features \"pg${postgresMajor} ${pgrxFeatures}\"";
              postPatch = "patchShebangs .";
              preBuild = preBuildAndTest;
              preCheck = preBuildAndTest;
              postBuild = ''
                if [ -f "${name}.control" ]; then
                  export NIX_PGLIBDIR=${postgresql.out}/share/postgresql/extension/
                  ${cargo-pgrx}/bin/cargo-pgrx pgrx package --pg-config ${postgresql}/bin/pg_config --features "${pgrxFeatures}" --out-dir $out
                  export NIX_PGLIBDIR=$PGRX_HOME/${postgresMajor}/lib
                fi
              '';

              PGRX_PG_SYS_SKIP_BINDING_REWRITE = "1";
              CARGO = "${toolchain}/bin/cargo";
              CARGO_BUILD_INCREMENTAL = "false";
              RUST_BACKTRACE = "full";
            };

            cargoArtifacts = craneLib.buildDepsOnly craneCommonBuildArgs;
          in
          craneLib.mkCargoDerivation (
            {
              inherit cargoArtifacts;
              buildPhaseCargoCommand = ''
                ${cargo-pgrx}/bin/cargo-pgrx pgrx package --pg-config ${postgresql}/bin/pg_config --features "${pgrxFeatures}" --out-dir $out
              '';
              doCheck = false;
              preFixup = ''
                if [ -f "${name}.control" ]; then
                  ${cargo-pgrx}/bin/cargo-pgrx pgrx stop all
                  rm -rfv $out/target*
                fi
              '';

              postInstall = ''
                mkdir -p $out/lib
                cp target/release/lib${name}.so $out/lib/${name}.so
                mv -v $out/${postgresql.out}/* $out
                rm -rfv $out/nix
              '';
            }
            // craneCommonBuildArgs
          );
      }
    );
}
