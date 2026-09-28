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
          log = "${pkgs.testers.testBuildFailure (checkOf case.module)}/testBuildFailure.log";
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
    touch $out
  ''
