describe ManageIQ::Providers::Nutanix::InfraManager::Refresher do
  include Spec::Support::EmsRefreshHelper

  let(:ems)     { FactoryBot.create(:ems_nutanix_with_vcr_authentication) }
  let(:subject) { described_class.new(targets) }

  describe "#refresh" do
    context "full-refresh" do
      let(:targets) { [ems] }

      it "performs a full refresh" do
        with_vcr { subject.refresh }

        assert_counts
        assert_ems_counts
        assert_specific_vm
        assert_specific_template
        assert_specific_host
        assert_specific_cluster
      end
    end

    context "targeted refresh" do
      context "vm" do
        before        { with_vcr { EmsRefresh.refresh(ems) } }
        let(:targets) { [ems.vms.first] }

        it "performs a targeted refresh" do
          with_vcr("targeted_vm") { subject.refresh }

          assert_counts
          assert_ems_counts
          assert_specific_vm
          assert_specific_template
          assert_specific_host
          assert_specific_cluster
        end
      end
    end

    def assert_counts
      expect(Vm.count).to eq(26)
      expect(MiqTemplate.count).to eq(1)
      expect(Host.count).to eq(4)
      expect(EmsCluster.count).to eq(1)
    end

    def assert_ems_counts
      expect(ems.vms.count).to eq(26)
      expect(ems.miq_templates.count).to eq(1)
      expect(ems.hosts.count).to eq(4)
      expect(ems.ems_clusters.count).to eq(1)
    end

    def assert_specific_vm
      vm = ems.vms.find_by(:ems_ref => "12e3f98c-1b75-408c-93eb-acab4ce810da")
      expect(vm).to have_attributes(
        :name        => "Acme-VM1",
        :type        => "ManageIQ::Providers::Nutanix::InfraManager::Vm",
        :ems_ref     => "12e3f98c-1b75-408c-93eb-acab4ce810da",
        :uid_ems     => "12e3f98c-1b75-408c-93eb-acab4ce810da",
        :vendor      => "nutanix",
        :host        => ems.hosts.find_by(:ems_ref => "1458ea7a-5d96-4671-935a-e41cbe3924c1"),
        :ems_cluster => ems.ems_clusters.find_by(:ems_ref => "000633d6-6577-7490-6614-ac1f6b3d8797")
      )

      expect(vm.hardware).to have_attributes(
        :cpu_sockets     => 4,
        :cpu_total_cores => 4,
        :memory_mb       => 8_192
      )

      expect(vm.disks.count).to eq(1)
      expect(vm.disks.first).to have_attributes(
        :device_name => "Disk 0",
        :device_type => "SCSI",
        :location    => "0",
        :filename    => "6a5c077f-c2b2-4762-bde3-fafa3f8d8e12"
      )
    end

    def assert_specific_template
      template = ems.miq_templates.find_by(:ems_ref => "63e3e039-50e0-442b-8a12-8ebd6df818f3")
      expect(template).to have_attributes(
        :name            => "Acme-Ubuntuu-22",
        :type            => "ManageIQ::Providers::Nutanix::InfraManager::Template",
        :ems_ref         => "63e3e039-50e0-442b-8a12-8ebd6df818f3",
        :uid_ems         => "63e3e039-50e0-442b-8a12-8ebd6df818f3",
        :raw_power_state => "never",
        :vendor          => "nutanix"
      )
    end

    def assert_specific_host
      host = ems.hosts.find_by(:ems_ref => "ffb769ef-9599-49f7-8608-4b5d10d076e7")
      expect(host).to have_attributes(
        :name        => "Host-ffb769ef-9599-49f7-8608-4b5d10d076e7",
        :ems_ref     => "ffb769ef-9599-49f7-8608-4b5d10d076e7",
        :type        => "ManageIQ::Providers::Nutanix::InfraManager::Host",
        :ems_cluster => ems.ems_clusters.find_by(:ems_ref => "000633d6-6577-7490-6614-ac1f6b3d8797")
      )
    end

    def assert_specific_cluster
      cluster = ems.ems_clusters.find_by(:ems_ref => "000633d6-6577-7490-6614-ac1f6b3d8797")
      expect(cluster).to have_attributes(
        :ems_ref => "000633d6-6577-7490-6614-ac1f6b3d8797",
        :uid_ems => "000633d6-6577-7490-6614-ac1f6b3d8797",
        :type    => "ManageIQ::Providers::Nutanix::InfraManager::Cluster"
      )
    end
  end
end
