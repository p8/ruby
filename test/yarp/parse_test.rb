# frozen_string_literal: true

require_relative "test_helper"

class ParseTest < Test::Unit::TestCase
  # When we pretty-print the trees to compare against the snapshots, we want to
  # be certain that we print with the same external encoding. This is because
  # methods like Symbol#inspect take into account external encoding and it could
  # change how the snapshot is generated. On machines with certain settings
  # (like LANG=C or -Eascii-8bit) this could have been changed. So here we're
  # going to force it to be UTF-8 to keep the snapshots consistent.
  def setup
    @previous_default_external = Encoding.default_external
    ignore_warnings { Encoding.default_external = Encoding::UTF_8 }
  end

  def teardown
    ignore_warnings { Encoding.default_external = @previous_default_external }
  end

  def test_empty_string
    result = YARP.parse("")
    assert_equal [], result.value.statements.body
  end

  def test_parse_takes_file_path
    filepath = "filepath.rb"
    result = YARP.parse("def foo; __FILE__; end", filepath)

    assert_equal filepath, find_source_file_node(result.value).filepath
  end

  def test_parse_lex
    node, tokens = YARP.parse_lex("def foo; end").value

    assert_kind_of YARP::ProgramNode, node
    assert_equal 5, tokens.length
  end

  def test_parse_lex_file
    node, tokens = YARP.parse_lex_file(__FILE__).value

    assert_kind_of YARP::ProgramNode, node
    refute_empty tokens
  end

  # To accurately compare against Ripper, we need to make sure that we're
  # running on Ruby 3.2+.
  ripper_enabled = RUBY_VERSION >= "3.2.0"

  # The FOCUS environment variable allows you to specify one particular fixture
  # to test, instead of all of them.
  base = File.join(__dir__, "fixtures")
  relatives = ENV["FOCUS"] ? [ENV["FOCUS"]] : Dir["**/*.txt", base: base]

  relatives.each do |relative|
    # These fail on TruffleRuby due to a difference in Symbol#inspect: :测试 vs :"测试"
    next if RUBY_ENGINE == "truffleruby" and %w[seattlerb/bug202.txt seattlerb/magic_encoding_comment.txt].include?(relative)

    filepath = File.join(base, relative)
    snapshot = File.expand_path(File.join("snapshots", relative), __dir__)

    directory = File.dirname(snapshot)
    FileUtils.mkdir_p(directory) unless File.directory?(directory)

    ripper_should_parse = ripper_should_match = ripper_enabled

    # This file has changed behavior in Ripper in Ruby 3.3, so we skip it if
    # we're on an earlier version.
    ripper_should_match = false if relative == "seattlerb/pct_w_heredoc_interp_nested.txt" && RUBY_VERSION < "3.3.0"

    # It seems like there are some oddities with nested heredocs and ripper.
    # Waiting for feedback on https://bugs.ruby-lang.org/issues/19838.
    ripper_should_match = false if relative == "seattlerb/heredoc_nested.txt"

    # Ripper seems to have a bug that the regex portions before and after the heredoc are combined
    # into a single token. See https://bugs.ruby-lang.org/issues/19838.
    #
    # Additionally, Ripper cannot parse the %w[] fixture in this file, so set ripper_should_parse to false.
    ripper_should_parse = false if relative == "spanning_heredoc.txt"

    define_method "test_filepath_#{relative}" do
      # First, read the source from the filepath. Use binmode to avoid converting CRLF on Windows,
      # and explicitly set the external encoding to UTF-8 to override the binmode default.
      source = File.read(filepath, binmode: true, external_encoding: Encoding::UTF_8)

      # Make sure that it can be correctly parsed by Ripper. If it can't, then we have a fixture
      # that is invalid Ruby.
      refute_nil(Ripper.sexp_raw(source), "Ripper failed to parse") if ripper_should_parse

      # Next, assert that there were no errors during parsing.
      result = YARP.parse(source, relative)
      assert_empty result.errors

      # Next, pretty print the source.
      printed = PP.pp(result.value, +"", 79)

      if File.exist?(snapshot)
        saved = File.read(snapshot)

        # If the snapshot file exists, but the printed value does not match the
        # snapshot, then update the snapshot file.
        if printed != saved
          File.write(snapshot, printed)
          warn("Updated snapshot at #{snapshot}.")
        end

        # If the snapshot file exists, then assert that the printed value
        # matches the snapshot.
        assert_equal(saved, printed)
      else
        # If the snapshot file does not yet exist, then write it out now.
        File.write(snapshot, printed)
        warn("Created snapshot at #{snapshot}.")
      end

      # Next, assert that the value can be serialized and deserialized without
      # changing the shape of the tree.
      assert_equal_nodes(result.value, YARP.load(source, YARP.dump(source, relative)).value)

      # Next, check that the location ranges of each node in the tree are a
      # superset of their respective child nodes.
      assert_non_overlapping_locations(result.value)

      # Next, assert that the newlines are in the expected places.
      expected_newlines = [0]
      source.b.scan("\n") { expected_newlines << $~.offset(0)[0] + 1 }

      # If there's a __END__, then we should trip out those newlines because we
      # don't actually scan them during parsing (because we don't need to).
      if found = result.comments.find { |comment| comment.type == :__END__ }
        expected_newlines = expected_newlines[...found.location.start_line]
      end

      assert_equal expected_newlines, YARP.const_get(:Debug).newlines(source)

      if ripper_should_parse && ripper_should_match
        # Finally, assert that we can lex the source and get the same tokens as
        # Ripper.
        lex_result = YARP.lex_compat(source)
        assert_equal [], lex_result.errors
        tokens = lex_result.value

        begin
          YARP.lex_ripper(source).zip(tokens).each do |(ripper, yarp)|
            assert_equal ripper, yarp
          end
        rescue SyntaxError
          raise ArgumentError, "Test file has invalid syntax #{filepath}"
        end
      end
    end
  end

  Dir["*.txt", base: base].each do |relative|
    next if relative == "newline_terminated.txt"

    # We test every snippet (separated by \n\n) in isolation
    # to ensure the parser does not try to read bytes further than the end of each snippet
    define_method "test_individual_snippets_#{relative}" do
      filepath = File.join(base, relative)

      # First, read the source from the filepath. Use binmode to avoid converting CRLF on Windows,
      # and explicitly set the external encoding to UTF-8 to override the binmode default.
      file_contents = File.read(filepath, binmode: true, external_encoding: Encoding::UTF_8)

      file_contents.split(/(?<=\S)\n\n(?=\S)/).each do |snippet|
        snippet = snippet.rstrip
        result = YARP.parse(snippet, relative)
        assert_empty result.errors

        assert_equal_nodes(result.value, YARP.load(snippet, YARP.dump(snippet, relative)).value)
      end
    end
  end

  private

  # Check that the location ranges of each node in the tree are a superset of
  # their respective child nodes.
  def assert_non_overlapping_locations(node)
    queue = [node]

    while (current = queue.shift)
      # We only want to compare parent/child location overlap in the case that
      # we are not looking at a heredoc. That's because heredoc locations are
      # special in that they only use the declaration of the heredoc.
      compare = !(current.is_a?(YARP::InterpolatedStringNode) || current.is_a?(YARP::InterpolatedXStringNode)) || !current.opening&.start_with?("<<")

      current.child_nodes.each do |child|
        # child_nodes can return nil values, so we need to skip those.
        next unless child

        # Now that we know we have a child node, add that to the queue.
        queue << child

        if compare
          assert_operator current.location.start_offset, :<=, child.location.start_offset
          assert_operator current.location.end_offset, :>=, child.location.end_offset
        end
      end
    end
  end

  def find_source_file_node(program)
    queue = [program]
    while (node = queue.shift)
      return node if node.is_a?(YARP::SourceFileNode)
      queue.concat(node.child_nodes.compact)
    end
  end

  def ignore_warnings
    previous_verbosity = $VERBOSE
    $VERBOSE = nil
    yield
  ensure
    $VERBOSE = previous_verbosity
  end
end
