# Unit tests for the pure helpers in lib/ (config format and secrets).
# Evaluated with lib.runTests; the result is the list of failed tests.
{
  lib,
  asteriskLib,
}: let
  inherit (asteriskLib) format;

  render = args: doc: format.render args doc;
  renderFile = file: doc:
    format.render {
      syntax = format.syntaxFor file;
      inherit file;
    }
    doc;

  # `success` is false when evaluation throws
  throws = expr: !(builtins.tryEval (builtins.deepSeq expr expr)).success;
in
  lib.runTests {
    # a list repeats its key in order, without its nulls; a null or an empty
    # list renders nothing
    testListsRenderRepeatedKeysInOrder = {
      expr = render {} {
        sections.s = {
          permit = [
            "10.0.0.0/8"
            null
            "192.168.1.0/24"
          ];
          a = null;
          allow = [];
        };
      };
      expected = ''
        [s]
        permit = 10.0.0.0/8
        permit = 192.168.1.0/24
      '';
    };

    # a line break ends a value, and Asterisk strips every byte below 33 at
    # either end of one and keeps it inside, and any other byte anywhere, such
    # as DEL or those of UTF-8; an attrset is no value
    testInvalidValuesThrow = {
      expr = map (a: throws (render {} {sections.s = {inherit a;};})) (["x\ny" "x\ry" "  x" "x\t" " " "x  y" {foo = 1;}] ++ map builtins.fromJSON [''"\u0001x"'' ''"x\u001f"'' ''"x\u0001y"'' ''"x\u007f"'' ''"\u00e9"'']);
      expected = [true true true true true false true true true false false false];
    };

    testTrueValuesAsAsteriskReadsThem = {
      expr = map format.isTrue [
        true
        "yes"
        "On"
        "T"
        1
        "1"
        false
        "no"
        2
        null
        (asteriskLib.secret "/run/secrets/x")
      ];
      expected = [
        true
        true
        true
        true
        true
        true
        false
        false
        false
        false
        false
      ];
    };

    testJoinFieldsDropsEmptyTrailingFields = {
      expr = [
        (format.joinFields ["1234" "Alice" "" "" ""])
        (format.joinFields ["PJSIP/101" "" "" "PJSIP/201"])
        (format.joinFields [""])
      ];
      expected = [
        "1234,Alice"
        "PJSIP/101,,,PJSIP/201"
        ""
      ];
    };

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

    testInvalidKeysThrow = {
      expr = map (key: throws (render {} {sections.s.${key} = 1;})) [
        "a=b"
        "a;b"
        "#include"
        "ok"
      ];
      expected = [
        true
        true
        true
        false
      ];
    };

    # consecutive lines of one extension become `same =>`, except a hint, and
    # an extension with a caller ID match is another extension
    testExtenCompactsToSame = {
      expr = renderFile "extensions.conf" {
        sections.internal.exten = [
          "100,hint,PJSIP/alice"
          "100,1,Answer()"
          "100,n(dial),Dial(PJSIP/alice,30)"
          "100/_555.,1,Busy()"
          "100/_555.,n,Hangup()"
          "101,1,Hangup()"
          "100,3,Hangup()"
        ];
      };
      expected = ''
        [internal]
        exten => 100,hint,PJSIP/alice
        exten => 100,1,Answer()
         same => n(dial),Dial(PJSIP/alice,30)
        exten => 100/_555.,1,Busy()
         same => n,Hangup()
        exten => 101,1,Hangup()
        exten => 100,3,Hangup()
      '';
    };

    # sections sort by order, which puts general and globals first, then
    # templates, which the sections inheriting from them must follow, then by
    # id
    testSectionOrderAndTemplates = {
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
          a.x = 1;
          z = {
            order = 2;
            x = 1;
          };
          globals.A = 1;
          general.format = "wav";
        };
      };
      expected = ''
        [general]
        format = wav

        [globals]
        A = 1

        [z]
        x = 1

        [base](!)
        type = endpoint

        [codecs](!,base)
        allow = ulaw

        [a]
        x = 1

        [phone](base,codecs)
        context = internal
      '';
    };

    # a comment is not a key, and every line of it stays a comment
    testSectionComment = {
      expr = render {} {
        sections.s = {
          comment = "from pbx.ringGroups.front\n\nrings 201; then 202\n";
          x = 1;
        };
      };
      expected = ''
        ; from pbx.ringGroups.front
        ;
        ; rings 201; then 202
        [s]
        x = 1
      '';
    };

    testInvalidSectionNamesThrow = {
      expr = [
        (throws (render {} {sections."a]b" = {};}))
        (throws (render {} {sections.a.inherits = ["x;y"];}))
      ];
      expected = [
        true
        true
      ];
    };

    testSectionNamesOfSettingsAndRawText = {
      expr = [
        (format.sectionNames {
          sections = {
            a = {};
            b.name = "renamed";
          };
          extraConfig = "[raw]\nexten => 1,1,Answer()\n  [indented](template)\n; [commented]\n";
        })
        (format.sectionNames {includes = ["local.conf"];})
        (format.sectionNames {extraConfig = "#tryinclude \"local.conf\"\n[raw]\n";})
      ];
      expected = [
        [
          "a"
          "renamed"
          "raw"
          "indented"
        ]
        null
        null
      ];
    };

    # parents' keys come first and later sources win, except for `type`; a
    # null value is not rendered, so it does not hide an inherited one
    testResolveInheritanceMergesInOrder = {
      expr = format.resolveInheritance {
        phone = {
          template = true;
          type = "endpoint";
          context = "a";
          transport = "udp";
        };
        office = {
          template = true;
          type = "aor";
          context = "b";
        };
        "101" = {
          inherits = [
            "phone"
            "office"
          ];
          type = "identify";
          aors = "101";
          transport = null;
        };
      };
      expected = {
        sections = [
          {
            name = "101";
            type = "endpoint";
            context = "b";
            transport = "udp";
            aors = "101";
          }
        ];
        unresolved = [];
      };
    };

    # a parent is the first section of that name rendered earlier
    testResolveInheritanceLooksParentsUpEarlier = {
      expr = format.resolveInheritance {
        "aor:101" = {
          name = "101";
          type = "aor";
          max_contacts = 1;
        };
        "endpoint:101" = {
          name = "101";
          type = "endpoint";
        };
        copy.inherits = ["101"];
        # rendered first, before its parent
        early = {
          order = 0;
          inherits = ["late"];
        };
        late = {
          template = true;
          type = "auth";
        };
        orphan.inherits = ["elsewhere"];
      };
      expected = {
        sections = [
          {
            name = "101";
            type = "aor";
            max_contacts = 1;
          }
          {
            name = "copy";
            type = "aor";
            max_contacts = 1;
          }
          {
            name = "101";
            type = "endpoint";
          }
        ];
        unresolved = [
          {
            name = "early";
            inherits = ["late"];
          }
          {
            name = "orphan";
            inherits = ["elsewhere"];
          }
        ];
      };
    };

    # a template inheriting a template passes on what it inherited; a section
    # below one whose parent is missing is left out too
    testResolveInheritanceFollowsChains = {
      expr = format.resolveInheritance {
        base = {
          template = true;
          type = "endpoint";
          context = "nowhere";
          direct_media = true;
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
        lost = {
          template = true;
          inherits = ["elsewhere"];
        };
        door.inherits = ["lost"];
      };
      expected = {
        sections = [
          {
            name = "gate";
            type = "endpoint";
            context = "internal";
            direct_media = true;
            aors = "gate";
          }
        ];
        unresolved = [
          {
            name = "lost";
            inherits = ["elsewhere"];
          }
          {
            name = "door";
            inherits = ["lost"];
          }
        ];
      };
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
  }
