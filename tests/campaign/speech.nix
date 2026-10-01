# Voice menu prompts that flite speaks, recorded as a phone hears them over a
# call, and what speech.py transcribes them with: `recordings` is a VM test
# whose result holds <menu>.wav, the audio of a call to each menu of
# `prompts` up to its hangup, and prompts.json with each menu's text;
# `whisper` is whisper.cpp and `model` its English base model.
#
#   import tests/campaign/speech.nix { self = builtins.getFlake (toString ./.); }
{self}: let
  pkgs = self.inputs.nixpkgs.legacyPackages.x86_64-linux;
  inherit (pkgs) lib;

  # the menus' texts; `known` names the finding a text's words are known to
  # come out wrong by
  prompts = {
    test.text = "Press 1 for the test.";
    welcome.text = "Thank you for calling. For sales, press 1. For support, press 2. To reach the operator, press 0.";
    closed.text = "Our office is closed. We are open Monday to Friday from nine in the morning until five in the afternoon.";
    message.text = "Please leave a message after the tone. When you are done, hang up or press the pound key.";
    # a long prompt, about 2,000 characters, in sentences that do not repeat:
    # whisper leaves out some of a sentence said over and over
    long.text = lib.concatStringsSep " " [
      "Thank you for calling Example and Sons."
      "Our main office is open from Monday to Friday, eight in the morning until six in the evening, and on Saturday from ten until two."
      "If you are calling about an order you have already placed, please have your order number ready before you speak with one of our agents."
      "For questions about a delivery, our drivers can be reached through the dispatch desk, which answers within a few minutes during business hours."
      "Customers who need technical help with one of our products will find detailed guides and videos on our website, where you can also book a visit from a service engineer."
      "If you would like to return an item, please keep the original packaging and the receipt, and ask our team for a return label."
      "Our showroom has recently moved to a larger building next to the central station, with free parking for visitors in the garage behind it."
      "We are always looking for friendly people to join our team, so if you would like to work with us, please send your application to our human resources department."
      "Remember that you can change your contact details and your delivery address at any time in your online account."
      "Business customers with a framework agreement have their own number, which is printed on every invoice they receive from us."
      "During the summer holidays our warehouse closes for two weeks, and orders placed in that time are shipped on the first working day after it opens again."
      "Gift vouchers can be bought in the showroom and online, and they are valid for three years from the day of purchase."
      "Please note that calls to this number may be recorded to help us train our staff and improve our service."
      "If you prefer to write to us, our postal address and our email address are listed on the contact page of our website."
      "For urgent matters outside our opening hours, please leave a short message with your name and your phone number, and a member of our team will call you back first thing in the morning."
      "Thank you for your patience, and thank you for choosing Example and Sons."
    ];
    umlauts = {
      text = builtins.fromJSON ''"Welcome to M\u00fcller and S\u00f6hne."'';
      # flite drops the letters outside ASCII
      known = "F57";
    };
  };
  names = builtins.attrNames prompts;
  # 701, 702 ... in the order of the names
  numbers = lib.listToAttrs (lib.imap1 (i: name: lib.nameValuePair name (toString (700 + i))) names);
in {
  recordings = pkgs.testers.runNixOSTest {
    name = "asterisk-speech";

    nodes.pbx = {config, ...}: {
      imports = [
        self.nixosModules.pbx
        ../vm/common.nix
        ../vm/phone.nix
        (import ../vm/secrets.nix {fixed.sip-201 = "pw-201";})
      ];
      environment.systemPackages = [pkgs.sox];

      pbx = {
        enable = true;
        extensions."201" = {
          name = "Caller";
          password = config.lib.asterisk.secret "/run/test-secrets/sip-201";
        };
        # a prompt, 2 s for a key, and the default no-input destination, a hangup
        ivrs =
          lib.mapAttrs (name: prompt: {
            number = numbers.${name};
            prompt.text = prompt.text;
            attempts = 1;
            timeout = 2;
          })
          prompts;
      };
      services.asterisk.pjsip.transports.udp = {};
    };

    extraPythonPackages = p: [p.numpy];

    testScript =
      builtins.readFile ../vm/phone.py
      + builtins.readFile ../vm/tones.py
      + ''
        pbx.wait_for_unit("asterisk.service")
        phone = Phone(pbx, "201", "201", "pw-201", "127.0.0.1")
        start_phones([phone])
        wait_registrations({phone: 200})

        for name, number in ${builtins.toJSON numbers}.items():
            with subtest(f"a call to menu {name} records its prompt"):
                ended, start = phone.disconnects(), recorded(phone)
                phone.call(number)
                # the menu hangs up 2 s after its prompt
                phone.wait_disconnected(after=ended, timeout=600)
                # the 2 s of silence push the prompt out of pjsua's buffer
                end = recorded(phone)
                pbx.succeed(
                    f"dd if={phone.recording} iflag=skip_bytes,count_bytes skip={HEADER + start} count={end - start} status=none"
                    + f" | sox -t raw -r {sample_rate(phone)} -e signed-integer -b 16 -c 1 - /tmp/{name}.wav"
                )
                pbx.copy_from_vm(f"/tmp/{name}.wav")

        (driver.out_dir / "prompts.json").write_text(json.dumps(${builtins.toJSON prompts}))
      '';
  };

  whisper = pkgs.whisper-cpp;

  model = pkgs.fetchurl {
    url = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin";
    hash = "sha256-oDd5yG3zMjB19eeWyyzlAp8A7Ihp7uP9+4l6/jbG0AI=";
  };

  sox = lib.getBin pkgs.sox;
}
