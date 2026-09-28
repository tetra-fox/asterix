# Unit tests for the pure helpers in lib/ (config format and secrets).
# Evaluated with lib.runTests; the result is the list of failed tests.
{
  lib,
  asteriskLib,
}: let
  inherit (asteriskLib) format secrets;

  render = args: doc: format.render args doc;
  renderFile = file: doc:
    format.render {
      syntax = format.syntaxFor file;
      inherit file;
    }
    doc;

  # `success` is false when evaluation throws.
  throws = expr: !(builtins.tryEval (builtins.deepSeq expr expr)).success;

  # Evaluate definitions against an option of the layer-0 `sections` type,
  # the way layer 1 uses it, and render the merged result.
  evalSections = modules: let
    eval = lib.evalModules {
      modules =
        [
          {
            options.file = lib.mkOption {
              type = format.types.sections;
              default = {};
            };
          }
        ]
        ++ modules;
    };
  in
    format.render {syntax = format.syntaxFor "pjsip.conf";} {sections = eval.config.file;};
in
  lib.runTests {
    # --- values -----------------------------------------------------------

    testBooleansRenderYesNo = {
      expr = render {} {
        sections.s = {
          on = true;
          off = false;
        };
      };
      expected = ''
        [s]
        off = no
        on = yes
      '';
    };

    testNumbers = {
      expr = render {} {
        sections.s = {
          port = 5060;
          negative = -1;
          ratio = 0.5;
        };
      };
      expected = ''
        [s]
        negative = -1
        port = 5060
        ratio = 0.500000
      '';
    };

    testNullValuesAreOmitted = {
      expr = render {} {
        sections.s = {
          a = null;
          b = "x";
        };
      };
      expected = ''
        [s]
        b = x
      '';
    };

    testListsRenderRepeatedKeysInOrder = {
      expr = render {} {
        sections.s.permit = [
          "10.0.0.0/8"
          null
          "192.168.1.0/24"
        ];
      };
      expected = ''
        [s]
        permit = 10.0.0.0/8
        permit = 192.168.1.0/24
      '';
    };

    testEmptyListRendersNothing = {
      expr = render {} {sections.s.allow = [];};
      expected = ''
        [s]
      '';
    };

    testSemicolonIsEscaped = {
      expr = render {} {sections.s.callerid = ''"A; B" <100>'';};
      expected = ''
        [s]
        callerid = "A\; B" <100>
      '';
    };

    testNewlineInValueThrows = {
      expr = throws (render {} {sections.s.a = "x\ny";});
      expected = true;
    };

    testCarriageReturnInValueThrows = {
      expr = throws (render {} {sections.s.a = "x\ry";});
      expected = true;
    };

    testAttrsetValueThrows = {
      expr = throws (
        render {} {
          sections.s.a = {
            foo = 1;
          };
        }
      );
      expected = true;
    };

    testStringLikeValuesRenderAsPath = {
      expr = render {} {
        sections.s.directory = {
          outPath = "/nix/store/abc-moh";
        };
      };
      expected = ''
        [s]
        directory = /nix/store/abc-moh
      '';
    };

    testNixStringEscapesForDialplanVariables = {
      # "\${EXTEN}" and ''${EXTEN} both produce a literal ${EXTEN}.
      expr = render {} {
        sections.s.exten = [
          "_X.,1,Dial(PJSIP/\${EXTEN})"
          "_X.,n,Set(A=\${CALLERID(num)})"
        ];
      };
      expected = ''
        [s]
        exten = _X.,1,Dial(PJSIP/''${EXTEN})
        exten = _X.,n,Set(A=''${CALLERID(num)})
      '';
    };

    # --- keys -------------------------------------------------------------

    testKeyOrderTypeDisallowAllowFirst = {
      expr = render {} {
        sections.alice = {
          context = "internal";
          allow = [
            "ulaw"
            "g722"
          ];
          disallow = "all";
          type = "endpoint";
          aors = "alice";
        };
      };
      expected = ''
        [alice]
        type = endpoint
        disallow = all
        allow = ulaw
        allow = g722
        aors = alice
        context = internal
      '';
    };

    testCustomKeyOrder = {
      expr = render {syntax.keyOrder = ["z"];} {
        sections.s = {
          a = 1;
          z = 2;
        };
      };
      expected = ''
        [s]
        z = 2
        a = 1
      '';
    };

    testInvalidKeyThrows = {
      expr = throws (render {} {sections.s."a=b" = 1;});
      expected = true;
    };

    testKeyWithSemicolonThrows = {
      expr = throws (render {} {sections.s."a;b" = 1;});
      expected = true;
    };

    testKeyWithLeadingHashThrows = {
      expr = throws (render {} {sections.s."#include" = "x";});
      expected = true;
    };

    # --- operators ----------------------------------------------------------

    testArrowKeys = {
      expr = renderFile "modules.conf" {
        sections.modules = {
          autoload = false;
          load = [
            "res_pjsip.so"
            "chan_pjsip.so"
          ];
          noload = ["chan_iax2.so"];
        };
      };
      expected = ''
        [modules]
        autoload = no
        load => res_pjsip.so
        load => chan_pjsip.so
        noload => chan_iax2.so
      '';
    };

    testArrowSections = {
      expr = renderFile "logger.conf" {
        sections = {
          general.dateformat = "%F %T";
          logfiles.console = "notice,warning,error";
        };
      };
      expected = ''
        [general]
        dateformat = %F %T

        [logfiles]
        console => notice,warning,error
      '';
    };

    testGlobalsUseEquals = {
      expr = renderFile "extensions.conf" {sections.globals.TRUNK = "PJSIP/provider";};
      expected = ''
        [globals]
        TRUNK = PJSIP/provider
      '';
    };

    # --- extensions.conf ----------------------------------------------------

    testExtenCompactsToSame = {
      expr = renderFile "extensions.conf" {
        sections.internal.exten = [
          "100,1,Answer()"
          "100,n(dial),Dial(PJSIP/alice,30)"
          "100,n,Hangup()"
          "101,1,Hangup()"
        ];
      };
      expected = ''
        [internal]
        exten => 100,1,Answer()
         same => n(dial),Dial(PJSIP/alice,30)
         same => n,Hangup()
        exten => 101,1,Hangup()
      '';
    };

    testHintLinesAreNotCompacted = {
      expr = renderFile "extensions.conf" {
        sections.internal.exten = [
          "100,hint,PJSIP/alice"
          "100,1,Dial(PJSIP/alice)"
          "100,n,Hangup()"
        ];
      };
      expected = ''
        [internal]
        exten => 100,hint,PJSIP/alice
        exten => 100,1,Dial(PJSIP/alice)
         same => n,Hangup()
      '';
    };

    testCallerIdMatchIsPartOfExtension = {
      expr = renderFile "extensions.conf" {
        sections.inbound.exten = [
          "100/_555.,1,Busy()"
          "100,1,Answer()"
          "100,n,Hangup()"
        ];
      };
      expected = ''
        [inbound]
        exten => 100/_555.,1,Busy()
        exten => 100,1,Answer()
         same => n,Hangup()
      '';
    };

    testNonAdjacentExtensionStartsNewExten = {
      expr = renderFile "extensions.conf" {
        sections.c.exten = [
          "1,1,NoOp()"
          "2,1,NoOp()"
          "1,2,NoOp()"
        ];
      };
      expected = ''
        [c]
        exten => 1,1,NoOp()
        exten => 2,1,NoOp()
        exten => 1,2,NoOp()
      '';
    };

    testIncludesBeforeExtensions = {
      expr = renderFile "extensions.conf" {
        sections.c = {
          exten = ["s,1,Hangup()"];
          include = [
            "b"
            "a"
          ];
          switch = ["Realtime/default@extensions"];
        };
      };
      expected = ''
        [c]
        include => b
        include => a
        switch => Realtime/default@extensions
        exten => s,1,Hangup()
      '';
    };

    testSemicolonInDialplanIsEscaped = {
      expr = renderFile "extensions.conf" {
        sections.page.exten = [
          "s,1,Set(PJSIP_HEADER(add,Call-Info)=<sip:intercom>;answer-after=0)"
          "s,n,Return()"
        ];
      };
      expected = ''
        [page]
        exten => s,1,Set(PJSIP_HEADER(add,Call-Info)=<sip:intercom>\;answer-after=0)
         same => n,Return()
      '';
    };

    # --- sections -------------------------------------------------------------

    testRepeatedSectionNames = {
      expr = render {} {
        sections = {
          alice-endpoint = {
            name = "alice";
            order = 1;
            type = "endpoint";
            auth = "alice";
          };
          alice-auth = {
            name = "alice";
            order = 2;
            type = "auth";
            username = "alice";
          };
        };
      };
      expected = ''
        [alice]
        type = endpoint
        auth = alice

        [alice]
        type = auth
        username = alice
      '';
    };

    testTemplatesAndInheritance = {
      expr = render {} {
        sections = {
          phone = {
            inherits = [
              "base"
              "codecs"
            ];
            context = "internal";
          };
          base = {
            template = true;
            type = "endpoint";
          };
          codecs = {
            template = true;
            inherits = ["base"];
            allow = "ulaw";
          };
        };
      };
      expected = ''
        [base](!)
        type = endpoint

        [codecs](!,base)
        allow = ulaw

        [phone](base,codecs)
        context = internal
      '';
    };

    testSectionOrderThenId = {
      expr = render {} {
        sections = {
          b.x = 1;
          a.x = 1;
          z = {
            order = 1;
            x = 1;
          };
        };
      };
      expected = ''
        [z]
        x = 1

        [a]
        x = 1

        [b]
        x = 1
      '';
    };

    testGeneralAndGlobalsComeFirst = {
      expr = render {} {
        sections = {
          default."100" = "1234,Alice";
          globals.A = 1;
          general.format = "wav";
        };
      };
      expected = ''
        [general]
        format = wav

        [globals]
        A = 1

        [default]
        100 = 1234,Alice
      '';
    };

    testEmptySection = {
      expr = render {} {sections.unauthorized = {};};
      expected = ''
        [unauthorized]
      '';
    };

    testInvalidSectionNameThrows = {
      expr = throws (render {} {sections."a]b" = {};});
      expected = true;
    };

    testInvalidInheritNameThrows = {
      expr = throws (render {} {sections.a.inherits = ["x;y"];});
      expected = true;
    };

    # --- file level -----------------------------------------------------------

    testIncludesHeaderAndExtraConfig = {
      expr =
        render
        {
          header = "Generated by Nix.";
        }
        {
          includes = [
            "pjsip_custom.conf"
            {
              file = "/var/lib/asterisk/extra.conf";
              optional = true;
            }
          ];
          sections.general.a = 1;
          extraConfig = ''
            [raw]
            foo=bar
          '';
        };
      expected = ''
        ; Generated by Nix.

        #include "pjsip_custom.conf"
        #tryinclude "/var/lib/asterisk/extra.conf"

        [general]
        a = 1

        [raw]
        foo=bar
      '';
    };

    testEmptyDocument = {
      expr = render {} {};
      expected = "\n";
    };

    # --- secrets ----------------------------------------------------------------

    testSecretRendersPlaceholder = {
      expr = render {} {sections.alice.password = asteriskLib.secret "/run/secrets/alice";};
      expected = ''
        [alice]
        password = ${secrets.placeholder {_secret = "/run/secrets/alice";}}
      '';
    };

    testCredentialRendersPlaceholder = {
      expr = render {secretPlaceholder = ref: "<${ref._credential}>";} {
        sections.alice.password = asteriskLib.credential "alice-pw";
      };
      expected = ''
        [alice]
        password = <alice-pw>
      '';
    };

    testSecretPlaceholderIsStableAndDistinct = {
      expr = let
        p = path: secrets.placeholder (asteriskLib.secret path);
      in [
        (p "/a" == p "/a")
        (p "/a" == p "/b")
        (p "/a" == "@NIX_ASTERISK_SECRET:file:/a@")
      ];
      expected = [
        true
        false
        true
      ];
    };

    testSecretIsNotConfusedWithOtherAttrs = {
      expr = map secrets.isSecret [
        {_secret = "/x";}
        {_credential = "x";}
        {
          _secret = "/x";
          other = 1;
        }
        {_secret = 1;}
        "/x"
      ];
      expected = [
        true
        true
        false
        false
        false
      ];
    };

    testSecretInterpolatesToPlaceholder = {
      expr = [
        "${asteriskLib.secret "/run/secrets/vm"},Sales,sales@example.org"
        "${asteriskLib.credential "pin"}"
      ];
      expected = [
        "@NIX_ASTERISK_SECRET:file:/run/secrets/vm@,Sales,sales@example.org"
        "@NIX_ASTERISK_SECRET:credential:pin@"
      ];
    };

    testSecretsFoundInText = {
      expr = secrets.fromText ''
        password = @NIX_ASTERISK_SECRET:file:/run/secrets/a@
        200 => @NIX_ASTERISK_SECRET:credential:vm-200@,Sales
        again = @NIX_ASTERISK_SECRET:file:/run/secrets/a@;x
      '';
      expected = [
        {_secret = "/run/secrets/a";}
        {_credential = "vm-200";}
      ];
    };

    testUnsafeSecretPathThrows = {
      expr = map (p: throws (asteriskLib.secret p)) [
        "relative/path"
        "/run/with space"
        "/run/semi;colon"
        "/run/at@sign"
        "/run/secrets/ok-path_1.2"
      ];
      expected = [
        true
        true
        true
        true
        false
      ];
    };

    testInvalidCredentialNameThrows = {
      expr = map (n: throws (asteriskLib.credential n)) [
        "ok-name_1.x"
        "bad/name"
        ".."
      ];
      expected = [
        false
        true
        true
      ];
    };

    testCollectSecretsDeduplicates = {
      expr = secrets.collect {
        a.b = [
          (asteriskLib.secret "/s1")
          "plain"
        ];
        c = asteriskLib.secret "/s1";
        d = asteriskLib.credential "c1";
        e = {
          outPath = "/nix/store/x";
        };
      };
      expected = [
        {_secret = "/s1";}
        {_credential = "c1";}
      ];
    };

    testCredentialNames = {
      expr = [
        (secrets.credentialName (asteriskLib.credential "alice-pw"))
        (builtins.match "secret-[0-9a-f]{32}" (secrets.credentialName (asteriskLib.secret "/x")) != null)
        (secrets.isValidCredentialName "ok_name.1-2")
        (secrets.isValidCredentialName "no/slash")
      ];
      expected = [
        "alice-pw"
        true
        true
        false
      ];
    };

    testStorePathSecretIsDetected = {
      expr = [
        (secrets.isStorePath (asteriskLib.secret "${builtins.storeDir}/abc-pw"))
        (secrets.isStorePath (asteriskLib.secret "/run/secrets/pw"))
      ];
      expected = [
        true
        false
      ];
    };

    # --- dialplan helpers -------------------------------------------------------

    testEscapingConventionsAgree = {
      expr = [
        "\${EXTEN}"
        "\${EXTEN}"
        (asteriskLib.dialplan.var "EXTEN")
      ];
      expected = [
        "\${EXTEN}"
        "\${EXTEN}"
        "\${EXTEN}"
      ];
    };

    testVarRendersDollarBrace = {
      expr =
        builtins.substring 0 2 (asteriskLib.dialplan.var "EXTEN")
        + "|"
        + toString (builtins.stringLength (asteriskLib.dialplan.var "X"));
      expected = "\${|4";
    };

    testAppJoinsArguments = {
      expr = asteriskLib.dialplan.app "Dial" [
        "PJSIP/101&PJSIP/102"
        30
        "tT"
      ];
      expected = "Dial(PJSIP/101&PJSIP/102,30,tT)";
    };

    testAppWithoutArguments = {
      expr = asteriskLib.dialplan.app "Answer" [];
      expected = "Answer()";
    };

    testPageDefaults = {
      expr = asteriskLib.dialplan.page {
        endpoints = [
          "kitchen"
          "office"
        ];
      };
      expected = "Page(PJSIP/kitchen&PJSIP/office,d,20)";
    };

    testPageWithPredialAndOptions = {
      expr = asteriskLib.dialplan.page {
        endpoints = ["kitchen"];
        duplex = false;
        quiet = true;
        predial = "page-autoanswer";
        timeout = 10;
        extraOptions = "i";
      };
      expected = "Page(PJSIP/kitchen,qb(page-autoanswer^s^1)i,10)";
    };

    testAutoAnswerContext = {
      expr = asteriskLib.dialplan.autoAnswerContext {};
      expected = {
        extensions.s = [
          "Set(PJSIP_HEADER(add,Call-Info)=<sip:intercom>;answer-after=0)"
          "Set(PJSIP_HEADER(add,Alert-Info)=info=alert-autoanswer)"
          "Return()"
        ];
      };
    };

    testAutoAnswerContextWithoutAlertInfo = {
      expr = asteriskLib.dialplan.autoAnswerContext {alertInfo = null;};
      expected = {
        extensions.s = [
          "Set(PJSIP_HEADER(add,Call-Info)=<sip:intercom>;answer-after=0)"
          "Return()"
        ];
      };
    };

    # --- module system integration ----------------------------------------------

    testModuleMergingAndPriorities = {
      expr = evalSections [
        {
          file.alice = {
            type = "endpoint";
            context = "internal";
            allow = ["ulaw"];
          };
        }
        {
          file.alice = {
            context = lib.mkForce "other";
            allow = ["g722"];
          };
        }
        {
          file.alice-auth = {
            name = "alice";
            type = "auth";
            password = asteriskLib.secret "/run/secrets/alice";
          };
        }
      ];
      expected = ''
        [alice]
        type = endpoint
        allow = ulaw
        allow = g722
        context = other

        [alice]
        type = auth
        password = ${secrets.placeholder {_secret = "/run/secrets/alice";}}
      '';
    };

    testModuleTypeRejectsNestedAttrs = {
      expr = throws (evalSections [{file.alice.nested.x = 1;}]);
      expected = true;
    };

    testModuleConflictingScalarsThrow = {
      expr = throws (evalSections [
        {file.a.context = "one";}
        {file.a.context = "two";}
      ]);
      expected = true;
    };
  }
