# frozen_string_literal: true

require 'test_helper'

# Measured on HV-CL01 through the plugin's own WinRM path (production.log
# 99f1679a): the preferred-owners write exited 0 and printed nothing, and the
# only thing the shell answered was a PARSE error —
#
#   At line:28 char:110 ... Missing statement block after if ( condition ).
#
# The line read `if ((A) -join '|') -eq ((B) -join '|') { 'applied' } else {
# 'refused' }`. PowerShell closes an if condition at the FIRST unmatched ')',
# so the condition it parsed was `(A) -join '|'` and the comparison fell
# outside the parentheses: the parser saw `if (cond) -eq (B) {`, and a
# comparison is not a statement block. The parse error also explains the shape
# of the contract around it: a script that fails to parse writes nothing to
# stdout, still exits 0, and leaves $? at whatever the previous statement set,
# so the transport reports success and only the "silence is not a readable
# outcome" guard stands between that and a setting silently left unfixed.
#
# A script fog cannot parse is a script fog cannot run, and no assertion about
# its JSON can be true of it, so the shape is pinned here — before it goes
# down the wire, where the only symptom is quiet.
class UnitPowershellIfConditionTest < Minitest::Test
  LIB = File.join(File.expand_path('../../..', __dir__), 'lib')
  QUOTES = ["'", '"'].freeze

  # Every heredoc fog ships, `<<~SCRIPT` and friends through their terminator.
  # Interpolated values are not expanded, so this is a scan of the source
  # shape; the second test covers the one script whose condition a caller's
  # argument rides into.
  def self.script_bodies
    Dir.glob("#{LIB}/**/*.rb").each_with_object([]) do |file, scripts|
      lines = File.readlines(file)
      index = 0
      while index < lines.size
        marker = lines[index].match(/<<(?:~|-)?(['"]?)([A-Z][A-Z0-9_]*)\1\s*$/)
        index += 1
        next unless marker

        terminator = /\A\s*#{marker[2]}\s*\z/
        body = []
        while index < lines.size && !lines[index].match?(terminator)
          body << lines[index]
          index += 1
        end
        index += 1
        scripts << [file.sub("#{LIB}/", ''), body.join]
      end
    end
  end

  # Splits an `if` line into the condition PowerShell would read and what
  # follows it, walking past the matching ')' with quoted strings skipped. It
  # answers nil when the line holds no if, and a nil tail when the block opens
  # on a later line, which this scan cannot judge.
  def self.if_statement(line)
    match = line.match(/(?:^|[\s;{=(])(?:el)?if\s*(\()/)
    return nil unless match

    depth = 0
    cursor = match.begin(1)
    while cursor < line.length
      char = line[cursor]
      if QUOTES.include?(char)
        cursor += 1
        cursor += 1 while cursor < line.length && line[cursor] != char
      elsif char == '('
        depth += 1
      elsif char == ')'
        depth -= 1
        if depth.zero?
          open = match.begin(1) + 1
          return [line[open...cursor], line[(cursor + 1)..].lstrip]
        end
      end
      cursor += 1
    end
    [nil, nil]
  end

  def test_every_if_in_a_shipped_script_is_followed_by_its_block
    offenders = []
    self.class.script_bodies.each do |file, script|
      script.lines.each_with_index do |line, number|
        next if line.strip.start_with?('#')

        _condition, tail = self.class.if_statement(line)
        next if tail.nil? || tail.empty? || tail.start_with?('{')

        offenders << "#{file}:#{number + 1}: #{line.strip[0, 90]}"
      end
    end

    assert_empty offenders, "PowerShell closes an if condition at the first unmatched ')', so each of " \
                            "these leaves a comparison where the block belongs:\n#{offenders.join("\n")}"
  end

  # The measured defect itself, pinned on the script the request sends: the
  # verdict's comparison rides INSIDE the if parentheses, so the condition
  # closes immediately before the block that assigns it.
  def test_the_owners_verdict_condition_wraps_the_whole_comparison
    script = Fog::Hyperv::Utils::ClusterRole.build_owner_nodes_script(
      id: '1c51c4ee-df90-4cee-a9f7-218888711248', owner_nodes: %w[hv-node2 hv-node3]
    )

    verdict = script.lines.find { |line| line.include?("$answer['result'] = if") }

    assert verdict, 'the owners write is expected to decide its verdict inside the script'

    condition, tail = self.class.if_statement(verdict)

    assert_includes condition.to_s, '-eq', 'the set comparison must sit inside the if condition'
    assert tail.to_s.start_with?('{'), "the condition must close immediately before its block: #{verdict.strip}"
  end
end
