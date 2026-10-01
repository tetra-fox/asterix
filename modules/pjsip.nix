# Every typed object is rendered as explicit pjsip.conf sections (not the
# pjsip wizard) with the layer-1 ids documented below, so everything can be
# extended or overridden through `settings."pjsip.conf"`:
#
#   transports.<n>  -> "transport:<n>"                     [<n>]  type=transport
#   acls.<n>        -> "acl:<n>"                           [<n>]  type=acl
#   endpoints.<n>   -> "endpoint:<n>"                      [<n>]  type=endpoint
#                      "auth:<n>"          (auth)          [<n>]  type=auth
#                      "outbound-auth:<n>" (outboundAuth)  [<n>-outbound] type=auth
#                      "aor:<n>"           (aor)           [<n>]  type=aor
#                      "identify:<n>"      (identify)      [<n>]  type=identify
#   trunks.<n>      -> the same ids as an endpoint, plus
#                      "registration:<n>"                  [<n>]  type=registration
#
# Single values generated here are defaults (mkDefault), so a value in
# `settings` replaces them; list values (allow, match, permit, ...) are
# extended by further definitions.
{
  config,
  lib,
  ...
}: let
  inherit
    (lib)
    attrNames
    concatLists
    concatStringsSep
    filter
    filterAttrs
    isList
    isString
    mapAttrsToList
    mapAttrs'
    mkDefault
    mkIf
    mkMerge
    mkOption
    mkOptionDefault
    nameValuePair
    optional
    optionalAttrs
    splitString
    types
    unique
    ;

  cfg = config.services.asterisk;
  pcfg = cfg.pjsip;
  asteriskLib = import ../lib {inherit lib;};
  inherit (asteriskLib) format;
  inherit (format) hostPort;
  inherit (format.types) secretOrString;
  inherit (import ./lib.nix {inherit lib;}) settingsOption toSection;

  section = {
    name,
    type,
    order ? 1000,
    values,
    extra ? {},
  }:
    mkMerge [
      (
        {
          inherit name type order;
        }
        // toSection values
      )
      extra
    ];

  # --- submodule types ----------------------------------------------------

  authOptions = {defaultName}: {
    options = {
      name = mkOption {
        type = types.str;
        default = defaultName;
        description = "Name of the auth section.";
      };
      username = mkOption {
        type = types.str;
        description = "User name used for digest authentication.";
      };
      password = mkOption {
        type = secretOrString;
        description = ''
          Password, normally a secret reference such as
          `config.lib.asterisk.secret config.sops.secrets.alice.path`. A plain string
          ends up in the world-readable Nix store and triggers a warning.
        '';
      };
      realm = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Authentication realm; Asterisk's default is `asterisk`.";
      };
      settings = settingsOption "auth";
    };
  };

  inboundAuthType = name:
    types.submodule [
      (authOptions {defaultName = name;})
      {config.username = mkDefault name;}
    ];

  outboundAuthType = name:
    types.submodule (authOptions {
      defaultName = "${name}-outbound";
    });

  aorType = name:
    types.submodule {
      options = {
        name = mkOption {
          type = types.str;
          default = name;
          description = "Name of the aor section, which is also the user part phones register to.";
        };
        maxContacts = mkOption {
          type = types.ints.unsigned;
          default = 1;
          description = "Maximum number of registered contacts (0 accepts no registrations).";
        };
        removeExisting = mkOption {
          type = types.bool;
          default = true;
          description = ''
            When a registration would exceed maxContacts, make room by removing
            the other contacts that expire soonest, instead of refusing it with
            403.
          '';
        };
        qualifyFrequency = mkOption {
          type = types.ints.unsigned;
          default = 60;
          description = "Interval in seconds for OPTIONS keepalives (0 disables them).";
        };
        contacts = mkOption {
          type = types.listOf types.str;
          default = [];
          example = ["sip:10.0.2.21:5060"];
          description = "Static contacts, for devices that do not register.";
        };
        settings = settingsOption "aor";
      };
    };

  identifyType = name:
    types.submodule {
      options = {
        name = mkOption {
          type = types.str;
          default = name;
          description = "Name of the identify section.";
        };
        match = mkOption {
          type = types.listOf types.str;
          example = [
            "203.0.113.10"
            "198.51.100.0/24"
            "sip.provider.example"
          ];
          description = ''
            Source addresses, networks or host names identifying this endpoint.
            Asterisk resolves host names, through their SRV records where they
            have them but not NAPTR, when it loads pjsip.conf, so a changed
            address counts only after `asterisk -rx 'module reload res_pjsip.so'`
            or a restart. A host name that does not resolve then, including
            the provider host a trunk's `matchProviderHost` adds to this list,
            keeps Asterisk from creating the whole identify section, its
            addresses and networks too, until the next reload or restart. To
            match a trunk by address whatever DNS does when Asterisk loads,
            list its addresses and turn `matchProviderHost` off.
          '';
        };
        settings = settingsOption "identify";
      };
    };

  commonEndpointOptions = name: {
    context = mkOption {
      type = types.str;
      description = "Dialplan context calls from this endpoint start in.";
    };
    transport = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Transport for outgoing requests; by default Asterisk picks a matching one.";
    };
    allow = mkOption {
      type = types.nonEmptyListOf types.str;
      default = [
        "g722"
        "ulaw"
        "alaw"
      ];
      description = "Allowed codecs in order of preference (`disallow = all` is rendered first).";
    };
    directMedia = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Let RTP flow directly between endpoints, when both in a call have it
        on. Off by default, so Asterisk relays media, which works across VLANs
        and NAT. Asterisk sends each phone the address the other gave and
        does not check that it is reachable: between networks without a route,
        or with a phone behind NAT, the call has no audio and nothing is
        logged. Calls with media encryption are always relayed.
      '';
    };
    callerId = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = ''"Kitchen" <101>'';
      description = ''
        Caller ID presented for calls from this endpoint, as Asterisk reads
        one: `"name" <number>`, a number alone or a name alone. In the name,
        a backslash takes the character after it as it is, so `\\` is one
        backslash.
      '';
    };
    dtmfMode = mkOption {
      type = types.nullOr (
        types.enum [
          "rfc4733"
          "inband"
          "info"
          "auto"
          "auto_info"
        ]
      );
      default = null;
      description = ''
        DTMF mode; Asterisk's default is `rfc4733`. Asterisk hears keys sent
        as tones (`inband`, and `auto` for a device that offers no RFC 4733)
        only in ulaw and alaw calls, so give an `inband` endpoint
        `allow = [ "ulaw" "alaw" ]`: in a g722 call its keys are lost.
      '';
    };
    behindNat = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Enable `rtp_symmetric`, `force_rport` and `rewrite_contact` for devices
        behind NAT. The From header of requests to the device still names the
        PBX's own address, not its transport's external one, so a private
        address when the PBX is behind NAT as well; `from_domain` in
        `settings` replaces it.
      '';
    };
    identify = mkOption {
      type = types.nullOr (identifyType name);
      default = null;
      description = "Identify requests from these addresses as this endpoint (an identify section).";
    };
    outboundAuth = mkOption {
      type = types.nullOr (outboundAuthType name);
      default = null;
      description = "Credentials Asterisk uses when the remote side challenges it.";
    };
    settings = settingsOption "endpoint";
  };

  endpointType = types.submodule (
    {name, ...}: {
      options =
        commonEndpointOptions name
        // {
          auth = mkOption {
            type = types.nullOr (inboundAuthType name);
            default = null;
            description = ''
              Credentials the device must present (an auth section named like
              the endpoint). The user name defaults to the endpoint name.
              Without them, Asterisk takes the endpoint's requests from anyone
              (see `open`).
            '';
          };
          open = mkOption {
            type = types.bool;
            default = false;
            description = ''
              Let anyone who reaches the SIP port register as this endpoint
              and call from its context, without a password or a known
              address. An endpoint with neither `auth` nor `identify` whose
              aor takes registrations does not evaluate unless this is set.
            '';
          };
          aor = mkOption {
            type = types.nullOr (aorType name);
            default = {};
            defaultText = lib.literalExpression "{ }";
            description = ''
              Address of record (where to reach the endpoint): registrations or
              static contacts. Set to `null` for endpoints that are never called.
            '';
          };
          mailboxes = mkOption {
            type = types.listOf types.str;
            default = [];
            example = ["101@default"];
            description = ''
              Voicemail boxes whose message-waiting state is sent to the device,
              in NOTIFYs it did not ask for. Asterisk refuses a device's own
              subscription to message-summary with 404, so the device has to take
              these NOTIFYs. Each is `box@context`, such as `101@default`, as
              voicemail.conf spells it, since Asterisk sends a mailbox's MWI only
              in that form and compares it exactly, or an alias from the section
              voicemail.conf's `aliasescontext` names.
            '';
          };
        };
    }
  );

  trunkType = types.submodule (
    {
      name,
      config,
      ...
    }: {
      options =
        commonEndpointOptions name
        // {
          host = mkOption {
            type = types.str;
            example = "sip.provider.example";
            description = "Provider SIP server (host name or address).";
          };
          port = mkOption {
            type = types.nullOr types.port;
            default = null;
            description = ''
              Provider SIP port. Without it, Asterisk looks up the host's
              NAPTR and SRV records, which can name another host and port, and
              falls back to the transport's standard port.
            '';
          };
          username = mkOption {
            type = types.str;
            description = "Account user name, used for authentication, registration and the From header.";
          };
          password = mkOption {
            type = secretOrString;
            description = "Account password, normally a secret reference.";
          };
          fromDomain = mkOption {
            type = types.nullOr types.str;
            default = config.host;
            defaultText = lib.literalExpression "host";
            description = "Domain of the From header of outgoing calls.";
          };
          register = mkOption {
            type = types.bool;
            default = true;
            description = "Register to the provider (outbound registration).";
          };
          registration = {
            expiration = mkOption {
              type = types.ints.positive;
              default = 3600;
              description = "Requested registration lifetime in seconds.";
            };
            retryInterval = mkOption {
              type = types.ints.positive;
              default = 60;
              description = ''
                Seconds between registration attempts after a temporary
                failure: no answer, a host name that does not resolve, 408,
                500, 502, 503, 504 or 6xx. The trunk keeps trying for as long
                as that lasts. After an answer with Retry-After, whatever its
                status, the next attempt comes that many seconds later
                instead. On any other refusal, such as 403, a 3xx, or 401 and
                407 to the credentials it sent, Asterisk gives up at once and
                the journal says `Fatal response`; it tries again once
                res_pjsip reloads, as a deploy that changes pjsip.conf (a new
                password, say) or `asterisk -rx 'module reload res_pjsip.so'`
                does, or Asterisk restarts.
              '';
            };
            contactUser = mkOption {
              type = types.nullOr types.str;
              default = null;
              description = "User part of the registered Contact, i.e. the extension inbound calls arrive at.";
            };
            line = mkOption {
              type = types.bool;
              default = true;
              description = ''
                Add a `line` parameter to the registered Contact and identify
                inbound requests that carry it as this trunk (`line` and
                `endpoint` of the registration), whatever address they come
                from. Requests without it are still identified by `identify`.
              '';
            };
            settings = settingsOption "registration";
          };
          qualifyFrequency = mkOption {
            type = types.ints.unsigned;
            default = 60;
            description = "Interval in seconds for OPTIONS keepalives to the provider (0 disables them).";
          };
          matchProviderHost = mkOption {
            type = types.bool;
            default = true;
            description = ''
              Identify inbound requests coming from `host` as this trunk, in
              addition to `identify.match`, whose description says when a host
              name is resolved. When a network in `identify.match` already
              contains the host's address, Asterisk skips it and logs a
              misleading "did not resolve to any address" warning; turn this
              off then.
            '';
          };
          aorSettings = settingsOption "aor";
        };
      # the whole identify is conditional: an identify section that matches
      # nothing is an error in Asterisk
      config.identify = mkIf config.matchProviderHost {match = [config.host];};
    }
  );

  transportType = types.submodule (
    {config, ...}: {
      options = {
        protocol = mkOption {
          type = types.enum [
            "udp"
            "tcp"
            "tls"
            "ws"
            "wss"
          ];
          default = "udp";
          description = ''
            Transport protocol. `ws` and `wss` run over Asterisk's HTTP server
            (http.conf) and ignore the address and port here.
          '';
        };
        address = mkOption {
          type = types.str;
          default = "0.0.0.0";
          example = "10.0.2.1";
          description = ''
            Local address to bind; `0.0.0.0` or `::` for all addresses. The
            service waits up to 90 s at start for a specific address to be
            configured and through duplicate address detection, then fails
            with a message naming the address, and systemd starts it again
            5 s later. With systemd-networkd, an interface that loses its
            carrier loses its addresses, so Asterisk restarted while the link
            is down waits for the link. Setting
            `networkConfig.IgnoreCarrierLoss = true` in the interface's
            `systemd.network.networks` entry (`"40-<interface>"` for one from
            `networking.interfaces`) keeps them, as does
            `ConfigureWithoutCarrier = true`, which turns it on.
          '';
        };
        port = mkOption {
          type = types.port;
          default =
            if config.protocol == "tls"
            then 5061
            else 5060;
          defaultText = lib.literalExpression "5061 for tls, else 5060";
          description = "Local port to bind.";
        };
        externalMediaAddress = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = ''
            Public address put in SDP for peers outside `localNet` (NAT),
            where `externalSignalingAddress` says Asterisk applies it.
          '';
        };
        externalSignalingAddress = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = ''
            Public address used in SIP headers for peers outside `localNet`
            (NAT). Asterisk applies it, `externalSignalingPort` and
            `externalMediaAddress` to what it sends over udp, and over tcp
            and tls on IPv4. Over tcp and tls on IPv6 it applies them only to
            endpoints whose `transport` names this transport, and over ws and
            wss to none. Otherwise a PBX behind NAT sends its private address
            in SIP headers and SDP.
          '';
        };
        externalSignalingPort = mkOption {
          type = types.nullOr types.port;
          default = null;
          description = ''
            Public port used in SIP headers for peers outside `localNet`,
            where `externalSignalingAddress` says Asterisk applies it.
          '';
        };
        localNet = mkOption {
          type = types.listOf types.str;
          default = [];
          example = ["10.0.0.0/8"];
          description = "Networks considered local, where no external address is substituted.";
        };
        tls = {
          certFile = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = ''
              Certificate chain (PEM). Loaded as a systemd credential, so it may
              be readable by root only. From systemd 260 on, a renewed
              certificate is applied by `systemctl reload asterisk`, which with
              security.acme is `reloadServices = [ "asterisk.service" ]`.
            '';
          };
          keyFile = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "Private key (PEM), loaded as a systemd credential.";
          };
          caListFile = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = ''
              CA certificates used to verify peers, loaded as a systemd
              credential. By default TLS transports use the system's CA bundle
              ({option}`security.pki.caBundle`), so `verifyServer` works with
              publicly signed certificates.
            '';
          };
          method = mkOption {
            type = types.nullOr (
              types.enum [
                "tlsv1"
                "tlsv1_1"
                "tlsv1_2"
                "tlsv1_3"
                "sslv23"
              ]
            );
            default = "sslv23";
            example = "tlsv1_3";
            description = ''
              TLS protocol version (pjsip `method`). `sslv23` negotiates the
              highest version both sides support, TLS 1.2 or 1.3 with current
              OpenSSL, which refuses older versions; any other value allows
              that version only. Asterisk's own default (used with `null`) is
              TLS 1.0.
            '';
          };
          verifyClient = mkOption {
            type = types.bool;
            default = false;
            description = ''
              Admit only clients that present a certificate the CA list
              verifies (`verify_client` and `require_client_cert`).
            '';
          };
          verifyServer = mkOption {
            type = types.bool;
            default = false;
            description = "Verify the server certificate on outgoing connections.";
          };
        };
        allowReload = mkOption {
          type = types.bool;
          default = false;
          description = ''
            Let `module reload res_pjsip.so` recreate this transport. Changing a
            transport restarts Asterisk anyway when deployed through NixOS.
          '';
        };
        settings = settingsOption "transport";
      };
    }
  );

  aclType = types.submodule {
    options = {
      deny = mkOption {
        type = types.listOf types.str;
        default = [];
        example = [
          "0.0.0.0/0.0.0.0"
          "::/0"
        ];
        description = "Networks to deny. Rendered before `permit`; the last matching rule wins.";
      };
      permit = mkOption {
        type = types.listOf types.str;
        default = [];
        example = ["10.0.1.0/24"];
        description = "Networks to permit, overriding earlier `deny` rules.";
      };
      contactDeny = mkOption {
        type = types.listOf types.str;
        default = [];
        description = ''
          Networks the addresses in a request's Contact header must not be in.
          Asterisk checks every request that has one, calls from a trunk as
          well as registrations, and answers 403.
        '';
      };
      contactPermit = mkOption {
        type = types.listOf types.str;
        default = [];
        description = "Networks the addresses in a request's Contact header may be in, overriding `contactDeny`.";
      };
      settings = settingsOption "acl";
    };
  };

  # --- section generation --------------------------------------------------

  credentialName = transport: kind: "pjsip-${transport}-${kind}";
  credentialPath = transport: kind: "${cfg.paths.credentials}/${credentialName transport kind}";

  transportSections =
    mapAttrs' (
      name: t:
        nameValuePair "transport:${name}" (section {
          inherit name;
          type = "transport";
          order = 100;
          values = {
            inherit (t) protocol;
            bind = hostPort t.address t.port;
            external_media_address = t.externalMediaAddress;
            external_signaling_address = t.externalSignalingAddress;
            external_signaling_port = t.externalSignalingPort;
            local_net = t.localNet;
            cert_file =
              if t.tls.certFile != null
              then credentialPath name "cert"
              else null;
            priv_key_file =
              if t.tls.keyFile != null
              then credentialPath name "key"
              else null;
            # without a CA list, pjproject logs an error for every TLS connection
            # it accepts
            ca_list_file =
              if t.tls.caListFile != null
              then credentialPath name "ca"
              else if t.protocol == "tls"
              then config.security.pki.caBundle
              else null;
            method =
              if t.protocol == "tls"
              then t.tls.method
              else null;
            verify_client =
              if t.protocol == "tls"
              then t.tls.verifyClient
              else null;
            # verify_client only checks a certificate the client presents
            require_client_cert =
              if t.protocol == "tls"
              then t.tls.verifyClient
              else null;
            verify_server =
              if t.protocol == "tls"
              then t.tls.verifyServer
              else null;
            allow_reload =
              if t.allowReload
              then true
              else null;
          };
          extra = t.settings;
        })
    )
    pcfg.transports;

  transportCredentials = concatLists (
    mapAttrsToList (
      name: t:
        optional (t.tls.certFile != null) (nameValuePair (credentialName name "cert") t.tls.certFile)
        ++ optional (t.tls.keyFile != null) (nameValuePair (credentialName name "key") t.tls.keyFile)
        ++ optional (t.tls.caListFile != null) (nameValuePair (credentialName name "ca") t.tls.caListFile)
    )
    pcfg.transports
  );

  aclSections =
    mapAttrs' (
      name: a:
        nameValuePair "acl:${name}" (section {
          inherit name;
          type = "acl";
          order = 200;
          values = {
            inherit (a) deny permit;
            contact_deny = a.contactDeny;
            contact_permit = a.contactPermit;
          };
          extra = a.settings;
        })
    )
    pcfg.acls;

  # Sections shared by endpoints and trunks. `e` is the endpoint-like
  # attrset; `aor` and `auth` are normalized by the callers.
  endpointSections = name: e: {
    aor,
    auth,
    mailboxes ? [],
    extraValues ? {},
  }:
    {
      "endpoint:${name}" = section {
        inherit name;
        type = "endpoint";
        values =
          {
            inherit (e) context transport allow;
            disallow = "all";
            direct_media = e.directMedia;
            callerid = e.callerId;
            dtmf_mode = e.dtmfMode;
            rtp_symmetric =
              if e.behindNat
              then true
              else null;
            force_rport =
              if e.behindNat
              then true
              else null;
            rewrite_contact =
              if e.behindNat
              then true
              else null;
            auth =
              if auth != null
              then auth.name
              else null;
            outbound_auth =
              if e.outboundAuth != null
              then e.outboundAuth.name
              else null;
            aors =
              if aor != null
              then aor.name
              else null;
            mailboxes =
              if mailboxes == []
              then null
              else concatStringsSep "," mailboxes;
          }
          // extraValues;
        extra = e.settings;
      };
    }
    // optionalAttrs (auth != null) {
      "auth:${name}" = section {
        inherit (auth) name;
        type = "auth";
        values = {
          inherit (auth) username password realm;
        };
        extra = auth.settings;
      };
    }
    // optionalAttrs (e.outboundAuth != null) {
      "outbound-auth:${name}" = section {
        inherit (e.outboundAuth) name;
        type = "auth";
        values = {
          inherit (e.outboundAuth) username password realm;
        };
        extra = e.outboundAuth.settings;
      };
    }
    // optionalAttrs (aor != null) {
      "aor:${name}" = section {
        inherit (aor) name;
        type = "aor";
        values = {
          max_contacts = aor.maxContacts;
          remove_existing = aor.removeExisting;
          qualify_frequency = aor.qualifyFrequency;
          contact = aor.contacts;
        };
        extra = aor.settings;
      };
    }
    // optionalAttrs (e.identify != null) {
      "identify:${name}" = section {
        inherit (e.identify) name;
        type = "identify";
        values = {
          endpoint = name;
          # Asterisk warns about a host it matches already, such as a trunk's
          # host that is in identify.match too
          match = unique e.identify.match;
        };
        extra = e.identify.settings;
      };
    };

  endpointSectionsFor = name: e:
    endpointSections name e {
      inherit (e) aor auth mailboxes;
    };

  trunkSectionsFor = name: t: let
    server = hostPort t.host t.port;
    # A trunk always authenticates outbound with the account credentials.
    t' =
      t
      // {
        outboundAuth =
          if t.outboundAuth != null
          then t.outboundAuth
          else {
            name = "${name}-outbound";
            inherit (t) username password;
            realm = null;
            settings = {};
          };
      };
  in
    endpointSections name t' {
      aor = {
        inherit name;
        maxContacts = 0;
        removeExisting = false;
        inherit (t) qualifyFrequency;
        contacts = ["sip:${server}"];
        settings = t.aorSettings;
      };
      auth = null;
      extraValues = {
        from_user = t.username;
        from_domain = t.fromDomain;
        # only identify and the registration's line pick the trunk: anyone
        # can put its name in From, and a trunk takes calls unauthenticated
        identify_by = "ip";
      };
    }
    // optionalAttrs t.register {
      "registration:${name}" = section {
        inherit name;
        type = "registration";
        values = {
          inherit (t) transport;
          outbound_auth = t'.outboundAuth.name;
          server_uri = "sip:${server}";
          client_uri = "sip:${t.username}@${server}";
          contact_user = t.registration.contactUser;
          retry_interval = t.registration.retryInterval;
          # Asterisk gives up after 10 temporary failures by default and
          # never tries again without a reload; this is the largest it takes
          max_retries = 4294967295;
          expiration = t.registration.expiration;
          # Asterisk only accepts `endpoint` together with `line`
          inherit (t.registration) line;
          endpoint =
            if t.registration.line
            then name
            else null;
        };
        extra = t.registration.settings;
      };
    };

  globalSections =
    optionalAttrs (pcfg.global != {}) {
      global = section {
        name = "global";
        type = "global";
        order = 0;
        values = pcfg.global;
      };
    }
    // optionalAttrs (pcfg.system != {}) {
      system = section {
        name = "system";
        type = "system";
        order = 0;
        values = pcfg.system;
      };
    };

  # --- validation on the final (layer 1) pjsip.conf ---------------------------

  resolved = format.resolveInheritance (cfg.settings."pjsip.conf" or {});
  objects = resolved.sections;
  ofType = type: filter (s: (s.type or null) == type) objects;
  endpointObjects = ofType "endpoint";
  takesRegistrations = aor: toString (aor.max_contacts or 0) != "0";

  # the modules the objects need; without res_pjsip_authenticator_digest,
  # Asterisk takes every request as authenticated (res_pjsip.c)
  neededModules = {
    "endpoints in pjsip.conf" = mkIf (endpointObjects != []) ["chan_pjsip.so"];
    "endpoints with auth in pjsip.conf" = mkIf (builtins.any (s: s ? auth) endpointObjects) ["res_pjsip_authenticator_digest.so"];
    "endpoints with mailboxes in pjsip.conf" = mkIf (builtins.any (s: s ? mailboxes) endpointObjects) [
      "res_pjsip_mwi.so"
      "res_pjsip_mwi_body_generator.so"
    ];
    "aors that accept registrations in pjsip.conf" = mkIf (builtins.any takesRegistrations (ofType "aor")) ["res_pjsip_registrar.so"];
    "outbound_auth in pjsip.conf" = mkIf (builtins.any (s: s ? outbound_auth) objects) ["res_pjsip_outbound_authenticator_digest.so"];
    "identify sections in pjsip.conf" = mkIf (ofType "identify" != []) ["res_pjsip_endpoint_identifier_ip.so"];
    "registrations in pjsip.conf" = mkIf (ofType "registration" != []) ["res_pjsip_outbound_registration.so"];
    "acls in pjsip.conf" = mkIf (ofType "acl" != []) ["res_pjsip_acl.so"];
  };
  # the names of each type's objects as a set, made once, so checking every
  # reference takes as long as the objects are many, not their square
  namesByType = lib.mapAttrs (_: sections: lib.genAttrs (map (s: s.name) sections) (_: true)) (
    builtins.groupBy (s: s.type or "") objects
  );

  # sorcery.conf's sections by name, or null when it includes files
  sorcerySections = format.sectionNames {
    sections = cfg.settings."sorcery.conf" or {};
    includes = cfg.includes."sorcery.conf" or [];
    extraConfig = cfg.extraConfig."sorcery.conf" or "";
  };
  # sections of the raw text (of unknown type), or null when objects can also
  # come from included files or other sorcery backends
  rawSections =
    if sorcerySections == null || builtins.any (lib.hasPrefix "res_pjsip") sorcerySections
    then null
    else
      format.sectionNames {
        includes = cfg.includes."pjsip.conf" or [];
        extraConfig = cfg.extraConfig."pjsip.conf" or "";
      };

  # without included files a parent can only be a section rendered earlier:
  # the raw text comes after all of them
  missingParents =
    if rawSections == null
    then []
    else map (s: "[${s.name}](${concatStringsSep "," s.inherits})") resolved.unresolved;

  refList = v:
    if isString v
    then filter (x: x != "") (map lib.trim (splitString "," v))
    else if isList v
    then lib.concatMap refList v
    else [];

  danglingRefs = let
    elsewhere = rawSections ++ map (u: u.name) resolved.unresolved;
    check = s: key: type:
      map (ref: "[${s.name}] (type=${s.type}) ${key} = ${ref}: no ${type} named `${ref}`") (
        filter (ref: !((namesByType.${type} or {}) ? ${ref} || builtins.elem ref elsewhere)) (
          refList (s.${key} or null)
        )
      );
    checksFor = s:
      {
        endpoint =
          check s "auth" "auth"
          ++ check s "outbound_auth" "auth"
          ++ check s "aors" "aor"
          ++ check s "transport" "transport";
        identify = check s "endpoint" "endpoint";
        registration =
          check s "outbound_auth" "auth" ++ check s "transport" "transport" ++ check s "endpoint" "endpoint";
        aor = check s "outbound_auth" "auth";
      }
        .${
        s.type or ""
      } or [
      ];
  in
    if rawSections == null
    then []
    else lib.concatMap checksFor objects;

  duplicateObjects = let
    keys = map (s: "${s.type or "?"} ${s.name}") (filter (s: s ? type) objects);
  in
    attrNames (filterAttrs (_: same: builtins.length same > 1) (builtins.groupBy (k: k) keys));

  # Asterisk refuses to load a registration with `endpoint` but no `line`
  registrationsWithoutLine = map (s: s.name) (
    filter (
      s:
        (s.type or null)
        == "registration"
        && (s.endpoint or null) != null
        && !(format.isTrue (s.line or false))
    )
    objects
  );

  tlsWithoutKeys = map (s: s.name) (
    filter (
      s:
        (s.type or null)
        == "transport"
        && (s.protocol or null) == "tls"
        && !(s ? cert_file && s ? priv_key_file)
    )
    objects
  );

  # typed endpoints anyone who reaches the SIP port can register as: Asterisk
  # takes every request of an endpoint without auth as authenticated
  # (res_pjsip_authenticator_digest.c:53-58)
  openEndpoints = let
    byName = type: lib.listToAttrs (map (s: nameValuePair s.name s) (ofType type));
    endpoints = byName "endpoint";
    aors = byName "aor";
    identified = lib.genAttrs (map (s: toString s.endpoint) (filter (s: s ? endpoint) (ofType "identify"))) (_: true);
  in
    if rawSections == null
    then []
    else
      filter (
        name: let
          s = endpoints.${name};
        in
          !pcfg.endpoints.${name}.open
          && refList (s.auth or null) == []
          && !(identified ? ${name})
          && builtins.any (aor: takesRegistrations (aors.${aor} or {})) (refList (s.aors or null))
      ) (filter (name: endpoints ? ${name}) (attrNames pcfg.endpoints));

  missingContexts = filter (s: !(builtins.elem s.context cfg.dialplan.knownContexts)) (
    filter (s: (s.type or null) == "endpoint" && isString (s.context or null)) objects
  );

  # the name and number Asterisk takes from a callerid (main/callerid.c
  # ast_callerid_parse and ast_callerid_split): `"name" <number>`, `name
  # <number>`, a number alone or a name alone
  callerIdParts = value: let
    # ast_strip_quoted: the text without whitespace around it, then without
    # a pair of quotes around it
    unquote = s: let
      t = lib.trim s;
      length = builtins.stringLength t;
    in
      if length > 0 && lib.hasPrefix "\"" t && lib.hasSuffix "\"" t
      then builtins.substring 1 (lib.max 0 (length - 2)) t
      else t;
    # ast_unescape_quoted: each backslash goes, the character after it stays
    unescape = s: let
      parts = builtins.split "\\\\(.)" s;
    in
      lib.concatMapStrings (part:
        if isList part
        then builtins.head part
        else part) (lib.init parts)
      + lib.removeSuffix "\\" (lib.last parts);
    # ast_shrink_phone_number: without ( ) and spaces, - outside [ ] and . but
    # at the end
    shrink = number: let
      characters = lib.stringToCharacters number;
      last = builtins.length characters - 1;
    in
      (lib.foldl' (
          acc: i: let
            c = builtins.elemAt characters i;
          in
            if c == "["
            then {
              bracketed = acc.bracketed + 1;
              kept = acc.kept + c;
            }
            else if c == "]"
            then {
              bracketed = acc.bracketed - 1;
              kept = acc.kept + c;
            }
            else if c == "-" && acc.bracketed == 0 || c == "." && i != last || builtins.elem c ["(" " " ")"]
            then acc
            else acc // {kept = acc.kept + c;}
        ) {
          bracketed = 0;
          kept = "";
        } (lib.range 0 last))
      .kept;
    input = unquote value;
    # the last < and the last > after it
    bracketed = builtins.match "(.*)<(.*)" input;
    location = builtins.elemAt bracketed 1;
    closed = builtins.match "(.*)>.*" location;
    # without <, the text is a number alone when it is not in quotes and its
    # first 255 bytes shrink to one
    shrunk = shrink (builtins.substring 0 255 input);
  in
    if bracketed != null
    then {
      name = unescape (unquote (builtins.head bracketed));
      number = shrink (
        if closed == null
        then location
        else builtins.head closed
      );
    }
    else if input == lib.trim value && builtins.match "[0-9*#+]+" shrunk != null
    then {
      name = "";
      number = shrunk;
    }
    else {
      name = unescape (unquote input);
      number = "";
    };
  # endpoints whose callerid Asterisk cuts: it keeps 79 bytes of the name and
  # of the number (res/res_pjsip/pjsip_configuration.c caller_id_handler)
  longCallerIds = lib.concatMap (
    s: let
      parts = callerIdParts s.callerid;
    in
      lib.concatMap (part: lib.optional (builtins.stringLength parts.${part} > 79) "[${s.name}] ${part} of ${toString (builtins.stringLength parts.${part})} bytes") ["name" "number"]
  ) (filter (s: isString (s.callerid or null) && asteriskLib.secrets.fromText s.callerid == []) endpointObjects);

  # Asterisk's DSP reads tones in 8 kHz signed linear, ulaw and alaw only
  # (main/dsp.c ast_dsp_process), and drops the keys of a call in any other codec
  inbandCodecs =
    lib.concatMap (
      s: let
        others = filter (codec: !(builtins.elem codec ["ulaw" "alaw" "slin"])) (refList (s.allow or null));
      in
        optional ((s.dtmf_mode or null) == "inband" && others != []) "[${s.name}] ${concatStringsSep ", " others}"
    )
    endpointObjects;
