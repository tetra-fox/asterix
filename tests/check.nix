# The build-time check (services.asterisk.checkConfig) fails on what Asterisk
# rejects, with the lines each case expects, and passes what it accepts.
{
  pkgs,
  self,
}: let
  inherit (pkgs) lib;
  inherit (import ./eval-lib.nix {inherit pkgs self;}) evalConfig;

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
    lib.findFirst (check: lib.hasPrefix "asterisk-config-check" check.name) (throw "no config check")
    (
      evalConfig [
        base
        module
      ]
    ).system.checks;

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

  failing = {
    misspelledKey = {
      module.services.asterisk.pjsip.endpoints."101".settings.direct_mdia = false;
      expect = ["Could not create an object of type 'endpoint' with id '101'"];
    };
    applicationNotLoaded = {
      module.services.asterisk.dialplan.contexts.internal.extensions."411" = ["Directory(default)"];
      expect = ["(internal, 411): no loaded module provides the application Directory"];
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
  };

  # IPv4 addresses become loopback ones, which need no namespace
  passingWithoutUserNamespaces = {
    ipv4Addresses.services.asterisk.pjsip.transports = {
      udp.address = "10.0.10.10";
      voip.address = "10.0.20.10";
    };
  };

  passing = {
    base = {};
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
    touch $out
  ''
