# pbx.paging: one number that makes several phones answer by themselves, in
# pbx-paging-<name>. The `member` routine collects every device of the
# members, and Page() sends each the headers phones take as an auto-answer
# request, from its pre-dial routine (the `headers` extension).
{
  config,
  lib,
  ...
}: let
  inherit
    (lib)
    concatMap
    concatMapStringsSep
    concatStringsSep
    mapAttrs'
    mkDefault
    mkIf
    mkOption
    nameValuePair
    types
    ;

  cfg = config.pbx;
  pbxLib = import ./lib.nix {inherit lib;};

  pagingType = types.submodule {
    options = {
      number = mkOption {
        type = types.str;
        example = "650";
        description = "Number phones dial to page.";
      };
      members = mkOption {
        type = types.nonEmptyListOf types.str;
        example = [
          "201"
          "202"
        ];
        description = "Extensions of {option}`pbx.extensions` that answer and play the page.";
      };
      duplex = mkOption {
        type = types.bool;
        default = false;
        description = "Let the paged phones talk back; by default only the caller is heard.";
      };
      skipBusy = mkOption {
        type = types.bool;
        default = true;
        description = "Leave out phones that are in a call.";
      };
      headers = mkOption {
        type = types.listOf (types.strMatching "[A-Za-z-]+: [^\n]+");
        default = [
          "Alert-Info: <http://example.com>;info=alert-autoanswer;delay=0"
          "Call-Info: <sip:pbx>;answer-after=0"
        ];
        description = ''
          SIP headers added to each page, as `Name: value`. The defaults
          are the auto-answer requests most desk phones understand; the
          phone must also allow auto-answer.
        '';
      };
    };
  };

  pagingSection = name: paging: let
    context = pbxLib.objectContext "paging" name;
    # Page() finds the caller's phone, and with `s` busy ones, by the device a
    # dial string names, which a contact's does not, so `member` does both
    options =
      "i"
      + lib.optionalString paging.duplex "d"
      + "b(${context}^headers^1)";
  in {
    comment = mkDefault "from pbx.paging.${name}";
    extensions = {
      s =
        [(pbxLib.app "Set" ["PBX_PAGE="])]
        ++ map (member: pbxLib.app "Gosub" ["member" "1(${member})"]) paging.members
        ++ [
          (pbxLib.app "Page" ["\${PBX_PAGE}" options])
          (pbxLib.app "Hangup" [])
        ];
      # adds the devices of extension ARG1 to PBX_PAGE, unless it is the
      # caller's own or, with skipBusy, not idle
      member =
        [(pbxLib.app "GotoIf" [''$["''${CUT(CHANNEL,-,1)}" = "PJSIP/''${ARG1}"]?done''])]
        ++ lib.optionals paging.skipBusy [
          (pbxLib.app "Set" ["PBX_STATE=\${DEVICE_STATE(PJSIP/\${ARG1})}"])
          (pbxLib.app "GotoIf" [''$["''${PBX_STATE}" != "NOT_INUSE" & "''${PBX_STATE}" != "UNKNOWN"]?done''])
        ]
        ++ [
          (pbxLib.app "Set" ["PBX_PAGE=\${PBX_PAGE}&${pbxLib.devices "\${ARG1}"}"])
          {
            app = "Return";
            args = [];
            label = "done";
          }
        ];
      headers =
        map (header: let
          m = builtins.match "([A-Za-z-]+): (.*)" header;
        in
          pbxLib.app "Set" ["PJSIP_HEADER(add,${builtins.elemAt m 0})=${builtins.elemAt m 1}"])
        paging.headers
        ++ [(pbxLib.app "Return" [])];
    };
  };

  missing = concatMap (
    name:
      map (member: "pbx.paging.${name}: ${member}") (
        builtins.filter (member: !(cfg.extensions ? ${member})) cfg.paging.${name}.members
      )
  ) (builtins.attrNames cfg.paging);
  # in Page's b() option, ) ends the routine, ^ becomes a comma, and Gosub
  # ends its target at the first (
  badNames = builtins.filter (name: pbxLib.breaksContext name || pbxLib.breaksArgument name || builtins.match ".*[()^].*" name != null) (builtins.attrNames cfg.paging);
in {
  options.pbx.paging = mkOption {
    type = types.attrsOf pagingType;
    default = {};
    example = lib.literalExpression ''{ all = { number = "650"; members = [ "201" "202" ]; }; }'';
    description = ''
      Paging groups, keyed by group name. A name cannot contain `,` `;` `[`
      `]` `"` `\` `''${` `$[` `(` `)` `^` or a line break, nor end with white
      space.
    '';
  };

  config = mkIf cfg.enable {
    services.asterisk.dialplan.contexts = mapAttrs' (name: paging: nameValuePair (pbxLib.objectContext "paging" name) (pagingSection name paging)) cfg.paging;

    assertions = [
      {
        assertion = missing == [];
        message = ''
          pbx.paging: members that are not extensions of pbx.extensions:
            ${concatStringsSep "\n  " missing}
        '';
      }
      {
        assertion = badNames == [];
        message = ''
          pbx.paging: names that Asterisk would misread in the dialplan (they may not contain , ; [ ] " \ ''${ $[ ( ) or ^):
            ${concatMapStringsSep "\n  " (name: lib.showOption ["pbx" "paging" name]) badNames}
        '';
      }
    ];
  };
}
