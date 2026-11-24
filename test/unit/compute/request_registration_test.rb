# frozen_string_literal: true

require 'test_helper'
require 'rbconfig'
require 'open3'

# FOG-22 (BD-1 fog PR-4): a request file only EXISTS until the service DECLARES
# it. fog-core 2.6's Service#require_requests_and_mock (fog-core-2.6.0,
# service.rb:299) walks the list built by the `request :name` DSL and requires
# exactly those files, adding a Fog::Mock.not_implemented placeholder to Mock
# for every declared request that ships no Mock method (service.rb:301-310,
# read on the lab controller 2026-11-24). Service.setup_requirements runs that
# walk once per process, memoized by @required (service.rb:128-141). An
# undeclared request file is therefore dead weight on a real install: no
# method on Real, no Mock answer, and respond_to? says false.
#
# Every request this repo added after upstream (eject_vm_dvd_drive,
# fetch_url_to_path, get_vm_boot_order, set_vm_boot_order, remove_file) shipped
# without its declaration, and NOTHING in this suite noticed: each request's own
# test file does a direct `require 'fog/hyperv/compute/requests/<name>'` at the
# top, which defines the methods in-process and masks the missing registration.
# That masking is also why the probes below must not trust the IN-PROCESS class:
# the Rakefile loads every test file before running any test, so by the time a
# test executes, the siblings' requires have already defined these methods
# regardless of any declaration. The disk-vs-declared and subprocess tests are
# immune; the mock test only passes on the strength of fog-core's placeholder.
# The bug surfaced only when foreman_bootdisk's plugin side called
# client.fetch_url_to_path against the INSTALLED gem on the lab controller and
# got NoMethodError while every CI suite stayed green (2026-11-24).
class UnitRequestRegistrationTest < Minitest::Test
  # The request files this repo added, each measured undefined against the
  # installed gem before its declaration landed.
  FORK_REQUESTS = %i[
    eject_vm_dvd_drive
    fetch_url_to_path
    get_vm_boot_order
    remove_file
    set_vm_boot_order
  ].freeze

  # Request files deliberately NOT declared. update_vm predates this fork
  # (upstream commit e6a1410, Real and Mock both) and is out of scope for
  # FOG-22; recording the exception HERE is what makes the disk-vs-declared
  # test a statement of policy rather than an accident — declaring it (or
  # deleting it) must be a decision, same as joining a capability word on
  # the plugin's opt-in side.
  KNOWN_UNDECLARED = %i[update_vm].freeze

  def request_files_on_disk
    Dir[File.expand_path('../../../lib/fog/hyperv/compute/requests/*.rb', __dir__)]
      .map { |file| File.basename(file, '.rb').to_sym }
  end

  def declared_requests
    Fog::Hyperv::Compute.requests.map { |_scope, name| name.to_sym }
  end

  def test_service_declares_every_request_file_this_repo_added
    missing = FORK_REQUESTS.reject { |name| declared_requests.include?(name) }

    assert_empty missing,
                 'these request files exist under compute/requests but no `request :name` in ' \
                 'compute.rb declares them, so fog-core never requires them and no client gains them'
  end

  def test_every_request_file_on_disk_is_declared_or_excused
    # The round-18 fold: FORK_REQUESTS alone cannot catch the NEXT forgotten
    # declaration, because it is a hand-kept list. This one compares the
    # directory to the service's own list, so a sixth request file that
    # forgets its `request :` line fails here without touching any list.
    undeclared = request_files_on_disk - declared_requests - KNOWN_UNDECLARED

    assert_empty undeclared,
                 'request files exist that fog-core will never load and that KNOWN_UNDECLARED ' \
                 'does not excuse: add `request :name` to compute.rb or add the file to the ' \
                 'excused list with a reason'
  end

  def test_a_mock_built_client_answers_to_every_declared_request
    # What this proves is DECLARATION, not a usable mock: four of these five
    # files ship no Mock method, and their mock answers are fog-core's
    # placeholder that raises Fog::Errors::MockNotImplemented on CALL (see
    # service.rb:301-310). Under Fog.mock! respond_to? is true either way;
    # mock-mode consumers must not read this as a working fake (PR body says
    # the same). The five names are pinned because respond_to? on the mock
    # client is set purely by the declarations.
    was_mocking = Fog.mocking?
    Fog.mock!
    client = Fog::Compute.new(provider: :hyperv, hyperv_username: 'u', hyperv_password: 'p')
    unanswered = FORK_REQUESTS.reject { |name| client.respond_to?(name) }

    assert_empty unanswered,
                 'a mocked client does not answer to these requests: fog-core only registers ' \
                 'declared requests (with a raise-on-call Mock placeholder where no Mock method ' \
                 'ships), and these were not declared'
  ensure
    Fog.unmock! unless was_mocking
  end

  def test_a_clean_process_sees_the_methods_on_a_real_client
    # Round-18 finding 1: the in-process Real class is NOT trustworthy here —
    # sibling test files require these request files directly, so by suite
    # time Real has the methods whether or not the service declares them.
    # A consumer's process is clean, so this probe is a subprocess: fog-core
    # loads the service from scratch, exactly as an installed gem does for
    # the plugin's respond_to? gates, and the subprocess is pinned to THIS
    # tree by -Ilib. Non-mocked build: Real#initialize composes the WinRM
    # endpoint eagerly, so the client is given a host — parsed and validated,
    # never contacted (WinRM opens its shell on the first request; this test
    # sends none).
    script = <<~RUBY
      require 'fog/hyperv'
      client = Fog::Compute.new(provider: :hyperv, hyperv_username: 'u', hyperv_password: 'p',
                                hyperv_host: 'labnode.example.com')
      silent = %w[#{FORK_REQUESTS.join(' ')}].reject do |name|
        client.respond_to?(name) && Fog::Hyperv::Compute::Real.method_defined?(name)
      end
      puts silent.join(',')
    RUBY
    out, err, status = Open3.capture3(RbConfig.ruby, '-Ilib', '-e', script)

    assert_predicate status, :success?, "clean process failed to build the client: #{err}"
    assert_empty out.strip,
                 'a freshly built client never gained these methods: require_requests_and_mock ' \
                 'only requires requests the service declares, and these files were never declared'
  end
end
