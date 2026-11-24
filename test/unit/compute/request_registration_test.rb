# frozen_string_literal: true

require 'test_helper'

# FOG-22 (BD-1 fog PR-4): a request file only EXISTS until the service DECLARES
# it. fog-core 2.6's Service#require_requests_and_mock (fog-core-2.6.0,
# service.rb:299) walks the list built by the `request :name` DSL and requires
# exactly those files, and Service.setup_requirements runs that walk on every
# Fog::Compute.new. An undeclared request file is therefore dead weight on a
# real install: no method on Real, no Mock answer, and respond_to? says false.
#
# Every request this repo added after upstream (eject_vm_dvd_drive,
# fetch_url_to_path, get_vm_boot_order, set_vm_boot_order, remove_file) shipped
# without its declaration, and NOTHING in this suite noticed: each request's own
# test file does a direct `require 'fog/hyperv/compute/requests/<name>'` at the
# top, which defines the methods in-process and masks the missing registration.
# The bug surfaced only when foreman_bootdisk's plugin side called
# client.fetch_url_to_path against the INSTALLED gem on the lab controller and
# got NoMethodError while every CI suite stayed green (2026-11-24).
#
# So this test deliberately requires NO request file of its own. It asks the
# three questions a consumer actually asks a freshly built client — is it in
# the service's request list, does the client answer to it, does Real have the
# method — and pins the fork-era five by name so the next request file has to
# cross the line on purpose, the same way the plugin pins its capability words.
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

  def test_service_declares_every_request_file_this_repo_added
    declared = Fog::Hyperv::Compute.requests.map(&:last)
    missing = FORK_REQUESTS.reject { |name| declared.include?(name) }

    assert_empty missing,
                 'these request files exist under compute/requests but no `request :name` in ' \
                 'compute.rb declares them, so fog-core never requires them and no client gains them'
  end

  def test_a_mock_built_client_answers_to_every_request_file_this_repo_added
    was_mocking = Fog.mocking?
    Fog.mock!
    client = Fog::Compute.new(provider: :hyperv, hyperv_username: 'u', hyperv_password: 'p')
    unanswered = FORK_REQUESTS.reject { |name| client.respond_to?(name) }

    assert_empty unanswered,
                 'a mocked client does not answer to these requests: fog-core only registers ' \
                 'declared requests, and these were not declared'
  ensure
    Fog.unmock! unless was_mocking
  end

  def test_real_class_gains_the_methods_when_the_service_loads_its_requests
    # Non-mocked build. Real#initialize composes the WinRM connection eagerly
    # (URI.parse of the endpoint), so the client is given a host — a name it
    # validates and parses but never contacts: WinRM opens its shell on the
    # first request, and this test sends none. The plugin's gates probe
    # respond_to? on exactly this kind of client.
    client = Fog::Compute.new(provider: :hyperv, hyperv_username: 'u', hyperv_password: 'p',
                              hyperv_host: 'labnode.example.com')
    silent = FORK_REQUESTS.reject do |name|
      client.respond_to?(name) && Fog::Hyperv::Compute::Real.method_defined?(name)
    end

    assert_empty silent,
                 'Real never gained these methods: require_requests_and_mock only requires ' \
                 'requests the service declares, and these files were never declared'
  end
end
