# The twelve slots of pbx objects that take a destination (the uses of
# modules/pbx/destinations.nix), each with every kind of destination of
# `targets`: extensions 211, 212, ..., ring groups, queues, voice menus and
# announcements to-<kind>, and inbound numbers 5552001, ... and, by hours,
# 5553001, ... The blocklist, which turns away 5550000, has the first kind.
# Kinds are numbered alphabetically, and each slot of an object after the
# first gets the kind after the one before, so they lead to different places.
# The objects need extension 201, trunk provider and hours office.
{lib}: targets: let
  inherit (lib) concatLists concatMap listToAttrs nameValuePair;

  names = builtins.attrNames targets;
  first = builtins.head names;
  count = builtins.length names;
  # the kind `shift` places after the kind numbered `index`
  kindAfter = index: shift: builtins.elemAt names (lib.mod (index - 1 + shift) count);

  objects =
    lib.imap1 (index: kind: {
      inherit kind;
      extension = "21${toString index}";
      name = "to-${kind}";
      inbound = "555200${toString index}";
      inboundByHours = "555300${toString index}";
      next = shift: kindAfter index shift;
    })
    names;

  forEach = f: listToAttrs (map f objects);
in {
  module = {config, ...}: {
    services.asterix = {
      extensions = forEach (o:
        nameValuePair o.extension {
          password = config.lib.asterisk.secret "/run/secrets/sip-${o.extension}";
          noAnswer = targets.${o.kind};
          busy = targets.${o.next 1};
        });
      ringGroups = forEach (o:
        nameValuePair o.name {
          members = ["201"];
          noAnswer = targets.${o.kind};
        });
      queues = forEach (o:
        nameValuePair o.name {
          maxWait = 1;
          noAnswer = targets.${o.kind};
        });
      inbound =
        forEach (o:
          nameValuePair o.inbound {
            trunk = "provider";
            destination = targets.${o.kind};
          })
        // forEach (o:
          nameValuePair o.inboundByHours {
            trunk = "provider";
            hours = "office";
            open = targets.${o.kind};
            closed = targets.${o.next 1};
          });
      ivrs = forEach (o:
        nameValuePair o.name {
          prompt.sound = "beep";
          timeout = 1;
          attempts = 1;
          options."1" = targets.${o.kind};
          noInput = targets.${o.next 1};
          invalid = targets.${o.next 2};
        });
      announcements = forEach (o:
        nameValuePair o.name {
          prompt.sound = "beep";
          destination = targets.${o.kind};
        });
      blocklist = {
        numbers = ["5550000"];
        destination = targets.${first};
      };
    };
  };

  # the inbound numbers by hours, by the kind in their `open` slot
  inboundByHoursTo = forEach (o: nameValuePair o.kind o.inboundByHours);

  # each slot as the assertion on missing destinations names it, with the
  # kind in it, in the order the assertion lists them
  slots = let
    slot = where: kind: {inherit where kind;};
  in
    concatLists [
      (concatMap (o: [
          (slot ''services.asterix.extensions."${o.extension}".noAnswer'' o.kind)
          (slot ''services.asterix.extensions."${o.extension}".busy'' (o.next 1))
        ])
        objects)
      (map (o: slot "services.asterix.ringGroups.${o.name}.noAnswer" o.kind) objects)
      (map (o: slot "services.asterix.queues.${o.name}.noAnswer" o.kind) objects)
      (map (o: slot ''services.asterix.inbound."${o.inbound}".destination'' o.kind) objects)
      (concatMap (o: [
          (slot ''services.asterix.inbound."${o.inboundByHours}".open'' o.kind)
          (slot ''services.asterix.inbound."${o.inboundByHours}".closed'' (o.next 1))
        ])
        objects)
      [(slot "services.asterix.blocklist.destination" first)]
      (concatMap (o: [
          (slot ''services.asterix.ivrs.${o.name}.options."1"'' o.kind)
          (slot "services.asterix.ivrs.${o.name}.noInput" (o.next 1))
          (slot "services.asterix.ivrs.${o.name}.invalid" (o.next 2))
        ])
        objects)
      (map (o: slot "services.asterix.announcements.${o.name}.destination" o.kind) objects)
    ];
}
