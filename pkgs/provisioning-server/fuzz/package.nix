# The server's fuzz target (fuzz_targets/connection.rs), built by cargo-fuzz with
# its own libFuzzer flags; with `--sanitizer none` they all work on stable rustc.
{
  lib,
  stdenv,
  rustPlatform,
  cargo,
  rustc,
  cargo-fuzz,
}: let
  server = (lib.importTOML ../Cargo.toml).package;
  target = stdenv.hostPlatform.rust.rustcTarget;

  # the fuzz target has its own lock file, which must keep the server's crates at
  # the versions the server is built with
  locked = lockFile: map (crate: "${crate.name} ${crate.version}") (lib.importTOML lockFile).package;
  drifted = lib.subtractLists (locked ./Cargo.lock) (locked ../Cargo.lock);
in
  stdenv.mkDerivation {
    pname = "${server.name}-fuzz";
    inherit (server) version;

    src = lib.fileset.toSource {
      root = ../.;
      fileset = lib.fileset.unions [
        ../Cargo.toml
        ../src
        ./Cargo.toml
        ./Cargo.lock
        ./fuzz_targets
      ];
    };

    cargoDeps = rustPlatform.importCargoLock {lockFile = ./Cargo.lock;};
    cargoRoot = "fuzz";

    nativeBuildInputs = [
      rustPlatform.cargoSetupHook
      cargo
      rustc
      cargo-fuzz
    ];

    postPatch = lib.optionalString (drifted != []) ''
      echo "fuzz/Cargo.lock lacks these crates of Cargo.lock: ${lib.concatStringsSep ", " drifted}" >&2
      exit 1
    '';

    buildPhase = ''
      runHook preBuild
      cargo fuzz build --sanitizer none --target ${target} connection
      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      install -D fuzz/target/${target}/release/connection $out/bin/connection
      runHook postInstall
    '';

    meta = {
      description = "libFuzzer target for the request handling of provisioning-server";
      mainProgram = "connection";
      platforms = lib.platforms.linux;
    };
  }
