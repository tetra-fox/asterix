# Secret values Asterisk reads as written, for tests/vm/core.nix: ; and \;
# and the ;-- that starts a comment block, commas, 4 KiB, letters outside
# ASCII, and one that ends with a CR LF and an empty line (secrets.nix adds a
# line end to each)
{lib}: {
  semicolon = ''a;b\;c;--d'';
  comma = "a,b,,c";
  long = lib.strings.replicate 256 "0123456789abcdef";
  unicode = builtins.fromJSON ''"p\u00e4ss w\u00f6rd \u20ac \u65e5\u672c \ud83d\udd11"'';
  crlf = "crlf\r\n";
}
