# sops-nix for the tests that run the examples. `secrets` is encrypted for a
# throwaway age key at build time, so the VM decrypts a real sops file.
{ pkgs, sops-nix }:
secrets:
let
  fixture =
    pkgs.runCommand "asterisk-test-sops"
      {
        nativeBuildInputs = [
          pkgs.age
          pkgs.sops
        ];
        secrets = builtins.toJSON secrets;
        passAsFile = [ "secrets" ];
      }
      ''
        mkdir $out
        age-keygen -o $out/key.txt
        sops --encrypt --age "$(age-keygen -y $out/key.txt)" \
          --input-type json --output-type yaml "$secretsPath" > $out/secrets.yaml
      '';
in
{
  imports = [ sops-nix.nixosModules.sops ];

  sops = {
    defaultSopsFile = "${fixture}/secrets.yaml";
    # the file is a build output, so it cannot be hashed at evaluation time;
    # the VM still decrypts it for real
    validateSopsFiles = false;
    age = {
      keyFile = "/run/sops-test/key.txt";
      sshKeyPaths = [ ];
    };
    gnupg.sshKeyPaths = [ ];
  };

  # sops-nix refuses a key file in the store: copy it out before it runs
  system.activationScripts = {
    sops-test-key = {
      deps = [ "specialfs" ];
      text = "install -D -m 0400 ${fixture}/key.txt /run/sops-test/key.txt";
    };
    setupSecrets.deps = [ "sops-test-key" ];
  };
}
