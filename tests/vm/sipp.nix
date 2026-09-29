# SIPp for VM tests, for the requests phones never send. The scenarios in
# ./sipp are installed to /etc/sipp; phone.py's sipp() plays one.
{pkgs, ...}: {
  environment.systemPackages = [pkgs.sipp];
  environment.etc.sipp.source = ./sipp;
}
