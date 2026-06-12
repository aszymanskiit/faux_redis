defmodule FauxRedis.GlobTest do
  use ExUnit.Case, async: true

  alias FauxRedis.Glob

  describe "match?/2" do
    test "matches literal keys" do
      assert Glob.match?("foo", "foo")
      refute Glob.match?("foo", "bar")
    end

    test "matches a single asterisk as any string" do
      assert Glob.match?("anything", "*")
      assert Glob.match?("", "*")
    end

    test "matches multiple asterisks including *@*" do
      assert Glob.match?("user@example.com", "*@*")
      assert Glob.match?("@local", "*@*")
      assert Glob.match?("prefix@suffix", "*@*")
      refute Glob.match?("no-at-sign", "*@*")
      refute Glob.match?("", "*@*")
    end

    test "matches prefix, suffix and infix wildcards" do
      assert Glob.match?("user1@example.com", "*@example.com")
      refute Glob.match?("user1@other.com", "*@example.com")

      assert Glob.match?("session:abc", "session:*")
      refute Glob.match?("other:abc", "session:*")

      assert Glob.match?("file.txt", "*.txt")
      refute Glob.match?("file.md", "*.txt")
    end

    test "matches question mark wildcards" do
      assert Glob.match?("hallo", "h?llo")
      assert Glob.match?("hello", "h?llo")
      refute Glob.match?("hllo", "h?llo")
      refute Glob.match?("heello", "h?llo")
    end

    test "matches character classes" do
      assert Glob.match?("hello", "h[ae]llo")
      assert Glob.match?("hallo", "h[ae]llo")
      refute Glob.match?("hillo", "h[ae]llo")

      assert Glob.match?("hbllo", "h[a-b]llo")
      refute Glob.match?("hcllo", "h[a-b]llo")
    end

    test "matches negated character classes" do
      assert Glob.match?("hallo", "h[^e]llo")
      refute Glob.match?("hello", "h[^e]llo")
    end

    test "matches escaped metacharacters" do
      assert Glob.match?("foo*bar", "foo\\*bar")
      refute Glob.match?("fooxbar", "foo\\*bar")

      assert Glob.match?("what?", "what\\?")
      refute Glob.match?("whatx", "what\\?")
    end

    test "handles edge cases with adjacent wildcards" do
      assert Glob.match?("abc", "**")
      assert Glob.match?("a@b@c", "*@*@*")
      refute Glob.match?("abc", "a*c*d")
    end
  end
end
