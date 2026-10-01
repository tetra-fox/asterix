# sip-probe (./sip-probe.py) for VM tests: single requests as a phone or an
# intruder sends them, and a busy lamp key's subscription to the dialog state
# of an extension.
{pkgs, ...}: {
  environment.systemPackages = [(pkgs.writers.writePython3Bin "sip-probe" {flakeIgnore = ["E501"];} ./sip-probe.py)];
}
