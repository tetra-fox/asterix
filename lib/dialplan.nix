# Helpers for writing dialplan in Nix.
#
# Escaping: Nix and Asterisk both use `${...}`. In Nix double-quoted strings
# write `"\${EXTEN}"`, in indented strings `''${EXTEN}`, or use `var "EXTEN"`.
# Semicolons need no escaping; the generator does that.
{ lib }:
let
  inherit (lib)
    concatMapStringsSep
    concatStringsSep
    isString
    optional
    ;

  argString = arg: if isString arg then arg else toString arg;
in
rec {
  # `var "EXTEN"` is the Asterisk variable reference `${EXTEN}`.
  var = name: "\${${name}}";

  # `app "Dial" [ "PJSIP/alice" 30 ]` is `Dial(PJSIP/alice,30)`. Arguments are
  # joined with commas and not escaped.
  app = name: args: "${name}(${concatMapStringsSep "," argString args})";

  # Dial string for several PJSIP endpoints: `PJSIP/a&PJSIP/b`.
  pjsipTargets = endpoints: concatMapStringsSep "&" (e: "PJSIP/${e}") endpoints;

  # A `b()`/predial Gosub target: `context^exten^priority`.
  gosubTarget =
    {
      context,
      extension ? "s",
      priority ? 1,
    }:
    "${context}^${extension}^${toString priority}";

  # Page() application: one-way or full-duplex paging of several endpoints.
  #
  #   page { endpoints = [ "kitchen" "office" ]; predial = "page-autoanswer"; }
  #   => Page(PJSIP/kitchen&PJSIP/office,db(page-autoanswer^s^1),20)
  #
  # `predial` is a context whose `s` extension runs on every paged channel
  # before it is called, typically `autoAnswerContext` below.
  page =
    {
      endpoints,
      duplex ? true,
      quiet ? false,
      predial ? null,
      timeout ? 20,
      extraOptions ? "",
    }:
    let
      options = concatStringsSep "" (
        optional duplex "d"
        ++ optional quiet "q"
        ++ optional (predial != null) "b(${gosubTarget { context = predial; }})"
        ++ optional (extraOptions != "") extraOptions
      );
    in
    app "Page" [
      (pjsipTargets endpoints)
      options
      timeout
    ];

  # A subroutine context that adds auto-answer headers to an outgoing PJSIP
  # channel; use it as the predial handler of Page() or Dial(). The defaults
  # cover Grandstream, Snom and Yealink (Call-Info) and Polycom (Alert-Info).
  # Assign the result to `dialplan.contexts.<name>`.
  autoAnswerContext =
    {
      callInfo ? "<sip:intercom>;answer-after=0",
      alertInfo ? "info=alert-autoanswer",
    }:
    {
      extensions.s =
        optional (callInfo != null) "Set(PJSIP_HEADER(add,Call-Info)=${callInfo})"
        ++ optional (alertInfo != null) "Set(PJSIP_HEADER(add,Alert-Info)=${alertInfo})"
        ++ [ "Return()" ];
    };
}
