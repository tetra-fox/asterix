# ami (./ami.py) for VM tests, on the machine Asterisk runs on: logs in to
# AMI, runs actions and writes the events a user receives.
{pkgs, ...}: {
  environment.systemPackages = [(pkgs.writers.writePython3Bin "ami" {} ./ami.py)];
}
