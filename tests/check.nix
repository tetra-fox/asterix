# The build-time check (services.asterisk.checkConfig) fails on what Asterisk
# rejects, with the lines each case expects, and passes what it accepts.
{
  pkgs,
  self,
  # the examples' configurations, whose checks run again without user namespaces
  examples,
}: let
  inherit (pkgs) lib;
  inherit (import ./eval-lib.nix {inherit pkgs self;}) evalConfig configCheckOf;

  base = {config, ...}: {
    services.asterisk = {
      enable = true;
      pjsip = {
        transports.udp = {};
        endpoints."101" = {
          context = "internal";
          auth.password = config.lib.asterisk.secret "/run/secrets/101";
        };
      };
      dialplan.contexts.internal.extensions."_1XX" = ["Dial(PJSIP/\${EXTEN})"];
    };
  };

  checkOf = module:
    configCheckOf (evalConfig [
      base
      module
    ]);

  # the check on a machine that forbids unprivileged user namespaces, as
  # Ubuntu 24.04 does: the build may not create any below its own
  withoutUserNamespaces = check:
    check.overrideAttrs (old: {
      nativeBuildInputs = (old.nativeBuildInputs or []) ++ [pkgs.util-linux];
      buildCommand = ''
        unshare --user --map-root-user bash -euo pipefail -c ${lib.escapeShellArg ''
          echo 0 > /proc/sys/user/max_user_namespaces
          ${old.buildCommand}
        ''}
      '';
    });

  # the check with a logger thread that writes each line of the check's log
  # late, as on a busy machine
  withSlowLogger = check:
    check.overrideAttrs {
      LD_PRELOAD = "${pkgs.runCommandCC "slow-log" {} ''
        mkdir -p $out/lib
        $CC -shared -fPIC -o $out/lib/slow-log.so ${./slow-log.c}
      ''}/lib/slow-log.so";
    };

  failing = {
    misspelledKey = {
      module.services.asterisk.pjsip.endpoints."101".settings.direct_mdia = false;
      expect = [
        "Could not find option suitable for category '101' named 'direct_mdia'"
        "Could not create an object of type 'endpoint' with id '101'"
        "(services.asterisk.checkConfig = false turns this check off)"
      ];
    };
    # what Asterisk logged while loading counts, however late its logger
    # thread writes it
    misspelledKeyWithSlowLogger = {
      module.services.asterisk.pjsip.endpoints."101".settings.direct_mdia = false;
      slowLogger = true;
      expect = ["Could not create an object of type 'endpoint' with id '101'"];
    };
    applicationNotLoaded = {
      module.services.asterisk.dialplan.contexts.internal.extensions."411" = ["Directory(default)"];
      expect = ["(internal, 411): no loaded module provides the application Directory"];
    };
    # the reference checks cannot see into an included file, Asterisk loads it
    # here
    includedFileProblem = {
      module.services.asterisk.includes."pjsip.conf" = [
        "${pkgs.writeText "pjsip-local.conf" ''
          [102]
          type = endpoint
          context = internal
          direct_mdia = no
        ''}"
      ];
      expect = ["Could not find option suitable for category '102' named 'direct_mdia'"];
    };
    aelApplicationNotLoaded = {
      module.services.asterisk = {
        modules.load = [
          "res_ael_share"
          "pbx_ael"
        ];
        extraConfig."extensions.ael" = "context from-ael { 411 => Directory(default); };";
      };
      expect = ["pbx_ael (from-ael, 411): no loaded module provides the application Directory"];
    };
    functionsNotLoaded = {
      module.services.asterisk.dialplan.contexts.internal.extensions."412" = [
        "NoOp(\${SHELL(ls)})"
        "Set(LOCK(x)=1)"
      ];
      expect = [
        "(internal, 412): no loaded module provides the function SHELL"
        "(internal, 412): no loaded module provides the function LOCK"
      ];
    };
    # Asterisk says it blocks all SIP traffic, then drops the whole ACL
    malformedAcl = {
      module.services.asterisk.pjsip.acls.lan = {
        contactDeny = ["0.0.0.0/0.0.0.0"];
        contactPermit = ["10.0.300.0/24"];
      };
      expect = [
        "Bad contact ACL '10.0.300.0/24'"
        "Could not create an object of type 'acl' with id 'lan'"
      ];
    };
    # Asterisk closes it and warns
    unclosedParenthesis = {
      module.services.asterisk.dialplan.contexts.internal.extensions."413" = ["Dial(PJSIP/101"];
      expect = ["No closing parenthesis found? 'Dial(PJSIP/101'"];
    };
    ipv6AddressWithoutUserNamespaces = {
      module.services.asterisk.pjsip.transports.udp.address = "2001:db8::10";
      withoutUserNamespaces = true;
      expect = ["needs a user and network namespace of its own (to listen on 2001:db8::10)"];
    };
    lowPortWithoutUserNamespaces = {
      module.services.asterisk.pjsip.transports.web = {
        protocol = "tcp";
        port = 443;
      };
      withoutUserNamespaces = true;
      expect = ["(to listen below port 1024)"];
    };
    # AMI only takes ports from 1024 up, whatever the privileges
    amiBelowPort1024 = {
      module.services.asterisk.ami = {
        enable = true;
        port = 1000;
      };
      expect = ["Invalid port number '1000'"];
    };
    # an assertion reports it first; the check shows that Asterisk refuses
    # the file
    parentAfterChild = {
      module.services.asterisk.settings."pjsip.conf" = {
        early = {
          order = 0;
          inherits = ["late"];
        };
        late = {
          template = true;
          type = "endpoint";
          context = "internal";
        };
      };
      expect = [
        "Inheritance requested, but category 'late' does not exist"
        "Contents of config file 'pjsip.conf' are invalid and cannot be parsed"
      ];
    };
  };

  # IPv4 addresses become loopback ones, which need no namespace
  passingWithoutUserNamespaces = {
    ipv4Addresses.services.asterisk.pjsip.transports = {
      udp.address = "10.0.10.10";
      voip.address = "10.0.20.10";
    };
    # [::] and ::1 need no namespace either: the build's loopback interface
    # has ::1
    ipv6WildcardAndLoopback.services.asterisk = {
      pjsip.transports.udp.address = "::";
      http = {
        enable = true;
        address = "::1";
        tls = {
          enable = true;
          certFile = "/var/lib/acme/pbx/cert.pem";
          keyFile = "/var/lib/acme/pbx/key.pem";
        };
      };
      ami = {
        enable = true;
        address = "::1";
      };
    };
  };

  passing = {
    base = {};
    # res_parking, which parkcall loads, starts from the file rendered for it
    parkcall.services.asterisk.features.featureMap.parkcall = "#72";
    # an endpoint in a context only the AEL dialplan defines, and a Lua one
    aelAndLuaDialplans.services.asterisk = {
      pjsip.endpoints."101".context = lib.mkForce "from-ael";
      modules.load = [
        "res_ael_share"
        "pbx_ael"
        "pbx_lua"
      ];
      extraConfig = {
        "extensions.ael" = "context from-ael { _1XX => Dial(PJSIP/\${EXTEN}); };";
        "extensions.lua" = ''
          extensions = {
            ["from-lua"] = {
              ["_1XX"] = function(context, extension)
                app.dial("PJSIP/" .. extension)
              end;
            };
          }
        '';
      };
    };
    # what the reference checks accept since they resolve templates
    endpointFromTemplate.services.asterisk.settings."pjsip.conf" = {
      phone = {
        template = true;
        type = "endpoint";
        context = "internal";
      };
      gate = {
        inherits = ["phone"];
        aors = "gate";
      };
      "aor:gate" = {
        name = "gate";
        type = "aor";
        contact = "sip:10.0.0.5";
      };
      "identify:gate" = {
        name = "gate";
        type = "identify";
        endpoint = "gate";
        match = ["10.0.0.5"];
      };
    };
    # sorcery takes `type` from the first section that sets it: gate is an
    # endpoint (an aor would reject `context`), door an aor (an endpoint
    # would reject remove_existing)
    inheritance.services.asterisk.settings."pjsip.conf" = {
      base = {
        template = true;
        type = "endpoint";
        context = "nowhere";
      };
      phone = {
        template = true;
        inherits = ["base"];
        type = "aor";
        context = "internal";
      };
      gate = {
        inherits = ["phone"];
        aors = "gate";
      };
      "aor:gate" = {
        name = "gate";
        type = "aor";
        max_contacts = 1;
      };
      contact = {
        template = true;
        type = "aor";
        max_contacts = 1;
      };
      door = {
        inherits = ["contact"];
        type = "endpoint";
        remove_existing = true;
      };
    };
    # an identify resolves the host names its template matches too
    identifyMatchFromTemplate.services.asterisk.settings."pjsip.conf" = {
      provider = {
        template = true;
        type = "identify";
        match = ["sip.provider.example"];
      };
      "identify:101" = {
        name = "101";
        inherits = ["provider"];
        endpoint = "101";
        match = ["192.0.2.10"];
      };
    };
    tlsTransport.services.asterisk.pjsip.transports.tls = {
      protocol = "tls";
      tls.certFile = "/var/lib/acme/pbx/cert.pem";
      tls.keyFile = "/var/lib/acme/pbx/key.pem";
    };
    boundAddresses.services.asterisk.pjsip.transports = {
      udp.address = "10.0.20.10";
      v6.address = "2001:db8::10";
    };
    # root in a namespace of its own may listen below 1024
    lowPort.services.asterisk.pjsip.transports.web = {
      protocol = "tcp";
      port = 443;
    };
    # Asterisk resolves the host in identify `match` while loading, and the
    # build has no DNS
    trunkByHostName = {config, ...}: {
      services.asterisk.pjsip.trunks.provider = {
        host = "sip.provider.example";
        username = "5551000";
        password = config.lib.asterisk.secret "/run/secrets/trunk";
        context = "internal";
      };
    };
    # a trunk that matches no address has no identify section, which Asterisk
    # would refuse as matching nothing
    trunkWithoutAddressMatch = {config, ...}: {
      services.asterisk.pjsip.trunks.provider = {
        host = "203.0.113.5";
        username = "5551000";
        password = config.lib.asterisk.secret "/run/secrets/trunk";
        context = "internal";
        register = false;
        matchProviderHost = false;
      };
    };
    # a digest after its algorithm must have that algorithm's length
    sha256Digest = {config, ...}: {
      services.asterisk.pjsip.endpoints."101".auth.settings.password_digest = "SHA-256:${
        config.lib.asterisk.secret "/run/secrets/101-digest"
      }";
    };
  };
in
  pkgs.runCommand "asterisk-config-check-tests" {} ''
    ${lib.concatStrings (
      lib.mapAttrsToList (
        name: case: let
          check =
            if case.withoutUserNamespaces or false
            then withoutUserNamespaces (checkOf case.module)
            else if case.slowLogger or false
            then withSlowLogger (checkOf case.module)
            else checkOf case.module;
          log = "${pkgs.testers.testBuildFailure check}/testBuildFailure.log";
        in
          lib.concatMapStrings (line: ''
            if ! grep -qF ${lib.escapeShellArg line} ${log}; then
              echo ${lib.escapeShellArg "${name}: expected `${line}` in:"} >&2
              cat ${log} >&2
              exit 1
            fi
          '')
          case.expect
      )
      failing
    )}
    # the passing cases only have to build
    : ${lib.concatMapStringsSep " " (module: "${checkOf module}") (lib.attrValues passing)}
    : ${lib.concatMapStringsSep " " (module: "${withoutUserNamespaces (checkOf module)}") (
      lib.attrValues passingWithoutUserNamespaces
    )}
    : ${lib.concatMapStringsSep " " (config: "${withoutUserNamespaces (configCheckOf config)}") (lib.attrValues examples)}
    touch $out
  ''
