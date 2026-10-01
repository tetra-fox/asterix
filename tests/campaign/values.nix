# What options.nix sets each option to, beyond what its type gives: `valid`
# values, which must evaluate and load (P2), `invalid` ones, which must fail
# at evaluation or when Asterisk loads them (P3), and `warn` ones, which
# evaluate with a warning. `key` is the key freeform options get strings
# under, `strings = false` leaves out the adversarial strings (raw text by
# design), `lineBreak` is what a line break must do where it is not
# rejected. A value that needs more configuration is `with extra value`.
{
  pkgs,
  secret,
  credential,
}: let
  with' = extra: value: {_campaign = {inherit extra value;};};
  # the modules that read these files are only loaded with their options
  voicemail = with' {services.asterisk.voicemail.enable = true;};
  queues = with' {services.asterisk.modules.load = ["app_queue.so"];};
  iceEndpoint = with' {services.asterisk.pjsip.endpoints."101".settings.ice_support = true;};
  # a language other than the default one: the package has English sounds
  # only, and the build-time check fails a language without sounds
  language = "en_US";
  password = secret "/run/secrets/campaign";

  # keys each freeform section reads, one per value kind, one no Asterisk
  # module knows and, as `wrong`, a key with a value of another kind. Only
  # Asterisk knows what a freeform key takes, so loading is where a wrong one
  # fails; strings go under the string key.
  freeform = kinds:
    {
      valid = builtins.attrValues (removeAttrs kinds ["unknown" "wrong"]);
      invalid = [kinds.unknown or {q7unknown = "x";}] ++ lib.optional (kinds ? wrong) kinds.wrong;
      guard = "t1";
      strings = kinds ? str;
    }
    // lib.optionalAttrs (kinds ? str) {key = builtins.head (builtins.attrNames kinds.str);};
  inherit (pkgs) lib;

  destination = {
    extension = {
      valid = ["201"];
      invalid = ["299"];
    };
    ringGroup = {
      valid = ["sales"];
      invalid = ["nope"];
    };
    queue = {
      valid = ["support"];
      invalid = ["nope"];
    };
    conference = {
      valid = ["board"];
      invalid = ["nope"];
    };
    ivr = {
      valid = ["main"];
      invalid = ["nope"];
    };
    voicemail = {
      valid = ["201" "201@default"];
      invalid = ["299" "201@sales"];
    };
    "voicemail.mailbox" = {
      valid = ["201@default"];
      invalid = ["299"];
    };
    context = {
      valid = [
        {
          context = "pbx-internal";
          extension = "201";
        }
      ];
      invalid = [{context = "nowhere";}];
    };
    "context.context" = {
      valid = ["pbx-internal"];
      invalid = ["nowhere"];
    };
    "context.extension".valid = ["201"];
    # the type takes any positive number, and the build-time check a
    # priority the extension has
    "context.priority" = {
      valid = [1];
      invalid = [2147483647 2147483648 4294967296 9223372036854775807];
    };
  };
  slots = [
    "pbx.extensions.<name>.busy"
    "pbx.extensions.<name>.noAnswer"
    "pbx.ringGroups.<name>.noAnswer"
    "pbx.queues.<name>.noAnswer"
    "pbx.inbound.<name>.destination"
    "pbx.inbound.<name>.open"
    "pbx.inbound.<name>.closed"
    "pbx.ivrs.<name>.noInput"
    "pbx.ivrs.<name>.invalid"
    "pbx.ivrs.<name>.options.<name>"
  ];
  destinations = lib.listToAttrs (lib.concatMap (slot:
    lib.mapAttrsToList (tag: spec: lib.nameValuePair "${slot}.${tag}" spec) destination)
  slots);
