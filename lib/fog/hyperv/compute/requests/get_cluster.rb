# frozen_string_literal: true

class Fog::Hyperv::Compute
  class Real
    def get_cluster(**options)
      by_id = options.delete(:id)

      run_cmd 'Get-Cluster', _by_id: by_id, **options
    end
  end

  class Mock
    def get_cluster(**args)
      data = handle_mock_response(**args)

      # _by_id and name are filtered by the real request on the host itself, so the
      # mock has to filter too: without this, asking for one cluster answers with
      # whichever cluster the fixture happens to hold, and an identifier that
      # matches nothing answers with that same cluster. Callers arrive with the
      # identifier either as _by_id (Clusters#get) or as id (Cluster#reload), which
      # the real request folds together before it builds the PowerShell.
      id = args[:_by_id] || args[:id]
      data = data.select { |cluster| cluster[:id] == id } if id
      data = data.select { |cluster| cluster[:name] == args[:name] } if args[:name]
      data
    end
  end
end
