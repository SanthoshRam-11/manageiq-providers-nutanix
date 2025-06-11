class ManageIQ::Providers::Nutanix::Inventory::Collector::TargetCollection < ManageIQ::Providers::Nutanix::Inventory::Collector
  def initialize(_manager, _target)
    super
    parse_targets!
    infer_related_ems_refs!

    # Reset the target cache, so we can access new targets inside
    target.manager_refs_by_association_reset
  end

  def clusters
    return [] if references(:clusters).blank?
    return @clusters if @clusters

    clusters_api = NutanixClustermgmt::ClustersApi.new(cluster_mgmt_connection)
    @clusters = references(:clusters).map do |cluster_ref|
      clusters_api.get_cluster_by_id(cluster_ref).data
    end
  end

  def hosts
    return [] if references(:hosts).blank?
    return @hosts if @hosts

    clusters_api = NutanixClustermgmt::ClustersApi.new(cluster_mgmt_connection)
    @hosts = references(:hosts).map do |host_ref|
      clusters_api.get_host_by_id(host_ref).data
    end
  end

  def datastores
    return [] if references(:datastores).blank?
    return @datastores if @datastores

    storage_containers_api = NutanixClustermgmt::StorageContainersApi.new(cluster_mgmt_connection)
    @datastores = references(:datastores).map do |datastore_ref|
      storage_containers_api.get_storage_container_by_id(datastore_ref).data
    end
  end

  def templates
    return [] if references(:miq_templates).blank?
    return @templates if @templates

    template_api = NutanixVmm::TemplatesApi.new(vmm_connection)
    @templates = references(:miq_templates).map do |template_ref|
      template_api.get_template_by_id_0(template_ref).data
    end
  end

  def vms
    return [] if references(:vms).blank?
    return @vms if @vms

    vms_api = NutanixVmm::VmApi.new(vmm_connection)
    @vms = references(:vms).map do |vm_ref|
      vms_api.get_vm_by_id_0(vm_ref).data
    end
  end

  private

  def parse_targets!
    target.targets.each do |t|
      case t
      when Vm
        add_target!(:vms, t.ems_ref)
      when MiqTemplate
        add_target!(:miq_templates, t.ems_ref)
      when Host
        add_target!(:hosts, t.ems_ref)
      when Storage
        add_target(:storages, t.ems_ref)
      when Cluster
        add_target(:clusters, t.ems_ref)
      end
    end
  end

  def infer_related_ems_refs!
  end
end