in
  destinations
  // {
    "services.asterisk.ami.address" = {
      valid = ["0.0.0.0" "10.0.20.10" "::1"];
      invalid = ["pbx" "300.0.0.1" "127.0.0.1:5038"];
    };
    "services.asterisk.ami.port" = {
      valid = [1024 65535];
      invalid = [1023];
    };
    "services.asterisk.ami.settings" = freeform {
      bool.displayconnects = false;
      int.authtimeout = 60;
      str.channelvars = "CALLERID(num)";
    };
    "services.asterisk.ami.users.<name>.permit" = {
      valid = [["10.0.0.0/8"] ["10.0.0.0/255.0.0.0" "::1/128"]];
      invalid = [["10.0.0.0/33"] ["pbx"]];
    };
    "services.asterisk.ami.users.<name>.read" = {
      valid = [["system" "call"] ["all"]];
      invalid = [["q7class"]];
    };
    "services.asterisk.ami.users.<name>.write" = {
      valid = [["originate"]];
      invalid = [["q7class"]];
    };
    "services.asterisk.ami.users.<name>.secret" = {
      valid = [(credential "ami") password];
      warn = ["hunter2"];
    };
    "services.asterisk.ami.users.<name>.settings" = freeform {
      int.writetimeout = 1000;
      bool.allowmultiplelogin = false;
      str.eventfilter = "!Event: Newexten";
    };
    "services.asterisk.ari.allowedOrigins".valid = [["https://ari.example.org" "https://ops.example.org"]];
    "services.asterisk.ari.settings" = freeform {
      bool.pretty = true;
      int.websocket_write_timeout = 200;
    };
    "services.asterisk.ari.users.<name>.password" = {
      valid = [password];
      warn = ["hunter2"];
    };
    "services.asterisk.cdr.csv.settings" = freeform {bool.usegmtime = true;};
    "services.asterisk.cdr.settings" = freeform {
      bool.batch = true;
      int.size = 100;
    };
    "services.asterisk.cdr.sqlite.table" = {
      valid = ["calls"];
      invalid = [""];
    };
    "services.asterisk.cel.events" = {
      valid = [["CHAN_START" "CHAN_END" "ANSWER" "HANGUP"]];
      invalid = [["Q7_EVENT"]];
    };
    "services.asterisk.cel.sqlite.table" = {
      valid = ["events"];
      invalid = [""];
    };
    "services.asterisk.confbridge.bridges.<name>.language".valid = ["de"];
    "services.asterisk.confbridge.bridges.<name>.settings" = freeform {
      int.mixing_interval = 40;
      bool.binaural_active = false;
      str.sound_join = "confbridge-join";
    };
    # strings as the action of key *1 of menu *1
    "services.asterisk.confbridge.menus" = {
      valid = [{admin_menu."*1" = "toggle_mute";}];
      invalid = [{admin_menu."*1" = "q7action";}];
      key = "*1";
    };
    "services.asterisk.confbridge.users.<name>.musicOnHoldClass" = {
      valid = ["default"];
      invalid = ["q7class"];
    };
    "services.asterisk.confbridge.users.<name>.pin" = {
      valid = [password];
      warn = ["1234"];
    };
    "services.asterisk.confbridge.users.<name>.settings" = freeform {
      bool.announce_join_leave = true;
      int.dsp_silence_threshold = 2500;
      str.music_on_hold_class = "default";
    };
    "services.asterisk.credentials" = {
      valid = [{tls-key = "/var/lib/acme/pbx/key.pem";}];
      invalid = [{secret-x = "/run/x";} {"bad/name" = "/run/x";}];
    };
    "services.asterisk.dialplan.contexts.<name>.comment" = {
      valid = ["calls from the provider"];
      lineBreak = "accept";
    };
    "services.asterisk.dialplan.contexts.<name>.extensions" = {
      valid = [
        {"100" = ["Answer()" "Playback(hello-world)" "Hangup()"];}
        # VoiceMail is there with app_voicemail
        (voicemail {
          "_1XX" = [
            {
              app = "Dial";
              args = ["PJSIP/\${EXTEN}" 20];
            }
            {
              app = "VoiceMail";
              args = ["\${EXTEN}@default"];
              label = "unavailable";
            }
          ];
        })
      ];
      invalid = [
        {"100" = [];}
        {"1,00" = ["NoOp()"];}
        {"100" = ["Dial(PJSIP/101"];}
        {"100" = ["Q7NoSuchApp(x)"];}
        {"100" = ["q7notanapp"];}
      ];
      key = "100";
    };
    "services.asterisk.dialplan.contexts.<name>.extraConfig" = {
      valid = ["exten => 999,1,Playback(tt-monkeys)"];
      strings = false;
    };
    "services.asterisk.dialplan.contexts.<name>.hints" = {
      valid = [{"101" = "PJSIP/101";}];
      invalid = [{"101" = "Q7Tech/101";}];
      key = "101";
    };
    "services.asterisk.dialplan.contexts.<name>.ignorePatterns".valid = [["9"]];
    "services.asterisk.dialplan.contexts.<name>.includes" = {
      valid = [["internal"] ["internal,09:00-17:00,mon-fri,*,*"]];
      invalid = [["nowhere"]];
    };
    # a switch's module is loaded with it
    "services.asterisk.dialplan.contexts.<name>.switches".valid = [["Realtime/default@extensions"]];
    "services.asterisk.dialplan.general" = freeform {
      bool.autofallthrough = false;
      str.userscontext = "internal";
    };
    "services.asterisk.dialplan.globals" = {
      valid = [
        {TRUNK = "PJSIP/provider";}
        {COUNT = 3;}
        {ENABLED = true;}
      ];
      key = "CAMPAIGN";
    };
    # systemd's ExecStart, which escapes them for systemd
    "services.asterisk.extraArguments" = {
      valid = [["-vvv"]];
      invalid = [["--q7-no-such-option"]];
      verbatim = false;
    };
    "services.asterisk.extraConfig" = {
      valid = [{"extensions.conf" = "[legacy]\nexten => 999,1,Playback(tt-monkeys)\n";}];
      invalid = [{"pjsip.conf" = "[q7]\ntype = q7type\n";}];
      strings = false;
    };
    "services.asterisk.features.applications.<name>.app" = {
      valid = ["Playback"];
      invalid = ["Q7NoSuchApp"];
    };
    "services.asterisk.features.applications.<name>.args".valid = ["tt-weasels"];
    "services.asterisk.features.applications.<name>.dtmf" = {
      valid = ["*9" "#7"];
      invalid = ["q7"];
    };
    "services.asterisk.features.featureMap" = {
      valid = [{blindxfer = "#1";} {automixmon = "*3";}];
      invalid = [{q7feature = "*1";} {blindxfer = "q7";}];
      key = "blindxfer";
    };
    "services.asterisk.features.general" = freeform {
      int.featuredigittimeout = 1500;
      str.pickupexten = "*8";
    };
    # only with openFirewall
    "services.asterisk.firewallInterfaces" = {
      valid = [["lan" "voip"]];
      full = true;
      extra.services.asterisk.openFirewall = true;
    };
    "services.asterisk.http.address" = {
      valid = ["0.0.0.0" "::1" "10.0.20.10"];
      invalid = ["pbx" "300.0.0.1"];
    };
    "services.asterisk.http.settings" = freeform {
      str.prefix = "asterisk";
      int.sessionlimit = 100;
    };
    "services.asterisk.http.tls.address" = {
      valid = ["0.0.0.0" "::1"];
      invalid = ["pbx"];
    };
    # tls.enable needs both
    "services.asterisk.http.tls.certFile" = {
      valid = ["/var/lib/acme/pbx/fullchain.pem"];
      default = "reject";
      invalid = [null];
    };
    "services.asterisk.http.tls.keyFile" = {
      valid = ["/var/lib/acme/pbx/privkey.pem"];
      default = "reject";
      invalid = [null];
    };
    "services.asterisk.includes.<name>.*.file" = {
      valid = ["pjsip-local.conf"];
      # a file outside the store does not exist where the check runs
      limitations."\"pjsip-local.conf\"" = "the included file is not in the build";
    };
    "services.asterisk.includes.<name>.*.optional".limitations = {
      default = "the included file is not in the build";
      false = "the included file is not in the build";
    };
    "services.asterisk.logger.channels" = {
      valid = [
        {messages = ["notice" "warning" "error"];}
        {"syslog.local0" = ["warning" "error"];}
        {security = ["security"];}
        {console = [];}
      ];
      invalid = [{messages = ["q7level"];}];
      key = "messages";
    };
    "services.asterisk.logger.dateFormat".valid = ["%F %T"];
    # the options load the modules they need, but not what those need
    "services.asterisk.modules.defaultModules".invalid = [false];
    "services.asterisk.modules.load" = {
      valid = [["app_system.so"] ["app_system"]];
      invalid = [["q7_no_such_module.so"] ["chan_sip.so"]];
    };
    "services.asterisk.modules.noload" = {
      valid = [["res_pjsip_messaging.so"]];
      invalid = [["res_pjsip.so"]];
    };
    "services.asterisk.modules.preload" = {
      # a module without a configuration file of its own
      valid = [["func_md5.so"]];
      invalid = [["q7_no_such_module.so"]];
    };
    "services.asterisk.musicOnHold.classes.<name>.application".valid = [
      (with' {services.asterisk.musicOnHold.classes.office.mode = "custom";} "${pkgs.coreutils}/bin/cat /dev/zero")
    ];
    # mode files needs one
    "services.asterisk.musicOnHold.classes.<name>.directory" = {
      default = "reject";
      valid = ["moh" (pkgs.linkFarm "campaign-moh" [])];
      invalid = ["q7-no-such-directory" null];
    };
    "services.asterisk.musicOnHold.classes.<name>.entries".valid = [
      (with' {services.asterisk.musicOnHold.classes.office.mode = "playlist";} ["http://example.org/stream.mp3"])
    ];
    "services.asterisk.musicOnHold.classes.<name>.mode" = {
      valid = [
        (with' {services.asterisk.musicOnHold.classes.office.application = "${pkgs.coreutils}/bin/cat /dev/zero";} "custom")
        (with' {services.asterisk.musicOnHold.classes.office.entries = ["http://example.org/stream.mp3"];} "playlist")
      ];
      invalid = ["custom" "playlist"];
    };
    "services.asterisk.musicOnHold.classes.<name>.settings" = freeform {str.announcement = "queue-thankyou";};
    "services.asterisk.pjsip.acls.<name>.contactDeny".invalid = [["q7net"]];
    "services.asterisk.pjsip.acls.<name>.contactPermit".invalid = [["q7net"]];
    "services.asterisk.pjsip.acls.<name>.deny" = {
      valid = [["0.0.0.0/0.0.0.0" "::/0"]];
      invalid = [["q7net"] ["10.0.0.0/33"]];
    };
    "services.asterisk.pjsip.acls.<name>.permit" = {
      valid = [["10.0.1.0/24" "2001:db8::/32"]];
      invalid = [["q7net"]];
    };
    "services.asterisk.pjsip.acls.<name>.settings" = freeform {};
    "services.asterisk.pjsip.endpoints.<name>.allow" = {
      valid = [["ulaw"] ["opus" "g722"] ["ulaw" "ulaw"]];
      invalid = [["q7codec"]];
    };
    "services.asterisk.pjsip.endpoints.<name>.aor.contacts" = {
      valid = [["sip:10.0.2.21:5060"]];
      invalid = [["q7 contact"]];
    };
    "services.asterisk.pjsip.endpoints.<name>.aor.name".valid = ["102-phone"];
    "services.asterisk.pjsip.endpoints.<name>.aor.settings" = freeform {
      int.default_expiration = 1800;
      bool.remove_unavailable = true;
      str.outbound_proxy = "sip:proxy.example.org";
    };
    "services.asterisk.pjsip.endpoints.<name>.auth.name".valid = ["102-auth"];
    "services.asterisk.pjsip.endpoints.<name>.auth.password" = {
      valid = [(credential "sip-102")];
      warn = ["hunter2"];
    };
    "services.asterisk.pjsip.endpoints.<name>.auth.realm".valid = ["pbx.example.org"];
    "services.asterisk.pjsip.endpoints.<name>.auth.settings" = freeform {str.auth_type = "digest";};
    # the endpoint's name unless set
    "services.asterisk.pjsip.endpoints.<name>.auth.username" = {
      valid = ["alice"];
      default = "accept";
    };
    # Asterisk keeps 79 bytes of a caller ID's name and of its number
    "services.asterisk.pjsip.endpoints.<name>.callerId" = {
      valid = [''"Kitchen" <101>'' "Kitchen <101>" "101" (lib.strings.replicate 79 "x")];
      invalid = [(lib.strings.replicate 80 "x")];
    };
    "services.asterisk.pjsip.endpoints.<name>.context" = {
      valid = ["internal"];
      invalid = ["nowhere" ""];
    };
    "services.asterisk.pjsip.endpoints.<name>.identify.match" = {
      valid = [["10.0.0.5"] ["198.51.100.0/24"] ["gate.example.org"]];
      invalid = [[] ["q7 host"]];
    };
    "services.asterisk.pjsip.endpoints.<name>.identify.name".valid = ["102-identify"];
    "services.asterisk.pjsip.endpoints.<name>.identify.settings" = freeform {bool.srv_lookups = false;};
    # with voicemail off nothing sends a mailbox's MWI
    "services.asterisk.pjsip.endpoints.<name>.mailboxes" = {
      valid = [(with' {services.asterisk.voicemail.mailboxes."102".pin = password;} ["102@default"])];
      warn = [["102@default"]];
    };
    # the endpoint has neither auth nor identify
    "services.asterisk.pjsip.endpoints.<name>.open" = {
      default = "reject";
      invalid = [false];
    };
    "services.asterisk.pjsip.endpoints.<name>.outboundAuth.name".valid = ["102-out"];
    "services.asterisk.pjsip.endpoints.<name>.outboundAuth.password".warn = ["hunter2"];
    "services.asterisk.pjsip.endpoints.<name>.outboundAuth.realm".valid = ["provider.example"];
    "services.asterisk.pjsip.endpoints.<name>.outboundAuth.settings" = freeform {str.auth_type = "digest";};
    "services.asterisk.pjsip.endpoints.<name>.outboundAuth.username".valid = ["alice"];
    "services.asterisk.pjsip.endpoints.<name>.settings" = freeform {
      int.rtp_timeout = 30;
      bool.send_pai = true;
      str.language = language;
      list.set_var = ["A=1" "B=2"];
      wrong.rtp_timeout = 0.5;
    };
    "services.asterisk.pjsip.endpoints.<name>.transport" = {
      valid = ["udp"];
      invalid = ["nope"];
    };
    "services.asterisk.pjsip.global" = freeform {
      str.user_agent = "PBX";
      int.max_forwards = 70;
      bool.ignore_uri_user_options = true;
    };
    "services.asterisk.pjsip.system" = freeform {
      int.timer_t1 = 500;
      bool.disable_tcp_switch = true;
    };
    "services.asterisk.pjsip.transports.<name>.address" = {
      valid = ["10.0.2.1" "::1" "::"];
      invalid = ["pbx" "300.0.0.1" "10.0.0.1:5060"];
    };
    "services.asterisk.pjsip.transports.<name>.externalMediaAddress" = {
      valid = ["203.0.113.1" "pbx.example.org"];
      invalid = ["q7 address"];
    };
    "services.asterisk.pjsip.transports.<name>.externalSignalingAddress" = {
      valid = ["203.0.113.1" "pbx.example.org"];
      invalid = ["q7 address"];
    };
    "services.asterisk.pjsip.transports.<name>.localNet" = {
      valid = [["10.0.0.0/8"] ["192.168.0.0/255.255.0.0" "2001:db8::/32"]];
      invalid = [["q7net"]];
    };
    "services.asterisk.pjsip.transports.<name>.protocol" = {
      valid = [
        (with' {
          services.asterisk.pjsip.transports.lan.tls = {
            certFile = "/var/lib/acme/pbx/cert.pem";
            keyFile = "/var/lib/acme/pbx/key.pem";
          };
        } "tls")
        (with' {services.asterisk.http.enable = true;} "ws")
        (with' {
          services.asterisk.http = {
            enable = true;
            tls = {
              enable = true;
              certFile = "/var/lib/acme/pbx/cert.pem";
              keyFile = "/var/lib/acme/pbx/key.pem";
            };
          };
        } "wss")
      ];
    };
    "services.asterisk.pjsip.transports.<name>.settings" = freeform {
      str.tos = "cs3";
      int.cos = 3;
      bool.symmetric_transport = true;
    };
    "services.asterisk.pjsip.transports.<name>.tls.caListFile".valid = ["/var/lib/acme/pbx/chain.pem"];
    # a tls transport needs both
    "services.asterisk.pjsip.transports.<name>.tls.certFile" = {
      valid = ["/var/lib/acme/pbx/fullchain.pem"];
      default = "reject";
      invalid = [null];
    };
    "services.asterisk.pjsip.transports.<name>.tls.keyFile" = {
      valid = ["/var/lib/acme/pbx/privkey.pem"];
      default = "reject";
      invalid = [null];
    };
    # against the system's CA bundle, any certificate a public CA signed passes
    "services.asterisk.pjsip.transports.<name>.tls.verifyClient" = {
      valid = [(with' {services.asterisk.pjsip.transports.lan.tls.caListFile = "/var/lib/acme/pbx/chain.pem";} true)];
      invalid = [true];
    };
    "services.asterisk.pjsip.trunks.<name>.aorSettings" = freeform {int.default_expiration = 1800;};
    "services.asterisk.pjsip.trunks.<name>.allow" = {
      valid = [["alaw"]];
      invalid = [["q7codec"]];
    };
    "services.asterisk.pjsip.trunks.<name>.callerId".valid = [''"Office" <5551000>''];
    "services.asterisk.pjsip.trunks.<name>.context" = {
      valid = ["internal"];
      invalid = ["nowhere"];
    };
    "services.asterisk.pjsip.trunks.<name>.fromDomain".valid = ["provider.example"];
    "services.asterisk.pjsip.trunks.<name>.host" = {
      # registering with an IPv6 address needs a transport that listens on IPv6
      valid = ["203.0.113.5" (with' {services.asterisk.pjsip.transports.udp.address = "::";} "2001:db8::5") "sip.provider.example"];
      invalid = ["" "q7 host"];
    };
    # empty unless set, and an identify that matches nothing is refused: the
    # trunk's host has an identify section of its own
    "services.asterisk.pjsip.trunks.<name>.identify.match" = {
      default = "reject";
      valid = [["198.51.100.0/24"]];
      invalid = [[] ["q7 host"]];
    };
    "services.asterisk.pjsip.trunks.<name>.identify.settings" = freeform {bool.srv_lookups = false;};
    "services.asterisk.pjsip.trunks.<name>.outboundAuth.settings" = freeform {str.auth_type = "digest";};
    "services.asterisk.pjsip.trunks.<name>.outboundAuth.username".valid = ["account"];
    "services.asterisk.pjsip.trunks.<name>.password" = {
      valid = [(credential "trunk")];
      warn = ["hunter2"];
    };
    "services.asterisk.pjsip.trunks.<name>.registration.contactUser".valid = ["5551000"];
    "services.asterisk.pjsip.trunks.<name>.registration.settings" = freeform {
      int.max_retries = 20;
      bool.auth_rejection_permanent = false;
    };
    "services.asterisk.pjsip.trunks.<name>.settings" = freeform {
      int.rtp_timeout = 30;
      bool.send_pai = true;
      str.language = language;
    };
    "services.asterisk.pjsip.trunks.<name>.transport" = {
      valid = ["udp"];
      invalid = ["nope"];
    };
    "services.asterisk.pjsip.trunks.<name>.username".valid = ["account"];
    "services.asterisk.queues.queues.<name>.members" = {
      valid = [
        ["PJSIP/101" "Local/101@internal"]
        [
          {
            interface = "PJSIP/101";
            penalty = 1;
            name = "Alice";
          }
        ]
      ];
      invalid = [["q7member"]];
      verbatim = false;
    };
    # member fields are escaped for app_queue, which reads them back
    "services.asterisk.queues.queues.<name>.members.*.interface" = {
      valid = ["Local/101@internal"];
      invalid = ["q7member"];
      verbatim = false;
    };
    "services.asterisk.queues.queues.<name>.members.*.name" = {
      valid = ["Alice"];
      verbatim = false;
    };
    # app_queue overflows from 2147 on
    "services.asterisk.queues.queues.<name>.members.*.penalty" = {
      valid = [0 2146];
      invalid = [2147];
    };
    "services.asterisk.queues.queues.<name>.members.*.stateInterface" = {
      valid = ["PJSIP/101"];
      verbatim = false;
    };
    "services.asterisk.queues.queues.<name>.musicOnHoldClass" = {
      valid = ["default"];
      invalid = ["q7class"];
    };
    "services.asterisk.queues.queues.<name>.settings" = freeform {
      int.announce-frequency = 60;
      str.joinempty = "paused,invalid";
      bool.ringinuse = false;
    };
    # rtpstart must stay below rtpend, and both from 1024 to 65535
    "services.asterisk.rtp.portRange.from" = {
      valid = [(with' {services.asterisk.rtp.portRange.to = 65535;} 65534) 10001 1024];
      invalid = [65535 1023];
    };
    "services.asterisk.rtp.portRange.to" = {
      valid = [(with' {services.asterisk.rtp.portRange.from = 1024;} 1025)];
      invalid = [1023 10000];
    };
    "services.asterisk.rtp.settings" = freeform {
      int.rtcpinterval = 5000;
      bool.rtpchecksums = true;
    };
    # a STUN or TURN server serves ICE alone, which no endpoint uses without
    # ice_support
    "services.asterisk.rtp.stunServer" = {
      valid = [(iceEndpoint "stun.example.org:3478")];
      warn = ["stun.example.org:3478" "203.0.113.9"];
      invalid = ["q7 host"];
    };
    "services.asterisk.rtp.turn.password" = {
      valid = [password];
      warn = ["hunter2"];
    };
    "services.asterisk.rtp.turn.server" = {
      valid = [(iceEndpoint "turn.example.org:3478")];
      warn = ["turn.example.org:3478"];
    };
    "services.asterisk.rtp.turn.username".valid = ["pbx"];
    # CORE-01: each kind of value in each file, under a key of that file that
    # takes it; a float where Asterisk reads an integer, and keys no module
    # knows, must not load
    "services.asterisk.settings" = {
      valid = [
        {"asterisk.conf".options.transmit_silence = true;}
        {"asterisk.conf".options.maxcalls = 100;}
        {"asterisk.conf".options.maxload = 0.9;}
        {"asterisk.conf".options.systemname = "pbx";}
        {"modules.conf".modules.load = ["app_system.so" "func_shell.so"];}
        {"pjsip.conf"."endpoint:101".send_pai = true;}
        {"pjsip.conf"."endpoint:101".rtp_timeout = 30;}
        {"pjsip.conf"."endpoint:101".language = language;}
        {"pjsip.conf"."endpoint:101".set_var = ["A=1" "B=2"];}
        {"pjsip.conf"."auth:101".password = secret "/run/secrets/101-settings";}
        {
          "pjsip.conf".campaign-auth = {
            name = "campaign";
            type = "auth";
            username = "campaign";
            password_digest = "SHA-256:${secret "/run/secrets/digest"}";
            supported_algorithms_uas = "SHA-256";
            supported_algorithms_uac = "SHA-256";
          };
        }
        {"extensions.conf".globals.RATIO = 1.5;}
        {"extensions.conf".globals.ENABLED = true;}
        {"extensions.conf".internal.exten = ["300,1,Answer()" "300,n,Hangup()"];}
        {"rtp.conf".general.rtcpinterval = 5000;}
        {"rtp.conf".general.icesupport = false;}
        {"rtp.conf".general.stunaddr = "203.0.113.9:3478";}
        {"logger.conf".general.rotatestrategy = "rotate";}
        {"logger.conf".general.queue_log = true;}
        (voicemail {"voicemail.conf".general.volgain = 0.5;})
        (voicemail {"voicemail.conf".general.maxmsg = 50;})
        (voicemail {"voicemail.conf".general.attach = false;})
        (voicemail {"voicemail.conf".general.serveremail = "pbx@example.org";})
        (voicemail {"voicemail.conf".general.mailcmd = "${pkgs.coreutils}/bin/true";})
        {
          "musiconhold.conf".office = {
            mode = "files";
            directory = pkgs.linkFarm "campaign-moh" [];
          };
        }
        {
          "confbridge.conf".board = {
            type = "bridge";
            max_members = 10;
            record_conference = false;
          };
        }
        (queues {
          "queues.conf".support = {
            member = ["PJSIP/101" "PJSIP/102"];
            timeout = 15;
            ringinuse = false;
            strategy = "rrmemory";
          };
        })
        {"features.conf".general.featuredigittimeout = 1500;}
        {"features.conf".general.pickupexten = "*8";}
        {"manager.conf".general.displayconnects = false;}
        {"http.conf".general.sessionlimit = 50;}
        {"cdr.conf".general.batch = true;}
        {"cdr.conf".general.size = 50;}
        {"cel.conf".general.dateformat = "%F %T";}
        {"indications.conf".general.country = "de";}
        {"udptl.conf".general.udptlstart = 4000;}
        {"ccss.conf".general.cc_max_requests = 20;}
        {
          "acl.conf".office = {
            deny = ["0.0.0.0/0.0.0.0"];
            permit = ["10.0.0.0/8" "192.168.0.0/16"];
          };
        }
      ];
      invalid = [
        {"pjsip.conf"."endpoint:101".rtp_timeout = 0.5;}
        {"asterisk.conf".options.maxcalls = 0.5;}
        {"asterisk.conf".options.q7unknown = true;}
        {"pjsip.conf"."endpoint:101".q7unknown = true;}
        {"extensions.conf".general.q7unknown = true;}
        {"rtp.conf".general.q7unknown = true;}
        (voicemail {"voicemail.conf".general.q7unknown = true;})
        {"confbridge.conf".general.q7unknown = true;}
        (queues {"queues.conf".general.q7unknown = true;})
        {"features.conf".general.q7unknown = true;}
        {"manager.conf".general.q7unknown = true;}
        {"http.conf".general.q7unknown = true;}
        {"cdr.conf".general.q7unknown = true;}
        {"cel.conf".general.q7unknown = true;}
        {"logger.conf".general.q7unknown = true;}
        {"musiconhold.conf".default.q7unknown = true;}
        {"indications.conf".general.q7unknown = true;}
        {"udptl.conf".general.q7unknown = true;}
        {"ccss.conf".general.q7unknown = true;}
        {"acl.conf".office.q7unknown = true;}
      ];
    };
    "services.asterisk.settings.<name>.<name>.comment" = {
      valid = ["from the campaign"];
      lineBreak = "accept";
    };
    "services.asterisk.settings.<name>.<name>.inherits".invalid = [["nowhere"]];
    "services.asterisk.settings.<name>.<name>.name".valid = ["campaign-renamed"];
    "services.asterisk.sounds.packages".valid = [[(pkgs.linkFarm "campaign-sounds" [])]];
    # key and section names, which only change how the file is written
    "services.asterisk.syntax".names = false;
    "services.asterisk.syntax.<name>.arrowKeys" = {
      valid = [["type"]];
      strings = false;
    };
    "services.asterisk.syntax.<name>.arrowSections" = {
      valid = [["udp"]];
      strings = false;
    };
    "services.asterisk.syntax.<name>.keyOrder" = {
      valid = [["type" "protocol"]];
      strings = false;
    };
    "services.asterisk.voicemail.email.command".valid = ["${pkgs.msmtp}/bin/msmtp --read-envelope-from -t"];
    "services.asterisk.voicemail.email.fromAddress".valid = ["pbx@example.org"];
    "services.asterisk.voicemail.email.fromName".valid = ["Voicemail"];
    "services.asterisk.voicemail.format" = {
      valid = [["wav"] ["wav49" "gsm"]];
      invalid = [["q7format"]];
    };
    "services.asterisk.voicemail.mailboxes.<name>.context" = {
      valid = ["sales"];
      invalid = ["general" ""];
    };
    "services.asterisk.voicemail.mailboxes.<name>.email" = {
      valid = [(with' {services.asterisk.voicemail.email.command = "/run/current-system/sw/bin/msmtp -t";} "alice@example.org")];
      invalid = ["alice@example.org"];
    };
    "services.asterisk.voicemail.mailboxes.<name>.fullName".valid = ["Alice Doe"];
    # app_voicemail ignores a mailbox that starts with *
    "services.asterisk.voicemail.mailboxes.<name>.mailbox" = {
      valid = ["7002" "4*2"];
      invalid = ["q7 box" "" "*42"];
    };
    "services.asterisk.voicemail.mailboxes.<name>.options" = {
      valid = [{attach = true;} {saycid = true;} {tz = "eastern";} {volgain = 0.5;}];
      invalid = [{q7option = true;}];
      key = "saycid";
    };
    "services.asterisk.voicemail.mailboxes.<name>.pagerEmail".valid = [
      (with' {services.asterisk.voicemail.email.command = "/run/current-system/sw/bin/msmtp -t";} "pager@example.org")
    ];
    "services.asterisk.voicemail.mailboxes.<name>.pin" = {
      valid = [(credential "vm-7001")];
      warn = ["1234"];
      invalid = ["12,34"];
    };
    "services.asterisk.voicemail.settings" = freeform {
      int.minsecs = 2;
      float.volgain = 0.5;
      bool.review = true;
      str.emaildateformat = "%A, %B %d, %Y at %r";
    };

    "pbx.conferences.<name>.bridgeProfile" = {
      valid = ["default_bridge"];
      invalid = ["nope"];
    };
    "pbx.conferences.<name>.number" = {
      valid = ["801"];
      invalid = ["80a" "620"];
    };
    "pbx.conferences.<name>.userProfile" = {
      valid = ["default_user"];
      invalid = ["nope"];
    };
    "pbx.emergency.callerId".valid = ["5551000"];
    "pbx.emergency.notify" = {
      valid = [["201" "202"]];
      invalid = [["299"]];
    };
    "pbx.emergency.numbers" = {
      valid = [["112" "911"]];
      invalid = [["620"]];
    };
    "pbx.emergency.trunk".invalid = ["nope"];
    "pbx.extensions.<name>.name".valid = ["Reception"];
    "pbx.extensions.<name>.pickupGroups" = {
      valid = [["front" "sales team"]];
      invalid = [["front,back"] ["front "]];
    };
    "pbx.extensions.<name>.password" = {
      valid = [(credential "sip-203")];
      warn = ["hunter2"];
    };
    "pbx.extensions.<name>.voicemail.email" = {
      valid = [(with' {services.asterisk.voicemail.email.command = "/run/current-system/sw/bin/msmtp -t";} "alice@example.org")];
      invalid = ["alice@example.org"];
    };
    "pbx.extensions.<name>.voicemail.pin".warn = ["1234"];
    "pbx.hours.<name>.closeEarly" = {
      valid = ["*28"];
      invalid = ["*8" "28a" "620"];
    };
    "pbx.hours.<name>.holidays" = {
      valid = [["dec 24-26" "jan 1"] ["feb 29"]];
      invalid = [["feb 30"] ["dec 30-2"] ["xyz 1"]];
    };
    "pbx.hours.<name>.open.*.days" = {
      valid = ["sat" "mon&wed" "*" "fri-mon"];
      invalid = ["monday"];
    };
    "pbx.hours.<name>.open.*.time" = {
      valid = ["00:00-23:59" "22:00-06:00"];
      invalid = ["24:00-01:00" "9:00-17:00"];
    };
    "pbx.hours.<name>.timezone" = {
      valid = ["UTC" "America/Argentina/Buenos_Aires"];
      invalid = ["Mars/Olympus_Mons" "zone.tab" "right/UTC"];
    };
    # a number needs a destination, or hours with open and closed
    "pbx.inbound.<name>.hours" = {
      valid = ["office"];
      invalid = ["nope" null];
      default = "reject";
    };
    "pbx.inbound.<name>.destination" = {
      invalid = [null];
      default = "reject";
    };
    "pbx.inbound.<name>.open" = {
      invalid = [null];
      default = "reject";
    };
    "pbx.inbound.<name>.closed" = {
      invalid = [null];
      default = "reject";
    };
    "pbx.inbound.<name>.trunk" = {
      valid = [["provider"]];
      invalid = ["nope" ["provider" "nope"]];
    };
    "pbx.ivrs.<name>.number" = {
      valid = ["701"];
      invalid = ["70a" "620"];
    };
    "pbx.ivrs.<name>.options" = {
      valid = [{"*".extension = "201";} {"#".hangup = true;}];
      invalid = [{"12".extension = "201";} {"a".extension = "201";}];
      key = "3";
    };
    "pbx.ivrs.<name>.prompt.sound".valid = ["custom/main-menu"];
    # spoken by flite when the system is built, not written to a file
    "pbx.ivrs.<name>.prompt.text" = {
      valid = ["For sales, press 1."];
      lineBreak = "accept";
      verbatim = false;
    };
    "pbx.outbound.callerId".valid = ["5551000"];
    "pbx.outbound.prefix" = {
      valid = ["" "0" "*9"];
      invalid = ["9a"];
    };
    "pbx.outbound.trunk".invalid = ["nope"];
    "pbx.paging.<name>.headers" = {
      valid = [["Call-Info: <sip:pbx>;answer-after=0"] []];
      invalid = [["q7 header"]];
    };
    "pbx.paging.<name>.members" = {
      valid = [["201"]];
      invalid = [["299"]];
    };
    "pbx.paging.<name>.number" = {
      valid = ["652"];
      invalid = ["65a" "620"];
    };
    # with none, systemd drops every connection
    "pbx.phones.allowedNetworks" = {
      valid = [["10.0.20.0/24" "2001:db8::/64"]];
      invalid = [[]];
      full = true;
    };
    # written to the provisioning server's manifest
    "pbx.phones.files.<name>.allowedAddress" = {
      valid = ["10.0.20.21"];
      verbatim = false;
    };
    "pbx.phones.files.<name>.text" = {
      valid = ["account.1.password = ${password}\n"];
      lineBreak = "accept";
    };
    "pbx.phones.firewallInterfaces" = {
      valid = [["voip"]];
      full = true;
      extra.pbx.phones.openFirewall = true;
    };
    # 4 to 30 characters, which HT801 V2 hardware takes
    "pbx.phones.grandstream.ht801.adminPassword" = {
      valid = [password];
      warn = ["hunter22"];
      invalid = [0 (-1) "1"];
    };
    "pbx.phones.grandstream.ht801.devices.<name>.allowedAddress" = {
      valid = ["10.0.20.22"];
      verbatim = false;
    };
    "pbx.phones.grandstream.ht801.devices.<name>.endpoint" = {
      valid = ["201"];
      invalid = ["299"];
    };
    "pbx.phones.grandstream.ht801.devices.<name>.mac" = {
      valid = ["C0-74-AD-00-02-02" "c074ad000202"];
      invalid = ["c0:74:ad:00:02" "c0:74:ad:00:02:01"];
    };
    "pbx.phones.grandstream.ht801.devices.<name>.settings" = {
      valid = [{P1362 = "de";} {P30 = 5;}];
      invalid = [{Q7 = "x";}];
      key = "P1362";
    };
    "pbx.phones.grandstream.ht801.ntpServer".valid = ["10.0.20.10"];
    "pbx.phones.grandstream.ht801.settings" = {
      valid = [{P1362 = "en";}];
      invalid = [{Q7 = "x";}];
      key = "P1362";
    };
    "pbx.phones.grandstream.ht801.sipServer".valid = ["10.0.20.10:5060"];
    "pbx.phones.grandstream.ht801.timeZone".valid = ["CET-1CEST-2,M3.5.0/02:00:00,M10.5.0/03:00:00"];
    "pbx.phones.listenAddress" = {
      valid = ["::" "10.0.20.10"];
      full = true;
    };
    "pbx.queues.<name>.members" = {
      valid = [["201" "202"]];
      invalid = [["299"]];
    };
    "pbx.queues.<name>.number" = {
      valid = ["611"];
      invalid = ["61a" "620"];
    };
    "pbx.ringGroups.<name>.external".valid = [["5551234" "5559876"]];
    # a ring group needs members or external numbers
    "pbx.ringGroups.<name>.members" = {
      valid = [["201" "202"]];
      invalid = [["299"] []];
      default = "reject";
    };
    "pbx.ringGroups.<name>.number" = {
      valid = ["601"];
      invalid = ["60a" "620"];
    };
    "pbx.ringGroups.<name>.trunk" = {
      valid = ["provider"];
      invalid = ["nope"];
    };
    "pbx.voicemailMenu" = {
      valid = ["*97"];
      invalid = ["97a" "*8"];
    };
  }
