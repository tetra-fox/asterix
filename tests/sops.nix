# sops-nix for the tests that run the examples. `secrets` is encrypted for a
# throwaway age key at build time, so the VM decrypts a real sops file.
{pkgs}: secrets: let
  # pinned here instead of as a flake input, so users of the flake don't lock
  # it. to bump, set rev and replace narHash with the hash nix reports
  sops-nix = builtins.fetchTree {
    type = "github";
    owner = "Mic92";
    repo = "sops-nix";
    rev = "5efb5a6f4f5ab192817d28557dd4d650fa14d866";
    narHash = "sha256-rs9meAYxW3zzrh43yaW7htrqCD+X9+pupDPHN86fumI=";
  };

  fixture =
    pkgs.runCommand "asterisk-test-sops"
    {
      nativeBuildInputs = [
        pkgs.age
        pkgs.sops
      ];
      secrets = builtins.toJSON secrets;
      passAsFile = ["secrets"];
    }
    ''
      mkdir $out
      age-keygen -o $out/key.txt
      sops --encrypt --age "$(age-keygen -y $out/key.txt)" \
        --input-type json --output-type yaml "$secretsPath" > $out/secrets.yaml
    '';
in {
  imports = ["${sops-nix}/modules/sops"];

  sops = {
    defaultSopsFile = "${fixture}/secrets.yaml";
    # the file is a build output, so it cannot be hashed at evaluation time;
    # the VM still decrypts it for real
    validateSopsFiles = false;
    age = {
      keyFile = "/run/sops-test/key.txt";
      sshKeyPaths = [];
    };
    gnupg.sshKeyPaths = [];
  };

  # sops-nix refuses a key file in the store: copy it out before it runs
  system.activationScripts = {
    sops-test-key = {
      deps = ["specialfs"];
      text = "install -D -m 0400 ${fixture}/key.txt /run/sops-test/key.txt";
    };
    setupSecrets.deps = ["sops-test-key"];
  };
}
