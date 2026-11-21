# frozen_string_literal: true

class Fog::Hyperv::Compute
  class Real
    require 'fog/hyperv/utils/destructive_path'

    # Delete one exact file or folder on the Hyper-V host.
    #
    #   remove_item(path: 'C:\VMs\web1\web1.vhdx', computer_name: 'hv-node2', recurse: true)
    #
    # The path is validated first and sent as -LiteralPath. -Path — what the
    # published gem renders — is wildcard semantics: a machine named web[12] is
    # legal on NTFS, passes every name check this side can run, and reaches
    # Remove-Item as a character class, which then deletes the sibling folders
    # web1 and web2 and leaves web[12] standing. A name that cannot be a
    # literal path is refused here rather than honoured under either render,
    # because the two renders disagree about what the name means and neither
    # answer is safe to pick silently.
    def remove_item(path:, computer_name: nil, **options)
      literal = Fog::Hyperv::Utils::DestructivePath.validate_destructive_path!(path, __method__)

      run_cmd 'Remove-Item', _target_computer: computer_name, _skip_json: true,
                             literal_path: literal, **options
    end
  end
end
