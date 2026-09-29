# A pbx that grows with `size`: `size` extensions with a mailbox each, a ring
# group of ten of them for every ten, an inbound number for each group, a
# voice menu for every 25 extensions, a queue, a conference and a page for
# every 50, opening hours, outbound calls and emergency numbers. With
# `directDial`, callers of every menu can dial every extension. The result is
# the system as evalConfig in tests/eval-lib.nix makes it:
#
#   import tests/campaign/scale.nix { self = builtins.getFlake (toString ./.); } { size = 500; }
#
# scale.py measures its evaluation and its config check.
{self}: {
  size,
  directDial ? false,
}: let
  pkgs = self.inputs.nixpkgs.legacyPackages.x86_64-linux;
  inherit (pkgs) lib;
  inherit (import ../eval-lib.nix {inherit pkgs self;}) evalConfig;

  numbers = start: count: map (i: toString (start + i)) (lib.range 0 (count - 1));
  extensions = numbers 2000 size;
  groups = lib.imap0 (i: number: {
    inherit number;
    name = "group${toString i}";
    members = lib.sublist (i * 10) 10 extensions;
  }) (numbers 3000 (size / 10));
  menus = lib.imap0 (i: number: {
    inherit number;
    name = "menu${toString i}";
  }) (numbers 4000 (size / 25));
  fifty = kind: start:
    lib.imap0 (i: number: {
      inherit number;
      name = "${kind}${toString i}";
    }) (numbers start (size / 50));
  queues = fifty "queue" 5000;
  conferences = fifty "room" 6000;
  pages = fifty "page" 7000;

  byName = objects: f: lib.listToAttrs (map (o: lib.nameValuePair o.name (f o)) objects);
in
  evalConfig [
    self.nixosModules.pbx
    ({config, ...}: let
      secret = name: config.lib.asterisk.secret "/run/secrets/${name}";
    in {
      pbx = {
        enable = true;
        extensions = lib.genAttrs extensions (number: {
          name = "Phone ${number}";
          password = secret "sip-${number}";
          voicemail.pin = secret "vm-${number}";
        });
        voicemailMenu = "*97";
        ringGroups = byName groups (group: {
          inherit (group) number members;
          noAnswer.voicemail = builtins.head group.members;
        });
        ivrs = byName menus (menu: {
          inherit (menu) number;
          inherit directDial;
          prompt.sound = "beep";
          options = {
            "1".ringGroup = "group0";
            "2".extension = builtins.head extensions;
          };
          noInput.ringGroup = "group0";
        });
        queues = byName queues (queue: {
          inherit (queue) number;
          timeout = 60;
          noAnswer.voicemail = builtins.head extensions;
        });
        conferences = byName conferences (room: {inherit (room) number;});
        paging = byName pages (page: {
          inherit (page) number;
          members = lib.take 10 extensions;
        });
        hours.office = {
          timezone = "UTC";
          open = [
            {
              days = "mon-fri";
              time = "09:00-17:00";
            }
          ];
          closeEarly = "*28";
        };
        inbound = lib.listToAttrs (lib.imap0 (i: group:
          lib.nameValuePair (toString (5551000 + i)) {
            trunk = "provider";
            hours = "office";
            open.ringGroup = group.name;
            closed.voicemail = builtins.head group.members;
          })
        groups);
        outbound = {
          prefix = "9";
          trunk = "provider";
        };
        emergency = {
          numbers = ["911"];
          trunk = "provider";
          notify = [(builtins.head extensions)];
        };
      };
      services.asterisk = {
        pjsip = {
          transports.udp = {};
          trunks.provider = {
            host = "sip.provider.example";
            username = "5551000";
            password = secret "trunk";
          };
        };
        queues.queues = byName queues (_: {members = map (number: "PJSIP/${number}") (lib.take 5 extensions);});
      };
    })
  ]
