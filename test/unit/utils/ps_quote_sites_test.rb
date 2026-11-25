# frozen_string_literal: true

require 'test_helper'

require 'fog/json'

require 'fog/hyperv/utils/boot_order'
require 'fog/hyperv/utils/cluster_role'
require 'fog/hyperv/utils/destructive_path'
require 'fog/hyperv/utils/file_pull'

# Every site that embeds text into a PowerShell single-quoted literal, tested
# through the entry point that embeds it — not against the escape primitive
# (ps_quote_test.rb covers that). The attack is one shape repeated at each
# site: a typographic quote (U+2019, the one copy-paste and friendly filenames
# actually carry) followed by code, exactly the review's scenario:
#
#   http://x/a’; Remove-Item C:\VMs -Recurse; ’
#
# Rendered unescaped, U+2019 closes the literal and Remove-Item runs under the
# WinRM account. These tests hand-build their expected bytes instead of
# calling the primitive, so each one states the wire shape the site must
# produce on its own terms.
class UnitPsQuoteSitesTest < Minitest::Test
  CURLY = "\u2019"

  # Records the exact strings that would go down the wire; the shape copied
  # from the stdout-hygiene harness, so a real run_cmd renders through the
  # real build_pscall with nothing dialled.
  class RecordingShell
    attr_reader :runs

    def initialize
      @runs = []
    end

    def run(script)
      @runs << script
      return Fog::Hyperv::Utils::Winrm::LocalExecOutput.new('True', '', 0) if script == '$?'

      Fog::Hyperv::Utils::Winrm::LocalExecOutput.new('{"Name":"HV-NODE1"}', '', 0)
    end
  end

  class RecordingConnection
    def initialize(endpoint, shell)
      @shell = shell
      @connection_opts = { endpoint: endpoint }
    end

    def shell(_kind)
      yield @shell
    end
  end

  class OfflineClient < Fog::Hyperv::Compute::Real
    attr_reader :recording_shell

    def initialize(options)
      @recording_shell = RecordingShell.new
      super
    end

    def ps_version
      { major: 5, minor: 1 }
    end

    private

    def connect(endpoint = nil)
      endpoint ||= @hyperv_endpoint
      conn = RecordingConnection.new(endpoint, @recording_shell)
      @connections[URI.parse(endpoint).host] = conn
      if endpoint == @hyperv_endpoint
        @connection = conn
        @connections['.'] = conn
        @connections['localhost'] = conn
      end
      conn
    end

    def discover_host_names(_fqdn)
      [nil, nil]
    end
  end

  def setup
    @client = OfflineClient.new(hyperv_endpoint: 'http://recorded.invalid:5985/wsman')
    @shell = @client.recording_shell
  end

  # Hand-built expected bytes: each of the five quote characters doubles, and
  # nothing else moves. Written as a loop so the four Unicode quotes cannot be
  # silently dropped from a hand-typed literal.
  def doubled(text)
    ["'", "\u2018", "\u2019", "\u201A", "\u201B"].each { |q| text = text.gsub(q, q + q) }
    text
  end

  # --- the pull script (fetch_url_to_path) ---------------------------------

  def test_the_pull_script_doubles_typographic_quotes_in_the_url
    url = "http://x/a#{CURLY}; Remove-Item C:\\VMs -Recurse; #{CURLY}"
    script = Fog::Hyperv::Utils::FilePull.build_script(
      url: url, path: 'C:\bootdisk\x.iso', sha256: 'AB12', size: 7
    )

    assert_includes script, "-Uri '#{doubled(url)}'"
  end

  def test_the_pull_script_doubles_typographic_quotes_in_the_path
    # The request gate (ContainedPath) also refuses this path — ALLOWED_CHARS
    # excludes the typographic quotes — so this pins the builder's own
    # contract for callers that hand it a string directly, not a hole in
    # fetch_url_to_path (the url test above is the live F7 surface).
    path = "C:\\VMs\\web#{CURLY}1\\x.iso"
    script = Fog::Hyperv::Utils::FilePull.build_script(
      url: 'http://x/a.iso', path: path, sha256: 'AB12', size: 7
    )

    assert_includes script, "$fogPart = '#{doubled(path)}.part'"
    assert_includes script, "-Destination '#{doubled(path)}'"
  end

  def test_the_pull_script_still_doubles_the_ascii_apostrophe
    script = Fog::Hyperv::Utils::FilePull.build_script(
      url: "http://x/O'Brien.iso", path: "C:\\a\\O'Brien.iso", sha256: 'AB12', size: 7
    )

    assert_includes script, "-Uri 'http://x/O''Brien.iso'"
  end

  # --- the boot-order request JSON ------------------------------------------

  def test_the_boot_order_json_escapes_quotes_in_device_names
    requests = [
      { 'Class' => 'DvdDrive', 'Id' => "IDE (0,0)#{CURLY}" },
      { 'Class' => 'HardDiskDrive', 'Id' => "O'Brien" }
    ]
    script = Fog::Hyperv::Utils::BootOrder.build_set_script(requests)

    json = Fog::JSON.encode(requests)

    assert_includes script, "$fogReq = ConvertFrom-Json -InputObject '#{doubled(json)}'"
  end

  def test_the_boot_order_json_passes_backslashes_through_exactly_once
    # The JSON encoder's own doubling for a literal backslash in a device
    # path must survive as the encoder wrote it: single-quoted literals do not
    # process backslashes, so a second doubling would corrupt what
    # ConvertFrom-Json parses.
    requests = [{ 'Class' => 'HardDiskDrive', 'Id' => 'SCSI (0,0)\Disk1' }]
    script = Fog::Hyperv::Utils::BootOrder.build_set_script(requests)

    json = Fog::JSON.encode(requests)

    assert_includes script, "$fogReq = ConvertFrom-Json -InputObject '#{json}'"
  end

  # --- the cmdlet option map (every run_cmd call rides this) ----------------

  def test_the_option_map_json_escapes_quotes_on_the_ps5_path
    lines = Fog::Hyperv::Utils::Powershell.build_call('Get-VM', { name: "web#{CURLY}1" }, _ps_version: 5)
    carrier = lines.find { |l| l.include?('$FogJsonObject = ') }

    refute_nil carrier, 'the PS 5 branch carries the option map as a JSON literal'
    json = Fog::JSON.encode('Name' => "web#{CURLY}1")

    assert_includes carrier, "$FogJsonObject = '#{doubled(json)}'"
  end

  def test_the_option_map_json_escapes_quotes_on_the_ps6_path
    lines = Fog::Hyperv::Utils::Powershell.build_call('Get-VM', { name: "O'Brien" }, _ps_version: 6)
    carrier = lines.find { |l| l.include?('ConvertFrom-Json -AsHashtable') }

    json = Fog::JSON.encode('Name' => "O'Brien")

    assert_includes carrier, "ConvertFrom-Json -AsHashtable '#{doubled(json)}'"
  end

  def test_the_option_map_of_quote_free_arguments_is_byte_for_byte_what_it_was
    # The escape must be invisible except where a quote actually appears —
    # this is what makes the change safe under every existing caller.
    lines = Fog::Hyperv::Utils::Powershell.build_call('Get-VM', { path: 'C:\VMs' }, _ps_version: 5)
    carrier = lines.find { |l| l.include?('$FogJsonObject = ') }

    json = Fog::JSON.encode('Path' => 'C:\VMs')

    assert_includes carrier, "$FogJsonObject = '#{json}'"
  end

  def test_the_non_json_option_map_renders_unchanged
    # The _from_json: false branch quotes values with shell_quote, a different
    # (double-quoted, backtick-escaped) scheme this change deliberately does
    # not touch; this pins that the fork did not move it. Running it at all is
    # new: the branch's Fog::Hyperv.shell_quote call never resolved (a
    # pre-utils-split leftover), so this test is the first execution of the
    # line and the PR ships the one-word qualification fix with it.
    lines = Fog::Hyperv::Utils::Powershell.build_call('Get-VM', { name: 'web1', _from_json: false }, _ps_version: 5)

    assert_match(/= @\{'Name'="web1"\}/, lines.join(' '))
  end

  # --- the _by_id pipeline filter --------------------------------------------

  def test_the_by_id_filter_doubles_quotes_before_embedding
    @client.run_cmd('Get-VMHardDiskDrive', vmid: 'x', _by_id: "a#{CURLY}b'O")

    assert_equal 1, @shell.runs.size
    assert_includes @shell.runs.first, "Where-Object {$_.id -eq 'a#{CURLY}#{CURLY}b''O'}"
  end

  # --- the cluster-role name gate and filter ---------------------------------

  def test_role_names_carrying_typographic_quotes_are_refused
    ["web#{CURLY}1", "left\u2018", "low\u201A", "rev\u201B"].each do |bad|
      assert_raises(Fog::Hyperv::Errors::InvalidRoleIdentifier, "expected #{bad.inspect} to be refused") do
        Fog::Hyperv::Utils::ClusterRole.validate_role_name!(bad, 'req')
      end
    end
  end

  def test_the_role_read_script_refuses_a_name_the_gate_now_bans
    assert_raises(Fog::Hyperv::Errors::InvalidRoleIdentifier) do
      Fog::Hyperv::Utils::ClusterRole.build_read_script(vm_id: nil, name: "Web#{CURLY}1")
    end
  end

  # The -Name literal the builder renders for a gate-legal name must be the
  # bytes it always was: the escape the site now rides is invisible except
  # where a quote actually appears, and the gate has always kept quotes out
  # of names entirely (the doubling inside the builder is defense-in-depth,
  # covered by the primitive's own tests).
  def test_the_role_filter_renders_gate_legal_names_byte_for_byte
    script = Fog::Hyperv::Utils::ClusterRole.build_read_script(vm_id: nil, name: 'Virtual Machine web 01')

    assert_includes script, "-Name 'Virtual Machine web 01'"
  end

  # --- the machine-folder cleanup script --------------------------------------

  def test_the_folder_cleanup_script_doubles_typographic_quotes_in_the_path
    script = Fog::Hyperv::Utils::DestructivePath.build_empty_folder_removal_script("C:\\VMs\\web#{CURLY}1")

    # The path is embedded twice (enumerate, then delete): both must be safe.
    assert_equal 2, script.scan("'C:\\VMs\\web#{CURLY}#{CURLY}1'").size,
                 'both embeddings must carry the doubled quote'
  end
end
