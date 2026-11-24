# frozen_string_literal: true

require 'test_helper'

require 'fog/hyperv/utils/contained_path'

# FOG-21: ContainedPath decides the one question a file delete in a
# caller-configured directory cannot ask the remote cmdlet — "is this location
# inside the scope the operator's setting allows". The predicate is tested on its
# own because it is a pure function over two strings and every interesting case
# of it (case folding, separator equivalence, a sibling whose name merely starts
# like the root, a `..` nobody resolved) is a comparison, not a wire behaviour.
class UnitContainedPathTest < Minitest::Test
  ROOT = 'C:\ClusterStorage\Volume1\foreman-bootdisk'

  # --- the predicate ---------------------------------------------------------

  def test_a_path_directly_inside_the_root_is_contained
    assert Fog::Hyperv::Utils::ContainedPath.contained?("#{ROOT}\\a.iso", ROOT)
  end

  def test_the_root_contains_itself
    assert Fog::Hyperv::Utils::ContainedPath.contained?(ROOT, ROOT)
  end

  # NTFS folds case in a comparison, so a store configured with a different case
  # than the path was built with is still the same directory.
  def test_case_makes_no_difference
    assert Fog::Hyperv::Utils::ContainedPath.contained?("#{ROOT.upcase}\\A.ISO", ROOT.downcase)
  end

  # NTFS honours '/' as a separator. A comparison that looked only at '\' would
  # call C:/ClusterStorage/Volume1/foreman-bootdisk/a.iso outside a root written
  # with backslashes, and the reverse would call it inside when it is not.
  def test_a_separator_makes_no_difference_either_way
    assert Fog::Hyperv::Utils::ContainedPath.contained?("#{ROOT.tr('\\', '/')}\\a.iso", ROOT)
    assert Fog::Hyperv::Utils::ContainedPath.contained?("#{ROOT}\\a.iso", ROOT.tr('\\', '/'))
  end

  def test_a_trailing_separator_on_either_side_makes_no_difference
    assert Fog::Hyperv::Utils::ContainedPath.contained?("#{ROOT}\\a.iso", "#{ROOT}\\")
    assert Fog::Hyperv::Utils::ContainedPath.contained?("#{ROOT}\\", ROOT)
  end

  # The prefix rule without a boundary is the bug this exists to avoid:
  # foreman-bootdisk-old is a sibling, not a child, and a delete allowed there is
  # a delete outside the store.
  def test_a_sibling_whose_name_starts_like_the_root_is_not_contained
    refute Fog::Hyperv::Utils::ContainedPath.contained?("#{ROOT}-old\\a.iso", ROOT)
  end

  def test_a_parent_is_not_contained
    refute Fog::Hyperv::Utils::ContainedPath.contained?('C:\ClusterStorage\Volume1', ROOT)
  end

  def test_a_drive_root_contains_any_path_on_that_drive
    assert Fog::Hyperv::Utils::ContainedPath.contained?('C:\VMs\a.iso', 'C:\\')
    refute Fog::Hyperv::Utils::ContainedPath.contained?('D:\VMs\a.iso', 'C:\\')
  end

  def test_a_unc_share_behaves_like_a_drive_letter
    assert Fog::Hyperv::Utils::ContainedPath.contained?('\\hv-node1\bootdisk\a.iso', '\\hv-node1\bootdisk')
    refute Fog::Hyperv::Utils::ContainedPath.contained?('\\hv-node1\bootdisk-old\a.iso', '\\hv-node1\bootdisk')
  end

  # Nothing here resolves a link or a `..`, because nothing here knows the host's
  # file system. An unresolved `..` is a location the comparison cannot vouch for,
  # so the answer is "not contained" — refused, not guessed.
  def test_an_unresolved_traversal_is_not_contained
    refute Fog::Hyperv::Utils::ContainedPath.contained?("#{ROOT}\\..\\a.iso", ROOT)
    refute Fog::Hyperv::Utils::ContainedPath.contained?("#{ROOT}\\a.iso", "#{ROOT}\\..")
  end

  def test_nothing_is_contained_in_nothing
    refute Fog::Hyperv::Utils::ContainedPath.contained?(nil, ROOT)
    refute Fog::Hyperv::Utils::ContainedPath.contained?("#{ROOT}\\a.iso", nil)
    refute Fog::Hyperv::Utils::ContainedPath.contained?(['C:\a.iso'], ROOT)
  end

  # --- the refusal -----------------------------------------------------------

  def test_the_validator_returns_the_path_it_was_given
    assert_equal "#{ROOT}\\a.iso", Fog::Hyperv::Utils::ContainedPath.validate_contained!("#{ROOT}\\a.iso", ROOT, 'req')
  end

  def test_the_refusal_names_both_sides
    error = assert_raises(Fog::Hyperv::Errors::InvalidDestructivePath) do
      Fog::Hyperv::Utils::ContainedPath.validate_contained!('C:\VMs\a.iso', ROOT, 'remove_file')
    end

    # The path refused, the root it is refused against, and the request that
    # refused: an operator reading this in a Foreman task trace has to be able to
    # tell which setting to fix without opening the gem.
    ['C:\VMs\a.iso', ROOT, 'remove_file'].each do |named|
      assert_includes error.message, named
    end
  end

  def test_a_relative_or_drive_relative_path_is_refused
    assert_raises(Fog::Hyperv::Errors::InvalidDestructivePath) do
      Fog::Hyperv::Utils::ContainedPath.validate_contained_path!('bootdisk\a.iso', 'req')
    end
    assert_raises(Fog::Hyperv::Errors::InvalidDestructivePath) do
      Fog::Hyperv::Utils::ContainedPath.validate_contained_path!('C:bootdisk\a.iso', 'req')
    end
  end

  # The single quote is the one character outside the Foreman side's SAFE_PATH
  # that this side accepts: NTFS allows it in a name and the script escapes it by
  # doubling, so refusing it here would make a legal file name unreachable.
  def test_a_single_quote_is_accepted_where_every_other_quoting_character_is_not
    assert_equal "#{ROOT}\\it's.iso", Fog::Hyperv::Utils::ContainedPath.validate_contained_path!("#{ROOT}\\it's.iso", 'req')

    ['"', '$', '`', ';', '|', '<', '>', "\t"].each do |ch|
      assert_raises Fog::Hyperv::Errors::InvalidDestructivePath do
        Fog::Hyperv::Utils::ContainedPath.validate_contained_path!("#{ROOT}\\a#{ch}b.iso", 'req')
      end
    end
  end

  # --- the script ------------------------------------------------------------

  def test_the_script_doubles_a_quote_in_the_name
    script = Fog::Hyperv::Utils::ContainedPath.build_file_removal_script("#{ROOT}\\it's.iso")

    assert_includes script, "'#{ROOT}\\it''s.iso'"
  end

  def test_the_script_revalidates_so_no_caller_can_reach_the_literal_unchecked
    assert_raises Fog::Hyperv::Errors::InvalidDestructivePath do
      Fog::Hyperv::Utils::ContainedPath.build_file_removal_script("#{ROOT}\\a[1].iso")
    end
  end
end
