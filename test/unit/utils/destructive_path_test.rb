# frozen_string_literal: true

require 'test_helper'

require 'fog/hyperv/utils/destructive_path'

# FOG-14: a path handed to a destructive cmdlet has to name one provable
# location. The published gem renders Remove-Item with -Path, which is wildcard
# semantics: a machine named web[12] passes every equality check this side runs,
# yet Remove-Item -Recurse -Force expands web[12] to web1 and web2 — deleting
# the siblings and leaving itself. These tests refuse every path shape whose
# deletion scope cannot be pinned down, and they refuse it client-side, before
# any of it reaches the wire.
class UnitDestructivePathTest < Minitest::Test
  VALID = [
    'C:\VMs\web1\web1.vhdx',
    'C:\ClusterStorage\Volume1\web 10\disk 1.vhdx', # spaces are legal in names
    "C:\\VMs\\it's\\disk.vhdx",                     # apostrophes are legal too
    '\\hyperv-n1\share\web1\web1.vhdx',             # UNC paths are legal
    'C:\VMs\web1\web1.vhdx.avhdx'                   # dots mid-name are legal
  ].freeze

  def test_accepts_an_ordinary_path_and_returns_it
    VALID.each do |path|
      assert_equal path, Fog::Hyperv::Utils::DestructivePath.validate_destructive_path!(path, 'remove_item')
    end
  end

  def test_refuses_nothing_at_all
    [nil, '', '   '].each do |blank|
      error = assert_raises(Fog::Hyperv::Errors::InvalidDestructivePath) do
        Fog::Hyperv::Utils::DestructivePath.validate_destructive_path!(blank, 'remove_item')
      end
      assert_includes error.message, 'remove_item'
    end
  end

  # The shape destroy used to send: the file plus a "#{path}.*" sibling glob.
  # A list is a scope, not a path, and the glob in it is exactly what this
  # refuses, so the old argument has to fail rather than be quietly honoured.
  def test_refuses_a_list_of_paths
    assert_raises(Fog::Hyperv::Errors::InvalidDestructivePath) do
      Fog::Hyperv::Utils::DestructivePath.validate_destructive_path!(
        ['C:\VMs\web1\web1.vhdx', 'C:\VMs\web1\web1.vhdx.*'], 'remove_item'
      )
    end
  end

  # Every character PowerShell expands. The bracket case is the one a real
  # machine name hits — [12] is a legal NTFS name and a wildcard to -Path.
  def test_refuses_each_wildcard_character
    [
      'C:\VMs\web[12]\disk.vhdx',
      'C:\VMs\web*\disk.vhdx',
      'C:\VMs\web?.vhdx',
      'C:\VMs\web[1*.vhdx',
      'C:\VMs\web1].vhdx'
    ].each do |path|
      error = assert_raises(Fog::Hyperv::Errors::InvalidDestructivePath) do
        Fog::Hyperv::Utils::DestructivePath.validate_destructive_path!(path, 'remove_item')
      end
      assert_includes error.message, 'wildcard'
    end
  end

  def test_refuses_a_path_that_is_not_a_string
    [123, :disk, { path: 'C:\VMs\web1.vhdx' }, true].each do |value|
      assert_raises(Fog::Hyperv::Errors::InvalidDestructivePath) do
        Fog::Hyperv::Utils::DestructivePath.validate_destructive_path!(value, 'remove_item')
      end
    end
  end

  # The folder cleanup is licensed by one thing only: a successful enumeration
  # that found nothing. Test-Path is not it — Test-Path answers $false for an
  # access-denied folder as readily as for an empty one, and the guard it sat in
  # deleted recursively when it answered $false.
  def test_the_folder_script_asks_for_an_enumeration_not_a_test_path
    script = Fog::Hyperv::Utils::DestructivePath.build_empty_folder_removal_script('C:\VMs\web1')

    assert_includes script, 'Get-ChildItem -LiteralPath'
    refute_includes script, 'Test-Path'
    refute_includes script, '-Recurse'
  end

  # The count guard sits between the enumeration and the delete: zero found,
  # then delete — never "not found", then delete.
  def test_the_folder_script_deletes_only_after_a_zero_count
    script = Fog::Hyperv::Utils::DestructivePath.build_empty_folder_removal_script('C:\VMs\web1')

    assert_includes script, "Remove-Item -LiteralPath 'C:\\VMs\\web1'"
    assert_match(/Count -eq 0.*Remove-Item/m, script)
  end

  # An apostrophe is legal in a machine name and would otherwise terminate the
  # single-quoted literal the path rides in.
  def test_the_folder_script_escapes_quotes_in_the_path
    script = Fog::Hyperv::Utils::DestructivePath.build_empty_folder_removal_script("C:\\VMs\\it's")

    assert_includes script, "'C:\\VMs\\it''s'"
  end

  # A wildcard path can never be a provable folder either; the script builder
  # refuses it rather than emitting -LiteralPath around something that used to
  # be handed to -Path.
  def test_the_folder_script_refuses_an_unprovable_path
    assert_raises(Fog::Hyperv::Errors::InvalidDestructivePath) do
      Fog::Hyperv::Utils::DestructivePath.build_empty_folder_removal_script('C:\VMs\web[12]')
    end
  end
end
