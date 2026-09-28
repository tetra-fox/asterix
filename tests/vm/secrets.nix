# Secret files for the tests that don't run an example (those use real
# sops-nix, see ../sops.nix): writes root-only files under /run/test-secrets
# before Asterisk starts. `random` secrets are generated at boot, so their
# values exist nowhere in the Nix store; `fixed` ones are test fixtures that
# clients also need to know.
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
      install -d -m 0755 /run/test-secrets
      ${lib.concatStrings (
        lib.mapAttrsToList (name: value: ''
          printf '%s\n' ${lib.escapeShellArg value} > /run/test-secrets/${name}
        '') fixed
      )}
      ${lib.concatMapStrings (name: ''
        head -c 18 /dev/urandom | base64 | tr -d '\n/+=' > /run/test-secrets/${name}
      '') random}
      chmod 0400 /run/test-secrets/*
    '';
  };
}
