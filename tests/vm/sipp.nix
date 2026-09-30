# SIPp for VM tests, for the requests phones never send and for load. The
# scenarios in ./sipp are installed to /etc/sipp, with tone.wav, the audio
# call.xml sends; phone.py's sipp() plays one.
{pkgs, ...}: {
  environment.systemPackages = [pkgs.sipp];
  environment.etc.sipp.source = pkgs.runCommand "sipp-scenarios" {nativeBuildInputs = [pkgs.sox];} ''
    cp -r ${./sipp} $out
    chmod u+w $out
    sox -n -r 8000 -c 1 -e u-law $out/tone.wav synth 1 sine 440 vol 0.1
  '';
}
