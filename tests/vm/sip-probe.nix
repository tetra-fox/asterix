# sip-probe (./sip-probe.py) for VM tests: single requests as a phone or an
# intruder sends them.
{pkgs, ...}: {
  environment.systemPackages = [(pkgs.writers.writePython3Bin "sip-probe" {flakeIgnore = ["E501"];} ./sip-probe.py)];
}