in {
  options.services.asterisk.pjsip = {
    global = mkOption {
      type = types.attrsOf format.types.value;
      default = {};
      example = {
        user_agent = "PBX";
        endpoint_identifier_order = "ip,username";
      };
      description = ''
        Keys of the `[global]` section (`type = global`). The module sets
        `max_initial_qualify_time = 5`, so phones and trunks are qualified
        within 5 seconds of a start; any definition replaces it.
      '';
    };

    system = mkOption {
      type = types.attrsOf format.types.value;
      default = {};
      example = {
        timer_t1 = 500;
      };
      description = "Keys of the `[system]` section (`type = system`).";
    };

    transports = mkOption {
      type = types.attrsOf transportType;
      default = {};
      example = lib.literalExpression ''
        {
          udp = { protocol = "udp"; port = 5060; };
          tls = {
            protocol = "tls";
            tls.certFile = "/var/lib/acme/pbx.example.org/fullchain.pem";
            tls.keyFile = "/var/lib/acme/pbx.example.org/key.pem";
          };
        }
      '';
      description = ''
        PJSIP transports. Changing a transport restarts Asterisk, since
        transports are not reloadable. The firewall ports are derived from
        these (see {option}`services.asterisk.openFirewall`).

        Asterisk sends its requests to a UDP contact over UDP, whatever their
        size. Phones built on pjsip, and others that follow RFC 3261 18.1.1,
        send their requests of 1300 bytes or more over TCP to the same address
        and port, often an INVITE with its credentials; they need a `tcp`
        transport on that port too, or the firewall drops the connection and
        the call fails after 32 seconds.
      '';
    };

    acls = mkOption {
      type = types.attrsOf aclType;
      default = {};
      example = lib.literalExpression ''
        {
          lan = {
            deny = [ "0.0.0.0/0.0.0.0" "::/0" ];
            permit = [ "10.0.1.0/24" "10.0.2.0/24" ];
          };
        }
      '';
      description = ''
        Global ACLs (`type = acl`) applied to every incoming SIP request.
        `permit` rules are rendered after `deny` rules and the last matching
        rule wins, so "deny everything, permit these networks" works as
        expected.
      '';
    };

    endpoints = mkOption {
      type = types.attrsOf endpointType;
      default = {};
      example = lib.literalExpression ''
        {
          "101" = {
            context = "internal";
            callerId = '''"Kitchen" <101>''';
            auth.password = config.lib.asterisk.secret config.sops.secrets.sip-101.path;
          };
        }
      '';
      description = ''
        SIP devices. Each endpoint gets an auth section (when `auth` is set),
        an aor section (unless `aor = null`) and optionally an identify
        section, all named like the endpoint. Phones register with the
        endpoint name as user name.
      '';
    };

    trunks = mkOption {
      type = types.attrsOf trunkType;
      default = {};
      example = lib.literalExpression ''
        {
          provider = {
            host = "sip.provider.example";
            username = "5551000";
            password = config.lib.asterisk.secret config.sops.secrets.trunk.path;
            context = "from-provider";
            identify.match = [ "203.0.113.0/24" ];
          };
        }
      '';
      description = ''
        SIP provider accounts: an endpoint with outbound authentication, an
        aor pointing at the provider, an identify section for the provider's
        addresses and, unless `register = false`, an outbound registration.
        A request counts as the trunk's when it comes from an address of its
        identify or carries its registration's `line`; the user in its From
        header plays no part, as anyone can send any.
      '';
    };
  };

  config = mkIf cfg.enable {
    services.asterisk = {
      settings."pjsip.conf" = mkMerge [
        globalSections
        transportSections
        aclSections
        (lib.concatMapAttrs endpointSectionsFor pcfg.endpoints)
        # a trunk named like an endpoint is reported by an assertion below
        # instead of producing conflicting definitions
        (lib.concatMapAttrs trunkSectionsFor (
          filterAttrs (name: _: !(pcfg.endpoints ? ${name})) pcfg.trunks
        ))
      ];

      credentials = lib.listToAttrs transportCredentials;

      modules.needed = neededModules;

      # after a start, queues skip a phone and calls to a trunk fail until its
      # first qualify, which Asterisk otherwise schedules within qualify_frequency
      pjsip.global.max_initial_qualify_time = mkOptionDefault 5;
    };

    assertions = [
      {
        assertion = danglingRefs == [];
        message = ''
          services.asterisk: pjsip.conf references objects that do not exist:
            ${concatStringsSep "\n  " danglingRefs}
        '';
      }
      {
        assertion = missingParents == [];
        message = ''
          services.asterisk: pjsip.conf sections inherit from sections that are not rendered before them, so Asterisk would not load the file:
            ${concatStringsSep "\n  " missingParents}
        '';
      }
      {
        assertion = duplicateObjects == [];
        message = ''
          services.asterisk: pjsip.conf defines these objects more than once (same type and name):
            ${concatStringsSep "\n  " duplicateObjects}
        '';
      }
      {
        assertion = registrationsWithoutLine == [];
        message = "services.asterisk: pjsip.conf registration(s) ${concatStringsSep ", " registrationsWithoutLine} set `endpoint` without `line = yes`; Asterisk would not load them.";
      }
      {
        assertion = tlsWithoutKeys == [];
        message = "services.asterisk: TLS transport(s) ${concatStringsSep ", " tlsWithoutKeys} need a certificate and a private key (pjsip.transports.<name>.tls.certFile and tls.keyFile, or cert_file and priv_key_file).";
      }
      {
        assertion = openEndpoints == [];
        message = "services.asterisk: PJSIP endpoint(s) ${concatStringsSep ", " openEndpoints} have neither auth nor identify and their aor takes registrations, so anyone who reaches the SIP port can register as them. Give each a password (pjsip.endpoints.<name>.auth.password), or for a device known by its address an identify with settings.identify_by = \"ip\", or aor.maxContacts = 0 if it never registers, or set open = true where anyone may register on purpose.";
      }
      {
        assertion = longCallerIds == [];
        message = ''
          services.asterisk: PJSIP endpoints with a caller ID longer than the 79 bytes of name and of number Asterisk keeps:
            ${concatStringsSep "\n  " longCallerIds}
        '';
      }
      {
        assertion = cfg.dialplan.knownContexts == null || missingContexts == [];
        message = ''
          services.asterisk: PJSIP endpoints use dialplan contexts that are not defined:
            ${concatStringsSep "\n  " (map (s: "[${s.name}] context = ${s.context}") missingContexts)}
        '';
      }
      {
        assertion = builtins.all (n: !(pcfg.endpoints ? ${n})) (attrNames pcfg.trunks);
        message = "services.asterisk: pjsip.trunks and pjsip.endpoints share the name(s) ${
          concatStringsSep ", " (filter (n: pcfg.endpoints ? ${n}) (attrNames pcfg.trunks))
        }.";
      }
    ];

    warnings = optional (inbandCodecs != []) ''
      services.asterisk: Asterisk hears keys sent as tones only in ulaw and alaw calls, so endpoints with dtmf_mode = inband lose the keys of calls in the other codecs they allow:
        ${concatStringsSep "\n  " inbandCodecs}
      Allow only ulaw and alaw there, or use another dtmfMode.
    '';
  };
}
