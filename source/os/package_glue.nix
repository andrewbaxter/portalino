{ pkgs }: pkgs.callPackage
  ({ lib
   , rustPlatform
   , rustc
   , cargo
   , makeWrapper
   , sqlite
   }:
  rustPlatform.buildRustPackage rec {
    pname = "glue";
    version = "0.0.0";
    cargoLock = {
      lockFile = ../rust/glue/Cargo.lock;
    };
    src = ../rust;
    sourceRoot = "rust/glue";
    preConfigure = ''
      cd ../../
      mv rust ro
      cp -r ro rw
      chmod -R u+w rw
      cd rw/glue
    '';
    cargoBuildFlags = [ "--bin=setup" "--bin=inject_dns" ];
    buildInputs = [
      sqlite
    ];
    nativeBuildInputs = [
      cargo
      rustc
      rustPlatform.bindgenHook
      makeWrapper
    ];
    postFixup =
      let
        path = lib.makeBinPath [ pkgs.systemd pkgs.iproute2 ];
      in
      ''
        wrapProgram $out/bin/setup --prefix PATH : ${path}
      '';
  })
{ }
