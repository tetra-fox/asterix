# Test stand-in for agenix/sops-nix: writes root-only secret files under
# /run/agenix before Asterisk starts. `random` secrets are generated at boot,
# so their values exist nowhere in the Nix store; `fixed` ones are test
# fixtures that clients also need to know.
{
  fixed ? { },
  random ? [ ],
}:
{ lib, pkgs, ... }:
{
  systemd.services.provision-test-secrets = {
    wantedBy = [ "multi-user.target" ];
    before = [ "asterisk.service" ];
    requiredBy = [ "asterisk.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    path = [ pkgs.coreutils ];
    script = ''
      install -d -m 0755 /run/agenix
      ${lib.concatStrings (
        lib.mapAttrsToList (name: value: ''
          printf '%s\n' ${lib.escapeShellArg value} > /run/agenix/${name}
        '') fixed
      )}
      ${lib.concatMapStrings (name: ''
        head -c 18 /dev/urandom | base64 | tr -d '\n/+=' > /run/agenix/${name}
      '') random}
      chmod 0400 /run/agenix/*
    '';
  };
}
