# pbx.paging: one number that makes several phones answer by themselves, in
# pbx-paging-<name>. Page() sends each phone the headers phones take as an
# auto-answer request, from its pre-dial routine (the `headers` extension).
{
  config,
  lib,
  ...
}: let
  inherit
    (lib)
    concatMap
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
    options =
      "i"
      + lib.optionalString paging.duplex "d"
      + lib.optionalString paging.skipBusy "s"
      + "b(${context}^headers^1)";
  in {
    comment = mkDefault "from pbx.paging.${name}";
    extensions = {
      s = [
        (pbxLib.app "Page" [
          (concatStringsSep "&" (map (member: "PJSIP/${member}") paging.members))
          options
        ])
        (pbxLib.app "Hangup" [])
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
in {
  options.pbx.paging = mkOption {
    type = types.attrsOf pagingType;
    default = {};
    example = lib.literalExpression ''{ all = { number = "650"; members = [ "201" "202" ]; }; }'';
    description = "Paging groups, keyed by group name.";
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
    ];
  };
}
